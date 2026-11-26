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
        const a = try args(c, lines.no, line);
        const key = a[0];
        const n = a.len - 1;
        if (std.mem.eql(u8, key, "case") and n == 1) {
            cfg.case_sensitive = std.mem.eql(u8, a[1], "sensitive");
        } else if (std.mem.eql(u8, key, "title") and n >= 1) {
            cfg.title = std.mem.eql(u8, a[1], "yes");
            if (n == 2) cfg.title_prefix = a[2];
        } else if (std.mem.eql(u8, key, "comment") and n >= 2) {
            if (std.mem.eql(u8, a[1], "line")) {
                for (a[2..]) |x| cfg.line_comments = try c.add([]const u8, cfg.line_comments, x);
            } else if (std.mem.eql(u8, a[1], "tail")) {
                for (a[2..]) |x| cfg.tail_comments = try c.add([]const u8, cfg.tail_comments, x);
            } else if (std.mem.eql(u8, a[1], "block") and n == 3) {
                cfg.block_comment = .{ a[2], a[3] };
            } else return c.fail(lines.no, "comment must be 'line', 'tail' or 'block \"open\" " ++
                "\"close\"'", .{});
        } else if (std.mem.eql(u8, key, "continue") and n == 2) {
            if (std.mem.eql(u8, a[1], "lead")) {
                cfg.cont_lead = a[2];
            } else if (std.mem.eql(u8, a[1], "trail")) {
                cfg.cont_trail = a[2];
            } else return c.fail(lines.no, "continue must be 'lead' or 'trail'", .{});
        } else if (std.mem.eql(u8, key, "parens") and n == 1) {
            cfg.parens_are_space = std.mem.eql(u8, a[1], "space");
        } else if (std.mem.eql(u8, key, "expr") and n == 1 and std.mem.eql(u8, a[1], "bare")) {
            cfg.bare_expr = true;
        } else if (std.mem.eql(u8, key, "expr") and n == 1 and
            std.mem.eql(u8, a[1], "after-equals"))
        {
            cfg.bare_after_eq = true;
        } else if (std.mem.eql(u8, key, "expr") and n == 2) {
            cfg.expr_delims = try c.add([2][]const u8, cfg.expr_delims, .{ a[1], a[2] });
        } else if (std.mem.eql(u8, key, "vectors") and n == 1) {
            cfg.vector_sep = if (std.mem.eql(u8, a[1], "comma")) ", " else " ";
        } else if (std.mem.eql(u8, key, "quotes") and n >= 2 and std.mem.eql(u8, a[1], "\"")) {
            if (std.mem.eql(u8, a[2], "expr-in-values")) {
                cfg.dquote_expr = true;
            } else if (!std.mem.eql(u8, a[2], "string")) return c.fail(lines.no, "quotes '\"' " ++
                "takes 'string' or 'expr-in-values'", .{});
            if (n > 2) {
                if (n == 3 or !std.mem.eql(u8, a[3], "except"))
                    return c.fail(lines.no, "expected `except key...` after the quote rule", .{});
                for (a[4..]) |x|
                    cfg.dquote_strings = try c.add(
                        []const u8,
                        cfg.dquote_strings,
                        try c.foldIf(!cfg.case_sensitive, x),
                    );
            }
        } else if (std.mem.eql(u8, key, "values") and n == 1) {
            cfg.ident_values = std.mem.eql(u8, a[1], "idents");
        } else if (std.mem.eql(u8, key, "scale") or std.mem.eql(u8, key, "readscale")) {
            for (a[1..]) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return c.fail(
                    lines.no,
                    "scale entries are suffix=exponent",
                    .{},
                );
                const exp = std.fmt.parseInt(i32, pair[eq + 1 ..], 10) catch return c.fail(
                    lines.no,
                    "bad scale exponent in '{s}'",
                    .{pair},
                );
                const entry: Scale = .{
                    .suffix = try c.foldIf(!cfg.case_sensitive, pair[0..eq]),
                    .exp10 = exp,
                };
                if (key[0] == 's') {
                    cfg.scales = try c.add(Scale, cfg.scales, entry);
                } else cfg.read_scales = try c.add(Scale, cfg.read_scales, entry);
            }
        } else if (std.mem.eql(u8, key, "oddscale")) {
            for (a[1..]) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return c.fail(
                    lines.no,
                    "oddscale entries are suffix=multiplier",
                    .{},
                );
                const mant, const exp = try parseDecimal(c, lines.no, pair[eq + 1 ..]);
                const suf = try c.foldIf(!cfg.case_sensitive, pair[0..eq]);
                cfg.odd_scales = try c.add(
                    OddScale,
                    cfg.odd_scales,
                    .{ .suffix = suf, .mant = mant, .exp10 = exp },
                );
            }
        } else if (std.mem.eql(u8, key, "numbers") and n == 1 and std.mem.eql(u8, a[1], "strict")) {
            cfg.strict_numbers = true;
        } else if (std.mem.eql(u8, key, "units") and n == 1) {
            cfg.units_ignored = std.mem.eql(u8, a[1], "ignore");
        } else if (std.mem.eql(u8, key, "end") and n == 1) {
            cfg.end_marker = try c.foldIf(!cfg.case_sensitive, a[1]);
        } else return c.fail(lines.no, "unknown lexer setting `{s}`", .{line});
    }
    return c.fail(lines.no, "lexer section is missing 'end'", .{});
}
