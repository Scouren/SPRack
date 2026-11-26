//! Captures of the matcher that take more than one token: runs of
//! tokens joined back into text, and the `key=value` entries of a bag.

const std = @import("std");
const grammar = @import("grammar");
const ir = @import("ir");
const lexer = @import("lexer");
const matcher = @import("matcher.zig");
const Matcher = matcher.Matcher;
const Allocator = std.mem.Allocator;
const Node = grammar.Node;
const Tok = lexer.Tok;
const Value = ir.Value;

/// The end of a run of tokens, balanced in parentheses, that stops at an
/// unmatched `)`. Null if the line ends first or the run is empty.
pub fn parenRun(self: *const Matcher, ti: usize) ?usize {
    var depth: usize = 0;
    var j = ti;
    while (j < self.toks().len) : (j += 1) {
        switch (self.toks()[j].tag) {
            .nl => return null,
            .lparen => depth += 1,
            .rparen => {
                if (depth == 0) return if (j > ti) j else null;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

pub fn joinRaw(self: *const Matcher, from: usize, to: usize) Allocator.Error![]const u8 {
    // `((a > 1))` is `(a > 1)`: drop parentheses around the whole run.
    var a = from;
    var b = to;
    while (b - a >= 2 and self.toks()[a].tag == .lparen and self.parenRun(a + 1) == b - 1) {
        a += 1;
        b -= 1;
    }
    return self.joinTokens(a, b);
}

/// The text the tokens were cut from. On one line that is the line's
/// own text between them: the lexer cuts `a == b` at each `=`, and the
/// pieces joined with a blank each would be `a = = b`.
pub fn joinTokens(self: *const Matcher, from: usize, to: usize) Allocator.Error![]const u8 {
    const ts = self.toks()[from..to];
    if (ts.len > 0 and ts[0].lno == ts[ts.len - 1].lno) {
        const start = @intFromPtr(ts[0].raw.ptr);
        const end = @intFromPtr(ts[ts.len - 1].raw.ptr) + ts[ts.len - 1].raw.len;
        if (end >= start) return self.arena.dupe(u8, ts[0].raw.ptr[0 .. end - start]);
    }
    var out: std.ArrayList(u8) = .empty;
    for (self.toks()[from..to], 0..) |t, i| {
        if (i > 0 and t.tag != .rparen and self.toks()[from + i - 1].tag != .lparen)
            try out.append(self.arena, ' ');
        try out.appendSlice(self.arena, t.raw);
    }
    return out.toOwnedSlice(self.arena);
}

pub fn capOne(self: *const Matcher, node: *const Node, t: Tok) Allocator.Error!?Value {
    if (node.slot == grammar.wild_slot)
        return if (t.tag == .word and !t.f.key) .{ .atom = t.text } else null;
    const v = (try self.toValue(self.slot(node.slot).ty, t)) orelse return null;
    if (node.prefix.len > 0 and !std.mem.startsWith(u8, t.text, node.prefix)) return null;
    return v;
}

/// Bind one `key=value` pair. False means the pair does not belong to this bag.
pub fn bagEntry(
    self: *Matcher,
    node: *const Node,
    key: []const u8,
    key_raw: []const u8,
    vt: Tok,
) Allocator.Error!bool {
    var rest_slot: ?u8 = null;
    for (node.bag) |e| {
        if (e.form == .rest) {
            rest_slot = e.slot;
            continue;
        }
        if (e.form == .call or !std.mem.eql(u8, e.key, key)) continue;
        if (e.also) {
            // `reli=reltol+`: the same value again is the one slot said twice.
            const v = (try self.toValue(self.slot(e.slot).ty, vt)) orelse continue;
            for (self.log.items) |c| {
                if (c.slot == e.slot and c.key.len == 0 and c.val.eql(v)) return true;
            }
            // Said by an earlier option statement (Xyce files one reltol
            // under three headings): this statement holds it too.
            if (self.kind == .options) for (self.said.items) |c| {
                if (c.slot != e.slot or !c.val.eql(v)) continue;
                try self.log.append(self.arena, .{ .slot = e.slot, .val = v });
                return true;
            };
            continue;
        }
        switch (e.form) {
            .fixed => if (!std.mem.eql(u8, vt.raw, e.fixed)) return false,
            .plain => {
                const v = (try self.toValue(self.slot(e.slot).ty, vt)) orelse return false;
                try self.log.append(self.arena, .{ .slot = e.slot, .val = v });
            },
            .quoted => {
                if (vt.tag != .str and vt.tag != .word) return false;
                const text = try self.own(vt);
                if (e.suffix.len > 0 and (text.len <= e.suffix.len or !std.mem.endsWith(u8, text, e.suffix))) return false;
                try self.log.append(
                    self.arena,
                    .{ .slot = e.slot, .val = .{ .atom = text[0 .. text.len - e.suffix.len] } },
                );
            },
            .vector => {
                if (vt.tag != .vec) return false;
                for (try self.vector(vt.text)) |v|
                    try self.log.append(self.arena, .{ .slot = e.slot, .val = v });
            },
            .pairs => if (!try self.pairs(e.slot, vt)) return false,
            .pair => {
                if (vt.tag == .str or vt.tag == .word) {
                    try self.log.append(
                        self.arena,
                        .{ .slot = e.slot, .val = .{ .atom = try self.own(vt) } },
                    );
                } else if (vt.tag == .vec) {
                    const items = try self.vector(vt.text);
                    if (items.len != 2) return false;
                    for ([_]u8{ e.slot, e.slot2 }, items) |sl, it| {
                        const raw: []const u8 = switch (it) {
                            .str, .atom, .expr => |x| x,
                            else => return false,
                        };
                        const name = if (raw.len >= 2 and raw[0] == '"' and
                            raw[raw.len - 1] == '"')
                            raw[1 .. raw.len - 1]
                        else
                            raw;
                        if (name.len == 0) return false;
                        try self.log.append(
                            self.arena,
                            .{ .slot = sl, .val = .{ .atom = name } },
                        );
                    }
                } else return false;
            },
            .rest, .call => unreachable,
        }
        if (e.tag_slot != grammar.no_slot) {
            try self.log.append(
                self.arena,
                .{ .slot = e.tag_slot, .val = .{ .atom = e.tag_atom } },
            );
        }
        return true;
    }
    const rs = rest_slot orelse return false;
    const v = (try self.anyValue(vt, key)) orelse return false;
    try self.log.append(self.arena, .{ .slot = rs, .key = key_raw, .val = v });
    return true;
}
