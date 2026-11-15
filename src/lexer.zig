//! Turns source text into logical lines and tokens, driven entirely by the
//! `lexer` section of a grammar: comments, continuation, case folding,
//! expression delimiters and scale factors are data, not code.

const std = @import("std");
const grammar = @import("grammar.zig");
const ir = @import("ir.zig");
const Allocator = std.mem.Allocator;
const LexCfg = grammar.LexCfg;

pub const TokTag = enum { word, str, expr, vec, eq, lparen, rparen, nl, comment, blank };

pub const Tok = struct {
    tag: TokTag,
    /// Case-folded text for words; contents without delimiters otherwise.
    /// On `nl`, the trailing comment of the statement that just ended.
    text: []const u8,
    /// Exact source spelling, pointing into the logical line.
    raw: []const u8,
    /// Index into `Lexed.lines`.
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
/// comment line, or a run of blank lines.
pub const Line = struct { text: []const u8, no: u32, kind: LineKind = .code, tail: []const u8 = "" };

/// A netlist cut into logical lines. `lines` stops before the end marker.
pub const Lexed = struct {
    title: []const u8,
    lines: []Line,
    all_lines: []Line = &.{},

    /// The line list lives outside the arena and is freed when reading is done.
    pub fn deinit(lx: *Lexed) void {
        ir.big.free(lx.all_lines);
        lx.lines = &.{};
        lx.all_lines = &.{};
    }
};

fn startsWithAny(s: []const u8, markers: []const []const u8) ?usize {
    for (markers) |m| if (m.len > 0 and std.mem.startsWith(u8, s, m)) return m.len;
    return null;
}

/// Where a trailing comment starts. A marker only counts at the start of the
/// line or after a blank, and never inside a string or an expression.
/// `open` carries a string or expression left open at the end of a line
/// into its continuation: the closing delimiter still to come.
fn tailStart(cfg: *const LexCfg, line: []const u8, open: *[]const u8) ?struct { usize, usize } {
    if (cfg.tail_comments.len == 0) return null;
    var i: usize = 0;
    if (open.len > 0) {
        i = (std.mem.indexOfPos(u8, line, 0, open.*) orelse return null) + open.len;
        open.* = "";
    }
    while (i < line.len) {
        const c = line[i];
        if (c == '"') {
            i = (std.mem.indexOfScalarPos(u8, line, i + 1, '"') orelse {
                open.* = "\"";
                return null;
            }) + 1;
            continue;
        }
        var skipped = false;
        for (cfg.expr_delims) |d| {
            if (std.mem.startsWith(u8, line[i..], d[0])) {
                const close = std.mem.indexOfPos(u8, line, i + d[0].len, d[1]) orelse {
                    open.* = d[1];
                    return null;
                };
                i = close + d[1].len;
                skipped = true;
                break;
            }
        }
        if (skipped) continue;
        if (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t') {
            if (startsWithAny(line[i..], cfg.tail_comments)) |n| return .{ i, n };
        }
        i += 1;
    }
    return null;
}

fn commentText(s: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, s, " \t");
    return if (t.len > 0 and t[0] == ' ') t[1..] else t;
}

const Joiner = struct {
    arena: Allocator,
    lines: std.ArrayList(Line) = .empty,
    /// The open statement while it is a single physical line: a slice of
    /// the source, no copy. `cur` takes over when a continuation arrives.
    first: []const u8 = "",
    first_tail: []const u8 = "",
    cur: std.ArrayList(u8) = .empty,
    tail: std.ArrayList(u8) = .empty,
    /// Comments met while a statement may still be continued. They are
    /// placed after it once it is known to have ended.
    pending: std.ArrayList(Line) = .empty,
    cur_no: u32 = 0,
    open: bool = false,

    fn note(j: *Joiner, kind: LineKind, text: []const u8, no: u32) Allocator.Error!void {
        const list = if (j.open) &j.pending else &j.lines;
        if (kind == .blank) {
            // Runs of blank lines collapse, and none leads the file.
            const prev: ?Line = if (list.items.len > 0) list.items[list.items.len - 1] else if (j.open or j.lines.items.len == 0) null else j.lines.items[j.lines.items.len - 1];
            if (!j.open and list.items.len == 0) return;
            if (prev) |q| if (q.kind == .blank) return;
        }
        try list.append(if (j.open) j.arena else ir.big, .{ .text = text, .no = no, .kind = kind });
    }

    fn flush(j: *Joiner) Allocator.Error!void {
        if (j.open) {
            const joined = j.cur.items.len > 0;
            try j.lines.append(ir.big, .{
                .text = if (joined) try j.cur.toOwnedSlice(j.arena) else j.first,
                .no = j.cur_no,
                .tail = if (j.tail.items.len > 0) try j.tail.toOwnedSlice(j.arena) else j.first_tail,
            });
            j.open = false;
        }
        try j.lines.appendSlice(ir.big, j.pending.items);
        j.pending.clearRetainingCapacity();
    }
};

