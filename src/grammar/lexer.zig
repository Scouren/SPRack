//! The `lexer ... end` section of a grammar into a `LexCfg`.
//!
//! Contents:
//! - `pub fn parseLexer(c: *C, lines: *Lines) Error!LexCfg`

const std = @import("std");
const context = @import("context.zig");
const types = @import("types.zig");
const C = context.C;
const Error = context.Error;
const Lines = context.Lines;
const args = context.args;
const parseDecimal = context.parseDecimal;
const LexCfg = types.LexCfg;
const OddScale = types.OddScale;
const Scale = types.Scale;

pub fn parseLexer(c: *C, lines: *Lines) Error!LexCfg {
    var cfg: LexCfg = .{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return cfg;
        try setting(c, &cfg, lines.no, line);
    }
    return c.fail(lines.no, "lexer section is missing 'end'", .{});
}

// ---- private ----

/// One line of the lexer section.
fn setting(c: *C, cfg: *LexCfg, no: u32, line: []const u8) Error!void {
    const a = try args(c, no, line);
    // A line `Lines.next` gives starts with a character that is no blank.
    std.debug.assert(a.len > 0);
    const key = a[0];
    const n = a.len - 1;
    const eql = std.mem.eql;
    if (eql(u8, key, "case") and n == 1) {
        cfg.case_sensitive = eql(u8, a[1], "sensitive");
    } else if (eql(u8, key, "title") and n >= 1) {
        cfg.title = eql(u8, a[1], "yes");
        if (n == 2) cfg.title_prefix = a[2];
    } else if (eql(u8, key, "comment") and n >= 2) {
        try comments(c, cfg, no, a);
    } else if (eql(u8, key, "annotation") and n == 1) {
        if (a[1].len == 0) return c.fail(no, "annotation needs its mark", .{});
        cfg.annotation = a[1];
    } else if (eql(u8, key, "continue") and n == 2) {
        if (eql(u8, a[1], "lead")) {
            cfg.cont_lead = a[2];
        } else if (eql(u8, a[1], "trail")) {
            cfg.cont_trail = a[2];
        } else return c.fail(no, "continue must be 'lead' or 'trail'", .{});
    } else if (eql(u8, key, "parens") and n == 1) {
        cfg.parens_are_space = eql(u8, a[1], "space");
    } else if (eql(u8, key, "expr") and n == 1 and eql(u8, a[1], "bare")) {
        cfg.bare_expr = true;
    } else if (eql(u8, key, "expr") and n == 1 and eql(u8, a[1], "after-equals")) {
        cfg.bare_after_eq = true;
    } else if (eql(u8, key, "expr") and n == 2) {
        cfg.expr_delims = try c.add([2][]const u8, cfg.expr_delims, .{ a[1], a[2] });
    } else if (eql(u8, key, "vectors") and n == 1) {
        cfg.vector_sep = if (eql(u8, a[1], "comma")) ", " else " ";
    } else if (eql(u8, key, "quotes") and n >= 2 and eql(u8, a[1], "\"")) {
        try quotes(c, cfg, no, a);
    } else if (eql(u8, key, "values") and n == 1) {
        cfg.ident_values = eql(u8, a[1], "idents");
    } else if (eql(u8, key, "scale") or eql(u8, key, "readscale")) {
        for (a[1..]) |pair| try scale(c, cfg, no, key[0] == 's', pair);
    } else if (eql(u8, key, "oddscale")) {
        for (a[1..]) |pair| try oddScale(c, cfg, no, pair);
    } else if (eql(u8, key, "numbers") and n == 1 and eql(u8, a[1], "strict")) {
        cfg.strict_numbers = true;
    } else if (eql(u8, key, "units") and n == 1) {
        cfg.units_ignored = eql(u8, a[1], "ignore");
    } else if (eql(u8, key, "end") and n == 1) {
        cfg.end_marker = try c.foldIf(!cfg.case_sensitive, a[1]);
    } else return c.fail(no, "unknown lexer setting `{s}`", .{line});
}

/// `comment line|tail "x" ...` or `comment block "open" "close"`.
fn comments(c: *C, cfg: *LexCfg, no: u32, a: []const []const u8) Error!void {
    if (std.mem.eql(u8, a[1], "line")) {
        for (a[2..]) |x| cfg.line_comments = try c.add([]const u8, cfg.line_comments, x);
    } else if (std.mem.eql(u8, a[1], "tail")) {
        for (a[2..]) |x| cfg.tail_comments = try c.add([]const u8, cfg.tail_comments, x);
    } else if (std.mem.eql(u8, a[1], "block") and a.len == 4) {
        cfg.block_comment = .{ a[2], a[3] };
    } else return c.fail(no, "comment must be 'line', 'tail' or 'block \"open\" " ++
        "\"close\"'", .{});
}

/// `quotes '"' string|expr-in-values [except key...]`.
fn quotes(c: *C, cfg: *LexCfg, no: u32, a: []const []const u8) Error!void {
    if (std.mem.eql(u8, a[2], "expr-in-values")) {
        cfg.dquote_expr = true;
    } else if (!std.mem.eql(u8, a[2], "string")) return c.fail(no, "quotes '\"' " ++
        "takes 'string' or 'expr-in-values'", .{});
    if (a.len == 3) return;
    if (a.len == 4 or !std.mem.eql(u8, a[3], "except"))
        return c.fail(no, "expected `except key...` after the quote rule", .{});
    for (a[4..]) |x|
        cfg.dquote_strings = try c.add(
            []const u8,
            cfg.dquote_strings,
            try c.foldIf(!cfg.case_sensitive, x),
        );
}

/// `suffix=exponent`, one entry of `scale` (`write`) or `readscale`.
fn scale(c: *C, cfg: *LexCfg, no: u32, write: bool, pair: []const u8) Error!void {
    const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return c.fail(
        no,
        "scale entries are suffix=exponent",
        .{},
    );
    // The exponent is what follows the '=', empty or not.
    std.debug.assert(eq < pair.len);
    const exp = std.fmt.parseInt(i32, pair[eq + 1 ..], 10) catch return c.fail(
        no,
        "bad scale exponent in '{s}'",
        .{pair},
    );
    const entry: Scale = .{
        .suffix = try c.foldIf(!cfg.case_sensitive, pair[0..eq]),
        .exp10 = exp,
    };
    if (write) {
        cfg.scales = try c.add(Scale, cfg.scales, entry);
    } else cfg.read_scales = try c.add(Scale, cfg.read_scales, entry);
}

/// `suffix=multiplier`, one entry of `oddscale`.
fn oddScale(c: *C, cfg: *LexCfg, no: u32, pair: []const u8) Error!void {
    const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return c.fail(
        no,
        "oddscale entries are suffix=multiplier",
        .{},
    );
    const mant, const exp = try parseDecimal(c, no, pair[eq + 1 ..]);
    const suf = try c.foldIf(!cfg.case_sensitive, pair[0..eq]);
    cfg.odd_scales = try c.add(
        OddScale,
        cfg.odd_scales,
        .{ .suffix = suf, .mant = mant, .exp10 = exp },
    );
}
