//! The bag of a pattern: `key=value` entries, calls (`v(out)=1`), bare
//! pairs and flags in any order, each bound to the slot the grammar names
//! for it or kept as a parameter.
//!
//! Contents:
//! - `pub fn bag(self: *Matcher, node: *const Node, rest: []const Node, ti: usize,
//!   k: ?*const Cont) Allocator.Error!bool`
//! - `pub fn bagEntry(self: *Matcher, node: *const Node, key: []const u8, key_raw: []const u8,
//!   vt: Tok) Allocator.Error!bool`

const std = @import("std");
const grammar = @import("grammar");
const ir = @import("ir");
const lexer = @import("lexer");
const matcher = @import("matcher.zig");
const assert = std.debug.assert;
const Matcher = matcher.Matcher;
const Capture = matcher.Capture;
const Cont = matcher.Cont;
const Allocator = std.mem.Allocator;
const Node = grammar.Node;
const Tok = lexer.Tok;
const Value = ir.Value;

/// The entries of a bag from `ti`, then what follows it. Fails where an
/// entry the bag requires is missing.
pub inline fn bag(
    self: *Matcher,
    node: *const Node,
    rest: []const Node,
    ti: usize,
    k: ?*const Cont,
) Allocator.Error!bool {
    const mark = self.log.items.len;
    var j = ti;
    // Each entry moves past at least one word, and the line ends in a token that is none.
    while (self.toks()[j].tag == .word) j = (try entryAt(self, node, j)) orelse break;
    if (!requiredSeen(self, node, mark)) {
        self.log.shrinkRetainingCapacity(mark);
        return false;
    }
    if (try self.m(rest, j, k)) return true;
    self.log.shrinkRetainingCapacity(mark);
    return false;
}