fn joinLines(arena: Allocator, cfg: *const LexCfg, src: []const u8, title: *[]const u8) Allocator.Error![]Line {
    var j: Joiner = .{ .arena = arena };
    var trail = false; // previous physical line ended with the trailing marker
    var open: []const u8 = ""; // a string or expression still open at the end of the last line
    var no: u32 = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    var in_block = false;
    while (it.next()) |phys_raw| {
        no += 1;
        var phys = std.mem.trimEnd(u8, phys_raw, "\r");
        if (cfg.block_comment) |bc| {
            // `/* ... */` spans, which may also run over several lines,
            // become comment lines of their own.
            if (in_block or std.mem.indexOf(u8, phys, bc[0]) != null) {
                var kept: std.ArrayList(u8) = .empty;
                var cut: std.ArrayList(u8) = .empty;
                var i: usize = 0;
                while (i < phys.len) {
                    if (in_block) {
                        const close = std.mem.indexOfPos(u8, phys, i, bc[1]) orelse {
                            try cut.appendSlice(arena, phys[i..]);
                            break;
                        };
                        try cut.appendSlice(arena, phys[i..close]);
                        i = close + bc[1].len;
                        in_block = false;
                    } else if (std.mem.startsWith(u8, phys[i..], bc[0])) {
                        in_block = true;
                        i += bc[0].len;
                    } else {
                        try kept.append(arena, phys[i]);
                        i += 1;
                    }
                }
                const text = std.mem.trim(u8, cut.items, " \t");
                if (text.len > 0) {
                    const marker = if (cfg.line_comments.len > 0) cfg.line_comments[0] else "*";
                    try j.note(.comment, try std.fmt.allocPrint(arena, "{s} {s}", .{ marker, text }), no);
                }
                phys = kept.items;
                if (std.mem.trim(u8, phys, " \t").len == 0) continue;
            }
        }
        if (first) {
            first = false;
            if (cfg.title) {
                var t = std.mem.trim(u8, phys, " \t");
                if (cfg.title_prefix.len > 0) {
                    const p = std.mem.trim(u8, cfg.title_prefix, " \t");
                    if (std.mem.startsWith(u8, t, p)) t = std.mem.trim(u8, t[p.len..], " \t");
                }
                title.* = t;
                continue;
            }
        }
        const lead = std.mem.trimStart(u8, phys, " \t");
        if (lead.len == 0) {
            if (!trail) try j.note(.blank, "", no);
            continue;
        }
        if (startsWithAny(lead, cfg.line_comments) != null) {
            try j.note(.comment, std.mem.trimEnd(u8, lead, " \t"), no);
            continue;
        }
        var body = lead;
        var tail: []const u8 = "";
        const continues = trail or (cfg.cont_lead.len > 0 and std.mem.startsWith(u8, lead, cfg.cont_lead));
        if (!continues) open = "";
        if (tailStart(cfg, lead, &open)) |cut| {
            body = lead[0..cut[0]];
            tail = commentText(lead[cut[0] + cut[1] ..]);
        }
        body = std.mem.trimEnd(u8, body, " \t");
        if (body.len == 0) {
            // The whole line was a trailing-style comment.
            try j.note(.comment, std.mem.trimEnd(u8, lead, " \t"), no);
            continue;
        }

        var is_cont = trail;
        if (!is_cont and cfg.cont_lead.len > 0 and std.mem.startsWith(u8, body, cfg.cont_lead)) {
            if (!j.open) {
                // Nothing to continue but the title or a comment: it is one.
                const marker = if (cfg.line_comments.len > 0) cfg.line_comments[0] else "*";
                try j.note(.comment, try std.fmt.allocPrint(arena, "{s} {s}", .{ marker, lead }), no);
                continue;
            }
            is_cont = true;
            body = body[cfg.cont_lead.len..];
        }
        trail = false;
        if (cfg.cont_trail.len > 0 and std.mem.endsWith(u8, body, cfg.cont_trail)) {
            trail = true;
            body = body[0 .. body.len - cfg.cont_trail.len];
            // HSPICE's `\\` joins with no blank; a blank is harmless here.
            if (std.mem.endsWith(u8, body, cfg.cont_trail)) body = body[0 .. body.len - cfg.cont_trail.len];
            body = std.mem.trimEnd(u8, body, " \t");
        }
        if (!is_cont) {
            try j.flush();
            j.open = true;
            j.cur_no = no;
            j.first = body;
            j.first_tail = tail;
            continue;
        }
        if (j.cur.items.len == 0) try j.cur.appendSlice(arena, j.first);
        try j.cur.append(arena, ' ');
        try j.cur.appendSlice(arena, body);
        if (tail.len > 0) {
            if (j.tail.items.len == 0 and j.first_tail.len > 0) try j.tail.appendSlice(arena, j.first_tail);
            if (j.tail.items.len > 0) try j.tail.appendSlice(arena, "; ");
            try j.tail.appendSlice(arena, tail);
        }
    }
    try j.flush();
    while (j.lines.items.len > 0 and j.lines.items[j.lines.items.len - 1].kind == .blank) _ = j.lines.pop();
    return j.lines.toOwnedSlice(ir.big);
}

