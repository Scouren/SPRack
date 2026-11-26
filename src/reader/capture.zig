//! Captures of the matcher: a slot's value taken from one token, from a run
//! of them (a recorded signal, a counted run, a list, the expression up to
//! a `)`), or from the rest of the line; and runs of tokens joined back
//! into the text they were cut from.
//!
//! Contents:
//! - `pub fn cap(self: *Matcher, node: *const Node, rest: []const Node, ti: usize,
//!   k: ?*const Cont) Allocator.Error!bool`
//! - `pub fn restOfLine(self: *Matcher, node: *const Node, rest: []const Node, ti: usize,
//!   k: ?*const Cont) Allocator.Error!bool`
//! - `pub fn parenRun(self: *const Matcher, ti: usize) ?usize`
//! - `pub fn joinRaw(self: *const Matcher, from: usize, to: usize) Allocator.Error![]const u8`
//! - `pub fn joinTokens(self: *const Matcher, from: usize, to: usize) Allocator.Error![]const u8`
//! - `pub fn capOne(self: *const Matcher, node: *const Node, t: Tok) Allocator.Error!?Value`

const std = @import("std");
const grammar = @import("grammar");
const ir = @import("ir");
const lexer = @import("lexer");
const matcher = @import("matcher.zig");
const assert = std.debug.assert;
const Matcher = matcher.Matcher;
const Cont = matcher.Cont;
const Allocator = std.mem.Allocator;
const Node = grammar.Node;
const Tok = lexer.Tok;
const Value = ir.Value;

/// A capture node: recorded signals, a counted run, a list, or one token.
pub inline fn cap(
    self: *Matcher,
    node: *const Node,
    rest: []const Node,
    ti: usize,
    k: ?*const Cont,
) Allocator.Error!bool {
    if (node.slot != grammar.wild_slot and self.slot(node.slot).ty == .signal)
        return capSignals(self, node, rest, ti, k);
    self.allow_key = Matcher.beforeEq(rest);
    defer self.allow_key = false;
    if (node.count != grammar.no_slot) return capCounted(self, node, rest, ti, k);
    if (node.star or node.plus) return capList(self, node, rest, ti, k);
    return capSingle(self, node, rest, ti, k);
}

/// The rest of the line: one expression where the slot holds a value
/// (`.if (a > b)`), else its text.
pub inline fn restOfLine(
    self: *Matcher,
    node: *const Node,
    rest: []const Node,
    ti: usize,
    k: ?*const Cont,
) Allocator.Error!bool {
    assert(node.tag == .rest);
    const mark = self.log.items.len;
    const text = lineAfter(self, ti);
    var j = ti;
    while (self.toks()[j].tag != .nl) j += 1;
    if (node.slot != grammar.wild_slot) {
        if (self.slot(node.slot).ty == .value) {
            // The rest of the line is one expression: `.if (a > b)`.
            if (text.len == 0) return false;
            try self.log.append(
                self.arena,
                .{ .slot = node.slot, .val = .{ .expr = unwrapParens(text) } },
            );
        } else if (text.len > 0) {
            try self.log.append(self.arena, .{ .slot = node.slot, .val = .{ .atom = text } });
        }
    }
    if (try self.m(rest, j, k)) return true;
    self.log.shrinkRetainingCapacity(mark);
    return false;
}

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
    assert(from <= to);
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

// ---- private ----

/// Signals may span several tokens, so they are taken greedily and never
/// given back.
inline fn capSignals(
    self: *Matcher,
    node: *const Node,
    rest: []const Node,
    ti: usize,
    k: ?*const Cont,
) Allocator.Error!bool {
    assert(node.slot != grammar.wild_slot);
    const mark = self.log.items.len;
    var j = ti;
    var n: usize = 0;
    while (try self.signalAt(j)) |sig| {
        try self.log.append(self.arena, .{ .slot = node.slot, .val = sig.v });
        j += sig.n;
        n += 1;
        if (!(node.star or node.plus)) break;
    }
    if (n == 0 and !node.star) return false;
    if (try self.m(rest, j, k)) return true;
    self.log.shrinkRetainingCapacity(mark);
    return false;
}

/// As many tokens as a count captured earlier says.
inline fn capCounted(
    self: *Matcher,
    node: *const Node,
    rest: []const Node,
    ti: usize,
    k: ?*const Cont,
) Allocator.Error!bool {
    const mark = self.log.items.len;
    const want = self.countOf(node.count) orelse return false;
    for (0..want) |i| {
        const v = (try self.capOne(node, self.toks()[ti + i])) orelse {
            self.log.shrinkRetainingCapacity(mark);
            return false;
        };
        try self.log.append(self.arena, .{ .slot = node.slot, .val = v });
    }
    if (try self.m(rest, ti + want, k)) return true;
    self.log.shrinkRetainingCapacity(mark);
    return false;
}

