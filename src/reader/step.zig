//! Reader: the statements of a body, one step at a time. A step reads what
//! starts at the next line: a comment, the end of the block it is in, a
//! line of that block, a block with its whole body, a statement by the
//! first rule that matches; else what `split.zig` and `kept.zig` make of it.
//!
//! Contents:
//! - `pub const Reader = struct`, with `pub const Grow = struct` (`pub fn append`,
//!   `pub fn toOwnedSlice`), `pub const Step = enum`,
//!   and the methods `pub fn toks`, `pub fn skipLine`, `pub fn isBoilerplate`,
//!   `pub fn lastClose`, `pub fn body`, `pub fn top`, `pub fn bodyInto`, `pub fn step`;
//!   from `split.zig` `pub const splitAt`, `pub const ruleAt`, `pub const spreadAt`; from
//!   `kept.zig` `pub const rawAt`; from `canon.zig` `pub const canonStmt`,
//!   `pub const finishValue`, `pub const finish`, `pub const flagOddValues`,
//!   `pub const collectDeclared`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const matcher = @import("matcher.zig");
const spelling = @import("spelling.zig");
const canon = @import("canon.zig");
const source = @import("source.zig");
const split = @import("split.zig");
const kept = @import("kept.zig");
const assert = std.debug.assert;
const Matcher = matcher.Matcher;
const Spelling = spelling.Spelling;
const normalize = source.normalize;
const mapModel = canon.mapModel;
const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Tok = lexer.Tok;

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

    pub const splitAt = split.splitAt;
    pub const ruleAt = split.ruleAt;
    pub const spreadAt = split.spreadAt;
    pub const rawAt = kept.rawAt;
    pub const canonStmt = canon.canonStmt;
    pub const finishValue = canon.finishValue;
    pub const finish = canon.finish;
    pub const flagOddValues = canon.flagOddValues;
    pub const collectDeclared = canon.collectDeclared;

    pub fn toks(self: *const Reader) []const Tok {
        return self.m.win.toks.items;
    }

    pub fn skipLine(self: *Reader) void {
        var ti = self.ti;
        while (self.toks()[ti].tag != .nl) ti += 1;
        self.ti = ti + 1;
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
        assert(last <= no);
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

        pub fn append(g: *Grow, _: Allocator, st: ir.Stmt) Allocator.Error!void {
            try g.items.append(g.gpa, st);
        }

        pub fn toOwnedSlice(g: *Grow, arena: Allocator) Allocator.Error![]ir.Stmt {
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
        // Bounded by the lines: each step reads at least one, until the end or the block's close.
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
        self.m.win.drop(self.ti);
        self.ti = 0;
        if (!try self.m.win.has(0)) return .eof;
        assert(self.toks().len > 0);
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
        if (try self.isBoilerplate(line.text) or self.isWrap(ti)) {
            self.skipLine();
            return .more;
        }
        if (block) |b| if (try self.inBlock(b, owner.?, ti, out)) |s| return s;
        if (try self.openBlock(ti, line.no, out)) return .more;
        if (try self.readRule(block, ti, line.no, out)) return .more;
        if (try self.spreadAt(ti, line.no)) |st| {
            try out.append(self.arena, st);
            return .more;
        }
        if (try self.splitAt(ti, line.no, out)) return .more;
        if (try self.rawAt(ti, line.no, out)) return .more;
        // A statement of the dialect's own (`own`): its words, not text.
        if (self.g.ownReason(line.text) != null) {
            try out.append(
                self.arena,
                try kept.nativeOf(self.arena, self.g, line.text, line.no, line.tail),
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

    /// A line of one word that opens or closes a wrapper around the netlist.
    fn isWrap(self: *const Reader, ti: usize) bool {
        const first = self.toks()[ti];
        if (first.tag != .word or self.toks()[ti + 1].tag != .nl) return false;
        for (self.g.wraps) |w| {
            if (std.mem.eql(u8, first.text, w.open) or std.mem.eql(u8, first.text, w.close))
                return true;
        }
        return false;
    }

    /// Inside `b`: the line that closes it, or one of its own lines, which
    /// sets what they say on `owner`. Null where the line is neither.
    fn inBlock(
        self: *Reader,
        b: *const grammar.Block,
        owner: *ir.Stmt,
        ti: usize,
        out: anytype,
    ) Allocator.Error!?Step {
        // `step` took the lines that are no statement.
        assert(self.toks()[ti].tag != .nl);
        const line_no = self.lines.get(self.toks()[ti].lno).no;
        if (try self.m.run(b.kind, b.close, ti)) {
            const tail = self.toks()[self.m.end].text;
            if (tail.len > 0)
                try out.append(
                    self.arena,
                    .{ .kind = .comment, .raw = tail, .line = line_no },
                );
            self.ti = self.m.end + 1;
            return .closed;
        }
        for (b.inner) |pat| {
            if (try self.m.run(b.kind, pat, ti)) {
                try self.m.applyTo(owner);
                if (!self.g.lex.case_sensitive)
                    try self.spell.statement(self.arena, owner);
                self.ti = self.m.end + 1;
                return .more;
            }
        }
        return null;
    }

    /// A line that opens a block: the statement with its whole body. False
    /// where no block opens here.
    fn openBlock(self: *Reader, ti: usize, line_no: u32, out: anytype) Allocator.Error!bool {
        assert(self.depth <= ir.max_depth);
        const b, var st = (try self.blockOpening(ti, line_no)) orelse return false;
        st.tail = self.toks()[self.m.end].text;
        if (!self.g.lex.case_sensitive) try self.spell.statement(self.arena, &st);
        self.ti = self.m.end + 1;
        self.depth += 1;
        defer self.depth -= 1;
        st.body = try self.body(b, &st);
        try out.append(self.arena, st);
        return true;
    }

    /// The block whose opening line this is, and the statement it opens.
    fn blockOpening(
        self: *Reader,
        ti: usize,
        line_no: u32,
    ) Allocator.Error!?struct { *const grammar.Block, ir.Stmt } {
        for (self.g.blocks) |*b| {
            if (!try self.m.run(b.kind, b.open, ti)) continue;
            if (b.closed and self.lastClose(b) < line_no) continue;
            // Deeper than any netlist nests: no block, so no stack
            // overflow; the line goes to the rules, and so to text.
            if (self.depth >= ir.max_depth) {
                if (!self.too_deep)
                    self.report.add(
                        .@"error",
                        .invalid,
                        line_no,
                        "blocks nested more than {d} deep: from here a line that would " ++
                            "open one deeper is read as a statement, or kept as text",
                        .{ir.max_depth},
                    );
                self.too_deep = true;
                return null;
            }
            const st = try self.m.build(line_no);
            // Segments are numbers: `.tran 1n 1u SWEEP ...` is a spread.
            if (st.kind == .tran and !numericSegments(&st)) continue;
            return .{ b, st };
        }
        return null;
    }

    /// The statement the first rule that matches reads from `ti`. False
    /// where none does.
    fn readRule(
        self: *Reader,
        block: ?*const grammar.Block,
        ti: usize,
        line_no: u32,
        out: anytype,
    ) Allocator.Error!bool {
        const first = self.toks()[ti];
        for (self.g.readCandidates(if (first.tag == .word) first.text else null)) |ri| {
            const rule = &self.g.rules[ri];
            if (rule.dir == .write or self.g.isEnding(rule)) continue;
            if (!self.g.ruleHere(rule, if (block) |b| b.kind else null)) continue;
            if (!try self.m.run(rule.kind, rule.pat, ti)) continue;
            // A rule for `opaque` names a statement this grammar recognises
            // but does not translate; it stops later rules from misreading it.
            if (rule.kind == .@"opaque") break;
            var st = try self.m.build(line_no);
            // Segments are numbers: `.tran 1n 1u SWEEP ...` is a spread.
            if (st.kind == .tran and !numericSegments(&st)) continue;
            try self.ruleRead(&st, ti, line_no, out);
            return true;
        }
        return false;
    }

    /// A statement a rule just read, made canonical, after the comment
    /// lines met inside it.
    fn ruleRead(
        self: *Reader,
        st: *ir.Stmt,
        ti: usize,
        line_no: u32,
        out: anytype,
    ) Allocator.Error!void {
        // The match ran from `ti` to the `nl` that ends the statement.
        assert(self.m.end >= ti);
        if (st.kind == .options)
            if (self.m.clash()) |sl|
                self.report.add(.@"error", .loss, line_no, "{s}.{s} is given twice " ++
                    "with different values, by two keys {s} reads as one; the last is " ++
                    "kept", .{
                    @tagName(st.kind), schema.info(st.kind).slots[sl].name, self.g.name,
                });
        st.tail = self.toks()[self.m.end].text;
        if (!self.g.lex.case_sensitive) try self.spell.statement(self.arena, st);
        if (st.kind == .model) try mapModel(self.arena, self.g, st, self.report);
        try self.canonStmt(st);
        self.flagOddValues(st);
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
        try out.append(self.arena, st.*);
    }
};

// ---- private ----

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