fn countCloses(text: []const u8, from: usize) u8 {
    var n: u8 = 0;
    for (text[from..]) |c| {
        if (c == ')') {
            n +|= 1;
        } else if (c != ' ' and c != '\t') break;
    }
    return n;
}

fn isBlank(cfg: *const LexCfg, c: u8) bool {
    if (c == ' ' or c == '\t' or c == ',') return true;
    return cfg.parens_are_space and (c == '(' or c == ')');
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

pub fn isIdent(s: []const u8) bool {
    if (s.len == 0 or !isIdentStart(s[0])) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '!' or c == ':' or c == '#' or c == '$')) return false;
    }
    return true;
}

/// Could this word be a node, instance or model name? Anything carrying
/// quote, brace or bracket characters is a malformed expression instead.
pub fn isNameLike(s: []const u8) bool {
    return s.len > 0 and std.mem.indexOfAny(u8, s, "{}'\"()=,") == null;
}

fn fold(arena: Allocator, cfg: *const LexCfg, s: []const u8) Allocator.Error![]const u8 {
    if (cfg.case_sensitive) return s;
    for (s) |c| {
        if (std.ascii.isUpper(c)) return std.ascii.allocLowerString(arena, s);
    }
    return s;
}

fn pushTok(list_gpa: Allocator, toks: *std.ArrayList(Tok), tag: TokTag, text: []const u8, raw: []const u8, lno: u32) Allocator.Error!void {
    try toks.append(list_gpa, .{ .tag = tag, .text = text, .raw = raw, .lno = lno });
}

