//! Turns source text into logical lines and tokens, driven entirely by the
//! `lexer` section of a grammar: comments, continuation, case folding,
//! expression delimiters and scale factors are data, not code.
//!
//! The logical lines are `lines.zig`, cutting one into tokens `tokens.zig`,
//! numbers and their scale factors `numbers.zig`. This file holds the
//! tokens themselves and the window of them a reader looks at.
//!
//! Contents:
//! - `pub const TokTag = enum`
//! - `pub const Tok = struct`, with `pub const Flags = packed struct(u8)`
//! - `pub const LineKind = enum`
//! - `pub const Line = struct`
//! - `pub const Window = struct`, with `pub fn init`, `pub fn deinit`, `pub fn has`,
//!   `pub fn rewind`, `pub fn drop`
//! - `pub const Lines = lines.Lines` (`lines.zig`)
//! - `pub const isIdent`, `pub const isNameLike`, `pub const unwrapWhole`,
//!   `pub const unescaped` (`tokens.zig`)
//! - `pub const parseNumber`, `pub const renderNumber` (`numbers.zig`)

const std = @import("std");
const grammar = @import("grammar");
const ir = @import("ir");
const logical = @import("lines.zig");
const tokens = @import("tokens.zig");
const numbers = @import("numbers.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const LexCfg = grammar.LexCfg;
const startsWithAny = logical.startsWithAny;
const commentText = logical.commentText;
const tokenizeLine = tokens.tokenizeLine;
const shiftDecimal = numbers.shiftDecimal;
const testing = std.testing;

pub const TokTag = enum { word, str, expr, vec, eq, lparen, rparen, nl, comment, blank };

pub const Tok = struct {
    tag: TokTag,
    /// Case-folded text for words; contents without delimiters otherwise.
    /// On `nl`, the trailing comment of the statement that just ended.
    text: []const u8,
    /// Exact source spelling, pointing into the logical line.
    raw: []const u8,
    /// The number of its line in `Lines`.
    lno: u32,
    f: Flags = .{},
    /// How many `)` follow this token. Only counted where parentheses are
    /// otherwise blanks, so that `v(a,b)` can still be told from `v(a) b`.
    closes: u8 = 0,

    pub const Flags = packed struct(u8) {
        /// Word directly followed by `=`.
        key: bool = false,
        /// Word directly followed by `(`, as in `v(out)`.
        call: bool = false,
        /// The token directly after `=`.
        val: bool = false,
        _: u5 = 0,
    };
};

pub const LineKind = enum { code, comment, blank };

/// A logical line: a statement with its continuation lines joined, or one
/// comment line, or a run of blank lines. `gen`: which of `Lines.gens`
/// holds the text made for it.
pub const Line = struct {
    text: []const u8,
    no: u32,
    kind: LineKind = .code,
    gen: u1 = 0,
    tail: []const u8 = "",
};

/// The tokens of a few logical lines at a time. A pass over a netlist lexes
/// each line when it reaches it and forgets it once it is read: the tokens
/// of a whole netlist would take five times its size.
pub const Window = struct {
    cfg: *const LexCfg,
    lines: *Lines,
    /// Case-folded copies of words, freed whenever the window empties. A
    /// value that keeps a folded `text` must copy it.
    scratch: std.heap.ArenaAllocator,
    toks: std.ArrayList(Tok) = .empty,
    /// The next line to lex.
    next: u32 = 0,

    pub fn init(cfg: *const LexCfg, lines: *Lines) Window {
        return .{ .cfg = cfg, .lines = lines, .scratch = .init(ir.big) };
    }

    pub fn deinit(w: *Window) void {
        w.toks.deinit(ir.big);
        w.scratch.deinit();
    }

    /// Is there a token at `i`? Lexes lines until there is one or the lines
    /// run out. A line is lexed whole: every token up to the `nl` that ends
    /// the line of token `i` is there too.
    pub fn has(w: *Window, i: usize) Allocator.Error!bool {
        // Bounded by the lines: each pass lexes one more, until there are none.
        while (i >= w.toks.items.len) {
            if (!try w.lines.has(w.next)) return false;
            try w.lexNext();
        }
        return true;
    }

    /// Back to the first line, for another pass; `keep` as for `Lines`.
    pub fn rewind(w: *Window, keep: ?Allocator) void {
        w.drop(w.toks.items.len);
        w.next = 0;
        w.lines.restart(keep);
    }

    /// Forget the tokens before `i`; token `i` becomes token 0. The lines
    /// before the first token left are released.
    pub fn drop(w: *Window, i: usize) void {
        const left = w.toks.items.len - i;
        if (left == 0) {
            w.toks.clearRetainingCapacity();
            _ = w.scratch.reset(.retain_capacity);
            w.lines.release(w.next);
            return;
        }
        std.mem.copyForwards(Tok, w.toks.items[0..left], w.toks.items[i..]);
        w.toks.shrinkRetainingCapacity(left);
        w.lines.release(w.toks.items[0].lno);
    }

    /// Lex the next line.
    fn lexNext(w: *Window) Allocator.Error!void {
        try w.lexLine(w.next);
        w.next += 1;
    }

    fn lexLine(w: *Window, lno: u32) Allocator.Error!void {
        const ln = w.lines.get(lno);
        const cfg = w.cfg;
        if (ln.kind != .code) {
            const tag: TokTag = if (ln.kind == .blank) .blank else .comment;
            var text = ln.text;
            if (startsWithAny(text, cfg.line_comments)) |n|
                text = commentText(text[n..])
            else if (startsWithAny(text, cfg.tail_comments)) |n| text = commentText(text[n..]);
            try w.toks.append(ir.big, .{ .tag = tag, .text = text, .raw = ln.text, .lno = lno });
            try w.toks.append(ir.big, .{ .tag = .nl, .text = "", .raw = "", .lno = lno });
            return;
        }
        try tokenizeLine(w.scratch.allocator(), w.lines.textFor(lno), cfg, ln.text, lno, &w.toks);
        try w.toks.append(ir.big, .{ .tag = .nl, .text = ln.tail, .raw = "", .lno = lno });
        // A line is lexed whole, up to the `nl` that ends it.
        assert(w.toks.items[w.toks.items.len - 1].tag == .nl);
    }
};

pub const Lines = logical.Lines;
pub const isIdent = tokens.isIdent;
pub const isNameLike = tokens.isNameLike;
pub const unescaped = tokens.unescaped;
pub const unwrapWhole = tokens.unwrapWhole;
pub const parseNumber = numbers.parseNumber;
pub const renderNumber = numbers.renderNumber;

const spice_cfg: LexCfg = .{
    .line_comments = &.{"*"},
    .tail_comments = &.{ "$", ";" },
    .cont_lead = "+",
    .expr_delims = &.{.{ "{", "}" }},
    .scales = &.{
        .{ .suffix = "meg", .exp10 = 6 }, .{ .suffix = "k", .exp10 = 3 },
        .{ .suffix = "m", .exp10 = -3 },  .{ .suffix = "u", .exp10 = -6 },
        .{ .suffix = "p", .exp10 = -12 }, .{ .suffix = "f", .exp10 = -15 },
    },
    .odd_scales = &.{.{ .suffix = "mil", .mant = 254, .exp10 = -7 }},
    .end_marker = ".end",
};

const spectre_cfg: LexCfg = .{
    .case_sensitive = true,
    .line_comments = &.{ "//", "*" },
    .tail_comments = &.{"//"},
    .cont_trail = "\\",
    .parens_are_space = false,
    .bare_expr = true,
    .ident_values = true,
    .scales = &.{
        .{ .suffix = "M", .exp10 = 6 },   .{ .suffix = "k", .exp10 = 3 },
        .{ .suffix = "m", .exp10 = -3 },  .{ .suffix = "u", .exp10 = -6 },
        .{ .suffix = "p", .exp10 = -12 },
    },
    .units_ignored = false,
};

test "the M trap" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqual(@as(i32, -3), parseNumber(a, &spice_cfg, "1m").?.exp10);
    try testing.expectEqual(@as(i32, 6), parseNumber(a, &spice_cfg, "1meg").?.exp10);
    try testing.expectEqual(@as(i32, 6), parseNumber(a, &spectre_cfg, "1M").?.exp10);
    try testing.expectEqual(@as(i32, -3), parseNumber(a, &spectre_cfg, "1m").?.exp10);
    // Spectre reads `1meg` as one milli with units "eg".
    try testing.expectEqual(@as(i32, -3), parseNumber(a, &spectre_cfg, "1meg").?.exp10);
    try testing.expectEqual(@as(i32, -12), parseNumber(a, &spice_cfg, "10pf").?.exp10);
    try testing.expectEqual(@as(i32, 6), parseNumber(a, &spice_cfg, "1.5e3k").?.exp10);
    try testing.expect(parseNumber(a, &spice_cfg, "2n2222") == null);
    try testing.expect(parseNumber(a, &spectre_cfg, "50Ohms") == null);
    try testing.expectApproxEqRel(
        @as(f64, 25.4e-6),
        parseNumber(a, &spice_cfg, "1mil").?.toFloat(),
        1e-12,
    );
}

