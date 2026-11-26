//! Matcher: one token line against one pattern of a grammar, with real
//! backtracking, and what the match captured folded into a statement.
//! The values a token is read as are `values.zig`; captures that take
//! several tokens (lists, bags, the rest of a line) are `capture.zig`.

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const dialects = @import("dialects");
const values = @import("values.zig");
const capture = @import("capture.zig");
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
    pub const max_stack = 1 << 20;

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
    pub const Sig = values.Sig;
    pub const signalAt = values.signalAt;
    pub const quotedExpr = values.quotedExpr;
    pub const anyValue = values.anyValue;
    pub const vector = values.vector;
    pub const pairs = values.pairs;
    pub const parenRun = capture.parenRun;
    pub const joinRaw = capture.joinRaw;
    pub const joinTokens = capture.joinTokens;
    pub const capOne = capture.capOne;
    pub const bagEntry = capture.bagEntry;

    pub fn slot(self: *const Matcher, idx: u8) schema.Slot {
        return schema.info(self.kind).slots[idx];
    }

    pub fn litMatches(node: *const Node, t: Tok) bool {
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

    pub fn startsWithLit(items: []const Node, t: Tok) bool {
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

    pub fn m(self: *Matcher, items: []const Node, ti: usize, k: ?*const Cont) Allocator.Error!bool {
        if (self.stack_top -% @frameAddress() > max_stack) return false;
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
            .glue => {
                // The lexer already dropped commas, and parentheses too in SPICE dialects.
                const dropped = std.mem.eql(u8, node.text, ",") or
                    (self.g.lex.parens_are_space and (std.mem.eql(u8, node.text, "(") or std.mem.eql(u8, node.text, ")")));
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
                return litMatches(node, t) and try self.m(rest, ti + 1, k);
            },
            .drop => return self.m(rest, ti, k),
            .nl => {
                if (t.tag != .nl) return false;
                // Comment lines inside a multi-line statement do not break it.
                var j = ti + 1;
                while (try self.win.has(j) and (self.toks()[j].tag == .comment or self.toks()[j].tag == .blank)) j += 2;
                return try self.win.has(j) and try self.m(rest, j, k);
            },
            .taglit => {
                if (!litMatches(node, t)) return false;
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
            },
            .cap => {
                if (node.slot != grammar.wild_slot and self.slot(node.slot).ty == .signal) {
                    // Signals may span several tokens, so they are taken
                    // greedily and never given back.
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
                self.allow_key = beforeEq(rest);
                defer self.allow_key = false;
                if (node.count != grammar.no_slot) {
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
                if (node.star or node.plus) {
                    // Greedy, then give items back one at a time. An item
                    // of a list of words may be a `key=value` among them
                    // (a PAT source's `r=1 rb=2` between its bit groups):
                    // one item of three tokens, so the ends are kept.
                    var ends: std.ArrayList(usize) = .empty;
                    var at = ti;
                    const wild = node.slot == grammar.wild_slot;
                    // Not where an `=` follows the list (`.param f(x)='x'`).
                    const words = !wild and self.slot(node.slot).ty == .atom and !self.allow_key;
                    while (true) {
                        const t0 = self.toks()[at];
                        if (words and ends.items.len > 0 and t0.f.key and self.toks()[at + 1].tag == .eq and (self.toks()[at + 2].tag == .word or self.toks()[at + 2].tag == .expr)) {
                            try self.log.append(
                                self.arena,
                                .{
                                    .slot = node.slot,
                                    .val = .{ .atom = try self.joinTokens(at, at + 3) },
                                },
                            );
                            at += 3;
                            try ends.append(self.arena, at);
                            continue;
                        }
                        const v = (try self.capOne(node, t0)) orelse break;
                        if (followLit(rest, t0)) break;
                        if (!wild)
                            try self.log.append(self.arena, .{ .slot = node.slot, .val = v });
                        at += 1;
                        try ends.append(self.arena, at);
                    }
                    const least: usize = if (node.plus) 1 else 0;
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
                const one = try self.capOne(node, t);
                if (one) |v| {
                    if (followLit(rest, t)) return false;
                    if (node.slot != grammar.wild_slot)
                        try self.log.append(self.arena, .{ .slot = node.slot, .val = v });
                    if (try self.m(rest, ti + 1, k)) return true;
                    self.log.shrinkRetainingCapacity(mark);
                }
                // `if (a > 1)`: where a dialect lexes parentheses as tokens
                // and the pattern closes one right after a value, everything
                // up to that `)` is the expression, whether its first token
                // is no value (`(`) or one the `)` does not follow (`a`).
                const close = rest.len > 0 and rest[0].tag == .lit and std.mem.eql(
                    u8,
                    rest[0].text,
                    ")",
                );
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
            },
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
            .rep => if (node.count != grammar.no_slot) {
                // Exactly as many passes as the count says: written out.
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
            } else {
                // Greedy: one more pass, then this node again; else stop
                // here. `star` on the node marks a pass already taken, so
                // the next one starts with the separator.
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
            },
            .rest => {
                const line = self.lines.get(t.lno).text;
                var text: []const u8 = "";
                if (t.tag != .nl) {
                    // From the end of the token before, so that an opening
                    // parenthesis the lexer treated as a blank is kept.
                    var off = @intFromPtr(t.raw.ptr) - @intFromPtr(line.ptr);
                    if (ti > 0 and self.toks()[ti - 1].lno == t.lno and
                        self.toks()[ti - 1].tag != .nl)
                    {
                        const prev = self.toks()[ti - 1].raw;
                        off = @intFromPtr(prev.ptr) + prev.len - @intFromPtr(line.ptr);
                    }
                    text = std.mem.trim(u8, line[off..], " \t");
                }
                var j = ti;
                while (self.toks()[j].tag != .nl) j += 1;
                if (node.slot != grammar.wild_slot) {
                    if (self.slot(node.slot).ty == .value) {
                        // The rest of the line is one expression: `.if (a > b)`.
                        if (text.len == 0) return false;
                        if (text.len >= 2 and text[0] == '(' and text[text.len - 1] == ')') {
                            var depth: usize = 0;
                            var whole = true;
                            for (text[0 .. text.len - 1]) |ch| {
                                if (ch == '(') depth += 1;
                                if (ch == ')') depth -= 1;
                                if (depth == 0) whole = false;
                            }
                            if (whole) text = std.mem.trim(u8, text[1 .. text.len - 1], " \t");
                        }
                        try self.log.append(
                            self.arena,
                            .{ .slot = node.slot, .val = .{ .expr = text } },
                        );
                    } else if (text.len > 0) try self.log.append(self.arena, .{ .slot = node.slot, .val = .{ .atom = text } });
                }
                if (try self.m(rest, j, k)) return true;
                self.log.shrinkRetainingCapacity(mark);
                return false;
            },
            .bag => {
                var j = ti;
                while (self.toks()[j].tag == .word) {
                    const kt = self.toks()[j];
                    if (kt.f.key and self.toks()[j + 1].tag == .eq) {
                        const vt = self.toks()[j + 2];
                        if (vt.tag == .nl or vt.tag == .eq) break;
                        const before = self.log.items.len;
                        if (!try self.bagEntry(node, kt.text, kt.raw, vt)) break;
                        j += 3;
                        // `R=0.2 0 0.2`: the numbers after one open-ended
                        // key are its matrix (CPL and RLGC line models).
                        const last: *Capture = if (self.log.items.len > before)
                            &self.log.items[self.log.items.len - 1]
                        else
                            continue;
                        if (last.key.len > 0 and last.val == .num and
                            self.toks()[j].tag == .word and !self.toks()[j].f.key and
                            self.number(self.toks()[j]) != null)
                        {
                            var matrix: std.ArrayList(Value) = .empty;
                            try matrix.append(self.arena, last.val);
                            while (self.toks()[j].tag == .word and !self.toks()[j].f.key) : (j += 1) {
                                try matrix.append(
                                    self.arena,
                                    .{ .num = self.number(self.toks()[j]) orelse break },
                                );
                            }
                            last.val = .{ .list = matrix.items };
                        }
                        continue;
                    }
                    if (kt.f.call) {
                        // `v(out)=1`
                        const entry = for (node.bag) |e| {
                            if (e.form == .call and std.mem.eql(u8, e.key, kt.text)) break e;
                        } else break;
                        const tokens = !self.g.lex.parens_are_space;
                        var a = j + 1;
                        if (tokens) {
                            if (self.toks()[a].tag != .lparen) break;
                            a += 1;
                        }
                        const nt = self.toks()[a];
                        if (nt.tag != .word) break;
                        var b = a + 1;
                        if (tokens) {
                            if (self.toks()[b].tag != .rparen) break;
                            b += 1;
                        }
                        if (self.toks()[b].tag != .eq) break;
                        const v = (try self.anyValue(self.toks()[b + 1], "")) orelse break;
                        try self.log.append(
                            self.arena,
                            .{ .slot = entry.slot, .key = nt.raw, .val = v },
                        );
                        j = b + 2;
                        continue;
                    }
                    // `n1 1`: a bare key and its value, where the bag takes them.
                    if (for (node.bag) |e| {
                        if (e.form == .call and e.bare_pairs) break e;
                    } else null) |entry| {
                        const vt = self.toks()[j + 1];
                        if (vt.tag != .word or vt.f.key) break;
                        const v = (try self.anyValue(vt, kt.text)) orelse break;
                        try self.log.append(
                            self.arena,
                            .{ .slot = entry.slot, .key = kt.raw, .val = v },
                        );
                        j += 2;
                        continue;
                    }
                    // A bare word is a flag where the bag accepts flags.
                    const flags = for (node.bag) |e| {
                        if (e.form == .rest and e.flags) break e;
                    } else break;
                    // A declared model is no flag: a longer form names it
                    // (`Q c b e s tj model`).
                    if (!lexer.isIdent(kt.text) or self.declared.contains(kt.text)) break;
                    try self.log.append(
                        self.arena,
                        .{ .slot = flags.slot, .key = kt.raw, .val = .none },
                    );
                    j += 1;
                }
                for (node.bag) |e| {
                    if (!e.required) continue;
                    var seen = false;
                    const want = if (e.form == .fixed) e.tag_slot else e.slot;
                    for (self.log.items[mark..]) |c| {
                        if (c.slot == want and c.key.len == 0) seen = true;
                    }
                    if (!seen) {
                        self.log.shrinkRetainingCapacity(mark);
                        return false;
                    }
                }
                if (try self.m(rest, j, k)) return true;
                self.log.shrinkRetainingCapacity(mark);
                return false;
            },
        }
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