/// `arena` owns token text; `keep`, text that must outlive the window;
/// `list_gpa` owns the token list itself.
fn tokenizeLine(arena: Allocator, keep: Allocator, list_gpa: Allocator, cfg: *const LexCfg, text: []const u8, lno: u32, toks: *std.ArrayList(Tok)) Allocator.Error!void {
    var i: usize = 0;
    var after_eq = false;
    const line_start = toks.items.len;
    outer: while (true) {
        if (cfg.parens_are_space and toks.items.len > line_start) toks.items[toks.items.len - 1].closes = countCloses(text, i);
        // After `=`, where an undelimited expression may follow, an opening
        // parenthesis belongs to that expression and is not a blank.
        const expr_next = after_eq and (cfg.bare_expr or cfg.bare_after_eq);
        while (i < text.len and isBlank(cfg, text[i]) and !(expr_next and text[i] == '(')) i += 1;
        if (i >= text.len) break;
        const c = text[i];
        const value_ctx = after_eq;
        after_eq = false;
        const tok_start = toks.items.len;
        defer if (value_ctx and toks.items.len > tok_start) {
            toks.items[tok_start].f.val = true;
        };

        if (c == '=') {
            if (toks.items.len > 0 and toks.items[toks.items.len - 1].tag == .word and toks.items[toks.items.len - 1].lno == lno) {
                toks.items[toks.items.len - 1].f.key = true;
            }
            try pushTok(list_gpa, toks, .eq, "=", text[i .. i + 1], lno);
            i += 1;
            after_eq = true;
            continue;
        }
        if (c == '"') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '"') orelse text.len;
            try pushTok(list_gpa, toks, .str, text[i + 1 .. end], text[i..@min(end + 1, text.len)], lno);
            i = @min(end + 1, text.len);
            continue;
        }
        if (value_ctx) if (try joinedExpr(keep, cfg, text, i)) |jx| {
            try pushTok(list_gpa, toks, .expr, jx.text, text[i..jx.end], lno);
            i = jx.end;
            continue;
        };
        for (cfg.expr_delims) |d| {
            if (!std.mem.startsWith(u8, text[i..], d[0])) continue;
            const j = delimClose(text, i, d);
            const inner = text[i + d[0].len .. @min(j, text.len)];
            const end = @min(j + d[1].len, text.len);
            try pushTok(list_gpa, toks, .expr, std.mem.trim(u8, inner, " \t"), text[i..end], lno);
            i = end;
            continue :outer;
        }
        if (value_ctx and (cfg.bare_expr or cfg.bare_after_eq)) {
            if (c == '[' and cfg.bare_expr) {
                const end = std.mem.indexOfScalarPos(u8, text, i + 1, ']') orelse text.len;
                try pushTok(list_gpa, toks, .vec, text[i + 1 .. end], text[i..@min(end + 1, text.len)], lno);
                i = @min(end + 1, text.len);
                continue;
            }
            // A bare expression runs to the next blank outside parentheses.
            var depth: usize = 0;
            var j = i;
            while (j < text.len) : (j += 1) {
                const ch = text[j];
                if (ch == '(') {
                    depth += 1;
                } else if (ch == ')') {
                    if (depth == 0) break;
                    depth -= 1;
                } else if (depth == 0 and (ch == ' ' or ch == '\t')) break;
            }
            var run = text[i..j];
            // `= (0,0) (1,2)`: a comma at the top level of the parentheses
            // makes a list (a TABLE's pairs), not an expression.
            if (!cfg.bare_expr and run.len > 0 and run[0] == '(' and topComma(run)) {
                after_eq = false;
                continue;
            }
            i = j;
            // `(a + b)` and `a + b` are the same expression; writers add the
            // parentheses only to protect the blanks.
            if (run.len >= 2 and run[0] == '(' and run[run.len - 1] == ')') {
                var d: usize = 0;
                var whole = true;
                for (run[0 .. run.len - 1]) |ch| {
                    if (ch == '(') d += 1;
                    if (ch == ')') d -= 1;
                    if (d == 0) whole = false;
                }
                if (whole) run = run[1 .. run.len - 1];
            }
            // Braces that are not this dialect's delimiters (`w={wn}` in
            // HSPICE) make no expression: kept as a word, flagged later.
            const braces = std.mem.indexOfAny(u8, run, "{}") != null;
            if (braces or parseNumber(arena, cfg, try fold(arena, cfg, run)) != null or isIdent(run)) {
                try pushTok(list_gpa, toks, .word, try fold(arena, cfg, run), run, lno);
            } else {
                try pushTok(list_gpa, toks, .expr, run, run, lno);
            }
            continue;
        }
        // `x = '-1*y' + z = 2`: a continuation mark left inside a line;
        // ngspice reads it as a blank (x = -3, z = 2).
        if (c == '+' and std.mem.eql(u8, cfg.cont_lead, "+") and (i + 1 == text.len or text[i + 1] == ' ' or text[i + 1] == '\t') and
            toks.items.len > line_start and toks.items[toks.items.len - 1].f.val)
        {
            i += 1;
            continue;
        }
        if (!cfg.parens_are_space and (c == '(' or c == ')')) {
            try pushTok(list_gpa, toks, if (c == '(') .lparen else .rparen, text[i .. i + 1], text[i .. i + 1], lno);
            i += 1;
            continue;
        }
        var j = i;
        while (j < text.len and !isBlank(cfg, text[j]) and text[j] != '=' and text[j] != '(' and text[j] != ')') j += 1;
        if (j == i) j += 1; // lone paren in space mode cannot happen; guard anyway
        try pushTok(list_gpa, toks, .word, try fold(arena, cfg, text[i..j]), text[i..j], lno);
        toks.items[toks.items.len - 1].f.call = j < text.len and text[j] == '(';
        i = j;
    }
}

