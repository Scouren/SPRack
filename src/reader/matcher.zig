//! Matcher: one token line against one pattern of a grammar, with real
//! backtracking, and what the match captured folded into a statement.
//! The values a token is read as are `values.zig`; captures that take
//! several tokens (lists, bags, the rest of a line) are `capture.zig`.
//!
//! Contents:
//! - `pub const Capture = struct`
//! - `pub const Cont = struct`
//! - `pub const Declared`
//! - `pub const Matcher = struct`, with `pub fn run`, `pub fn toks`, `pub fn slot`,
//!   `pub fn followLit`, `pub fn beforeEq`, `pub fn m`, `pub fn countOf`, `pub fn applyTo`,
//!   `pub fn clash`, `pub fn build`; from `values.zig` `pub const own`, `pub const number`,
//!   `pub const toValue`, `pub const signalAt`, `pub const quotedExpr`, `pub const anyValue`,
//!   `pub const vector`, `pub const pairs`; from `capture.zig` `pub const parenRun`,
//!   `pub const joinRaw`, `pub const joinTokens`, `pub const capOne`; from `bag.zig`
//!   `pub const bagEntry`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const dialects = @import("dialects");
const values = @import("values.zig");
const capture = @import("capture.zig");
const bag = @import("bag.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Node = grammar.Node;
const Kind = schema.Kind;
const Tok = lexer.Tok;
const Value = ir.Value;

pub const Capture = struct { slot: u8, key: []const u8 = "", val: Value };

pub const Cont = struct { items: []const Node, next: ?*const Cont };

pub const Declared = std.StringHashMapUnmanaged(void);

pub const Matcher = struct {
    g: *const Grammar,
    arena: Allocator,
    win: *lexer.Window,
    lines: *lexer.Lines,
    declared: *const Declared,
    kind: Kind = .@"opaque",
    /// The capture in progress is followed by a literal `=`, so a word in
    /// front of `=` is a value here and not the key of a parameter.
    allow_key: bool = false,
    /// Token index where the innermost `~"("` of the pattern was passed.
    paren_open: usize = 0,
    log: std.ArrayList(Capture) = .empty,
    /// What the option statements built so far in this pass said, slot by
    /// slot, copied to outlive them: a later one may say it again under
    /// another heading (`reltol=reltol+`).
    said: std.ArrayList(Capture) = .empty,
    keep: ir.Keep,
    /// Index of the `nl` token that ended the last successful match.
    end: usize = 0,
    /// Stack address where the match began: see `max_stack`.
    stack_top: usize = 0,

    /// Stack a match may use. `m` recurses once per pattern item and per
    /// pass of a repeated group, so a statement of a few thousand repeated
    /// words overflowed the stack; past this much it simply does not match.
    // ponytail: a byte budget, not a depth, since Debug frames are several
    // times larger; an explicit backtracking stack if a real deck needs more.
    const max_stack = 1 << 20;

    pub fn run(self: *Matcher, kind: Kind, pat: []const Node, ti: usize) Allocator.Error!bool {
        // A pattern whose first item cannot take this token fails at once,
        // as `m` would find (most rules start with a keyword or a letter).
        if (pat.len > 0) {
            const n = &pat[0];
            const t = self.toks()[ti];
            switch (n.tag) {
                .lit => if (!litMatches(n, t)) return false,
                .cap => if (n.prefix.len > 0 and !n.star and !n.plus and
                    n.count == grammar.no_slot and n.slot != grammar.wild_slot)
                {
                    const ty = schema.info(kind).slots[n.slot].ty;
                    if (ty != .value and ty != .signal and !std.mem.startsWith(
                        u8,
                        t.text,
                        n.prefix,
                    )) return false;
                },
                else => {},
            }
        }
        assert(ti < self.toks().len);
        self.kind = kind;
        self.log.clearRetainingCapacity();
        self.stack_top = @frameAddress();
        return self.m(pat, ti, null);
    }

    /// The tokens lexed so far. Only the `.nl` node reads past the line it
    /// is on, and it asks the window for the next one first.
    pub fn toks(self: *const Matcher) []const Tok {
        return self.win.toks.items;
    }

    pub const own = values.own;
    pub const number = values.number;
    pub const toValue = values.toValue;

    pub const signalAt = values.signalAt;
    pub const quotedExpr = values.quotedExpr;
    pub const anyValue = values.anyValue;
    pub const vector = values.vector;
    pub const pairs = values.pairs;
    pub const parenRun = capture.parenRun;
    pub const joinRaw = capture.joinRaw;
    pub const joinTokens = capture.joinTokens;
    pub const capOne = capture.capOne;
    pub const bagEntry = bag.bagEntry;

    pub fn slot(self: *const Matcher, idx: u8) schema.Slot {
        return schema.info(self.kind).slots[idx];
    }

    fn litMatches(node: *const Node, t: Tok) bool {
        return switch (t.tag) {
            .word => std.mem.eql(u8, t.text, node.text),
            .lparen => std.mem.eql(u8, node.text, "("),
            .rparen => std.mem.eql(u8, node.text, ")"),
            .eq => std.mem.eql(u8, node.text, "="),
            else => false,
        };
    }

    /// Does an optional group right after this point start with a literal
    /// equal to this token? Then a capture must leave the token alone: in
    /// `.subckt name ports* ["params:"] ...` the word `params:` is not a port.
    /// A mandatory literal is no reason to refuse (`ac ac start=1` is an
    /// analysis named ac).
    pub fn followLit(items: []const Node, t: Tok) bool {
        for (items) |*n| {
            switch (n.tag) {
                .glue, .drop => continue,
                .opt => if (startsWithLit(n.kids, t)) return true,
                .rep => if (startsWithLit(n.kids, t)) return true else if (n.plus) return false,
                .alt => {
                    for (n.kids) |*alt| if (startsWithLit(alt.kids, t)) return true;
                    return false;
                },
                else => return false,
            }
        }
        return false;
    }

    pub fn beforeEq(items: []const Node) bool {
        for (items) |*n| {
            switch (n.tag) {
                .glue => if (std.mem.eql(u8, n.text, "=")) return true else continue,
                .drop => continue,
                .lit => return std.mem.eql(u8, n.text, "="),
                else => return false,
            }
        }
        return false;
    }

    // tidy: allow(recursion) bounded by the nesting of a pattern (the grammar parser's max_depth)
    fn startsWithLit(items: []const Node, t: Tok) bool {
        for (items) |*n| {
            switch (n.tag) {
                .lit, .taglit => return litMatches(n, t),
                .glue, .drop => continue,
                .opt => if (startsWithLit(n.kids, t)) return true,
                .rep => if (startsWithLit(n.kids, t)) return true else if (n.plus) return false,
                .alt => {
                    for (n.kids) |*alt| if (startsWithLit(alt.kids, t)) return true;
                    return false;
                },
                else => return false,
            }
        }
        return false;
    }

    /// Match `items` and then what `k` goes on with, from token `ti` to the
    /// `nl` that ends the statement. True leaves the captures in `log` and
    /// that `nl` in `end`; false leaves `log` as it was.
    // tidy: allow(recursion) bounded by max_stack, the stack a match may use (checked first)
    pub fn m(self: *Matcher, items: []const Node, ti: usize, k: ?*const Cont) Allocator.Error!bool {
        if (self.stack_top -% @frameAddress() > max_stack) return false;
        // Entered only through `run`, which marks where the match began.
        assert(self.stack_top != 0);
        if (items.len == 0) {
            if (k) |c| return self.m(c.items, ti, c.next);
            if (self.toks()[ti].tag != .nl) return false;
            self.end = ti;
            return true;
        }
        const node = &items[0];
        const rest = items[1..];
        const t = self.toks()[ti];
        const mark = self.log.items.len;
        switch (node.tag) {
            .lit => return litMatches(node, t) and try self.m(rest, ti + 1, k),
            .glue => return self.glue(node, rest, ti, k),
            .drop => return self.m(rest, ti, k),
            .nl => return self.newline(rest, ti, k),
            .taglit => return self.tagLit(node, rest, ti, k),
            .cap => return capture.cap(self, node, rest, ti, k),
            .opt => {
                const c: Cont = .{ .items = rest, .next = k };
                if (try self.m(node.kids, ti, &c)) return true;
                self.log.shrinkRetainingCapacity(mark);
                return self.m(rest, ti, k);
            },
            .alt => {
                const c: Cont = .{ .items = rest, .next = k };
                for (node.kids) |alt| {
                    if (try self.m(alt.kids, ti, &c)) return true;
                    self.log.shrinkRetainingCapacity(mark);
                }
                return false;
            },
            .seq => {
                const c: Cont = .{ .items = rest, .next = k };
                return self.m(node.kids, ti, &c);
            },
            .rep => return if (node.count != grammar.no_slot)
                self.repCount(node, rest, ti, k)
            else
                self.repGreedy(node, rest, ti, k),
            .rest => return capture.restOfLine(self, node, rest, ti, k),
            .bag => return bag.bag(self, node, rest, ti, k),
        }
    }

    /// A literal glued to its neighbours: matched where the lexer kept it,
    /// passed over where the lexer dropped it.
    inline fn glue(
        self: *Matcher,
        node: *const Node,
        rest: []const Node,
        ti: usize,
        k: ?*const Cont,
    ) Allocator.Error!bool {
        // The lexer already dropped commas, and parentheses too in SPICE dialects.
        const dropped = std.mem.eql(u8, node.text, ",") or
            (self.g.lex.parens_are_space and
                (std.mem.eql(u8, node.text, "(") or std.mem.eql(u8, node.text, ")")));
        if (dropped and node.text[0] == '(') self.paren_open = ti;
        if (dropped and node.text[0] == ')' and ti > self.paren_open + 1) {
            // Where parentheses are blanks the lexer still noted where
            // they close. `sin(0 1 1k) ac 1`: the group ends at `1k`,
            // so `ac` and `1` are not its fourth and fifth values.
            for (self.toks()[self.paren_open .. ti - 1]) |inner| {
                if (inner.closes > 0) return false;
            }
        }
        if (dropped) return self.m(rest, ti, k);
        return litMatches(node, self.toks()[ti]) and try self.m(rest, ti + 1, k);
    }

    /// The end of a line inside a statement, and the comment lines after it.
    inline fn newline(
        self: *Matcher,
        rest: []const Node,
        ti: usize,
        k: ?*const Cont,
    ) Allocator.Error!bool {
        if (self.toks()[ti].tag != .nl) return false;
        // Comment lines inside a multi-line statement do not break it.
        var j = ti + 1;
        while (try self.win.has(j) and
            (self.toks()[j].tag == .comment or self.toks()[j].tag == .blank)) j += 2;
        return try self.win.has(j) and try self.m(rest, j, k);
    }

    /// A literal that also sets a slot to the value it stands for.
    inline fn tagLit(
        self: *Matcher,
        node: *const Node,
        rest: []const Node,
        ti: usize,
        k: ?*const Cont,
    ) Allocator.Error!bool {
        if (!litMatches(node, self.toks()[ti])) return false;
        const mark = self.log.items.len;
        const num = if (self.slot(node.slot).ty == .value)
            lexer.parseNumber(self.arena, &self.g.lex, node.atom)
        else
            null;
        try self.log.append(self.arena, .{ .slot = node.slot, .val = if (num) |n|
            .{ .num = n }
        else
            .{ .atom = node.atom } });
        if (try self.m(rest, ti + 1, k)) return true;
        self.log.shrinkRetainingCapacity(mark);
        return false;
    }

    /// Exactly as many passes of a repeated group as the count says: written out.
    inline fn repCount(
        self: *Matcher,
        node: *const Node,
        rest: []const Node,
        ti: usize,
        k: ?*const Cont,
    ) Allocator.Error!bool {
        assert(node.count != grammar.no_slot);
        const mark = self.log.items.len;
        const want = self.countOf(node.count) orelse return false;
        var seq: std.ArrayList(Node) = .empty;
        for (0..want) |i| {
            if (i > 0) try seq.appendSlice(self.arena, node.sep);
            try seq.appendSlice(self.arena, node.kids);
        }
        const c: Cont = .{ .items = rest, .next = k };
        if (try self.m(seq.items, ti, &c)) return true;
        self.log.shrinkRetainingCapacity(mark);
        return false;
    }

    /// Greedy: one more pass, then this node again; else stop here. `star`
    /// on the node marks a pass already taken, so the next one starts with
    /// the separator.
    inline fn repGreedy(
        self: *Matcher,
        node: *const Node,
        rest: []const Node,
        ti: usize,
        k: ?*const Cont,
    ) Allocator.Error!bool {
        assert(node.count == grammar.no_slot);
        const mark = self.log.items.len;
        var again = node.*;
        again.star = true;
        again.plus = false;
        const tail = [1]Node{again};
        const after: Cont = .{ .items = rest, .next = k };
        const loop: Cont = .{ .items = &tail, .next = &after };
        const pass: Cont = .{ .items = node.kids, .next = &loop };
        const ok = if (node.star)
            try self.m(node.sep, ti, &pass)
        else
            try self.m(node.kids, ti, &loop);
        if (ok) return true;
        self.log.shrinkRetainingCapacity(mark);
        return !node.plus and try self.m(rest, ti, k);
    }

    /// The count captured earlier in this match for `#slot`; at most 64.
    pub fn countOf(self: *const Matcher, want: u8) ?usize {
        var i = self.log.items.len;
        while (i > 0) {
            i -= 1;
            const c = self.log.items[i];
            if (c.slot != want or c.key.len > 0) continue;
            if (c.val != .num) return null;
            const f = c.val.num.toFloat();
            if (!(f >= 1 and f <= 64 and f == @floor(f))) return null;
            return @intFromFloat(f);
        }
        return null;
    }

    /// Fold the captures of the last match into a statement.
    pub fn applyTo(self: *const Matcher, st: *ir.Stmt) Allocator.Error!void {
        const slots = schema.info(st.kind).slots;
        var buf: [schema.max_slots]Value = undefined;
        assert(slots.len <= buf.len);
        const vals = st.unpack(&buf);
        for (slots, 0..) |sl, i| {
            if (sl.ty == .params) {
                var ps: std.ArrayList(ir.Param) = .empty;
                if (vals[i] == .params) try ps.appendSlice(self.arena, vals[i].params);
                for (self.log.items) |c| {
                    if (c.slot == i and c.key.len > 0)
                        try ps.append(self.arena, .{ .key = c.key, .val = c.val });
                }
                if (ps.items.len > 0) vals[i] = .{ .params = try ps.toOwnedSlice(self.arena) };
            } else if (sl.list) {
                var vs: std.ArrayList(Value) = .empty;
                if (vals[i] == .list) try vs.appendSlice(self.arena, vals[i].list);
                var touched = false;
                for (self.log.items) |c| {
                    if (c.slot == i) {
                        try vs.append(self.arena, c.val);
                        touched = true;
                    }
                }
                if (touched) vals[i] = .{ .list = try vs.toOwnedSlice(self.arena) };
            } else {
                for (self.log.items) |c| {
                    if (c.slot == i) vals[i] = c.val;
                }
            }
        }
        try st.store(self.arena, vals);
    }

    /// A one-value slot two keys of the last match gave different values
    /// (HSPICE RELV and RELTOL are one option): the last is kept. Checked
    /// for options, where aliases are; a device line read in the wrong
    /// dialect would trip it with no use.
    pub fn clash(self: *const Matcher) ?u8 {
        const slots = schema.info(self.kind).slots;
        for (self.log.items, 0..) |a, i| {
            if (a.key.len > 0 or slots[a.slot].list or slots[a.slot].ty == .params) continue;
            for (self.log.items[i + 1 ..]) |b| {
                if (b.slot == a.slot and b.key.len == 0 and !b.val.eql(a.val)) return a.slot;
            }
        }
        return null;
    }

    pub fn build(self: *Matcher, line: u32) Allocator.Error!ir.Stmt {
        var st = try ir.newStmt(self.arena, self.kind, line);
        try self.applyTo(&st);
        if (self.kind == .options) for (self.log.items) |c| {
            if (c.key.len == 0)
                try self.said.append(
                    self.keep.perm,
                    .{ .slot = c.slot, .val = try ir.cloneValue(self.keep, c.val) },
                );
        };
        return st;
    }
};