/// Greedy, then give items back one at a time.
inline fn capList(
    self: *Matcher,
    node: *const Node,
    rest: []const Node,
    ti: usize,
    k: ?*const Cont,
) Allocator.Error!bool {
    assert(node.star or node.plus);
    const mark = self.log.items.len;
    var ends: std.ArrayList(usize) = .empty;
    try takeList(self, node, rest, ti, &ends);
    const wild = node.slot == grammar.wild_slot;
    const least: usize = if (node.plus) 1 else 0;
    // Bounded by the items taken: each pass that goes on gives one back.
    while (true) {
        const n = ends.items.len;
        if (n >= least and try self.m(
            rest,
            if (n == 0) ti else ends.items[n - 1],
            k,
        )) return true;
        if (n <= least) break;
        _ = ends.pop();
        if (!wild) self.log.shrinkRetainingCapacity(mark + n - 1);
    }
    self.log.shrinkRetainingCapacity(mark);
    return false;
}

/// The items of a list from `ti`, as many as there are, each logged, and
/// where each ends. An item of a list of words may be a `key=value` among
/// them (a PAT source's `r=1 rb=2` between its bit groups): one item of
/// three tokens, so the ends are kept.
// tidy: allow(inline-always-large) one caller, inlined into `m` as before it was split
inline fn takeList(
    self: *Matcher,
    node: *const Node,
    rest: []const Node,
    ti: usize,
    ends: *std.ArrayList(usize),
) Allocator.Error!void {
    assert(ends.items.len == 0);
    var at = ti;
    const wild = node.slot == grammar.wild_slot;
    // Not where an `=` follows the list (`.param f(x)='x'`).
    const words = !wild and self.slot(node.slot).ty == .atom and !self.allow_key;
    // Bounded by the line: each item takes a token, and its `nl` is no item.
    while (true) {
        const t0 = self.toks()[at];
        if (words and ends.items.len > 0 and keyPairAt(self, at)) {
            try self.log.append(
                self.arena,
                .{ .slot = node.slot, .val = .{ .atom = try self.joinTokens(at, at + 3) } },
            );
            at += 3;
            try ends.append(self.arena, at);
            continue;
        }
        const v = (try self.capOne(node, t0)) orelse break;
        if (Matcher.followLit(rest, t0)) break;
        if (!wild)
            try self.log.append(self.arena, .{ .slot = node.slot, .val = v });
        at += 1;
        try ends.append(self.arena, at);
    }
}

/// A key, `=` and a word or expression at `at`.
fn keyPairAt(self: *const Matcher, at: usize) bool {
    const ts = self.toks();
    return ts[at].f.key and ts[at + 1].tag == .eq and
        (ts[at + 2].tag == .word or ts[at + 2].tag == .expr);
}

/// One token. `if (a > 1)`: where a dialect lexes parentheses as tokens
/// and the pattern closes one right after a value, everything up to that
/// `)` is the expression, whether its first token is no value (`(`) or one
/// the `)` does not follow (`a`).
// tidy: allow(inline-always-large) one caller, inlined into `m` as before it was split
inline fn capSingle(
    self: *Matcher,
    node: *const Node,
    rest: []const Node,
    ti: usize,
    k: ?*const Cont,
) Allocator.Error!bool {
    assert(node.count == grammar.no_slot);
    const mark = self.log.items.len;
    const t = self.toks()[ti];
    const one = try self.capOne(node, t);
    if (one) |v| {
        if (Matcher.followLit(rest, t)) return false;
        if (node.slot != grammar.wild_slot)
            try self.log.append(self.arena, .{ .slot = node.slot, .val = v });
        if (try self.m(rest, ti + 1, k)) return true;
        self.log.shrinkRetainingCapacity(mark);
    }
    const close = rest.len > 0 and rest[0].tag == .lit and std.mem.eql(u8, rest[0].text, ")");
    if (!close or node.slot == grammar.wild_slot or self.slot(node.slot).ty != .value)
        return false;
    const j = self.parenRun(ti) orelse return false;
    if (one != null and j == ti + 1) return false;
    try self.log.append(
        self.arena,
        .{ .slot = node.slot, .val = .{ .expr = try self.joinRaw(ti, j) } },
    );
    if (try self.m(rest, j, k)) return true;
    self.log.shrinkRetainingCapacity(mark);
    return false;
}

/// The text of the line from token `ti` on, "" at its end. From the end of
/// the token before, so that an opening parenthesis the lexer treated as a
/// blank is kept.
fn lineAfter(self: *const Matcher, ti: usize) []const u8 {
    const t = self.toks()[ti];
    if (t.tag == .nl) return "";
    const line = self.lines.get(t.lno).text;
    var off = @intFromPtr(t.raw.ptr) - @intFromPtr(line.ptr);
    if (ti > 0 and self.toks()[ti - 1].lno == t.lno and self.toks()[ti - 1].tag != .nl) {
        const prev = self.toks()[ti - 1].raw;
        off = @intFromPtr(prev.ptr) + prev.len - @intFromPtr(line.ptr);
    }
    return std.mem.trim(u8, line[off..], " \t");
}

/// `(a > b)` is `a > b`: parentheses around the whole text dropped.
fn unwrapParens(text: []const u8) []const u8 {
    if (!(text.len >= 2 and text[0] == '(' and text[text.len - 1] == ')')) return text;
    var depth: usize = 0;
    var whole = true;
    for (text[0 .. text.len - 1]) |ch| {
        if (ch == '(') depth += 1;
        if (ch == ')') depth -= 1;
        if (depth == 0) whole = false;
    }
    return if (whole) std.mem.trim(u8, text[1 .. text.len - 1], " \t") else text;
}