/// Where the delimited expression opening at `i` closes (`text.len` when
/// it does not). Nested braces count; quote-style delimiters cannot nest.
fn delimClose(text: []const u8, i: usize, d: [2][]const u8) usize {
    var depth: usize = 1;
    var j = i + d[0].len;
    const same = std.mem.eql(u8, d[0], d[1]);
    while (j < text.len) {
        if (std.mem.startsWith(u8, text[j..], d[1])) {
            depth -= 1;
            if (depth == 0) break;
            j += d[1].len;
        } else if (!same and std.mem.startsWith(u8, text[j..], d[0])) {
            depth += 1;
            j += d[0].len;
        } else j += 1;
    }
    return j;
}

fn isOperator(c: u8) bool {
    return c == '+' or c == '-' or c == '*' or c == '/' or c == '^';
}

/// `{a} + b`, `{a}*{b}`, `a + {b}`: a delimited expression joined to more
/// by an operator outside the delimiters, as one expression; and `a + b`
/// after `=` where an undelimited expression may stand. ngspice 45
/// takes such a line (when it takes it at all) as the delimiters dropped
/// and the rest kept: `{1+1}*3` is 4, not 6. Null when the value is not
/// such a join.
fn joinedExpr(arena: Allocator, cfg: *const LexCfg, text: []const u8, start: usize) Allocator.Error!?struct { text: []const u8, end: usize } {
    var out: std.ArrayList(u8) = .empty;
    var i = start;
    var depth: usize = 0;
    var delimited = false;
    var op_outside = false;
    var last_op = false;
    var spaced = false;
    scan: while (i < text.len) {
        for (cfg.expr_delims) |d| {
            if (!std.mem.startsWith(u8, text[i..], d[0])) continue;
            const j = delimClose(text, i, d);
            try out.appendSlice(arena, std.mem.trim(u8, text[i + d[0].len .. @min(j, text.len)], " \t"));
            i = @min(j + d[1].len, text.len);
            delimited = true;
            last_op = false;
            continue :scan;
        }
        const c = text[i];
        if (depth == 0 and (c == ' ' or c == '\t')) {
            var j = i;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
            // Past the blanks the expression goes on only after or before an operator.
            if (j < text.len and text[j] == '=' and spaced) return null;
            if (j == text.len or !(last_op or isOperator(text[j]))) break;
            // `100p -60p`: a sign, the start of the next value of a list.
            if (!last_op and (text[j] == '-' or text[j] == '+') and j + 1 < text.len and text[j + 1] != ' ' and text[j + 1] != '\t') break;
            try out.append(arena, ' ');
            spaced = true;
            i = j;
            continue;
        }
        if (depth == 0 and c == ',') break;
        // `x = '-1*y' + z = 2`: the `+` stands between two parameters
        // (ngspice reads x = -3 and z = 2), not in an expression.
        if (depth == 0 and c == '=') return null;
        if (c == '(') depth += 1;
        if (c == ')') {
            if (depth == 0) break;
            depth -= 1;
        }
        last_op = isOperator(c);
        op_outside = op_outside or last_op;
        try out.append(arena, c);
        i += 1;
    }
    // Undelimited, `0.0 + mc*agauss(0,1,1)` is one only where a bare
    // expression may follow `=`, and only with blanks in it.
    if (!op_outside or !(delimited or (cfg.bare_after_eq and spaced))) return null;
    return .{ .text = std.mem.trim(u8, out.items, " "), .end = i };
}

fn topComma(run: []const u8) bool {
    var depth: usize = 0;
    for (run) |ch| switch (ch) {
        '(' => depth += 1,
        ')' => depth -|= 1,
        ',' => if (depth == 1) return true,
        else => {},
    };
    return false;
}

