//! The value of a condition over parameters whose values are known
//! (`eval`), and whether text is a plain number.
//!
//! Contents:
//! - `pub fn isPlainNumber(text: []const u8) bool`
//! - `pub fn eval(text: []const u8, params: []const ir.Param, stop: *[]const u8, depth: u8) ?f64`

const std = @import("std");
const ir = @import("ir");
const expr = @import("expr.zig");
const expr_scan = @import("expr_scan.zig");
const canon_ne = expr.canon_ne;
const nextIsCall = expr_scan.nextIsCall;
const numberEnd = expr_scan.numberEnd;
const wordEnd = expr_scan.wordEnd;
const testing = std.testing;

/// The value of a condition over parameters whose values are known: no
/// more than that needs (`eval`).
const Eval = struct {
    text: []const u8,
    at: usize = 0,
    params: []const ir.Param,
    stop: *[]const u8,
    depth: u8,

    /// Loosest first; of two spellings that start alike, the longer first.
    const levels = [_][]const []const u8{
        &.{"||"},       &.{"&&"},       &.{ "==", canon_ne },
        &.{
            "<=",
            ">=",
            "<",
            ">",
        },
        &.{ "+", "-" }, &.{ "*", "/" },
    };

    fn fail(e: *Eval, what: []const u8) ?f64 {
        if (e.stop.len == 0) e.stop.* = what;
        return null;
    }

    fn op(e: *Eval, spelling: []const u8) bool {
        var at = e.at;
        while (at < e.text.len and (e.text[at] == ' ' or e.text[at] == '\t')) at += 1;
        e.at = at;
        if (!std.mem.startsWith(u8, e.text[e.at..], spelling)) return false;
        e.at += spelling.len;
        return true;
    }

    fn binary(e: *Eval, level: usize) ?f64 {
        std.debug.assert(level <= levels.len);
        if (level == levels.len) return e.unary();
        var a = e.binary(level + 1) orelse return null;
        // Until no operator of this level follows.
        next: while (true) {
            for (levels[level]) |o| {
                if (!e.op(o)) continue;
                const b = e.binary(level + 1) orelse return null;
                if (o[0] == '/' and b == 0) return e.fail(o);
                a = switch (o[0]) {
                    '+' => a + b,
                    '-' => a - b,
                    '*' => a * b,
                    '/' => a / b,
                    else => if (switch (o[0]) {
                        '|' => a != 0 or b != 0,
                        '&' => a != 0 and b != 0,
                        '=' => a == b,
                        '!' => a != b,
                        '<' => if (o.len == 2) a <= b else a < b,
                        else => if (o.len == 2) a >= b else a > b,
                    }) 1 else 0,
                };
                continue :next;
            }
            return a;
        }
    }

    fn unary(e: *Eval) ?f64 {
        std.debug.assert(e.at <= e.text.len);
        if (e.op("-")) return -(e.unary() orelse return null);
        if (e.op("!")) return if ((e.unary() orelse return null) == 0) 1 else 0;
        if (e.op("(")) {
            const v = e.binary(0) orelse return null;
            return if (e.op(")")) v else e.fail(")");
        }
        const from = e.at;
        if (from == e.text.len) return e.fail("its end");
        if (std.ascii.isDigit(e.text[from]) or e.text[from] == '.') {
            e.at = numberEnd(e.text, from);
            return std.fmt.parseFloat(f64, e.text[from..e.at]) catch e.fail(e.text[from..e.at]);
        }
        e.at = wordEnd(e.text, from);
        const word = e.text[from..e.at];
        if (word.len == 0 or nextIsCall(e.text, e.at))
            return e.fail(if (word.len == 0) e.text[from .. from + 1] else word);
        for (e.params) |p| {
            if (!std.ascii.eqlIgnoreCase(p.key, word)) continue;
            return switch (p.val) {
                .num => |n| n.toFloat(),
                // Bounded, so a parameter that is its own value ends.
                .expr, .atom => |t| if (e.depth < 16)
                    eval(t, e.params, e.stop, e.depth + 1) orelse e.fail(word)
                else
                    e.fail(word),
                else => e.fail(word),
            };
        }
        return e.fail(word);
    }
};

/// Every function name an expression calls that is not a canonical one.
pub fn isPlainNumber(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == 'e' or c == '-')) return false;
    return std.ascii.isDigit(text[0]) or text[0] == '.' or text[0] == '-';
}

/// The number that canonical expression text comes to when it holds only
/// numbers, `+ - * /`, comparisons, `&& || !`, parentheses and names that
/// `params` binds to numbers or to such expressions (the first of a name
/// counts, in any case of letters); a truth is 1 or 0. Null for anything
/// else, and `stop` is what it stopped at: a name bound to no number, a
/// function, another operator, a division by zero.
pub fn eval(text: []const u8, params: []const ir.Param, stop: *[]const u8, depth: u8) ?f64 {
    var e: Eval = .{ .text = text, .params = params, .stop = stop, .depth = depth };
    const v = e.binary(0) orelse return null;
    return if (e.op("") and e.at == text.len) v else e.fail(text[e.at .. e.at + 1]);
}

test "a condition over known parameters" {
    const ps: []const ir.Param = &.{
        .{ .key = "xd", .val = .{ .num = .init("0.7", 0) } },
        .{ .key = "scaling", .val = .{ .num = .init("1", -6) } },
        .{ .key = "xds", .val = .{ .expr = "xd/scaling" } },
        .{ .key = "loop", .val = .{ .expr = "loop+1" } },
        .{ .key = "ic", .val = .none },
    };
    var stop: []const u8 = "";
    try testing.expectEqual(1, eval("xds<0.8e6 && !(XD == 0) || 1 > 2", ps, &stop, 0));
    try testing.expectEqual(0, eval("(xds >= 1e6)", ps, &stop, 0));
    try testing.expectEqual(-5, eval("-(1+2*3) + 4/2", ps, &stop, 0));
    try testing.expectEqual(1, eval("1e-3 != .001 || 2 <= 2", ps, &stop, 0));
    inline for (.{
        .{
            "floor(xd) == 0",
            "floor",
        },
        .{ "xd > vdd", "vdd" },
        .{ "ic>1e9", "ic" },
        .{ "xd ? 1 : 2", "?" },
        .{ "xd**2 > 1", "*" },
        .{ "loop == 1", "loop" },
        .{ "1/(xd-xd)", "/" },
        .{ "(xd", ")" },
        .{ "xd >", "its end" },
    }) |c| {
        stop = "";
        try testing.expectEqual(null, eval(c[0], ps, &stop, 0));
        try testing.expectEqualStrings(c[1], stop);
    }
}