test "lines, comments, continuation" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var lx: Lines = .init(&spice_cfg,
        \\My Title
        \\* a comment
        \\R1 in out 1K $ trailing
        \\M1 d g s b nch
        \\+ W=1u L={2*0.5U}
        \\.end
        \\R9 never seen 1
    , a);
    defer lx.deinit();
    var w: Window = .init(&spice_cfg, &lx);
    defer w.deinit();
    while (try w.has(w.toks.items.len)) {}
    const toks = w.toks.items;
    try testing.expectEqualStrings("My Title", lx.title);
    try testing.expectEqual(3, w.next);
    try testing.expectEqual(TokTag.comment, toks[0].tag);
    try testing.expectEqualStrings("a comment", toks[0].text);
    try testing.expectEqualStrings("r1", toks[2].text);
    try testing.expectEqualStrings("R1", toks[2].raw);
    try testing.expectEqualStrings("trailing", toks[6].text);
    try testing.expectEqual(@as(u32, 4), lx.get(2).no);
    var saw_expr = false;
    for (toks) |t| {
        if (t.tag == .expr) {
            saw_expr = true;
            try testing.expectEqualStrings("2*0.5U", t.text);
        }
    }
    try testing.expect(saw_expr);
}

test "spectre tokens" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var cfg = spectre_cfg;
    cfg.title = false;
    var lx: Lines = .init(&cfg,
        \\r1 (a b) resistor r=(ra + rb)*2 // note
        \\v1 (a 0) vsource type=pwl \
        \\    wave=[0 0 1n 1]
    , a);
    defer lx.deinit();
    var w: Window = .init(&cfg, &lx);
    defer w.deinit();
    while (try w.has(w.toks.items.len)) {}
    const toks = w.toks.items;
    try testing.expectEqual(2, w.next);
    try testing.expectEqual(TokTag.lparen, toks[1].tag);
    try testing.expect(toks[6].f.key);
    try testing.expectEqual(TokTag.expr, toks[8].tag);
    try testing.expectEqualStrings("(ra + rb)*2", toks[8].text);
    try testing.expectEqual(TokTag.vec, toks[toks.len - 2].tag);
}

test "odd scale factors are exact" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "1e6mil", "25.4" },  .{ "1mil", "25.4u" }, .{ "2.5mil", "63.5u" },
        .{
            "-0.5mil",
            "-12.7u",
        },
        .{ "100mil", "2540u" },
    };
    for (cases) |c| {
        var aw: std.Io.Writer.Allocating = .init(a);
        try renderNumber(&aw.writer, &spice_cfg, parseNumber(a, &spice_cfg, c[0]).?);
        try testing.expectEqualStrings(c[1], aw.written());
    }
    try testing.expectEqualStrings("150", (try shiftDecimal(a, "1.5", 2)).?);
    try testing.expectEqualStrings("0.0015", (try shiftDecimal(a, "1.5", -3)).?);
    try testing.expect((try shiftDecimal(a, "1", -18)) == null);
}
