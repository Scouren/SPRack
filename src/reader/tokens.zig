//! Tokens: one logical line cut into words, strings, expressions, vectors
//! and punctuation, under the dialect's lexer section.

const std = @import("std");
const grammar = @import("grammar");
const lexer = @import("lexer.zig");
const Allocator = std.mem.Allocator;
const LexCfg = grammar.LexCfg;
const Tok = lexer.Tok;
const TokTag = lexer.TokTag;
const numbers = @import("numbers.zig");
const parseNumber = numbers.parseNumber;

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
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '!' or c == ':' or
            c == '#' or c == '$'))
            return false;
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

fn pushTok(
    list_gpa: Allocator,
    toks: *std.ArrayList(Tok),
    tag: TokTag,
    text: []const u8,
    raw: []const u8,
    lno: u32,
) Allocator.Error!void {
    try toks.append(list_gpa, .{ .tag = tag, .text = text, .raw = raw, .lno = lno });
}

/// `arena` owns token text; `keep`, text that must outlive the window;
/// `list_gpa` owns the token list itself.
pub fn tokenizeLine(
    arena: Allocator,
    keep: Allocator,
    list_gpa: Allocator,
    cfg: *const LexCfg,
    text: []const u8,
    lno: u32,
    toks: *std.ArrayList(Tok),
) Allocator.Error!void {
    var i: usize = 0;
    var after_eq = false;
    const line_start = toks.items.len;
    outer: while (true) {
        if (cfg.parens_are_space and toks.items.len > line_start)
            toks.items[toks.items.len - 1].closes = countCloses(text, i);
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
            if (toks.items.len > 0 and toks.items[toks.items.len - 1].tag == .word and
                toks.items[toks.items.len - 1].lno == lno)
            {
                toks.items[toks.items.len - 1].f.key = true;
            }
            try pushTok(list_gpa, toks, .eq, "=", text[i .. i + 1], lno);
            i += 1;
            after_eq = true;
            continue;
        }
        if (c == '"') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '"') orelse text.len;
            try pushTok(
                list_gpa,
                toks,
                .str,
                text[i + 1 .. end],
                text[i..@min(end + 1, text.len)],
                lno,
            );
            i = @min(end + 1, text.len);
            continue;
        }
        if (value_ctx) if (try joinedExpr(keep, cfg, text, i)) |jx| {
            try pushTok(list_gpa, toks, .expr, jx.text, text[i..jx.end], lno);
            i = jx.end;
            continue;
        };
        for (cfg.expr_delims) |d| {
            // Most tokens start with no delimiter's first byte.
            if (d[0].len > 0 and d[0][0] != c) continue;
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
                try pushTok(
                    list_gpa,
                    toks,
                    .vec,
                    text[i + 1 .. end],
                    text[i..@min(end + 1, text.len)],
                    lno,
                );
                i = @min(end + 1, text.len);
                continue;
            }
            // A bare expression runs to the next blank outside parentheses
            // and brackets: `hblin=[1, -1]` is one value. In a SPICE
            // dialect a comma outside them is a blank, as elsewhere on the
            // line: `results=va,vb` is two values (HSPICE's optimization).
            // VACASK's `nodeset={"q",5}` stays one.
            var depth: usize = 0;
            var square: usize = 0;
            var j = i;
            while (j < text.len) : (j += 1) {
                const ch = text[j];
                if (ch == '[') {
                    square += 1;
                } else if (ch == ']') {
                    square -|= 1;
                } else if (square > 0) {
                    continue;
                } else if (ch == '(') {
                    depth += 1;
                } else if (ch == ')') {
                    if (depth == 0) break;
                    depth -= 1;
                } else if (depth == 0 and
                    (ch == ' ' or ch == '\t' or (ch == ',' and !cfg.bare_expr))) break;
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
            if (braces or parseNumber(
                arena,
                cfg,
                try fold(arena, cfg, run),
            ) != null or isIdent(run)) {
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
            try pushTok(list_gpa, toks, if (c == '(')
                .lparen
            else
                .rparen, text[i .. i + 1], text[i .. i + 1], lno);
            i += 1;
            continue;
        }
        var j = i;
        while (j < text.len and !isBlank(
            cfg,
            text[j],
        ) and text[j] != '=' and text[j] != '(' and text[j] != ')') j += 1;
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
    // Only a byte that begins one of the two delimiters is looked at twice.
    const plain_skip = d[0].len > 0 and d[1].len > 0;
    while (j < text.len) {
        if (plain_skip and text[j] != d[1][0] and (same or text[j] != d[0][0])) {
            j += 1;
            continue;
        }
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

/// An operator an expression goes on across a blank with: of arithmetic,
/// or of a condition (`c ? a : b`, a comparison, `&` and `|`).
fn joins(c: u8) bool {
    // `%` and `\` are ngspice's modulo and integer division: `10 %3` is one
    // value (docs/verification.md 4.29).
    return isOperator(c) or std.mem.indexOfScalar(u8, "?:<>!&|%\\", c) != null;
}

/// `==`, `<=`, `>=` or `!=` at `i`: its `=` assigns nothing.
fn comparesAt(text: []const u8, i: usize) bool {
    return i + 1 < text.len and text[i + 1] == '=' and std.mem.indexOfScalar(
        u8,
        "=<>!",
        text[i],
    ) != null;
}

/// `{a} + b`, `{a}*{b}`, `a + {b}`: a delimited expression joined to more
/// by an operator outside the delimiters, as one expression; and `a + b`
/// after `=` where an undelimited expression may stand. ngspice 45
/// takes such a line (when it takes it at all) as the delimiters dropped
/// and the rest kept: `{1+1}*3` is 4, not 6. Null when the value is not
/// such a join.
fn joinedExpr(
    arena: Allocator,
    cfg: *const LexCfg,
    text: []const u8,
    start: usize,
) Allocator.Error!?struct { text: []const u8, end: usize } {
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
            try out.appendSlice(
                arena,
                std.mem.trim(u8, text[i + d[0].len .. @min(j, text.len)], " \t"),
            );
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
            if (j < text.len and text[j] == '=' and spaced and !comparesAt(text, j)) return null;
            if (j == text.len or !(last_op or joins(text[j]) or comparesAt(text, j))) break;
            // `5 %` alone is HSPICE's percent of a variation, no operator.
            if (!last_op and (text[j] == '%' or text[j] == '\\') and !operandAfter(text, j + 1))
                break;
            // `100p -60p`: a sign, the start of the next value of a list.
            if (!last_op and (text[j] == '-' or text[j] == '+') and j + 1 < text.len and
                text[j + 1] != ' ' and text[j + 1] != '\t')
                break;
            try out.append(arena, ' ');
            spaced = true;
            i = j;
            continue;
        }
        if (depth == 0 and c == ',') break;
        // `x = '-1*y' + z = 2`: the `+` stands between two parameters
        // (ngspice reads x = -3 and z = 2), not in an expression.
        if (comparesAt(text, i)) {
            try out.appendSlice(arena, text[i .. i + 2]);
            i += 2;
            last_op = true;
            op_outside = true;
            continue;
        }
        if (depth == 0 and c == '=') return null;
        if (c == '(') depth += 1;
        if (c == ')') {
            if (depth == 0) break;
            depth -= 1;
        }
        last_op = joins(c);
        op_outside = op_outside or last_op;
        try out.append(arena, c);
        i += 1;
    }
    // Undelimited, `0.0 + mc*agauss(0,1,1)` is one only where a bare
    // expression may follow `=`, and only with blanks in it.
    if (!op_outside or !(delimited or (cfg.bare_after_eq and spaced))) return null;
    return .{ .text = std.mem.trim(u8, out.items, " "), .end = i };
}

/// Is there a value after the operator, past blanks?
fn operandAfter(text: []const u8, from: usize) bool {
    var k = from;
    while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
    return k < text.len and (std.ascii.isAlphanumeric(text[k]) or text[k] == '(' or text[k] == '.' or text[k] == '{' or text[k] == '_');
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