/// Join physical lines into logical ones and find the end marker. Tokens
/// come later, a few lines at a time, from a `Window`.
pub fn lex(arena: Allocator, cfg: *const LexCfg, src: []const u8) Allocator.Error!Lexed {
    var title: []const u8 = "";
    const lines = try joinLines(arena, cfg, src, &title);
    var lx: Lexed = .{ .title = title, .lines = lines, .all_lines = lines };
    if (cfg.end_marker.len == 0) return lx;
    var w: Window = .init(cfg, lines, arena);
    defer w.deinit();
    for (lines, 0..) |ln, idx| {
        // Only a line that starts like the marker can be it.
        if (ln.kind != .code or ln.text.len < cfg.end_marker.len or
            !std.ascii.eqlIgnoreCase(ln.text[0..cfg.end_marker.len], cfg.end_marker)) continue;
        w.drop(w.toks.items.len);
        w.next = @intCast(idx);
        _ = try w.has(0);
        const first = w.toks.items[0];
        if (first.tag == .word and std.mem.eql(u8, first.text, cfg.end_marker)) {
            lx.lines = lines[0..idx];
            break;
        }
    }
    return lx;
}

/// The tokens of a few logical lines at a time. A pass over a netlist lexes
/// each line when it reaches it and forgets it once it is read: the tokens
/// of a whole netlist would take five times its size.
pub const Window = struct {
    cfg: *const LexCfg,
    lines: []const Line,
    /// Case-folded copies of words, freed whenever the window empties. A
    /// value that keeps a folded `text` must copy it.
    scratch: std.heap.ArenaAllocator,
    /// Text a token makes that is in no line (a joined expression) and
    /// outlives the window.
    keep: Allocator,
    toks: std.ArrayList(Tok) = .empty,
    /// The next line to lex.
    next: u32 = 0,

    pub fn init(cfg: *const LexCfg, lines: []const Line, keep: Allocator) Window {
        return .{ .cfg = cfg, .lines = lines, .scratch = .init(ir.big), .keep = keep };
    }

    pub fn deinit(w: *Window) void {
        w.toks.deinit(ir.big);
        w.scratch.deinit();
    }

    /// Is there a token at `i`? Lexes lines until there is one or the lines
    /// run out. A line is lexed whole: every token up to the `nl` that ends
    /// the line of token `i` is there too.
    pub fn has(w: *Window, i: usize) Allocator.Error!bool {
        while (i >= w.toks.items.len) {
            if (w.next >= w.lines.len) return false;
            try w.lexLine(w.next);
            w.next += 1;
        }
        return true;
    }

    /// Back to the first line, for another pass.
    pub fn rewind(w: *Window) void {
        w.drop(w.toks.items.len);
        w.next = 0;
    }

    /// Forget the tokens before `i`; token `i` becomes token 0.
    pub fn drop(w: *Window, i: usize) void {
        const left = w.toks.items.len - i;
        if (left == 0) {
            w.toks.clearRetainingCapacity();
            _ = w.scratch.reset(.retain_capacity);
            return;
        }
        std.mem.copyForwards(Tok, w.toks.items[0..left], w.toks.items[i..]);
        w.toks.shrinkRetainingCapacity(left);
    }

    fn lexLine(w: *Window, lno: u32) Allocator.Error!void {
        const ln = w.lines[lno];
        const cfg = w.cfg;
        if (ln.kind != .code) {
            const tag: TokTag = if (ln.kind == .blank) .blank else .comment;
            var text = ln.text;
            if (startsWithAny(text, cfg.line_comments)) |n| text = commentText(text[n..]) else if (startsWithAny(text, cfg.tail_comments)) |n| text = commentText(text[n..]);
            try w.toks.append(ir.big, .{ .tag = tag, .text = text, .raw = ln.text, .lno = lno });
            try w.toks.append(ir.big, .{ .tag = .nl, .text = "", .raw = "", .lno = lno });
            return;
        }
        try tokenizeLine(w.scratch.allocator(), w.keep, ir.big, cfg, ln.text, lno, &w.toks);
        try w.toks.append(ir.big, .{ .tag = .nl, .text = ln.tail, .raw = "", .lno = lno });
    }
};

// ------------------------------------------------------------------ numbers