/// Bind one `key=value` pair. False means the pair does not belong to this bag.
pub fn bagEntry(
    self: *Matcher,
    node: *const Node,
    key: []const u8,
    key_raw: []const u8,
    vt: Tok,
) Allocator.Error!bool {
    assert(node.tag == .bag);
    var rest_slot: ?u8 = null;
    for (node.bag) |e| {
        if (e.form == .rest) {
            rest_slot = e.slot;
            continue;
        }
        if (e.form == .call or !std.mem.eql(u8, e.key, key)) continue;
        if (e.also) {
            if (try saidAgain(self, e, vt)) return true;
            continue;
        }
        if (!try entryValue(self, e, vt)) return false;
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

// ---- private ----

/// The entry of the bag at word `j`: where the next one starts, or null
/// where the bag ends before it.
fn entryAt(self: *Matcher, node: *const Node, j: usize) Allocator.Error!?usize {
    const kt = self.toks()[j];
    assert(kt.tag == .word);
    if (kt.f.key and self.toks()[j + 1].tag == .eq) return keyValue(self, node, j);
    if (kt.f.call) return callEntry(self, node, j);
    // `n1 1`: a bare key and its value, where the bag takes them.
    if (for (node.bag) |e| {
        if (e.form == .call and e.bare_pairs) break e;
    } else null) |entry| {
        const vt = self.toks()[j + 1];
        if (vt.tag != .word or vt.f.key) return null;
        const v = (try self.anyValue(vt, kt.text)) orelse return null;
        try self.log.append(
            self.arena,
            .{ .slot = entry.slot, .key = kt.raw, .val = v },
        );
        return j + 2;
    }
    // A bare word is a flag where the bag accepts flags.
    const flags = for (node.bag) |e| {
        if (e.form == .rest and e.flags) break e;
    } else return null;
    // A declared model is no flag: a longer form names it
    // (`Q c b e s tj model`).
    if (!lexer.isIdent(kt.text) or self.declared.contains(kt.text)) return null;
    try self.log.append(
        self.arena,
        .{ .slot = flags.slot, .key = kt.raw, .val = .none },
    );
    return j + 1;
}

/// `key=value` at `j`, and the numbers after it where they are its matrix.
fn keyValue(self: *Matcher, node: *const Node, j: usize) Allocator.Error!?usize {
    const kt = self.toks()[j];
    const vt = self.toks()[j + 2];
    if (vt.tag == .nl or vt.tag == .eq) return null;
    const before = self.log.items.len;
    if (!try self.bagEntry(node, kt.text, kt.raw, vt)) return null;
    const next = j + 3;
    // `R=0.2 0 0.2`: the numbers after one open-ended
    // key are its matrix (CPL and RLGC line models).
    if (self.log.items.len == before) return next;
    const last: *Capture = &self.log.items[self.log.items.len - 1];
    if (last.key.len > 0 and last.val == .num and
        self.toks()[next].tag == .word and !self.toks()[next].f.key and
        self.number(self.toks()[next]) != null)
    {
        return try matrix(self, last, next);
    }
    return next;
}

/// The numbers from `from` on, after the value `last` already holds, as
/// one list: its matrix. Where the numbers end.
fn matrix(self: *Matcher, last: *Capture, from: usize) Allocator.Error!usize {
    var j = from;
    var list: std.ArrayList(Value) = .empty;
    try list.append(self.arena, last.val);
    while (self.toks()[j].tag == .word and !self.toks()[j].f.key) : (j += 1) {
        try list.append(
            self.arena,
            .{ .num = self.number(self.toks()[j]) orelse break },
        );
    }
    last.val = .{ .list = list.items };
    return j;
}

/// `v(out)=1` at `j`: the call's argument is the key.
fn callEntry(self: *Matcher, node: *const Node, j: usize) Allocator.Error!?usize {
    const kt = self.toks()[j];
    assert(kt.f.call);
    const entry = for (node.bag) |e| {
        if (e.form == .call and std.mem.eql(u8, e.key, kt.text)) break e;
    } else return null;
    const tokens = !self.g.lex.parens_are_space;
    var a = j + 1;
    if (tokens) {
        if (self.toks()[a].tag != .lparen) return null;
        a += 1;
    }
    const nt = self.toks()[a];
    if (nt.tag != .word) return null;
    var b = a + 1;
    if (tokens) {
        if (self.toks()[b].tag != .rparen) return null;
        b += 1;
    }
    if (self.toks()[b].tag != .eq) return null;
    const v = (try self.anyValue(self.toks()[b + 1], "")) orelse return null;
    try self.log.append(
        self.arena,
        .{ .slot = entry.slot, .key = nt.raw, .val = v },
    );
    return b + 2;
}

/// Does every entry the bag requires have a value among the captures since `mark`?
fn requiredSeen(self: *const Matcher, node: *const Node, mark: usize) bool {
    for (node.bag) |e| {
        if (!e.required) continue;
        var seen = false;
        const want = if (e.form == .fixed) e.tag_slot else e.slot;
        for (self.log.items[mark..]) |c| {
            if (c.slot == want and c.key.len == 0) seen = true;
        }
        if (!seen) return false;
    }
    return true;
}

/// `reli=reltol+`: the same value again is the one slot said twice. Said
/// by an earlier option statement (Xyce files one reltol under three
/// headings): this statement holds it too.
fn saidAgain(self: *Matcher, e: grammar.BagEntry, vt: Tok) Allocator.Error!bool {
    assert(e.also);
    const v = (try self.toValue(self.slot(e.slot).ty, vt)) orelse return false;
    for (self.log.items) |c| {
        if (c.slot == e.slot and c.key.len == 0 and c.val.eql(v)) return true;
    }
    if (self.kind == .options) for (self.said.items) |c| {
        if (c.slot != e.slot or !c.val.eql(v)) continue;
        try self.log.append(self.arena, .{ .slot = e.slot, .val = v });
        return true;
    };
    return false;
}

/// The value of an entry of a fixed form. False where the token is not
/// one this form takes.
fn entryValue(self: *Matcher, e: grammar.BagEntry, vt: Tok) Allocator.Error!bool {
    assert(!e.also);
    switch (e.form) {
        .fixed => return std.mem.eql(u8, vt.raw, e.fixed),
        .plain => {
            const v = (try self.toValue(self.slot(e.slot).ty, vt)) orelse return false;
            try self.log.append(self.arena, .{ .slot = e.slot, .val = v });
        },
        .quoted => {
            if (vt.tag != .str and vt.tag != .word) return false;
            const text = try self.own(vt);
            if (e.suffix.len > 0 and
                (text.len <= e.suffix.len or !std.mem.endsWith(u8, text, e.suffix))) return false;
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
        .pairs => return self.pairs(e.slot, vt),
        .pair => return pairEntry(self, e, vt),
        .rest, .call => unreachable,
    }
    return true;
}

/// Two names, as one word or string, or as a vector of two.
fn pairEntry(self: *Matcher, e: grammar.BagEntry, vt: Tok) Allocator.Error!bool {
    assert(e.form == .pair);
    if (vt.tag == .str or vt.tag == .word) {
        try self.log.append(
            self.arena,
            .{ .slot = e.slot, .val = .{ .atom = try self.own(vt) } },
        );
        return true;
    }
    if (vt.tag != .vec) return false;
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
    return true;
}
