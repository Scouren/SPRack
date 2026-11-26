//! Reader: the statements of a body, one step at a time. A step reads what
//! starts at the next line: a comment, a block with its body, a statement
//! by the first rule that matches, a line split in two, raw text.

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const matcher = @import("matcher.zig");
const spelling = @import("spelling.zig");
const canon = @import("canon.zig");
const source = @import("source.zig");
const Matcher = matcher.Matcher;
const Spelling = spelling.Spelling;
const normalize = source.normalize;
const mapModel = canon.mapModel;
const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Kind = schema.Kind;
const Tok = lexer.Tok;
const Value = ir.Value;

pub const Reader = struct {
    g: *const Grammar,
    arena: Allocator,
    spell: Spelling,
    lines: *lexer.Lines,
    report: *ir.Report,
    m: Matcher,
    /// Index into the matcher's window.
    ti: usize = 0,
    /// How many blocks the line being read is inside, and whether the
    /// limit on that (`ir.max_depth`) was reported.
    depth: usize = 0,
    too_deep: bool = false,
    boiler: []const []const u8 = &.{},
    /// The grammar's `header folded` lines, normalized; seeing one sets `folded`.
    folded_boiler: []const []const u8 = &.{},
    folded: bool = false,

    pub fn toks(self: *const Reader) []const Tok {
        return self.m.win.toks.items;
    }

    pub fn skipLine(self: *Reader) void {
        while (self.toks()[self.ti].tag != .nl) self.ti += 1;
        self.ti += 1;
    }

    pub fn isBoilerplate(self: *Reader, text: []const u8) Allocator.Error!bool {
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
    pub fn lastClose(self: *const Reader, b: *const grammar.Block) u32 {
        // ponytail: the whole file is scanned for each such opening line;
        // keep the number if a library of very many sections is slow to read.
        const word = b.close[0].text;
        var it = std.mem.splitScalar(u8, self.lines.src, '\n');
        var no: u32 = 0;
        var last: u32 = 0;
        while (it.next()) |l| {
            no += 1;
            const t = std.mem.trimStart(u8, l, " \t");
            if (t.len < word.len or (t.len > word.len and !std.ascii.isWhitespace(t[word.len])))
                continue;
            const head = t[0..word.len];
            if (if (self.g.lex.case_sensitive) std.mem.eql(
                u8,
                head,
                word,
            ) else std.ascii.eqlIgnoreCase(head, word)) last = no;
        }
        return last;
    }

    pub fn body(
        self: *Reader,
        block: ?*const grammar.Block,
        owner: ?*ir.Stmt,
    ) Allocator.Error![]ir.Stmt {
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
    pub fn top(self: *Reader) Allocator.Error![]ir.Stmt {
        var list: Grow = .{ .gpa = self.arena };
        try list.items.ensureTotalCapacityPrecise(
            self.arena,
            std.mem.count(u8, self.lines.src, "\n") + 1,
        );
        return self.bodyInto(null, null, &list);
    }

    pub const Grow = struct {
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

    pub fn bodyInto(
        self: *Reader,
        block: ?*const grammar.Block,
        owner: ?*ir.Stmt,
        out: anytype,
    ) Allocator.Error![]ir.Stmt {
        while (true) switch (try self.step(block, owner, out)) {
            .more => {},
            .closed => return out.toOwnedSlice(self.arena),
            .eof => break,
        };
        if (block) |b|
            self.report.add(.@"error", .invalid, 0, "{s} block is not closed", .{@tagName(b.kind)});
        return out.toOwnedSlice(self.arena);
    }

    pub const Step = enum { more, closed, eof };

    /// Read what starts at the next line: a statement (a block with its
    /// whole body), the comments in front of it, or the end of `block`.
    pub fn step(
        self: *Reader,
        block: ?*const grammar.Block,
        owner: ?*ir.Stmt,
        out: anytype,
    ) Allocator.Error!Step {
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
                        if (std.mem.eql(u8, first.text, w.open) or std.mem.eql(
                            u8,
                            first.text,
                            w.close,
                        )) {
                            self.skipLine();
                            return .more;
                        }
                    }
                }
            }
            if (block) |b| {
                if (try self.m.run(b.kind, b.close, ti)) {
                    const tail = self.toks()[self.m.end].text;
                    if (tail.len > 0)
                        try out.append(
                            self.arena,
                            .{ .kind = .comment, .raw = tail, .line = line.no },
                        );
                    self.ti = self.m.end + 1;
                    return .closed;
                }
                for (b.inner) |pat| {
                    if (try self.m.run(b.kind, pat, ti)) {
                        try self.m.applyTo(owner.?);
                        if (!self.g.lex.case_sensitive)
                            try self.spell.statement(self.arena, owner.?);
                        self.ti = self.m.end + 1;
                        return .more;
                    }
                }
            }
            for (self.g.blocks) |*b| {
                if (!try self.m.run(b.kind, b.open, ti)) continue;
                if (b.closed and self.lastClose(b) < line.no) continue;
                // Deeper than any netlist nests: no block, so no stack
                // overflow; the line goes to the rules, and so to text.
                if (self.depth >= ir.max_depth) {
                    if (!self.too_deep)
                        self.report.add(
                            .@"error",
                            .invalid,
                            line.no,
                            "blocks nested more than {d} deep: from here a line that would " ++
                                "open one deeper is read as a statement, or kept as text",
                            .{ir.max_depth},
                        );
                    self.too_deep = true;
                    break;
                }
                var st = try self.m.build(line.no);
                // Segments are numbers: `.tran 1n 1u SWEEP ...` is a spread.
                if (st.kind == .tran and !numericSegments(&st)) continue;
                st.tail = self.toks()[self.m.end].text;
                if (!self.g.lex.case_sensitive) try self.spell.statement(self.arena, &st);
                self.ti = self.m.end + 1;
                self.depth += 1;
                defer self.depth -= 1;
                st.body = try self.body(b, &st);
                try out.append(self.arena, st);
                return .more;
            }
            for (self.g.readCandidates(if (first.tag == .word) first.text else null)) |ri| {
                const rule = &self.g.rules[ri];
                if (rule.dir == .write or self.g.isEnding(rule)) continue;
                if (!self.g.ruleHere(rule, if (block) |b| b.kind else null)) continue;
                if (!try self.m.run(rule.kind, rule.pat, ti)) continue;
                // A rule for `opaque` names a statement this grammar recognises
                // but does not translate; it stops later rules from misreading it.
                if (rule.kind == .@"opaque") break;
                var st = try self.m.build(line.no);
                // Segments are numbers: `.tran 1n 1u SWEEP ...` is a spread.
                if (st.kind == .tran and !numericSegments(&st)) continue;
                if (st.kind == .options)
                    if (self.m.clash()) |sl|
                        self.report.add(.@"error", .loss, line.no, "{s}.{s} is given twice " ++
                            "with different values, by two keys {s} reads as one; the last is " ++
                            "kept", .{
                            @tagName(st.kind), schema.info(st.kind).slots[sl].name, self.g.name,
                        });
                st.tail = self.toks()[self.m.end].text;
                if (!self.g.lex.case_sensitive) try self.spell.statement(self.arena, &st);
                if (st.kind == .model) try mapModel(self.arena, self.g, &st, self.report);
                try self.canonStmt(&st);
                self.flagOddValues(&st);
                // Comment lines met inside a multi-line statement go before it.
                for (self.toks()[ti..self.m.end]) |ct| {
                    if (ct.tag == .comment)
                        try out.append(
                            self.arena,
                            .{
                                .kind = .comment,
                                .raw = ct.text,
                                .line = self.lines.get(ct.lno).no,
                            },
                        );
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
                    if (rb.kind) |k| if (k == .embed) {
                        // `embed "name" <<<FILE`, its lines, `>>>FILE`.
                        const path: Value = switch (self.toks()[ti + 1].tag) {
                            .str, .word, .expr => .{ .str = self.toks()[ti + 1].text },
                            else => .none,
                        };
                        self.skipLine();
                        var text: std.ArrayList(u8) = .empty;
                        while (try self.m.win.has(self.ti)) {
                            const t = self.toks()[self.ti];
                            const rl = self.lines.get(t.lno);
                            self.skipLine();
                            if (t.tag == .word and std.mem.eql(u8, t.text, rb.close)) break;
                            try text.appendSlice(self.arena, rl.text);
                            if (rl.tail.len > 0 and self.g.lex.tail_comments.len > 0)
                                try text.print(
                                    self.arena,
                                    " {s} {s}",
                                    .{ self.g.lex.tail_comments[0], rl.tail },
                                );
                            try text.append(self.arena, '\n');
                        }
                        var st = try ir.newStmt(self.arena, .embed, line.no);
                        try st.set(self.arena, schema.slot(.embed, "path"), path);
                        try st.set(
                            self.arena,
                            schema.slot(.embed, "text"),
                            .{ .atom = try text.toOwnedSlice(self.arena) },
                        );
                        try out.append(self.arena, st);
                        return .more;
                    };
                    var raw: std.ArrayList(u8) = .empty;
                    while (try self.m.win.has(self.ti)) {
                        const t = self.toks()[self.ti];
                        if (raw.items.len > 0) try raw.append(self.arena, '\n');
                        const rl = self.lines.get(t.lno);
                        try raw.appendSlice(self.arena, rl.text);
                        if (rl.tail.len > 0 and self.g.lex.tail_comments.len > 0) {
                            try raw.print(
                                self.arena,
                                " {s} {s}",
                                .{ self.g.lex.tail_comments[0], rl.tail },
                            );
                        }
                        self.skipLine();
                        if (t.tag == .word and std.mem.eql(u8, t.text, rb.close)) break;
                    }
                    try out.append(
                        self.arena,
                        .{
                            .kind = .@"opaque",
                            .raw = try raw.toOwnedSlice(self.arena),
                            .line = line.no,
                        },
                    );
                    return .more;
                }
            }
            // A statement of the dialect's own (`own`): its words, not text.
            if (self.g.ownReason(line.text) != null) {
                try out.append(
                    self.arena,
                    try nativeOf(self.arena, self.g, line.text, line.no, line.tail),
                );
                self.skipLine();
                return .more;
            }
            try out.append(
                self.arena,
                .{ .kind = .@"opaque", .raw = line.text, .line = line.no, .tail = line.tail },
            );
            self.skipLine();
            return .more;
        }
    }

    /// A line whose keyword starts rules of two kinds may hold statements
    /// of both, one after another: HSPICE's `.param f(x)='x*2' k=1`. Each
    /// shortest run that some rule reads is a statement, and the keyword is
    /// put back in front of what is left.
    pub fn splitAt(self: *Reader, ti: usize, line_no: u32, out: anytype) Allocator.Error!bool {
        const head = self.toks()[ti];
        if (head.tag != .word) return false;
        var first_kind: ?Kind = null;
        const shared = for (self.g.rules) |*rule| {
            if (rule.dir == .write or rule.within != null or rule.pat.len == 0 or
                rule.pat[0].tag != .lit)
                continue;
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
    pub fn ruleAt(self: *Reader, ti: usize, line_no: u32) Allocator.Error!?ir.Stmt {
        const head = self.toks()[ti];
        for (self.g.readCandidates(if (head.tag == .word) head.text else null)) |ri| {
            const rule = &self.g.rules[ri];
            if (rule.dir == .write or rule.within != null) continue;
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
    pub fn spreadAt(self: *Reader, ti: usize, line_no: u32) Allocator.Error!?ir.Stmt {
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
                    if (rule.dir == .write or rule.within != null or
                        schema.info(rule.kind).class != .analysis)
                        continue;
                    if (!try self.m.run(rule.kind, rule.pat, ti)) continue;
                    var st = try self.m.build(line_no);
                    try self.canonStmt(&st);
                    wrap.body = try self.arena.dupe(ir.Stmt, &.{st});
                    try self.canonStmt(&wrap);
                    self.ti = end + 1;
                    return wrap;
                }
                return null;
            }
        }
        return null;
    }

    pub const canonStmt = canon.canonStmt;
    pub const finishValue = canon.finishValue;
    pub const finish = canon.finish;
    pub const flagOddValues = canon.flagOddValues;
    pub const collectDeclared = canon.collectDeclared;
};