/// Multiply a decimal literal by an integer, digit by digit. No floating
/// point is involved, so `1mil` is exactly 25.4e-6.
fn mulDecimal(arena: Allocator, mant: []const u8, k: u64) Allocator.Error![]const u8 {
    const neg = mant.len > 0 and mant[0] == '-';
    const body = if (neg) mant[1..] else mant;
    var digits: std.ArrayList(u8) = .empty;
    var frac: usize = 0;
    var seen_point = false;
    for (body) |c| {
        if (c == '.') {
            seen_point = true;
        } else {
            try digits.append(arena, c - '0');
            if (seen_point) frac += 1;
        }
    }
    var out: std.ArrayList(u8) = .empty; // least significant digit first
    var carry: u64 = 0;
    var i = digits.items.len;
    while (i > 0) {
        i -= 1;
        const v = digits.items[i] * k + carry;
        try out.append(arena, @intCast(v % 10));
        carry = v / 10;
    }
    while (carry > 0) : (carry /= 10) try out.append(arena, @intCast(carry % 10));
    while (out.items.len <= frac) try out.append(arena, 0);
    var text: std.ArrayList(u8) = .empty;
    if (neg) try text.append(arena, '-');
    var j = out.items.len;
    while (j > 0) {
        j -= 1;
        try text.append(arena, '0' + out.items[j]);
        if (j == frac and frac > 0) try text.append(arena, '.');
    }
    var res: []const u8 = text.items;
    if (frac > 0) {
        res = std.mem.trimEnd(u8, res, "0");
        res = std.mem.trimEnd(u8, res, ".");
    }
    return res;
}

/// Move the decimal point instead of writing an exponent, when that stays short.
fn shiftDecimal(arena: Allocator, digits: []const u8, exp10: i32) Allocator.Error!?[]const u8 {
    if (exp10 == 0) return digits;
    if (exp10 > 6 or exp10 < -6) return null;
    const neg = digits.len > 0 and digits[0] == '-';
    const body = if (neg) digits[1..] else digits;
    const point = std.mem.indexOfScalar(u8, body, '.') orelse body.len;
    var all: std.ArrayList(u8) = .empty;
    for (body) |c| if (c != '.') try all.append(arena, c);
    var pos: i64 = @as(i64, @intCast(point)) + exp10;
    while (pos <= 0) : (pos += 1) try all.insert(arena, 0, '0');
    while (pos > all.items.len) try all.append(arena, '0');
    const p: usize = @intCast(pos);
    var out: std.ArrayList(u8) = .empty;
    if (neg) try out.append(arena, '-');
    try out.appendSlice(arena, all.items[0..p]);
    if (p < all.items.len) {
        try out.append(arena, '.');
        try out.appendSlice(arena, all.items[p..]);
    }
    var res: []const u8 = out.items;
    if (std.mem.indexOfScalar(u8, res, '.') != null) {
        res = std.mem.trimEnd(u8, res, "0");
        res = std.mem.trimEnd(u8, res, ".");
    }
    if (res.len > 12) return null;
    return res;
}

/// Parse a numeric literal under this dialect's scale-factor rules.
/// `text` must already be case-folded for case-insensitive dialects.
pub fn parseNumber(arena: Allocator, cfg: *const LexCfg, text: []const u8) ?ir.Number {
    var i: usize = 0;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
    const int_start = i;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    var digits_seen = i - int_start;
    if (i < text.len and text[i] == '.') {
        i += 1;
        const frac = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        digits_seen += i - frac;
    }
    if (digits_seen == 0) return null;
    var mant = text[0..i];
    if (mant[mant.len - 1] == '.') mant = mant[0 .. mant.len - 1];
    if (mant.len > 0 and mant[0] == '+') mant = mant[1..];

    var exp: i32 = 0;
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        var j = i + 1;
        if (j < text.len and (text[j] == '+' or text[j] == '-')) j += 1;
        const d0 = j;
        while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
        if (j > d0) {
            exp = std.fmt.parseInt(i32, text[i + 1 .. j], 10) catch return null;
            i = j;
        }
    }
    const rest = text[i..];
    if (rest.len == 0) return .init(mant, exp);

    // Longest suffix wins, so `meg` beats `m`.
    var best_len: usize = 0;
    var best_exp: i32 = 0;
    var best_odd: ?grammar.OddScale = null;
    for (cfg.scales) |s| {
        if (s.suffix.len > best_len and std.mem.startsWith(u8, rest, s.suffix)) {
            best_len = s.suffix.len;
            best_exp = s.exp10;
            best_odd = null;
        }
    }
    for (cfg.read_scales) |s| {
        if (s.suffix.len > best_len and std.mem.startsWith(u8, rest, s.suffix)) {
            best_len = s.suffix.len;
            best_exp = s.exp10;
            best_odd = null;
        }
    }
    for (cfg.odd_scales) |s| {
        if (s.suffix.len > best_len and std.mem.startsWith(u8, rest, s.suffix)) {
            best_len = s.suffix.len;
            best_odd = s;
        }
    }
    const units = rest[best_len..];
    for (units) |c| if (!std.ascii.isAlphabetic(c)) return null;
    if (best_len == 0 and !cfg.units_ignored) return null;
    if (best_odd) |odd| {
        const digits = mulDecimal(arena, mant, odd.mant) catch return null;
        return .init(digits, exp + odd.exp10);
    }
    return .init(mant, exp + best_exp);
}

