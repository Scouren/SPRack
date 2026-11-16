//! Generic reader: matches token lines against a grammar's patterns and
//! binds what it finds to canonical slots.
//!
//! Patterns are ordered choices with real backtracking, which is what SPICE
//! needs: `Q1 c b e [s] model [area]` cannot be split into nodes, model and
//! value without trying the alternatives.

const std = @import("std");
const grammar = @import("grammar.zig");
const schema = @import("schema.zig");
const ir = @import("ir.zig");
const lexer = @import("lexer.zig");
const expr = @import("expr.zig");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Node = grammar.Node;
const Kind = schema.Kind;
const Space = schema.Space;
const Tok = lexer.Tok;
const Value = ir.Value;

const Capture = struct { slot: u8, key: []const u8 = "", val: Value };
const Cont = struct { items: []const Node, next: ?*const Cont };
const Declared = std.StringHashMapUnmanaged(void);

const Matcher = struct {
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

    fn run(self: *Matcher, kind: Kind, pat: []const Node, ti: usize) Allocator.Error!bool {
        // A pattern whose first item cannot take this token fails at once,
        // as `m` would find (most rules start with a keyword or a letter).
        if (pat.len > 0) {
            const n = pat[0];
            const t = self.toks()[ti];
            switch (n.tag) {
                .lit => if (!litMatches(n, t)) return false,
                .cap => if (n.prefix.len > 0 and !n.star and !n.plus and n.count == grammar.no_slot and n.slot != grammar.wild_slot) {
                    const ty = schema.info(kind).slots[n.slot].ty;
                    if (ty != .value and ty != .signal and !std.mem.startsWith(u8, t.text, n.prefix)) return false;
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
    fn toks(self: *const Matcher) []const Tok {
        return self.win.toks.items;
    }

    /// A word's folded text lives only as long as its line's tokens.
    fn own(self: *const Matcher, t: Tok) Allocator.Error![]const u8 {
        return if (t.tag == .word and t.text.ptr != t.raw.ptr) self.arena.dupe(u8, t.text) else t.text;
    }

    /// A number keeps its digits from the source spelling, not from the
    /// folded copy, which goes away with the line.
    fn number(self: *const Matcher, t: Tok) ?ir.Number {
        var n = lexer.parseNumber(self.arena, &self.g.lex, t.text) orelse return null;
        const off = @intFromPtr(n.ptr) -% @intFromPtr(t.text.ptr);
        if (t.text.ptr != t.raw.ptr and off < t.text.len) n.ptr = t.raw.ptr + off;
        return n;
    }

    fn slot(self: *const Matcher, idx: u8) schema.Slot {
        return schema.info(self.kind).slots[idx];
    }

    fn toValue(self: *const Matcher, ty: schema.SlotType, t: Tok) Allocator.Error!?Value {
        if (t.f.key and !self.allow_key) return null;
        const cfg = &self.g.lex;
        switch (ty) {
            // HSPICE `.meas dc "ia" ...` is the measurement ia: a label.
            .name => return if ((t.tag == .word or (t.tag == .str and cfg.dquote_expr)) and lexer.isNameLike(t.text)) .{ .atom = if (t.tag == .str) t.text else t.raw } else null,
            .node => return if (t.tag == .word and lexer.isNameLike(t.text)) .{ .atom = t.raw } else null,
            .ident, .ref => {
                if (t.tag != .word or !lexer.isNameLike(t.text)) return null;
                // A model or subcircuit name starts like a name, not like an operator.
                if (!(std.ascii.isAlphanumeric(t.text[0]) or t.text[0] == '_')) return null;
                if (lexer.parseNumber(self.arena, cfg, t.text) != null) return null;
                return .{ .atom = t.raw };
            },
            .atom => return if (t.tag == .word or t.tag == .str) .{ .atom = try self.own(t) } else null,
            .value => switch (t.tag) {
                .word => {
                    if (self.number(t)) |n| return .{ .num = n };
                    // A bare identifier is a value only where the dialect allows it,
                    // and never when it names a model or subcircuit.
                    // After `=` a bare name is a parameter reference where
                    // the dialect reads undelimited expressions there.
                    if (!(cfg.ident_values or cfg.bare_expr or (cfg.bare_after_eq and t.f.val))) return null;
                    if (!lexer.isIdent(t.text) or self.declared.contains(t.text)) return null;
                    return .{ .expr = t.raw };
                },
                .expr => return .{ .expr = t.text },
                .str => return (try self.quotedExpr(t, "")) orelse .{ .str = t.text },
                else => return null,
            },
            .path => return switch (t.tag) {
                .str => .{ .str = t.text },
                .word => .{ .str = t.raw },
                // `.include 'file'` where quotes are also expression delimiters.
                .expr => .{ .str = t.text },
                else => null,
            },
            .text, .params, .signal => return null,
        }
    }

    const Sig = struct { v: Value, n: usize };

    /// One recorded signal starting at `ti`: `v(out)`, `v(a,b)`, `out`, `v1:p`.
    fn signalAt(self: *const Matcher, ti: usize) Allocator.Error!?Sig {
        const t = self.toks()[ti];
        if (t.f.key) return null;
        if (t.tag == .expr) return .{ .v = .{ .expr = t.text }, .n = 1 };
        if (t.tag != .word) return null;
        // `par('-i(vc)')`: the dialect's way of recording an expression.
        if (t.f.call and self.toks()[ti + 1].tag == .expr and self.g.lex.parens_are_space) {
            for (self.g.signals) |sf| {
                if (!std.mem.eql(u8, sf.form, "expr")) continue;
                if (sf.template.len > t.text.len and std.mem.startsWith(u8, sf.template, t.text) and sf.template[t.text.len] == '(') {
                    return .{ .v = .{ .expr = self.toks()[ti + 1].text }, .n = 2 };
                }
            }
        }
        // `-i(vc)`: a signal negated is an expression.
        const neg = t.raw.len > 1 and t.raw[0] == '-';
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(self.arena, if (neg) t.raw[1..] else t.raw);
        var n: usize = 1;
        if (t.f.call) {
            // Calls may nest (`db(i(vm))`); at most three names per call.
            const tokens = !self.g.lex.parens_are_space;
            var j = ti + 1;
            if (tokens) {
                if (self.toks()[j].tag != .lparen) return null;
                j += 1;
            }
            try text.append(self.arena, '(');
            var depth: usize = 1;
            var count: usize = 0;
            while (depth > 0) : (j += 1) {
                const a = self.toks()[j];
                if (tokens and a.tag == .rparen) {
                    try text.append(self.arena, ')');
                    depth -= 1;
                    continue;
                }
                // `v(a)=0.5`: the `=` after the call marks its last name a key.
                const closes = if (tokens) self.toks()[j + 1].tag == .rparen else a.closes > 0;
                if (a.tag != .word or (a.f.key and !closes) or count == 3 or j - ti > 12) return null;
                if (count > 0) try text.append(self.arena, ',');
                try text.appendSlice(self.arena, a.raw);
                count += 1;
                if (a.f.call) {
                    if (tokens) {
                        if (self.toks()[j + 1].tag != .lparen) return null;
                        j += 1;
                    }
                    try text.append(self.arena, '(');
                    depth += 1;
                    count = 0;
                }
                if (!tokens) for (0..a.closes) |_| {
                    if (depth == 0) break;
                    try text.append(self.arena, ')');
                    depth -= 1;
                };
            }
            n = j - ti;
        }
        const canon = (try signalCanon(self.arena, self.g, text.items)) orelse return null;
        if (neg) return .{ .v = .{ .expr = try std.mem.concat(self.arena, u8, &.{ "-", canon }) }, .n = n };
        return .{ .v = .{ .atom = canon }, .n = n };
    }

    /// A double-quoted value read as the expression it is where the dialect
    /// says so (`quotes '"' expr-in-values`: HSPICE `.param t2="a^3"` is 8
    /// with a=2). Null keeps it a string: a key the grammar names as a
    /// file name (`rlgcfile=`), an empty pair of quotes.
    fn quotedExpr(self: *const Matcher, t: Tok, key: []const u8) Allocator.Error!?Value {
        const cfg = &self.g.lex;
        if (!cfg.dquote_expr) return null;
        for (cfg.dquote_strings) |k| if (std.ascii.eqlIgnoreCase(k, key)) return null;
        const text = std.mem.trim(u8, t.text, " \t");
        if (text.len == 0) return null;
        const folded = if (cfg.case_sensitive) text else try std.ascii.allocLowerString(self.arena, text);
        if (lexer.parseNumber(self.arena, cfg, folded)) |n| return .{ .num = n };
        return .{ .expr = text };
    }

    /// Value of an open-ended `key=value` parameter: take whatever is there.
    fn anyValue(self: *const Matcher, t: Tok, key: []const u8) Allocator.Error!?Value {
        switch (t.tag) {
            .word => {
                if (self.number(t)) |n| return .{ .num = n };
                if (lexer.isIdent(t.text)) return .{ .expr = t.raw };
                // Neither a number, a name nor a delimited expression in this
                // dialect (`w={w}` in HSPICE, where braces mean nothing).
                // Keep the exact spelling rather than guess.
                return .{ .atom = t.raw };
            },
            // `version=3.3.0` read as an undelimited expression is a word, not arithmetic.
            .expr => return if (isVersion(t.text)) .{ .atom = t.text } else .{ .expr = t.text },
            // An unknown option keeps a string; a declared one is typed.
            .str => return (if (self.kind == .options) null else try self.quotedExpr(t, key)) orelse .{ .str = t.text },
            .vec => return .{ .list = try self.vector(t.text) },
            else => return null,
        }
    }

    fn vector(self: *const Matcher, text: []const u8) Allocator.Error![]const Value {
        var out: std.ArrayList(Value) = .empty;
        var it = std.mem.tokenizeAny(u8, text, " \t,");
        while (it.next()) |w| {
            const cfg = &self.g.lex;
            const folded = if (cfg.case_sensitive) w else try std.ascii.allocLowerString(self.arena, w);
            if (lexer.parseNumber(self.arena, cfg, folded)) |n| {
                try out.append(self.arena, .{ .num = n });
            } else try out.append(self.arena, .{ .expr = w });
        }
        return out.toOwnedSlice(self.arena);
    }

    /// `{"out",0.5,"a","b",1}`: quoted names, each run of them ended by a
    /// value; two names are a difference, kept as the key `a,b`.
    fn pairs(self: *Matcher, into: u8, vt: Tok) Allocator.Error!bool {
        const t = vt.text;
        if (t.len < 2 or t[0] != '{' or t[t.len - 1] != '}') return false;
        const start = self.log.items.len;
        var names: std.ArrayList(u8) = .empty;
        var it = std.mem.tokenizeAny(u8, t[1 .. t.len - 1], ", ");
        while (it.next()) |w| {
            if (w.len >= 2 and w[0] == '"' and w[w.len - 1] == '"') {
                if (names.items.len > 0) try names.append(self.arena, ',');
                try names.appendSlice(self.arena, w[1 .. w.len - 1]);
                continue;
            }
            if (names.items.len == 0) break;
            const v: Value = if (lexer.parseNumber(self.arena, &self.g.lex, w)) |n| .{ .num = n } else .{ .expr = w };
            try self.log.append(self.arena, .{ .slot = into, .key = try names.toOwnedSlice(self.arena), .val = v });
        } else if (names.items.len == 0 and self.log.items.len > start) return true;
        self.log.shrinkRetainingCapacity(start);
        return false;
    }

    fn litMatches(node: Node, t: Tok) bool {
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
    fn followLit(items: []const Node, t: Tok) bool {
        for (items) |n| {
            switch (n.tag) {
                .glue, .drop => continue,
                .opt => if (startsWithLit(n.kids, t)) return true,
                .rep => if (startsWithLit(n.kids, t)) return true else if (n.plus) return false,
                .alt => {
                    for (n.kids) |alt| if (startsWithLit(alt.kids, t)) return true;
                    return false;
                },
                else => return false,
            }
        }
        return false;
    }

    fn beforeEq(items: []const Node) bool {
        for (items) |n| {
            switch (n.tag) {
                .glue => if (std.mem.eql(u8, n.text, "=")) return true else continue,
                .drop => continue,
                .lit => return std.mem.eql(u8, n.text, "="),
                else => return false,
            }
        }
        return false;
    }

    fn startsWithLit(items: []const Node, t: Tok) bool {
        for (items) |n| {
            switch (n.tag) {
                .lit, .taglit => return litMatches(n, t),
                .glue, .drop => continue,
                .opt => if (startsWithLit(n.kids, t)) return true,
                .rep => if (startsWithLit(n.kids, t)) return true else if (n.plus) return false,
                .alt => {
                    for (n.kids) |alt| if (startsWithLit(alt.kids, t)) return true;
                    return false;
                },
                else => return false,
            }
        }
        return false;
    }

    fn m(self: *Matcher, items: []const Node, ti: usize, k: ?*const Cont) Allocator.Error!bool {
        if (self.stack_top -% @frameAddress() > max_stack) return false;
        if (items.len == 0) {
            if (k) |c| return self.m(c.items, ti, c.next);
            if (self.toks()[ti].tag != .nl) return false;
            self.end = ti;
            return true;
        }
        const node = items[0];
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
                const num = if (self.slot(node.slot).ty == .value) lexer.parseNumber(self.arena, &self.g.lex, node.atom) else null;
                try self.log.append(self.arena, .{ .slot = node.slot, .val = if (num) |n| .{ .num = n } else .{ .atom = node.atom } });
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
                    // Greedy, then give tokens back one at a time.
                    var n: usize = 0;
                    const wild = node.slot == grammar.wild_slot;
                    while (try self.capOne(node, self.toks()[ti + n])) |v| : (n += 1) {
                        if (followLit(rest, self.toks()[ti + n])) break;
                        if (!wild) try self.log.append(self.arena, .{ .slot = node.slot, .val = v });
                    }
                    const least: usize = if (node.plus) 1 else 0;
                    while (true) {
                        if (n >= least and try self.m(rest, ti + n, k)) return true;
                        if (n <= least) break;
                        n -= 1;
                        if (!wild) self.log.shrinkRetainingCapacity(mark + n);
                    }
                    self.log.shrinkRetainingCapacity(mark);
                    return false;
                }
                const one = try self.capOne(node, t);
                if (one) |v| {
                    if (followLit(rest, t)) return false;
                    if (node.slot != grammar.wild_slot) try self.log.append(self.arena, .{ .slot = node.slot, .val = v });
                    if (try self.m(rest, ti + 1, k)) return true;
                    self.log.shrinkRetainingCapacity(mark);
                }
                // `if (a > 1)`: where a dialect lexes parentheses as tokens
                // and the pattern closes one right after a value, everything
                // up to that `)` is the expression, whether its first token
                // is no value (`(`) or one the `)` does not follow (`a`).
                const close = rest.len > 0 and rest[0].tag == .lit and std.mem.eql(u8, rest[0].text, ")");
                if (!close or node.slot == grammar.wild_slot or self.slot(node.slot).ty != .value) return false;
                const j = self.parenRun(ti) orelse return false;
                if (one != null and j == ti + 1) return false;
                try self.log.append(self.arena, .{ .slot = node.slot, .val = .{ .expr = try self.joinRaw(ti, j) } });
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
                var again = node;
                again.star = true;
                again.plus = false;
                const tail = [1]Node{again};
                const after: Cont = .{ .items = rest, .next = k };
                const loop: Cont = .{ .items = &tail, .next = &after };
                const pass: Cont = .{ .items = node.kids, .next = &loop };
                const ok = if (node.star) try self.m(node.sep, ti, &pass) else try self.m(node.kids, ti, &loop);
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
                    if (ti > 0 and self.toks()[ti - 1].lno == t.lno and self.toks()[ti - 1].tag != .nl) {
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
                        try self.log.append(self.arena, .{ .slot = node.slot, .val = .{ .expr = text } });
                    } else try self.log.append(self.arena, .{ .slot = node.slot, .val = .{ .atom = text } });
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
                        const last: *Capture = if (self.log.items.len > before) &self.log.items[self.log.items.len - 1] else continue;
                        if (last.key.len > 0 and last.val == .num and self.toks()[j].tag == .word and !self.toks()[j].f.key and self.number(self.toks()[j]) != null) {
                            var matrix: std.ArrayList(Value) = .empty;
                            try matrix.append(self.arena, last.val);
                            while (self.toks()[j].tag == .word and !self.toks()[j].f.key) : (j += 1) {
                                try matrix.append(self.arena, .{ .num = self.number(self.toks()[j]) orelse break });
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
                        try self.log.append(self.arena, .{ .slot = entry.slot, .key = nt.raw, .val = v });
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
                        try self.log.append(self.arena, .{ .slot = entry.slot, .key = kt.raw, .val = v });
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
                    try self.log.append(self.arena, .{ .slot = flags.slot, .key = kt.raw, .val = .none });
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
    fn countOf(self: *const Matcher, want: u8) ?usize {
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

    /// The end of a run of tokens, balanced in parentheses, that stops at an
    /// unmatched `)`. Null if the line ends first or the run is empty.
    fn parenRun(self: *const Matcher, ti: usize) ?usize {
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

    fn joinRaw(self: *const Matcher, from: usize, to: usize) Allocator.Error![]const u8 {
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
    fn joinTokens(self: *const Matcher, from: usize, to: usize) Allocator.Error![]const u8 {
        const ts = self.toks()[from..to];
        if (ts.len > 0 and ts[0].lno == ts[ts.len - 1].lno) {
            const start = @intFromPtr(ts[0].raw.ptr);
            const end = @intFromPtr(ts[ts.len - 1].raw.ptr) + ts[ts.len - 1].raw.len;
            if (end >= start) return self.arena.dupe(u8, ts[0].raw.ptr[0 .. end - start]);
        }
        var out: std.ArrayList(u8) = .empty;
        for (self.toks()[from..to], 0..) |t, i| {
            if (i > 0 and t.tag != .rparen and self.toks()[from + i - 1].tag != .lparen) try out.append(self.arena, ' ');
            try out.appendSlice(self.arena, t.raw);
        }
        return out.toOwnedSlice(self.arena);
    }

    fn capOne(self: *const Matcher, node: Node, t: Tok) Allocator.Error!?Value {
        if (node.slot == grammar.wild_slot) return if (t.tag == .word and !t.f.key) .{ .atom = t.text } else null;
        const v = (try self.toValue(self.slot(node.slot).ty, t)) orelse return null;
        if (node.prefix.len > 0 and !std.mem.startsWith(u8, t.text, node.prefix)) return null;
        return v;
    }

    /// Bind one `key=value` pair. False means the pair does not belong to this bag.
    fn bagEntry(self: *Matcher, node: Node, key: []const u8, key_raw: []const u8, vt: Tok) Allocator.Error!bool {
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
                    try self.log.append(self.arena, .{ .slot = e.slot, .val = .{ .atom = try self.own(vt) } });
                },
                .vector => {
                    if (vt.tag != .vec) return false;
                    for (try self.vector(vt.text)) |v| try self.log.append(self.arena, .{ .slot = e.slot, .val = v });
                },
                .pairs => if (!try self.pairs(e.slot, vt)) return false,
                .rest, .call => unreachable,
            }
            if (e.tag_slot != grammar.no_slot) {
                try self.log.append(self.arena, .{ .slot = e.tag_slot, .val = .{ .atom = e.tag_atom } });
            }
            return true;
        }
        const rs = rest_slot orelse return false;
        const v = (try self.anyValue(vt, key)) orelse return false;
        try self.log.append(self.arena, .{ .slot = rs, .key = key_raw, .val = v });
        return true;
    }

    /// Fold the captures of the last match into a statement.
    fn applyTo(self: *const Matcher, st: *ir.Stmt) Allocator.Error!void {
        const slots = schema.info(st.kind).slots;
        var buf: [schema.max_slots]Value = undefined;
        const vals = st.unpack(&buf);
        for (slots, 0..) |sl, i| {
            if (sl.ty == .params) {
                var ps: std.ArrayList(ir.Param) = .empty;
                if (vals[i] == .params) try ps.appendSlice(self.arena, vals[i].params);
                for (self.log.items) |c| {
                    if (c.slot == i and c.key.len > 0) try ps.append(self.arena, .{ .key = c.key, .val = c.val });
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
    fn clash(self: *const Matcher) ?u8 {
        const slots = schema.info(self.kind).slots;
        for (self.log.items, 0..) |a, i| {
            if (a.key.len > 0 or slots[a.slot].list or slots[a.slot].ty == .params) continue;
            for (self.log.items[i + 1 ..]) |b| {
                if (b.slot == a.slot and b.key.len == 0 and !b.val.eql(a.val)) return a.slot;
            }
        }
        return null;
    }

    fn build(self: *const Matcher, line: u32) Allocator.Error!ir.Stmt {
        var st = try ir.newStmt(self.arena, self.kind, line);
        try self.applyTo(&st);
        return st;
    }
};

fn normalize(arena: Allocator, case_sensitive: bool, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |w| {
        if (out.items.len > 0) try out.append(arena, ' ');
        for (w) |c| try out.append(arena, if (case_sensitive) c else std.ascii.toLower(c));
    }
    return out.toOwnedSlice(arena);
}

fn valueIsText(arena: Allocator, g: *const Grammar, v: Value, text: []const u8) bool {
    return switch (v) {
        .num => |n| blk: {
            const want = lexer.parseNumber(arena, &g.lex, text) orelse break :blk false;
            break :blk n.toFloat() == want.toFloat();
        },
        .atom => |s| sameText(g, s, text),
        .expr => |s| sameText(g, s, text),
        .str => |s| sameText(g, s, text),
        else => false,
    };
}

/// `modeltype=RLGC` is `rlgc` where case does not matter.
fn sameText(g: *const Grammar, a: []const u8, b: []const u8) bool {
    return if (g.lex.case_sensitive) std.mem.eql(u8, a, b) else std.ascii.eqlIgnoreCase(a, b);
}

/// Replace a dialect's model spelling (`nmos level=54`) with the canonical
/// family and polarity (`bsim4`, `n`).
/// Match `text` against a template such as `v(%,%)`; `%` stands for a name.
fn matchTemplate(tmpl: []const u8, folded: []const u8, raw: []const u8, args: *[3][]const u8) ?usize {
    var it = std.mem.splitScalar(u8, tmpl, '%');
    const head = it.first();
    if (!std.mem.startsWith(u8, folded, head)) return null;
    var pos = head.len;
    var n: usize = 0;
    var seen: usize = 0;
    while (it.next()) |whole| {
        // `%2`: the second name, where this dialect gives them in another order.
        var lit = whole;
        var at = n;
        if (lit.len > 0 and lit[0] >= '1' and lit[0] <= '3') {
            at = lit[0] - '1';
            lit = lit[1..];
        }
        const last = it.peek() == null;
        const end = if (last) blk: {
            if (folded.len < pos + lit.len or !std.mem.endsWith(u8, folded[pos..], lit)) return null;
            break :blk folded.len - lit.len;
        } else std.mem.indexOfPos(u8, folded, pos, lit) orelse return null;
        if (end <= pos or n == args.len) return null;
        if (std.mem.indexOfAny(u8, raw[pos..end], "(), \t") != null) return null;
        args[at] = raw[pos..end];
        seen = @max(seen, at + 1);
        n += 1;
        pos = end + lit.len;
    }
    return if (pos == folded.len and seen == n) n else null;
}

/// The canonical spelling of a signal written in this dialect, or null if
/// the dialect's `signals` section has no form for it.
pub fn signalCanon(arena: Allocator, g: *const Grammar, text: []const u8) Allocator.Error!?[]const u8 {
    const folded = if (g.lex.case_sensitive) text else try std.ascii.allocLowerString(arena, text);
    var args: [3][]const u8 = undefined;
    for (g.signals) |sf| {
        // An expression is told by its syntax, not by a template.
        if (std.mem.eql(u8, sf.form, "expr")) continue;
        const n = matchTemplate(sf.template, folded, text, &args) orelse continue;
        if (std.mem.eql(u8, sf.form, "all")) return "all";
        const name = if (std.mem.eql(u8, sf.form, "vdiff")) "v" else sf.form;
        var out: std.ArrayList(u8) = .empty;
        try out.print(arena, "{s}(", .{name});
        for (args[0..n], 0..) |a, i| {
            if (i > 0) try out.append(arena, ',');
            try out.appendSlice(arena, a);
        }
        try out.append(arena, ')');
        return out.items;
    }
    return null;
}

/// Split canonical `name(a,b)` into its form and arguments.
pub fn signalParts(text: []const u8, args: *[3][]const u8) ?struct { []const u8, usize } {
    if (std.mem.eql(u8, text, "all")) return .{ "all", 0 };
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    if (text[text.len - 1] != ')') return null;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text[open + 1 .. text.len - 1], ',');
    while (it.next()) |a| {
        if (n == args.len) return null;
        args[n] = a;
        n += 1;
    }
    const name = text[0..open];
    return .{ if (std.mem.eql(u8, name, "v") and n == 2) "vdiff" else name, n };
}

/// The space of the `k`th name of a signal of this form: the nodes of a
/// voltage, the device of a current. The terminal of `ix` is no name.
fn signalSpace(form: []const u8, k: usize) ?Space {
    if (form.len == 0) return null;
    if (form[0] == 'v') return .node;
    return if (form[0] == 'i' and k == 0) .instance else null;
}

fn mapModel(arena: Allocator, g: *const Grammar, st: *ir.Stmt, report: *ir.Report) Allocator.Error!void {
    const ti = schema.slotIndex(.model, "type").?;
    const pi = schema.slotIndex(.model, "params").?;
    var buf: [schema.max_slots]Value = undefined;
    const vals = st.unpack(&buf);
    if (vals[ti] != .atom) return;
    const ty = vals[ti].atom;
    const params: []const ir.Param = if (vals[pi] == .params) vals[pi].params else &.{};

    var best: ?struct { e: *const grammar.ModelEntry, s: *const grammar.ModelSpelling } = null;
    for (g.models) |*e| {
        for (e.spellings) |*s| {
            if (!std.mem.eql(u8, s.type, ty)) continue;
            var ok = true;
            for (s.kv) |kv| {
                var found: ?Value = null;
                for (params) |p| {
                    if (std.mem.eql(u8, p.key, kv.key)) found = p.val;
                }
                if (kv.absent) {
                    if (found != null) ok = false;
                } else if (found == null or !valueIsText(arena, g, found.?, kv.val)) ok = false;
            }
            if (!ok) continue;
            if (best == null or s.kv.len > best.?.s.kv.len) best = .{ .e = e, .s = s };
        }
    }
    const hit = best orelse {
        // A type word the table knows, with a level it does not, is a
        // gap in the table. A word it has never seen is a Verilog-A module.
        var known_word = false;
        for (g.models) |*e| {
            for (e.spellings) |*s| {
                if (std.mem.eql(u8, s.type, ty)) known_word = true;
            }
        }
        if (known_word) report.add(.warning, .unsupported, st.line, "model type '{s}' with these parameters is not in the {s} models table; kept as written", .{ ty, g.name });
        return;
    };
    vals[schema.slotIndex(.model, "family").?] = .{ .atom = hit.e.family };
    if (hit.e.polarity.len > 0) vals[schema.slotIndex(.model, "polarity").?] = .{ .atom = hit.e.polarity };
    vals[ti] = .none;
    // The statement was just built and owns its list: filter it in place.
    // A PDK's models carry most of its text in their parameters.
    const kept: []ir.Param = @constCast(params);
    var n: usize = 0;
    for (params) |p| {
        var consumed = false;
        for (hit.s.kv) |kv| {
            if (!kv.absent and std.mem.eql(u8, p.key, kv.key)) consumed = true;
        }
        if (consumed) continue;
        kept[n] = p;
        n += 1;
    }
    // Switch levels back to SPICE's midpoint and hysteresis.
    const th = try expr.thresholds(arena, g, hit.e.family, kept[0..n], false);
    vals[pi] = if (th.params.len > 0) .{ .params = th.params } else .none;
    try st.store(arena, vals);
}

/// The names of a spelling table some lookup was answered with a spelling
/// of their own, for each space.
pub const Needed = struct {
    sets: std.EnumArray(Space, ir.CaselessSet) = .initFill(.empty),
    failed: bool = false,

    pub fn deinit(n: *Needed) void {
        for (&n.sets.values) |*set| set.deinit(ir.big);
    }
};

/// In a dialect that ignores case, `Vdd`, `VDD` and `vdd` are one name. The
/// output preserves what the author wrote, and must still be consistent when
/// the target does distinguish case, so every name gets one spelling among
/// the names of its space (`schema.Space`): the first one written with a
/// capital letter, or the lower-case one if it is never written with any. A
/// node and a device are different things that may share a name: the node
/// `vdd` of a source `Vdd` keeps its own spelling.
///
/// Only names that appear capitalised somewhere are stored. A netlist written
/// entirely in lower case, as large generated ones are, costs nothing here.
const Spelling = struct {
    const Map = std.StringHashMapUnmanaged([]const u8);
    /// The capitalised spelling of each name of a space, found by any spelling.
    mixed: std.EnumArray(Space, ir.NameSet),
    /// While set, the names of `mixed` some lookup was answered with a
    /// spelling other than the one it would fall back to (`prune`).
    needed: ?*Needed = null,
    /// Lower-cased names of the parameters the netlist itself defines.
    /// Built-in parameter names (`w`, `l`, `tc1`) are not in it and are
    /// written in lower case, which is what a case-sensitive target expects.
    params: Map = .empty,
    /// Where names that outlive the line they were read from are copied,
    /// unless they are in `src`, the netlist's own text.
    perm: Allocator,
    src: []const u8,

    /// `s` as long as the table lives.
    fn keep(sp: *const Spelling, s: []const u8) Allocator.Error![]const u8 {
        return ir.keepText(sp.perm, sp.src, s);
    }

    fn lowered(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
        for (s) |c| if (std.ascii.isUpper(c)) return std.ascii.allocLowerString(arena, s);
        return s;
    }

    // The table can be large and is rebuilt as it grows, so it lives
    // outside the arena and is freed when reading is done.

    /// The capitalised names of a statement read in the first pass, each
    /// in the space of its slot: the values of its name, node, model and
    /// reference slots, the names of its signals, the nodes of `.ic` keys
    /// and the parameters an instance sets. Keywords and other parameter
    /// keys are not names, so `DC` on a source does not respell a node `dc`.
    fn names(sp: *Spelling, st: *const ir.Stmt) Allocator.Error!void {
        for (schema.info(st.kind).slots, 0..) |sl, i| {
            const v = st.at(i);
            const one = [1]Value{v};
            const items: []const Value = switch (v) {
                .atom => &one,
                .list => |l| l,
                .params => |ps| {
                    if (st.kind == .ic or st.kind == .nodeset) for (ps) |p| try sp.learn(.node, p.key);
                    if (st.kind == .instance) for (ps) |p| try sp.learn(.param, p.key);
                    for (ps) |p| try sp.exprNames(p.val);
                    continue;
                },
                .expr => {
                    try sp.exprNames(v);
                    continue;
                },
                else => continue,
            };
            // An expression among the items of a list (`.print v(a) {VCM*2}`).
            try sp.exprNames(v);
            if (st.kind == .func) continue;
            for (items) |it| {
                if (it != .atom) continue;
                if (sl.ty != .signal) {
                    try sp.learn(sl.space orelse break, it.atom);
                    continue;
                }
                var args: [3][]const u8 = undefined;
                const form, const n = signalParts(it.atom, &args) orelse continue;
                for (args[0..n], 0..) |a, k| try sp.learn(signalSpace(form, k) orelse continue, a);
            }
        }
    }

    /// The names an expression refers to (`{VCM}`, `rload*2`): a parameter
    /// defined in another file, or in another block of a Python deck, keeps
    /// the spelling it is written with here. Calls are functions, not names;
    /// what `v(` and `i(` name is a node and a device (`expr.argSpace`).
    fn exprNames(sp: *Spelling, v: Value) Allocator.Error!void {
        const items: []const Value = switch (v) {
            .expr => &.{v},
            .list => |l| l,
            else => return,
        };
        for (items) |it| {
            if (it != .expr) continue;
            const text = it.expr;
            var i: usize = 0;
            var space: Space = .param;
            while (i < text.len) {
                const c = text[i];
                if (c == '"' or c == '\'') {
                    i = (std.mem.indexOfScalarPos(u8, text, i + 1, c) orelse text.len) + 1;
                    continue;
                }
                const word_char = std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c == '.';
                if (!word_char) {
                    if (c == ')') space = .param;
                    i += 1;
                    continue;
                }
                var j = i;
                while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_' or text[j] == '$' or text[j] == '.')) j += 1;
                var k = j;
                while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
                const call = k < text.len and text[k] == '(';
                // A number (`1.5k`, `2e-3`) starts with a digit or a point.
                if (call) {
                    space = expr.argSpace(text[i..j]);
                } else if (std.ascii.isAlphabetic(c) or c == '_') try sp.learn(space, text[i..j]);
                i = j;
            }
        }
    }

    /// A name built for its statement, or read from a line that goes away,
    /// is copied: the table outlives both.
    fn learn(sp: *Spelling, space: Space, name: []const u8) Allocator.Error!void {
        for (name) |c| {
            if (!std.ascii.isUpper(c)) continue;
            return sp.mixed.getPtr(space).put(name);
        }
    }

    fn deinit(sp: *Spelling) void {
        for (&sp.mixed.values) |*set| set.deinit();
    }

    /// The one spelling of the name `raw` of `space`. A parameter the
    /// netlist defines is spelled the way its first definition spells it.
    fn spell(sp: *const Spelling, arena: Allocator, space: Space, raw: []const u8) Allocator.Error![]const u8 {
        if (raw.len > 256) return raw;
        if (space != .param) return sp.lookup(space, raw, raw);
        const low = try lowered(arena, raw);
        return sp.params.get(low) orelse sp.lookup(.param, low, raw);
    }

    /// The capitalised spelling of `name` among those of `space`, else `fallback`.
    fn lookup(sp: *const Spelling, space: Space, name: []const u8, fallback: []const u8) []const u8 {
        const k = sp.mixed.getPtrConst(space).getKey(name) orelse return fallback;
        if (sp.needed) |n| if (!std.mem.eql(u8, k, fallback)) {
            n.sets.getPtr(space).put(ir.big, k, {}) catch {
                n.failed = true;
            };
        };
        return k;
    }

    /// Keep only the names `needed` recorded: a pass that reads the same
    /// statements again gets the same answers from the smaller tables.
    fn prune(sp: *Spelling) void {
        const n = sp.needed orelse return;
        sp.needed = null;
        if (n.failed) return;
        for (&sp.mixed.values, &n.sets.values) |*mixed, *set| {
            var small: ir.NameSet = .{ .src = sp.src, .perm = sp.perm };
            var it = set.keyIterator();
            while (it.next()) |k| small.put(k.*) catch {
                small.deinit();
                return;
            };
            mixed.deinit();
            mixed.* = small;
        }
    }

    fn atom(sp: *const Spelling, arena: Allocator, space: Space, v: Value) Allocator.Error!Value {
        switch (v) {
            .atom => |a| return .{ .atom = try sp.spell(arena, space, a) },
            .list => |items| {
                const out: []Value = @constCast(items);
                for (out) |*it| if (it.* == .atom) {
                    it.* = .{ .atom = try sp.spell(arena, space, it.atom) };
                };
                return v;
            },
            else => return v,
        }
    }

    /// Names, nodes and keys of one freshly read statement.
    fn statement(sp: *Spelling, arena: Allocator, st: *ir.Stmt) Allocator.Error!void {
        const defines_params = st.kind == .param or st.kind == .subckt;
        const node_keys = st.kind == .ic or st.kind == .nodeset;
        var buf: [schema.max_slots]Value = undefined;
        const vals = st.unpack(&buf);
        for (schema.info(st.kind).slots, 0..) |sl, i| {
            switch (sl.ty) {
                .name, .node, .ident => {
                    // Functions are called in any case, and a model's type
                    // word is a keyword, not a name: their one spelling is
                    // the lower-case one.
                    if (st.kind == .func or sl.space == null) {
                        if (vals[i] == .atom) vals[i] = .{ .atom = try lowered(arena, vals[i].atom) };
                    } else vals[i] = try sp.atom(arena, sl.space.?, vals[i]);
                },
                .params => {
                    if (vals[i] != .params) continue;
                    // The statement owns its parameter list: edit it in place.
                    const out: []ir.Param = @constCast(vals[i].params);
                    for (out) |*p| {
                        if (defines_params) {
                            // A parameter is spelled the way its first definition spells it.
                            const gop = try sp.params.getOrPut(sp.perm, try lowered(arena, p.key));
                            if (gop.found_existing) p.key = gop.value_ptr.* else {
                                gop.key_ptr.* = try sp.keep(gop.key_ptr.*);
                                gop.value_ptr.* = try sp.keep(p.key);
                            }
                        } else if (node_keys) {
                            p.key = try sp.spell(arena, .node, p.key);
                        } else if (st.kind == .instance) {
                            // A subcircuit's parameter, which may be defined
                            // in another file: spelled as the source does.
                            p.key = try sp.spell(arena, .param, p.key);
                        } else p.key = sp.params.get(try lowered(arena, p.key)) orelse try lowered(arena, p.key);
                    }
                },
                else => {},
            }
        }
        try st.store(arena, vals);
    }

    /// A word of an expression: a call (`space` null), or a name of `space`.
    fn identifier(sp: *const Spelling, arena: Allocator, word: []const u8, space: ?Space) Allocator.Error![]const u8 {
        const low = try lowered(arena, word);
        const in = space orelse return low;
        if (in == .param) if (sp.params.get(low)) |p| return p;
        return sp.lookup(in, low, low);
    }

    fn signal(sp: *const Spelling, arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
        var args: [3][]const u8 = undefined;
        const form, const n = signalParts(text, &args) orelse return text;
        if (n == 0) return text;
        var out: std.ArrayList(u8) = .empty;
        try out.print(arena, "{s}(", .{text[0..std.mem.indexOfScalar(u8, text, '(').?]});
        for (args[0..n], 0..) |a, i| {
            if (i > 0) try out.append(arena, ',');
            try out.appendSlice(arena, if (signalSpace(form, i)) |space| try sp.spell(arena, space, a) else a);
        }
        try out.append(arena, ')');
        return out.items;
    }
};

fn resolveName(ctx: ?*const anyopaque, arena: Allocator, word: []const u8, space: ?Space) Allocator.Error![]const u8 {
    const sp: *const Spelling = @ptrCast(@alignCast(ctx.?));
    return sp.identifier(arena, word, space);
}

const Reader = struct {
    g: *const Grammar,
    arena: Allocator,
    spell: Spelling,
    lines: *lexer.Lines,
    report: *ir.Report,
    m: Matcher,
    /// Index into the matcher's window.
    ti: usize = 0,
    boiler: []const []const u8 = &.{},
    /// The grammar's `header folded` lines, normalized; seeing one sets `folded`.
    folded_boiler: []const []const u8 = &.{},
    folded: bool = false,

    fn toks(self: *const Reader) []const Tok {
        return self.m.win.toks.items;
    }

    fn skipLine(self: *Reader) void {
        while (self.toks()[self.ti].tag != .nl) self.ti += 1;
        self.ti += 1;
    }

    fn isBoilerplate(self: *Reader, text: []const u8) Allocator.Error!bool {
        if (self.boiler.len == 0 and self.folded_boiler.len == 0) return false;
        const n = try normalize(self.arena, self.g.lex.case_sensitive, text);
        for (self.boiler) |b| if (std.mem.eql(u8, b, n)) return true;
        for (self.folded_boiler) |b| if (std.mem.eql(u8, b, n)) {
            self.folded = true;
            return true;
        };
        return false;
    }

    /// The number of the last line that starts with the closing word of
    /// `b`, 0 when there is none (`closed`).
    fn lastClose(self: *const Reader, b: *const grammar.Block) u32 {
        // ponytail: the whole file is scanned for each such opening line;
        // keep the number if a library of very many sections is slow to read.
        const word = b.close[0].text;
        var it = std.mem.splitScalar(u8, self.lines.src, '\n');
        var no: u32 = 0;
        var last: u32 = 0;
        while (it.next()) |l| {
            no += 1;
            const t = std.mem.trimStart(u8, l, " \t");
            if (t.len < word.len or (t.len > word.len and !std.ascii.isWhitespace(t[word.len]))) continue;
            const head = t[0..word.len];
            if (if (self.g.lex.case_sensitive) std.mem.eql(u8, head, word) else std.ascii.eqlIgnoreCase(head, word)) last = no;
        }
        return last;
    }

    fn body(self: *Reader, block: ?*const grammar.Block, owner: ?*ir.Stmt) Allocator.Error![]ir.Stmt {
        // A growing list leaves every outgrown copy behind in an arena. Grow
        // it on the page allocator and keep one copy of the final size.
        var list: Grow = .{ .gpa = ir.big };
        defer list.items.deinit(list.gpa);
        return self.bodyInto(block, owner, &list);
    }

    /// The netlist itself, as a list made in the arena at its largest
    /// possible size: a body takes at least one line per statement. The
    /// pages it does not fill are never touched, and copying a list as long
    /// as the netlist from `Grow` would double it for a moment.
    fn top(self: *Reader) Allocator.Error![]ir.Stmt {
        var list: Grow = .{ .gpa = self.arena };
        try list.items.ensureTotalCapacityPrecise(self.arena, std.mem.count(u8, self.lines.src, "\n") + 1);
        return self.bodyInto(null, null, &list);
    }

    const Grow = struct {
        gpa: Allocator,
        items: std.ArrayList(ir.Stmt) = .empty,

        fn append(g: *Grow, _: Allocator, st: ir.Stmt) Allocator.Error!void {
            try g.items.append(g.gpa, st);
        }

        fn toOwnedSlice(g: *Grow, arena: Allocator) Allocator.Error![]ir.Stmt {
            if (g.gpa.ptr == arena.ptr) return g.items.items;
            return arena.dupe(ir.Stmt, g.items.items);
        }
    };

    fn bodyInto(self: *Reader, block: ?*const grammar.Block, owner: ?*ir.Stmt, out: anytype) Allocator.Error![]ir.Stmt {
        while (true) switch (try self.step(block, owner, out)) {
            .more => {},
            .closed => return out.toOwnedSlice(self.arena),
            .eof => break,
        };
        if (block) |b| self.report.add(.@"error", .invalid, 0, "{s} block is not closed", .{@tagName(b.kind)});
        return out.toOwnedSlice(self.arena);
    }

    const Step = enum { more, closed, eof };

    /// Read what starts at the next line: a statement (a block with its
    /// whole body), the comments in front of it, or the end of `block`.
    fn step(self: *Reader, block: ?*const grammar.Block, owner: ?*ir.Stmt, out: anytype) Allocator.Error!Step {
        {
            self.m.win.drop(self.ti);
            self.ti = 0;
            if (!try self.m.win.has(0)) return .eof;
            const ti = self.ti;
            const first = self.toks()[ti];
            const line = self.lines.get(first.lno);
            if (first.tag == .nl) {
                self.ti += 1;
                return .more;
            }
            if (first.tag == .comment or first.tag == .blank) {
                try out.append(self.arena, .{
                    .kind = .comment,
                    .raw = if (first.tag == .blank) ir.blank_line else first.text,
                    .line = line.no,
                });
                self.ti += 2;
                return .more;
            }
            if (try self.isBoilerplate(line.text)) {
                self.skipLine();
                return .more;
            }
            if (first.tag == .word) {
                if (self.toks()[ti + 1].tag == .nl) {
                    for (self.g.wraps) |w| {
                        if (std.mem.eql(u8, first.text, w.open) or std.mem.eql(u8, first.text, w.close)) {
                            self.skipLine();
                            return .more;
                        }
                    }
                }
            }
            if (block) |b| {
                if (try self.m.run(b.kind, b.close, ti)) {
                    const tail = self.toks()[self.m.end].text;
                    if (tail.len > 0) try out.append(self.arena, .{ .kind = .comment, .raw = tail, .line = line.no });
                    self.ti = self.m.end + 1;
                    return .closed;
                }
                for (b.inner) |pat| {
                    if (try self.m.run(b.kind, pat, ti)) {
                        try self.m.applyTo(owner.?);
                        if (!self.g.lex.case_sensitive) try self.spell.statement(self.arena, owner.?);
                        self.ti = self.m.end + 1;
                        return .more;
                    }
                }
            }
            for (self.g.blocks) |*b| {
                if (!try self.m.run(b.kind, b.open, ti)) continue;
                if (b.closed and self.lastClose(b) < line.no) continue;
                var st = try self.m.build(line.no);
                // Segments are numbers: `.tran 1n 1u SWEEP ...` is a spread.
                if (st.kind == .tran and !numericSegments(&st)) continue;
                st.tail = self.toks()[self.m.end].text;
                if (!self.g.lex.case_sensitive) try self.spell.statement(self.arena, &st);
                self.ti = self.m.end + 1;
                st.body = try self.body(b, &st);
                try out.append(self.arena, st);
                return .more;
            }
            for (self.g.rules) |*rule| {
                if (rule.dir == .write or self.g.isEnding(rule)) continue;
                if (!try self.m.run(rule.kind, rule.pat, ti)) continue;
                // A rule for `opaque` names a statement this grammar recognises
                // but does not translate; it stops later rules from misreading it.
                if (rule.kind == .@"opaque") break;
                var st = try self.m.build(line.no);
                // Segments are numbers: `.tran 1n 1u SWEEP ...` is a spread.
                if (st.kind == .tran and !numericSegments(&st)) continue;
                if (st.kind == .options) if (self.m.clash()) |sl| self.report.add(.@"error", .loss, line.no, "{s}.{s} is given twice with different values, by two keys {s} reads as one; the last is kept", .{
                    @tagName(st.kind), schema.info(st.kind).slots[sl].name, self.g.name,
                });
                st.tail = self.toks()[self.m.end].text;
                if (!self.g.lex.case_sensitive) try self.spell.statement(self.arena, &st);
                if (st.kind == .model) try mapModel(self.arena, self.g, &st, self.report);
                try self.canonStmt(&st);
                self.flagOddValues(&st);
                // Comment lines met inside a multi-line statement go before it.
                for (self.toks()[ti..self.m.end]) |ct| {
                    if (ct.tag == .comment) try out.append(self.arena, .{ .kind = .comment, .raw = ct.text, .line = self.lines.get(ct.lno).no });
                }
                self.ti = self.m.end + 1;
                try out.append(self.arena, st);
                return .more;
            }
            if (try self.spreadAt(ti, line.no)) |st| {
                try out.append(self.arena, st);
                return .more;
            }
            if (try self.splitAt(ti, line.no, out)) return .more;
            if (first.tag == .word) {
                for (self.g.raws) |rb| {
                    if (!std.mem.eql(u8, first.text, rb.open)) continue;
                    var raw: std.ArrayList(u8) = .empty;
                    while (try self.m.win.has(self.ti)) {
                        const t = self.toks()[self.ti];
                        if (raw.items.len > 0) try raw.append(self.arena, '\n');
                        const rl = self.lines.get(t.lno);
                        try raw.appendSlice(self.arena, rl.text);
                        if (rl.tail.len > 0 and self.g.lex.tail_comments.len > 0) {
                            try raw.print(self.arena, " {s} {s}", .{ self.g.lex.tail_comments[0], rl.tail });
                        }
                        self.skipLine();
                        if (t.tag == .word and std.mem.eql(u8, t.text, rb.close)) break;
                    }
                    try out.append(self.arena, .{ .kind = .@"opaque", .raw = try raw.toOwnedSlice(self.arena), .line = line.no });
                    return .more;
                }
            }
            try out.append(self.arena, .{ .kind = .@"opaque", .raw = line.text, .line = line.no, .tail = line.tail });
            self.skipLine();
            return .more;
        }
    }

    /// A line whose keyword starts rules of two kinds may hold statements
    /// of both, one after another: HSPICE's `.param f(x)='x*2' k=1`. Each
    /// shortest run that some rule reads is a statement, and the keyword is
    /// put back in front of what is left.
    fn splitAt(self: *Reader, ti: usize, line_no: u32, out: anytype) Allocator.Error!bool {
        const head = self.toks()[ti];
        if (head.tag != .word) return false;
        var first_kind: ?Kind = null;
        const shared = for (self.g.rules) |*rule| {
            if (rule.dir == .write or rule.pat.len == 0 or rule.pat[0].tag != .lit) continue;
            if (!std.mem.eql(u8, rule.pat[0].text, head.text)) continue;
            if (first_kind) |k| {
                if (k != rule.kind) break true;
            } else first_kind = rule.kind;
        } else false;
        if (!shared) return false;
        var end = ti;
        while (self.toks()[end].tag != .nl) end += 1;
        const items = self.m.win.toks.items;
        // Every token changed, to put back whatever happens.
        var saved: std.ArrayList(struct { usize, Tok }) = .empty;
        defer for (saved.items) |s| {
            items[s[0]] = s[1];
        };
        var found: std.ArrayList(ir.Stmt) = .empty;
        var from = ti;
        outer: while (true) {
            if (try self.ruleAt(from, line_no)) |st| {
                try found.append(self.arena, st);
                break;
            }
            var j = from + 2;
            while (j < end) : (j += 1) {
                try saved.append(self.arena, .{ j, items[j] });
                items[j] = items[end];
                items[j].text = "";
                const st = try self.ruleAt(from, line_no);
                items[j] = saved.pop().?[1];
                const s = st orelse continue;
                try found.append(self.arena, s);
                try saved.append(self.arena, .{ j - 1, items[j - 1] });
                items[j - 1] = head;
                from = j - 1;
                continue :outer;
            }
            return false;
        }
        for (found.items) |st| try out.append(self.arena, st);
        self.ti = end + 1;
        return true;
    }

    /// The statement a rule reads from `ti` to the end of its line.
    fn ruleAt(self: *Reader, ti: usize, line_no: u32) Allocator.Error!?ir.Stmt {
        for (self.g.rules) |*rule| {
            if (rule.dir == .write) continue;
            if (!try self.m.run(rule.kind, rule.pat, ti)) continue;
            if (rule.kind == .@"opaque") return null;
            var st = try self.m.build(line_no);
            if (!self.g.lex.case_sensitive) try self.spell.statement(self.arena, &st);
            try self.canonStmt(&st);
            self.flagOddValues(&st);
            return st;
        }
        return null;
    }

    /// `spread`: an analysis line that ends with the rule of a block kind
    /// (`.tran 1n 1u sweep monte=30`) is that block around the analysis.
    fn spreadAt(self: *Reader, ti: usize, line_no: u32) Allocator.Error!?ir.Stmt {
        if (self.g.spreads.len == 0) return null;
        var end = ti;
        while (self.toks()[end].tag != .nl) end += 1;
        for (self.g.rules) |*sr| {
            if (sr.dir == .write or !self.g.isSpread(sr.kind)) continue;
            if (self.g.spreadWord(sr.kind) != null and !self.g.isEnding(sr)) continue;
            var j = ti + 1;
            while (j < end) : (j += 1) {
                if (!try self.m.run(sr.kind, sr.pat, j)) continue;
                var wrap = try self.m.build(line_no);
                wrap.tail = self.toks()[end].text;
                // The line without its suffix, read as a statement of its own.
                const items = self.m.win.toks.items;
                const cut = items[j];
                items[j] = items[end];
                items[j].text = "";
                defer items[j] = cut;
                for (self.g.rules) |*rule| {
                    if (rule.dir == .write or schema.info(rule.kind).class != .analysis) continue;
                    if (!try self.m.run(rule.kind, rule.pat, ti)) continue;
                    var st = try self.m.build(line_no);
                    try self.canonStmt(&st);
                    wrap.body = try self.arena.dupe(ir.Stmt, &.{st});
                    self.ti = end + 1;
                    return wrap;
                }
                return null;
            }
        }
        return null;
    }

    /// Closed-set values to their canonical names, and the values this
    /// dialect leaves unsaid made explicit.
    fn canonStmt(self: *Reader, st: *ir.Stmt) Allocator.Error!void {
        var buf: [schema.max_slots]Value = undefined;
        const vals = st.unpack(&buf);
        for (self.g.enums) |*e| {
            if (e.kind != st.kind or vals[e.slot] != .atom) continue;
            const have = vals[e.slot].atom;
            const hit = for (e.pairs) |pr| {
                if (std.mem.eql(u8, pr.spelling, have)) break pr.canon;
            } else {
                self.report.add(.warning, .invalid, st.line, "{s}.{s} = {s} is not a value the {s} grammar lists; kept as written", .{
                    @tagName(st.kind), schema.info(st.kind).slots[e.slot].name, have, self.g.name,
                });
                continue;
            };
            vals[e.slot] = .{ .atom = hit };
        }
        for (self.g.implied) |im| {
            // Options hold for the whole netlist, not per statement: the
            // writer says a default the target does not share (`defaultOptions`).
            if (im.kind == .options) continue;
            if (im.kind != st.kind or vals[im.slot] != .none) continue;
            if (im.when_slot != grammar.no_slot and (vals[im.when_slot] != .atom or !std.mem.eql(u8, vals[im.when_slot].atom, im.when_atom))) continue;
            vals[im.slot] = if (schema.info(st.kind).slots[im.slot].ty == .value)
                (if (lexer.parseNumber(self.arena, &self.g.lex, im.text)) |n| Value{ .num = n } else Value{ .expr = im.text })
            else
                Value{ .atom = im.text };
        }
        try st.store(self.arena, vals);
    }

    fn finishValue(self: *Reader, v: Value, line: u32) Allocator.Error!Value {
        switch (v) {
            .expr => |e| {
                var problems: std.ArrayList(expr.Problem) = .empty;
                const names: expr.Resolver = if (self.g.lex.case_sensitive) .{} else .{ .ctx = &self.spell, .func = resolveName };
                const canon = try expr.read(self.arena, self.g, e, names, &problems);
                for (problems.items) |pb| {
                    self.report.add(.@"error", .invalid, line, "expression '{s}': {s} is not an operator the {s} grammar lists; copied as written", .{ e, pb.text, self.g.name });
                }
                return .{ .expr = canon };
            },
            .list => |items| {
                const out: []Value = @constCast(items);
                for (out) |*it| it.* = try self.finishValue(it.*, line);
                return v;
            },
            .params => |ps| {
                const out: []ir.Param = @constCast(ps);
                for (out) |*pp| pp.val = try self.finishValue(pp.val, line);
                return v;
            },
            else => return v,
        }
    }

    /// Last pass, when every name in the netlist is known: expressions,
    /// references to instances, and the names inside signals.
    fn finish(self: *Reader, stmts: []ir.Stmt) Allocator.Error!void {
        const fold_case = !self.g.lex.case_sensitive;
        for (stmts) |*st| {
            var buf: [schema.max_slots]Value = undefined;
            const vals = st.unpack(&buf);
            for (schema.info(st.kind).slots, 0..) |sl, i| {
                if (sl.ty == .ref) {
                    if (fold_case) vals[i] = try self.spell.atom(self.arena, sl.space.?, vals[i]);
                } else if (sl.ty == .signal and fold_case) {
                    switch (vals[i]) {
                        .atom => |a| vals[i] = .{ .atom = try self.spell.signal(self.arena, a) },
                        .list => |items| {
                            const out = try self.arena.alloc(Value, items.len);
                            for (items, 0..) |it, k| out[k] = if (it == .atom) Value{ .atom = try self.spell.signal(self.arena, it.atom) } else try self.finishValue(it, st.line);
                            vals[i] = .{ .list = out };
                        },
                        else => {},
                    }
                } else vals[i] = try self.finishValue(vals[i], st.line);
            }
            try st.store(self.arena, vals);
            try self.finish(st.body);
        }
    }

    fn flagOddValues(self: *Reader, st: *const ir.Stmt) void {
        for (st.values()) |v| {
            if (v != .params) continue;
            if (schema.info(st.kind).class == .control) continue;
            for (v.params) |p| {
                if (p.val == .atom and !isVersion(p.val.atom)) self.report.add(.warning, .invalid, st.line, "{s}={s}: not a number, a name or a delimited expression in {s}; copied as written", .{ p.key, p.val.atom, self.g.name });
            }
        }
    }

    /// First pass: names of models and subcircuits, so the real pass can tell
    /// `R1 a b rmod` (a model) from `R1 a b rval` (a parameter).
    fn collectDeclared(self: *Reader, declared: *Declared) Allocator.Error!void {
        const fold_case = !self.g.lex.case_sensitive;
        const win = self.m.win;
        // The statements built here are thrown away: build them in a
        // scratch arena. Only names that go into `declared` and the
        // spelling tables are kept, and those are made in `self.arena`.
        var scratch: std.heap.ArenaAllocator = .init(ir.big);
        defer scratch.deinit();
        self.m.arena = scratch.allocator();
        defer {
            self.m.arena = self.arena;
            self.m.log = .empty;
        }
        var ti: usize = 0;
        while (true) {
            win.drop(ti);
            ti = 0;
            _ = scratch.reset(.retain_capacity);
            self.m.log = .empty;
            if (!try win.has(0)) break;
            // A line with capitals is read in full, so the spelling table
            // learns its names and nodes, and not its keywords (`DC`).
            var caps = false;
            if (fold_case) {
                var k = ti;
                while (self.toks()[k].tag != .nl) : (k += 1) {
                    const t = self.toks()[k];
                    // The lexer folds a word into a fresh copy only if it has capitals.
                    if (t.text.ptr != t.raw.ptr) caps = true;
                }
            }
            var found: ?ir.Stmt = null;
            for (self.g.rules) |*rule| {
                if (rule.dir == .write) continue;
                if (!caps and rule.kind != .model and rule.kind != .param) continue;
                if (try self.m.run(rule.kind, rule.pat, ti)) {
                    found = try self.m.build(0);
                    break;
                }
            }
            if (found == null) {
                blocks: for (self.g.blocks) |*b| {
                    if (!caps and b.kind != .subckt) continue;
                    for ([_][]const []const Node{ &.{b.open}, b.inner, if (caps) &.{b.close} else &.{} }) |pats| {
                        for (pats) |pat| {
                            if (try self.m.run(b.kind, pat, ti)) {
                                found = try self.m.build(0);
                                break :blocks;
                            }
                        }
                    }
                }
            }
            if (found) |*st| {
                if (caps) try self.spell.names(st);
                if (st.kind == .model or st.kind == .param or st.kind == .subckt) {
                    if (fold_case) try self.spell.statement(scratch.allocator(), st);
                    const n = st.get("name");
                    if (st.kind != .param and n == .atom) {
                        const name = if (fold_case) try Spelling.lowered(scratch.allocator(), n.atom) else n.atom;
                        const gop = try declared.getOrPut(self.spell.perm, name);
                        if (!gop.found_existing) gop.key_ptr.* = try self.spell.keep(name);
                    }
                }
            }
            while (self.toks()[ti].tag != .nl) ti += 1;
            ti += 1;
            // Every name kept from the lines before is a copy.
            self.lines.recycle();
        }
    }
};

fn bagEntryFor(nodes: []const Node, key: []const u8) ?grammar.BagEntry {
    for (nodes) |n| {
        if (n.tag == .bag) {
            for (n.bag) |e| {
                if ((e.form == .plain or e.form == .quoted) and e.tag_slot == grammar.no_slot and std.mem.eql(u8, e.key, key)) return e;
            }
        }
        if (bagEntryFor(n.kids, key)) |e| return e;
    }
    return null;
}

/// Does the statement say what the rule's `k=slot!` entries require? A
/// Spectre port's `r=` is its z0, a source's `r=` is not.
fn requiredMet(nodes: []const Node, st: *const ir.Stmt, params: []const ir.Param) bool {
    for (nodes) |n| {
        if (n.tag == .bag) for (n.bag) |e| {
            if (!e.required or st.at(e.slot) != .none) continue;
            for (params) |p| {
                if (std.mem.eql(u8, p.key, e.key)) break;
            } else return false;
        };
        if (!requiredMet(n.kids, st, params)) return false;
    }
    return true;
}

/// An instance retagged through its model (`v1 (1 0) v type="pulse" ...` where
/// `v` is a model of vsource) still has everything in `params`. Move the keys
/// this dialect's rule for that kind knows into their slots.
fn rebindParams(g: *const Grammar, arena: Allocator, stmts: []ir.Stmt) Allocator.Error!void {
    for (stmts) |*st| {
        try rebindParams(g, arena, st.body);
        if (schema.info(st.kind).class != .device or st.kind == .instance) continue;
        const pi = schema.slotIndex(st.kind, "params") orelse continue;
        if (st.at(pi) != .params) continue;
        var kept: std.ArrayList(ir.Param) = .empty;
        for (st.at(pi).params) |p| {
            const entry = for (g.rules) |*rule| {
                if (rule.kind != st.kind or !requiredMet(rule.pat, st, st.at(pi).params)) continue;
                if (bagEntryFor(rule.pat, p.key)) |e| break e;
            } else null;
            const e = entry orelse {
                try kept.append(arena, p);
                continue;
            };
            if (st.at(e.slot) != .none) {
                try kept.append(arena, p);
                continue;
            }
            const want_atom = schema.info(st.kind).slots[e.slot].ty == .atom;
            try st.set(arena, e.slot, switch (p.val) {
                .expr => |x| if (want_atom) Value{ .atom = x } else p.val,
                .str => |x| if (want_atom) Value{ .atom = x } else p.val,
                else => p.val,
            });
        }
        try st.set(arena, pi, if (kept.items.len > 0) .{ .params = try kept.toOwnedSlice(arena) } else .none);
    }
}

fn isBound(v: Value) bool {
    return switch (v) {
        .none => false,
        .list => |l| l.len > 0,
        .params => |p| p.len > 0,
        else => true,
    };
}

/// A `move a.x -> b.y` in the grammar says where this dialect writes the
/// value. Reading puts it back where the canonical IR keeps it.
fn undoMoves(g: *const Grammar, arena: Allocator, list: *std.ArrayList(ir.Stmt), report: *ir.Report) Allocator.Error!void {
    for (g.moves) |mv| {
        if (mv.oneway) continue;
        var i: usize = 0;
        while (i < list.items.len) : (i += 1) {
            const st = &list.items[i];
            if (st.kind != mv.to or !isBound(st.at(mv.to_slot))) continue;
            const v = st.at(mv.to_slot);
            try st.set(arena, mv.to_slot, .none);
            const home = for (list.items) |*h| {
                if (h.kind == mv.from) break h;
            } else blk: {
                try list.insert(arena, i, try ir.newStmt(arena, mv.from, list.items[i].line));
                i += 1;
                break :blk &list.items[i - 1];
            };
            if (isBound(home.at(mv.from_slot)) and !home.at(mv.from_slot).eql(v)) {
                report.add(.warning, .caveat, list.items[i].line, "{s}.{s} is given more than once with different values; the first is kept", .{
                    @tagName(mv.to), schema.info(mv.to).slots[mv.to_slot].name,
                });
                continue;
            }
            try home.set(arena, mv.from_slot, v);
        }
    }
}

/// A `merge a -> b` in the grammar: this dialect writes one statement as
/// two (HSPICE noise is `.ac` plus `.noise`). Reading makes them one again.
fn undoMerges(g: *const Grammar, arena: Allocator, list: *std.ArrayList(ir.Stmt)) Allocator.Error!void {
    for (g.merges) |mg| {
        var i: usize = 0;
        while (i < list.items.len) : (i += 1) {
            if (list.items[i].kind != mg.into) continue;
            var j = i;
            const from = while (j > 0) {
                j -= 1;
                if (list.items[j].kind == mg.from) break j;
            } else continue;
            const src = list.items[from];
            const dst = &list.items[i];
            for (schema.info(mg.into).slots, 0..) |sl, k| {
                if (isBound(dst.at(k))) continue;
                const fk = schema.slotIndex(mg.from, sl.name) orelse continue;
                try dst.set(arena, k, src.at(fk));
            }
            // Only comments between: the two lines were one statement.
            const adjacent = for (list.items[from + 1 .. i]) |st| {
                if (st.kind != .comment) break false;
            } else true;
            if (!adjacent) continue;
            if (dst.tail.len == 0) {
                dst.tail = src.tail;
                _ = list.orderedRemove(from);
            } else if (src.tail.len > 0) {
                list.items[from] = .{ .kind = .comment, .raw = src.tail, .line = src.line };
                continue;
            } else _ = list.orderedRemove(from);
            i -= 1;
        }
    }
}

/// Several option statements under one heading are one set of options.
pub fn mergeOptions(arena: Allocator, list: *std.ArrayList(ir.Stmt)) Allocator.Error!void {
    const package = schema.slotIndex(.options, "package").?;
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        if (list.items[i].kind != .options) continue;
        var j = i + 1;
        while (j < list.items.len) {
            const b = list.items[j];
            if (b.kind != .options or !list.items[i].at(package).eql(b.at(package))) {
                j += 1;
                continue;
            }
            const a = &list.items[i];
            for (schema.info(.options).slots, 0..) |sl, k| {
                if (!isBound(b.at(k))) continue;
                if (sl.ty == .params and a.at(k) == .params) {
                    try a.set(arena, k, .{ .params = try std.mem.concat(arena, ir.Param, &.{ a.at(k).params, b.at(k).params }) });
                } else try a.set(arena, k, b.at(k)); // a later option overrides an earlier one
            }
            if (a.tail.len == 0) a.tail = b.tail;
            _ = list.orderedRemove(j);
        }
    }
}

/// A binned model block (`model nch bsim4 { 1: ... }`) is the model cards
/// `nch.1`, `nch.2`, ... of the SPICE dialects, each with the block's type.
fn flattenBins(g: *const Grammar, arena: Allocator, list: *std.ArrayList(ir.Stmt), report: *ir.Report) Allocator.Error!void {
    const ni = schema.slotIndex(.model, "name").?;
    const ti = schema.slotIndex(.model, "type").?;
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        const parent = list.items[i];
        if (parent.kind != .model or parent.body.len == 0) continue;
        const bins = parent.body;
        for (bins) |*bin| {
            if (bin.kind != .model or bin.get("name") != .atom) continue;
            const label = std.mem.trimEnd(u8, bin.get("name").atom, ":");
            try bin.set(arena, ni, .{ .atom = try std.fmt.allocPrint(arena, "{s}.{s}", .{ parent.get("name").atom, label }) });
            try bin.set(arena, ti, parent.at(ti));
            try mapModel(arena, g, bin, report);
        }
        _ = list.orderedRemove(i);
        try list.insertSlice(arena, i, bins);
        i += bins.len - 1;
    }
}

/// A Monte Carlo statement with no body of its own (Xyce `.sampling`)
/// runs every analysis of the netlist.
fn gatherMonteCarlo(arena: Allocator, list: *std.ArrayList(ir.Stmt)) Allocator.Error!void {
    for (list.items) |st| {
        if (st.kind == .montecarlo and st.body.len == 0) break;
    } else return;
    var body: std.ArrayList(ir.Stmt) = .empty;
    var i: usize = 0;
    while (i < list.items.len) {
        if (schema.info(list.items[i].kind).class == .analysis and list.items[i].kind != .montecarlo and list.items[i].kind != .alter) {
            try body.append(arena, list.orderedRemove(i));
        } else i += 1;
    }
    for (list.items) |*st| {
        if (st.kind == .montecarlo and st.body.len == 0) {
            st.body = try body.toOwnedSlice(arena);
            break;
        }
    }
}

/// `.alter` (HSPICE): every statement after it, up to the next one, is its
/// body. Where analyses run where they stand (`rerun alter`, Spectre), an
/// alter is followed by the analyses again: those that are the netlist's
/// own are dropped, one-change alters (`a1 alter dev=r1 param=r value=2k`)
/// become bodies, and alters with no analysis between them are one.
fn gatherAlters(g: *const Grammar, arena: Allocator, list: *std.ArrayList(ir.Stmt), report: *ir.Report) Allocator.Error!void {
    const at = for (list.items, 0..) |st, i| {
        if (st.kind == .alter) break i;
    } else return;
    if (!g.isRerun(.alter)) {
        if (g.blockOf(.alter) != null) return;
        var out: std.ArrayList(ir.Stmt) = .fromOwnedSlice(try arena.dupe(ir.Stmt, list.items[0..at]));
        var i = at;
        while (i < list.items.len) {
            var alt = list.items[i];
            var j = i + 1;
            while (j < list.items.len and list.items[j].kind != .alter) j += 1;
            if (alt.body.len == 0) alt.body = try arena.dupe(ir.Stmt, list.items[i + 1 .. j]);
            try out.append(arena, alt);
            i = j;
        }
        list.* = out;
        return;
    }
    // One change each: the body is the edited copy.
    for (list.items[at..], at..) |*alt, i| {
        if (alt.kind != .alter or alt.get("param") != .atom) continue;
        try alt.own(arena);
        const edit = try oneChange(g, arena, list.items[0..i], alt, report) orelse continue;
        alt.body = try arena.dupe(ir.Stmt, &.{edit});
        for ([_][]const u8{ "dev", "mod", "param", "value" }) |n| try alt.set(arena, schema.slotIndex(.alter, n).?, .none);
    }
    var base: std.ArrayList(ir.Stmt) = .empty;
    var rest: std.ArrayList(ir.Stmt) = .empty;
    var alters: std.ArrayList(ir.Stmt) = .empty;
    // Where in `rest` the analyses since the last alter are.
    var run: std.ArrayList(usize) = .empty;
    for (list.items, 0..) |st, i| {
        const analysis = schema.info(st.kind).class == .analysis and st.kind != .alter;
        if (i < at) {
            if (analysis) try base.append(arena, st);
            try rest.append(arena, st);
        } else if (st.kind == .alter) {
            if (alters.items.len > 0 and run.items.len == 0) {
                // No analysis since the last alter: the same rerun.
                const last = &alters.items[alters.items.len - 1];
                last.body = try std.mem.concat(arena, ir.Stmt, &.{ last.body, st.body });
                continue;
            }
            try dropRerun(arena, &rest, &run, base.items, alters.items, report);
            try alters.append(arena, st);
        } else {
            if (analysis) try run.append(arena, rest.items.len);
            try rest.append(arena, st);
        }
    }
    try dropRerun(arena, &rest, &run, base.items, alters.items, report);
    try rest.appendSlice(arena, alters.items);
    list.* = rest;
}

/// The analyses written after an alter: dropped when they are the
/// netlist's own, which every alter reruns.
fn dropRerun(arena: Allocator, rest: *std.ArrayList(ir.Stmt), run: *std.ArrayList(usize), base: []const ir.Stmt, alters: []const ir.Stmt, report: *ir.Report) Allocator.Error!void {
    defer run.clearRetainingCapacity();
    if (alters.len == 0) return;
    var got: std.ArrayList(ir.Stmt) = .empty;
    for (run.items) |k| try got.append(arena, rest.items[k]);
    if (ir.looseListEql(got.items, base)) {
        var n = run.items.len;
        while (n > 0) {
            n -= 1;
            _ = rest.orderedRemove(run.items[n]);
        }
        return;
    }
    const alt = alters[alters.len - 1];
    report.add(.@"error", .invalid, alt.line, "alter '{s}': the analyses after it are not those of the netlist, which an alter reruns; they are kept as analyses of the netlist", .{if (alt.get("name") == .atom) alt.get("name").atom else "?"});
}

/// A one-change alter (`dev=` or `mod=`, `param=`, `value=`) as the
/// statement it changes, edited: an instance or a model card, a parameter,
/// or the temperature.
fn oneChange(g: *const Grammar, arena: Allocator, before: []const ir.Stmt, alt: *const ir.Stmt, report: *ir.Report) Allocator.Error!?ir.Stmt {
    const key = alt.get("param").atom;
    const val = alt.get("value");
    const target: ?[]const u8 = switch (alt.get("dev")) {
        .atom => |a| a,
        else => if (alt.get("mod") == .atom) alt.get("mod").atom else null,
    };
    const name = target orelse {
        var st = try ir.newStmt(arena, if (std.mem.eql(u8, key, "temp")) .options else .param, alt.line);
        if (st.kind == .options) {
            try st.set(arena, schema.slotIndex(.options, "temp").?, val);
        } else try st.set(arena, schema.slotIndex(.param, "params").?, .{ .params = try arena.dupe(ir.Param, &.{.{ .key = key, .val = val }}) });
        return st;
    };
    // The latest version: an earlier alter's copy, else the netlist's.
    var found: ?ir.Stmt = null;
    for (before) |*st| {
        if (st.kind == .alter) {
            for (st.body) |*b| if (namedAs(b, name)) {
                found = b.*;
            };
        } else if (namedAs(st, name)) found = st.*;
    }
    var st = found orelse {
        report.add(.@"error", .invalid, alt.line, "alter: the netlist has no instance or model '{s}'", .{name});
        return null;
    };
    try st.own(arena);
    st.body = &.{};
    st.line = alt.line;
    st.tail = "";
    if (st.kind != .model) {
        for (g.rules) |*rule| {
            if (rule.kind != st.kind) continue;
            const e = bagEntryFor(rule.pat, key) orelse continue;
            try st.set(arena, e.slot, val);
            return st;
        }
    }
    const pi = schema.slotIndex(st.kind, "params") orelse {
        report.add(.@"error", .invalid, alt.line, "alter: {s} '{s}' has no parameter '{s}' here", .{ @tagName(st.kind), name, key });
        return null;
    };
    var ps: std.ArrayList(ir.Param) = .empty;
    if (st.at(pi) == .params) try ps.appendSlice(arena, st.at(pi).params);
    for (ps.items) |*p| {
        if (std.mem.eql(u8, p.key, key)) {
            p.val = val;
            break;
        }
    } else try ps.append(arena, .{ .key = key, .val = val });
    try st.set(arena, pi, .{ .params = ps.items });
    return st;
}

fn namedAs(st: *const ir.Stmt, name: []const u8) bool {
    if (st.kind != .model and schema.info(st.kind).class != .device) return false;
    return st.get("name") == .atom and std.mem.eql(u8, st.get("name").atom, name);
}

/// A multi-segment `.tran tstep1 tstop1 tstep2 tstop2 ...` (HSPICE) runs to
/// the last stop. No other dialect has segments, so it is read as one run to
/// that stop at the smallest step. Numbers after the first pair that do not
/// rise are SPICE's start time and step ceiling: HSPICE reads the first
/// (measured: `.tran 1n 100n 90n` outputs from 90n, `.tran 1n 10n 0 1n`
/// stops at 10n, `.tran 1n 10n 2n 20n` at 20n) and takes the second as
/// nothing.
fn foldSegments(arena: Allocator, list: []ir.Stmt, report: *ir.Report) Allocator.Error!void {
    const seg = schema.slotIndex(.tran, "segments").?;
    const si = schema.slotIndex(.tran, "step").?;
    const ti = schema.slotIndex(.tran, "stop").?;
    for (list) |*st| {
        if (st.kind != .tran or st.at(seg) != .list) continue;
        var items = st.at(seg).list;
        try st.set(arena, seg, .none);
        // The pairs take a trailing UIC with them.
        const last: []const u8 = if (items.len == 0) "" else switch (items[items.len - 1]) {
            .atom, .expr, .str => |x| x,
            else => "",
        };
        if (std.ascii.eqlIgnoreCase(last, "uic")) {
            items = items[0 .. items.len - 1];
            try st.set(arena, schema.slotIndex(.tran, "skip_dc").?, .{ .atom = "yes" });
        }
        const rises = items.len >= 2 and items.len % 2 == 0 and for (0..items.len / 2) |k| {
            const prev = if (k == 0) st.at(ti) else items[2 * k - 1];
            const step = items[2 * k];
            const stop = items[2 * k + 1];
            if (prev != .num or step != .num or stop != .num or stop.num.toFloat() <= prev.num.toFloat()) break false;
        } else true;
        if (!rises) {
            if (items.len > 2) {
                report.add(.@"error", .invalid, st.line, "tran: {d} numbers after the step and stop are neither rising step and stop pairs nor a start time and a step ceiling", .{items.len});
                continue;
            }
            if (items.len > 0) try st.set(arena, schema.slotIndex(.tran, "start").?, items[0]);
            // Measured (docs/verification.md 4.18): the same samples with
            // and without it; `.option delmax` is what caps the step.
            if (items.len > 1) report.add(.info, .caveat, st.line, "tran: HSPICE takes a fourth .TRAN number that is no second segment as nothing (its step cap is .OPTION DELMAX), so it is left out", .{});
            continue;
        }
        var step = st.at(si);
        if (step != .num) {
            report.add(.@"error", .invalid, st.line, "tran: a multi-segment .tran with an expression in it has no smallest step to run at", .{});
            continue;
        }
        var k: usize = 0;
        while (k < items.len) : (k += 2) {
            if (items[k].num.toFloat() < step.num.toFloat()) step = items[k];
        }
        try st.set(arena, si, step);
        try st.set(arena, ti, items[items.len - 1]);
        report.add(.warning, .caveat, st.line, "tran: a multi-segment .tran is one run to its last stop at its smallest step; the output is no longer sampled per segment", .{});
    }
}

fn numericSegments(st: *const ir.Stmt) bool {
    const v = st.at(schema.slotIndex(.tran, "segments").?);
    if (v != .list) return true;
    for (v.list, 0..) |it, i| {
        if (it == .num) continue;
        const last = i + 1 == v.list.len;
        const word: []const u8 = switch (it) {
            .atom, .expr, .str => |x| x,
            else => "",
        };
        if (!(last and std.ascii.eqlIgnoreCase(word, "uic"))) return false;
    }
    return true;
}

/// A `.measure` that names no analysis (HSPICE) measures the last analysis
/// of the netlist.
fn measureAnalysis(arena: Allocator, list: []ir.Stmt) Allocator.Error!void {
    return measureWith(arena, list, lastAnalysis(list, null));
}

/// The last analysis a `.measure` may measure, of `list` and after `before`.
pub fn lastAnalysis(list: []const ir.Stmt, before: ?[]const u8) ?[]const u8 {
    var last = before;
    for (list) |st| switch (st.kind) {
        .tran, .ac, .dc => last = @tagName(st.kind),
        else => {},
    };
    return last;
}

fn measureWith(arena: Allocator, list: []ir.Stmt, last: ?[]const u8) Allocator.Error!void {
    const ai = schema.slotIndex(.measure, "analysis").?;
    const name = last orelse return;
    for (list) |*st| {
        if (st.kind == .measure and st.at(ai) == .none) try st.set(arena, ai, .{ .atom = name });
    }
}

fn normalizeLists(g: *const Grammar, arena: Allocator, stmts: []ir.Stmt, report: *ir.Report) Allocator.Error![]ir.Stmt {
    // Edited in place: a copy of the top-level list would be as large as
    // every statement header in the netlist.
    var list: std.ArrayList(ir.Stmt) = .fromOwnedSlice(stmts);
    for (list.items) |*st| {
        if (st.body.len > 0) st.body = try normalizeLists(g, arena, st.body, report);
    }
    try flattenBins(g, arena, &list, report);
    try gatherMonteCarlo(arena, &list);
    try foldSegments(arena, list.items, report);
    try measureAnalysis(arena, list.items);
    try gatherAlters(g, arena, &list, report);
    try expr.convert(arena, g, list.items, false);
    try undoMoves(g, arena, &list, report);
    try undoMerges(g, arena, &list);
    try mergeOptions(arena, &list);
    return list.toOwnedSlice(arena);
}

/// Does `line` start with the words of a `switch`? Blanks and case aside.
fn startsSwitch(line: []const u8, words: []const u8) bool {
    var a = std.mem.tokenizeAny(u8, line, " \t\r");
    var b = std.mem.tokenizeAny(u8, words, " \t");
    while (b.next()) |w| {
        const x = a.next() orelse return false;
        if (!std.ascii.eqlIgnoreCase(x, w)) return false;
    }
    return true;
}

fn switchOf(g: *const Grammar, line: []const u8) ?*const grammar.Switch {
    for (g.switches) |*s| if (startsSwitch(line, s.words)) return s;
    return null;
}

/// A file that changes language (`simulator lang=spice`) is read one run
/// of lines at a time, each with its own grammar. Lines outside the run
/// are blanked rather than cut, so that line numbers stay those of the file.
fn readSwitched(g: *const Grammar, arena: Allocator, src: []const u8, report: *ir.Report, opts: ir.ReadOptions) Allocator.Error!?ir.Netlist {
    var starts: std.ArrayList(usize) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    var lines: std.ArrayList([]const u8) = .empty;
    while (it.next()) |l| try lines.append(arena, l);
    var other = false;
    for (lines.items, 0..) |l, i| if (switchOf(g, l)) |sw| {
        try starts.append(arena, i);
        other = other or !std.ascii.eqlIgnoreCase(sw.dialect, g.name);
    };
    // Only the header naming the file's own language: nothing to switch.
    if (!other) return null;
    const root = @import("root.zig");
    var out: std.ArrayList(ir.Stmt) = .empty;
    var title: []const u8 = "";
    var from: usize = 0;
    var cur = g;
    var k: usize = 0;
    var folds = false;
    while (from < lines.items.len) {
        const to = if (k < starts.items.len) starts.items[k] else lines.items.len;
        if (to > from) {
            var text: std.ArrayList(u8) = .empty;
            for (lines.items, 0..) |l, i| {
                if (i >= from and i < to) try text.appendSlice(arena, l);
                if (i + 1 < lines.items.len) try text.append(arena, '\n');
            }
            var seg_opts = opts;
            seg_opts.library = opts.library or from > 0;
            const nl = try readPlain(cur, arena, text.items, report, seg_opts);
            if (from == 0) title = nl.title;
            folds = folds or nl.folds_case or !cur.lex.case_sensitive;
            const tag: u8 = if (cur == g) 0 else (try root.internDialect(cur.name)) orelse 0;
            for (nl.stmts) |st| {
                // The blanked lines read as blank lines; they are not the file's.
                if (st.kind == .comment and std.mem.eql(u8, st.raw, ir.blank_line) and (st.line < from + 1 or st.line > to)) continue;
                var s = st;
                if (s.dialect == 0) s.dialect = tag;
                try out.append(arena, s);
            }
        }
        if (k >= starts.items.len) break;
        const sw = switchOf(g, lines.items[starts.items[k]]).?;
        // Back to the file's own language is back to `g`, which may be a
        // grammar loaded from a file, not the built-in of the same name.
        cur = if (std.ascii.eqlIgnoreCase(sw.dialect, g.name)) g else root.find(sw.dialect) orelse g;
        const n = try normalize(arena, cur.lex.case_sensitive, lines.items[starts.items[k]]);
        for (cur.header_folded) |l| folds = folds or std.mem.eql(u8, n, try normalize(arena, cur.lex.case_sensitive, l));
        from = starts.items[k] + 1;
        k += 1;
    }
    var nl: ir.Netlist = .{ .title = title, .dialect = g.name, .library = opts.library, .folds_case = folds, .stmts = out.items };
    try ir.resolveInstances(arena, &nl, opts.env);
    return nl;
}

pub fn read(g: *const Grammar, arena: Allocator, src: []const u8, report: *ir.Report, opts: ir.ReadOptions) Allocator.Error!ir.Netlist {
    const switched = if (g.switches.len > 0 and std.mem.indexOf(u8, src, "lang") != null) try readSwitched(g, arena, src, report, opts) else null;
    const nl = switched orelse try readPlain(g, arena, src, report, opts);
    if (report.lost) return error.OutOfMemory;
    return nl;
}

/// A netlist being read: its lines, what the first pass learnt, and the
/// reader for the passes after it. Made in place, as the reader points
/// into it.
pub const Source = struct {
    cfg: grammar.LexCfg,
    lines: lexer.Lines,
    win: lexer.Window,
    declared: Declared = .empty,
    r: Reader,
    title: []const u8 = "",

    /// Pass one: what the netlist declares and how it spells its names.
    /// Tables go to `perm`; nothing the pass reads is kept unless copied.
    pub fn open(g: *const Grammar, perm: Allocator, src: []const u8, report: *ir.Report, opts: ir.ReadOptions) Allocator.Error!*Source {
        const s = try perm.create(Source);
        s.cfg = g.lex;
        if (opts.library) s.cfg.title = false;
        s.lines = .init(&s.cfg, src, null);
        s.win = .init(&s.cfg, &s.lines);
        // The lines and tokens are outside the arena: freed on the way out
        // with an error too.
        errdefer {
            s.win.deinit();
            s.lines.deinit();
        }
        s.declared = .empty;
        if (opts.env) |e| {
            var it = e.declared.keyIterator();
            while (it.next()) |k| try s.declared.put(perm, k.*, {});
        }
        var boiler: std.ArrayList([]const u8) = .empty;
        for (g.preamble) |l| try boiler.append(perm, try normalize(perm, g.lex.case_sensitive, l));
        for (g.header) |l| try boiler.append(perm, try normalize(perm, g.lex.case_sensitive, l));
        for (g.needs) |n| {
            for (n.lines) |l| try boiler.append(perm, try normalize(perm, g.lex.case_sensitive, l));
        }
        var folded: std.ArrayList([]const u8) = .empty;
        for (g.header_folded) |l| try folded.append(perm, try normalize(perm, g.lex.case_sensitive, l));
        s.r = .{
            .g = g,
            .arena = perm,
            .spell = .{ .perm = perm, .src = src, .mixed = .initFill(.{ .src = src, .perm = perm }) },
            .lines = &s.lines,
            .report = report,
            .boiler = boiler.items,
            .folded_boiler = folded.items,
            .m = .{ .g = g, .arena = perm, .win = &s.win, .lines = &s.lines, .declared = &s.declared },
        };
        errdefer s.r.spell.deinit();
        // The spelling table is filled in the first pass: nothing that pass
        // decides depends on it.
        try s.r.collectDeclared(&s.declared);
        s.title = s.lines.title;
        return s;
    }

    pub fn deinit(s: *Source) void {
        s.r.spell.deinit();
        s.win.deinit();
        s.lines.deinit();
    }

    /// Back to the first line for another pass, making statements in
    /// `arena`. `keep`: as for `lexer.Lines`.
    pub fn rewind(s: *Source, arena: Allocator, keep: ?Allocator) void {
        s.win.rewind(keep);
        s.r.ti = 0;
        s.r.folded = false;
        s.useArena(arena);
    }

    pub fn useArena(s: *Source, arena: Allocator) void {
        s.r.arena = arena;
        s.r.m.arena = arena;
        s.r.m.log = .empty;
    }

    /// The next top-level statements: one, with the comment lines before
    /// it, or the several statements of one line. False at the end.
    pub fn next(s: *Source, out: *std.ArrayList(ir.Stmt)) Allocator.Error!bool {
        while (true) {
            const n = out.items.len;
            switch (try s.r.step(null, null, out)) {
                .eof => return false,
                .closed => unreachable,
                .more => if (out.items.len > n) return true,
            }
        }
    }

    /// Done with every statement read so far: the lines they came from go.
    pub fn between(s: *Source) void {
        s.win.drop(s.r.ti);
        s.r.ti = 0;
        s.lines.recycle();
    }

    /// The spelling a case-folding reader gives every name of `space`: two
    /// names of it that both have it are the same text.
    pub fn canonical(s: *const Source, space: Space, name: []const u8) bool {
        const sp = &s.r.spell;
        var buf: [256]u8 = undefined;
        if (space == .param and name.len <= buf.len) {
            if (sp.params.get(std.ascii.lowerString(&buf, name))) |p| return std.mem.eql(u8, p, name);
        }
        if (sp.mixed.getPtrConst(space).getKey(name)) |k| return std.mem.eql(u8, k, name);
        for (name) |c| if (std.ascii.isUpper(c)) return false;
        return true;
    }

    /// Record, until `prune`, which names of the spelling table answer a
    /// lookup with a spelling of their own.
    pub fn watchSpelling(s: *Source, needed: *Needed) void {
        s.r.spell.needed = needed;
    }

    /// Keep only the names `watchSpelling` recorded; the others answered
    /// every lookup with what it falls back to. Kept whole if the record
    /// could not be made.
    pub fn pruneSpelling(s: *Source) void {
        s.r.spell.prune();
    }

    /// Parameters first defined in a pass after the first (a line split in
    /// two, `splitAt`), which respell names in statements before them.
    pub fn paramCount(s: *const Source) usize {
        return s.r.spell.params.count();
    }

    /// The passes `read` runs over the whole netlist that need nothing but
    /// the statements `next` gave, run on them. `last`: the netlist's last
    /// analysis (`lastAnalysis`), which a `.measure` naming none measures.
    pub fn finishGroup(s: *Source, list: *std.ArrayList(ir.Stmt), report: *ir.Report, last: ?[]const u8) Allocator.Error!void {
        const r = &s.r;
        const g = r.g;
        const arena = r.arena;
        report.phase = ir.Phase.finish;
        try r.finish(list.items);
        report.phase = ir.Phase.bodies;
        for (list.items) |*st| {
            if (st.body.len > 0) st.body = try normalizeLists(g, arena, st.body, report);
        }
        report.phase = ir.Phase.bins;
        try flattenBins(g, arena, list, report);
        report.phase = ir.Phase.segments;
        try foldSegments(arena, list.items, report);
        try measureWith(arena, list.items, last);
        try expr.convert(arena, g, list.items, false);
    }
};

/// What resolving instances and checking model kinds need of the whole
/// netlist (`ir.resolveInstances`, `ir.checkModelKinds`).
pub const Tables = struct {
    models: std.StringHashMapUnmanaged(Kind) = .empty,
    subckts: ir.CaselessSet = .empty,
    families: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(arena: Allocator, env: ?*const ir.Env) Allocator.Error!Tables {
        var t: Tables = .{};
        if (env) |e| {
            var it = e.models.iterator();
            while (it.next()) |kv| try t.models.put(arena, kv.key_ptr.*, kv.value_ptr.*);
            var si = e.subckts.keyIterator();
            while (si.next()) |k| try t.subckts.put(arena, k.*, {});
        }
        return t;
    }

    pub fn add(t: *Tables, k: ir.Keep, stmts: []const ir.Stmt) Allocator.Error!void {
        try ir.collectModels(k.perm, stmts, &t.models, &t.subckts, k.src);
        try ir.collectFamilies(k.perm, stmts, &t.families, k.src);
    }
};

/// The passes `read` ends with, on the statements `Source.next` gave.
pub fn resolveGroup(g: *const Grammar, arena: Allocator, list: []ir.Stmt, t: *const Tables, report: *ir.Report) Allocator.Error!void {
    if (t.models.count() > 0) try ir.retag(arena, list, &t.models, &t.subckts);
    try rebindParams(g, arena, list);
    report.phase = ir.Phase.kinds;
    if (t.models.count() > 0) try ir.checkKinds(list, &t.models, &t.families, report);
}

fn readPlain(g: *const Grammar, arena: Allocator, src: []const u8, report: *ir.Report, opts: ir.ReadOptions) Allocator.Error!ir.Netlist {
    const env = opts.env;
    const s = try Source.open(g, arena, src, report, opts);
    defer s.deinit();
    s.rewind(arena, arena);
    const r = &s.r;
    var nl: ir.Netlist = .{ .title = s.title, .dialect = g.name, .library = opts.library, .stmts = try r.top() };
    nl.folds_case = r.folded;
    try r.finish(nl.stmts);
    nl.stmts = try normalizeLists(g, arena, nl.stmts, report);
    try ir.markUnlistedBuiltins(arena, &nl);
    try ir.resolveInstances(arena, &nl, env);
    try ir.resolveSweeps(arena, &nl);
    try rebindParams(g, arena, nl.stmts);
    try ir.checkModelKinds(arena, &nl, report, env);
    return nl;
}

/// A dotted version number, `3.3.0`: digits with two or more dots.
pub fn isVersion(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isDigit(s[0])) return false;
    var dots: usize = 0;
    for (s) |c| {
        if (c == '.') dots += 1 else if (!std.ascii.isDigit(c)) return false;
    }
    return dots >= 2;
}