/// The words of a line no kind holds: the first, then each blank-separated
/// word (parentheses and quotes keep their blanks), a `key=value` one a
/// parameter. Values stay as written.
fn nativeOf(
    arena: Allocator,
    g: *const Grammar,
    text: []const u8,
    line_no: u32,
    tail: []const u8,
) Allocator.Error!ir.Stmt {
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i >= text.len) break;
        const from = i;
        var depth: usize = 0;
        var quote: u8 = 0;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (quote != 0) {
                if (ch == quote) quote = 0;
            } else if (ch == '\'' or ch == '"') {
                quote = ch;
            } else if (ch == '(' or ch == '[' or ch == '{') {
                depth += 1;
            } else if ((ch == ')' or ch == ']' or ch == '}') and depth > 0) {
                depth -= 1;
            } else if (depth == 0 and (ch == ' ' or ch == '\t')) break;
        }
        try words.append(arena, text[from..i]);
    }
    // `key = value` with blanks: one pair.
    var args: std.ArrayList(Value) = .empty;
    var ps: std.ArrayList(ir.Param) = .empty;
    var k: usize = 1;
    while (k < words.items.len) : (k += 1) {
        const w = words.items[k];
        if (k + 2 < words.items.len and std.mem.eql(u8, words.items[k + 1], "=")) {
            try ps.append(arena, .{ .key = w, .val = .{ .atom = words.items[k + 2] } });
            k += 2;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, w, '=');
        if (eq != null and eq.? > 0 and eq.? + 1 < w.len and std.mem.indexOfAny(
            u8,
            w[0..eq.?],
            "('\"[{",
        ) == null) {
            try ps.append(arena, .{ .key = w[0..eq.?], .val = .{ .atom = w[eq.? + 1 ..] } });
        } else try args.append(arena, .{ .atom = w });
    }
    var st = try ir.newStmt(arena, .native, line_no);
    st.tail = tail;
    try st.set(arena, schema.slot(.native, "of"), .{ .atom = g.name });
    try st.set(arena, schema.slot(.native, "word"), .{ .atom = if (words.items.len > 0)
        words.items[0]
    else
        "" });
    if (args.items.len > 0)
        try st.set(arena, schema.slot(.native, "args"), .{ .list = args.items });
    if (ps.items.len > 0)
        try st.set(arena, schema.slot(.native, "params"), .{ .params = ps.items });
    return st;
}

fn numericSegments(st: *const ir.Stmt) bool {
    const v = st.at(schema.slot(.tran, "segments"));
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