/// Spell a number in this dialect: a scale suffix where one fits exactly,
/// plain exponent notation otherwise. No arithmetic, so nothing is rounded.
pub fn renderNumber(w: *std.Io.Writer, cfg: *const LexCfg, n: ir.Number) std.Io.Writer.Error!void {
    if (n.exp10 == 0) return w.writeAll(n.digits());
    for (cfg.scales) |s| {
        if (s.exp10 == n.exp10) {
            try w.writeAll(n.digits());
            return w.writeAll(s.suffix);
        }
    }
    // No suffix for exactly this power. Moving the decimal point is exact, so
    // try the neighbouring suffixes and plain notation, and keep the shortest.
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const a = fba.allocator();
    var best: []const u8 = std.fmt.allocPrint(a, "{s}e{d}", .{ n.digits(), n.exp10 }) catch return w.print("{s}e{d}", .{ n.digits(), n.exp10 });
    if (shiftDecimal(a, n.digits(), n.exp10) catch null) |plain| {
        if (plain.len <= best.len) best = plain;
    }
    for (cfg.scales) |s| {
        // Only towards a larger suffix (254e-7 is 25.4u): padding with
        // zeros to reach a smaller one would turn 1e-14 into 10f.
        const delta = n.exp10 - s.exp10;
        if (delta < -3 or delta >= 0) continue;
        const shifted = (shiftDecimal(a, n.digits(), delta) catch null) orelse continue;
        if (shifted.len + s.suffix.len < best.len) {
            best = std.fmt.allocPrint(a, "{s}{s}", .{ shifted, s.suffix }) catch continue;
        }
    }
    try w.writeAll(best);
}

const testing = std.testing;

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
    try testing.expectApproxEqRel(@as(f64, 25.4e-6), parseNumber(a, &spice_cfg, "1mil").?.toFloat(), 1e-12);
}

test "lines, comments, continuation" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var lx = try lex(a, &spice_cfg,
        \\My Title
        \\* a comment
        \\R1 in out 1K $ trailing
        \\M1 d g s b nch
        \\+ W=1u L={2*0.5U}
        \\.end
        \\R9 never seen 1
    );
    defer lx.deinit();
    var w: Window = .init(&spice_cfg, lx.lines, a);
    defer w.deinit();
    while (try w.has(w.toks.items.len)) {}
    const toks = w.toks.items;
    try testing.expectEqualStrings("My Title", lx.title);
    try testing.expectEqual(3, lx.lines.len);
    try testing.expectEqual(TokTag.comment, toks[0].tag);
    try testing.expectEqualStrings("a comment", toks[0].text);
    try testing.expectEqualStrings("r1", toks[2].text);
    try testing.expectEqualStrings("R1", toks[2].raw);
    try testing.expectEqualStrings("trailing", toks[6].text);
    try testing.expectEqual(@as(u32, 4), lx.lines[2].no);
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
    var lx = try lex(a, &cfg,
        \\r1 (a b) resistor r=(ra + rb)*2 // note
        \\v1 (a 0) vsource type=pwl \
        \\    wave=[0 0 1n 1]
    );
    defer lx.deinit();
    var w: Window = .init(&cfg, lx.lines, a);
    defer w.deinit();
    while (try w.has(w.toks.items.len)) {}
    const toks = w.toks.items;
    try testing.expectEqual(2, lx.lines.len);
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
        .{ "1e6mil", "25.4" }, .{ "1mil", "25.4u" }, .{ "2.5mil", "63.5u" }, .{ "-0.5mil", "-12.7u" }, .{ "100mil", "2540u" },
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
