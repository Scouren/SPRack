//! The forms of an expression: which functions and operators it uses, and a
//! choice rewritten between `c ? a : b` and `if(c, a, b)`.
//!
//! Contents:
//! - `pub fn uses(text: []const u8, name: []const u8) bool`
//! - `pub fn ternaryToIf(arena: Allocator, text: []const u8) Allocator.Error![]const u8`
//! - `pub fn ifToTernary(arena: Allocator, text: []const u8) Allocator.Error![]const u8`

const std = @import("std");
const expr = @import("expr.zig");
const expr_scan = @import("expr_scan.zig");
const Allocator = std.mem.Allocator;
const canon_pow = expr.canon_pow;
const canon_xor = expr.canon_xor;
const isWordChar = expr_scan.isWordChar;
const matching = expr_scan.matching;
const nextIsCall = expr_scan.nextIsCall;
const topLevel = expr_scan.topLevel;
const testing = std.testing;

/// Does a canonical expression call function `name`, or (for `pow`, `xor`,
/// `ternary`) use that operator? `negpow` is a minus right after another
/// operator, before a power (`1+-2**2`), where dialects disagree on which
/// binds first.
pub fn uses(text: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, name, "pow") and std.mem.indexOf(u8, text, canon_pow) != null) return true;
    if (std.mem.eql(u8, name, "xor") and std.mem.indexOf(u8, text, canon_xor) != null) return true;
    if (std.mem.eql(u8, name, "ternary")) return nested(text, '?');
    if (std.mem.eql(u8, name, "mod")) return nested(text, '%');
    if (std.mem.eql(u8, name, "negpow")) return negPow(text);
    if (std.mem.eql(u8, name, "minuspow")) return minusPow(text);
    if (std.mem.eql(u8, name, "andor"))
        return std.mem.indexOf(u8, text, "&&") != null or std.mem.indexOf(u8, text, "||") != null;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, name)) |at| : (i = at + 1) {
        const end = at + name.len;
        std.debug.assert(end <= text.len);
        const starts = at == 0 or !isWordChar(text[at - 1]);
        const ends = end == text.len or !isWordChar(text[end]);
        if (starts and ends and nextIsCall(text, end)) return true;
    }
    return false;
}

/// `c ? a : b` as `if(c, a, b)`, in every group and argument.
// tidy: allow(recursion) depth is the nesting of the expression's groups, commas and
// choices; nothing but the length of its text bounds it
pub fn ternaryToIf(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (topLevel(text, 0, ',')) |comma| {
        return std.fmt.allocPrint(
            arena,
            "{s},{s}",
            .{ try ternaryToIf(arena, text[0..comma]), try ternaryToIf(arena, text[comma + 1 ..]) },
        );
    }
    if (topLevel(text, 0, '?')) |q| if (colonOf(text, q)) |colon| {
        const t = " \t";
        return std.fmt.allocPrint(arena, "if({s}, {s}, {s})", .{
            std.mem.trim(u8, try ternaryToIf(arena, text[0..q]), t),
            std.mem.trim(u8, try ternaryToIf(arena, text[q + 1 .. colon]), t),
            std.mem.trim(u8, try ternaryToIf(arena, text[colon + 1 ..]), t),
        });
    };
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"' or c == '\'') {
            const end = (std.mem.indexOfScalarPos(u8, text, i + 1, c) orelse text.len - 1) + 1;
            try out.appendSlice(arena, text[i..end]);
            i = end;
        } else if (c == '(') {
            const close = matching(text, i) orelse text.len;
            std.debug.assert(close > i);
            try out.append(arena, '(');
            try out.appendSlice(arena, try ternaryToIf(arena, text[i + 1 .. close]));
            if (close < text.len) try out.append(arena, ')');
            i = close + 1;
        } else {
            try out.append(arena, c);
            i += 1;
        }
    }
    return out.items;
}

/// `if(c, a, b)` as `(c ? a : b)`.
// tidy: allow(recursion) depth is the nesting of the expression's groups, commas and
// choices; nothing but the length of its text bounds it
pub fn ifToTernary(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"' or c == '\'') {
            const end = (std.mem.indexOfScalarPos(u8, text, i + 1, c) orelse text.len - 1) + 1;
            try out.appendSlice(arena, text[i..end]);
            i = end;
            continue;
        }
        const word = std.mem.startsWith(
            u8,
            text[i..],
            "if",
        ) and (i == 0 or !isWordChar(text[i - 1])) and
            (i + 2 == text.len or !isWordChar(text[i + 2])) and nextIsCall(text, i + 2);
        if (!word) {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        const open = std.mem.indexOfScalarPos(u8, text, i + 2, '(').?;
        const close = matching(text, open) orelse {
            try out.appendSlice(arena, text[i..]);
            break;
        };
        std.debug.assert(close > open);
        const inner = text[open + 1 .. close];
        const c1 = topLevel(inner, 0, ',');
        const c2 = if (c1) |x| topLevel(inner, x + 1, ',') else null;
        if (c1 == null or c2 == null or topLevel(inner, c2.? + 1, ',') != null) {
            try out.appendSlice(arena, text[i .. open + 1]);
            try out.appendSlice(arena, try ifToTernary(arena, inner));
            try out.append(arena, ')');
        } else {
            const t = " \t";
            const parts = [3][]const u8{
                inner[0..c1.?],
                inner[c1.? + 1 .. c2.?],
                inner[c2.? + 1 ..],
            };
            try out.append(arena, '(');
            for (parts, 0..) |part, k| {
                const conv = std.mem.trim(u8, try ifToTernary(arena, part), t);
                // A choice inside a choice keeps its own parentheses.
                const wrap = topLevel(conv, 0, '?') != null;
                if (k == 1) try out.appendSlice(arena, " ? ");
                if (k == 2) try out.appendSlice(arena, " : ");
                if (wrap) try out.append(arena, '(');
                try out.appendSlice(arena, conv);
                if (wrap) try out.append(arena, ')');
            }
            try out.append(arena, ')');
        }
        i = close + 1;
    }
    return out.items;
}

// ---- private ----

fn nested(text: []const u8, c: u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '"' or text[i] == '\'') {
            i = std.mem.indexOfScalarPos(u8, text, i + 1, text[i]) orelse return false;
            continue;
        }
        if (text[i] == c) return true;
    }
    return false;
}

fn topLevelAny(text: []const u8, from: usize) ?usize {
    const a = topLevel(text, from, '?');
    const b = topLevel(text, from, ':');
    if (a == null) return b;
    if (b == null) return a;
    return @min(a.?, b.?);
}

/// The `:` that closes the `?` at `q`: nested choices pair inside it.
fn colonOf(text: []const u8, q: usize) ?usize {
    var open: usize = 0;
    var i = q + 1;
    while (topLevelAny(text, i)) |at| : (i = at + 1) {
        if (text[at] == '?') {
            open += 1;
        } else if (open == 0) return at else open -= 1;
    }
    return null;
}

/// A unary minus right after another operator, in an operand of `**`.
fn negPow(text: []const u8) bool {
    if (std.mem.indexOf(u8, text, canon_pow) == null) return false;
    var prev: u8 = 0;
    var prev2: u8 = 0;
    for (text) |c| {
        if (c == ' ' or c == '\t') continue;
        if (c == '-' and prev != 0 and std.mem.indexOfScalar(u8, "+-*/^?:<>=!&|%", prev) != null) {
            // After `**` it is the exponent's sign: `2**-1`.
            if (!(prev == '*' and prev2 == '*')) return true;
        }
        prev2 = prev;
        prev = c;
    }
    return false;
}

/// A unary minus whose operand is the base of a power: `-2**2`, `(-x**2)`,
/// `1+-f(x)**2`, `-(a+b)**2`. Not `2**-1`, where it is the exponent's sign.
fn minusPow(text: []const u8) bool {
    var prev: u8 = 0;
    var prev2: u8 = 0;
    for (text, 0..) |c, at| {
        if (c == ' ' or c == '\t') continue;
        defer {
            prev2 = prev;
            prev = c;
        }
        if (c != '-' or (prev == '*' and prev2 == '*')) continue;
        if (prev != 0 and std.mem.indexOfScalar(u8, "(,+-*/^?:<>=!&|%", prev) == null) continue;
        // One operand: a group, or a word or number with the call after it.
        var i = at + 1;
        while (i < text.len and text[i] == ' ') i += 1;
        while (i < text.len and (isWordChar(text[i]) or text[i] == '.')) i += 1;
        if (i < text.len and text[i] == '(')
            i = (topLevel(text, i + 1, ')') orelse return false) + 1;
        while (i < text.len and text[i] == ' ') i += 1;
        std.debug.assert(i <= text.len);
        if (std.mem.startsWith(u8, text[i..], canon_pow)) return true;
    }
    return false;
}

test "a choice is written in the form the target has" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("if(x > 1, 3, 4)", try ternaryToIf(a, "x > 1 ? 3 : 4"));
    try testing.expectEqualStrings(
        "if(0, 1, if(1, 5, 6))",
        try ternaryToIf(a, "0 ? 1 : 1 ? 5 : 6"),
    );
    try testing.expectEqualStrings(
        "2 + (if(x > 1, 3, 4))",
        try ternaryToIf(a, "2 + (x > 1 ? 3 : 4)"),
    );
    try testing.expectEqualStrings("max(if(a, b, c),d)", try ternaryToIf(a, "max(a ? b : c,d)"));
    try testing.expectEqualStrings("(x > 1 ? 3 : 4)", try ifToTernary(a, "if(x > 1, 3, 4)"));
    try testing.expectEqualStrings(
        "2*(a ? (b ? 1 : 2) : 3)",
        try ifToTernary(a, "2*if(a, if(b,1,2), 3)"),
    );
    try testing.expectEqualStrings("diff(x)", try ifToTernary(a, "diff(x)"));
    try testing.expect(uses("1+-2**2", "negpow") and uses("2*-x**2", "negpow"));
    try testing.expect(
        !uses("-2**2", "negpow") and !uses("2**-1", "negpow") and !uses(
            "max(-2**2,0)",
            "negpow",
        ) and !uses("1-2", "negpow"),
    );
    try testing.expect(
        uses("-2**2", "minuspow") and uses("max(-x**2,0)", "minuspow") and uses(
            "1+-f(x, 2)**2",
            "minuspow",
        ) and uses("- (a+b) ** 2", "minuspow"),
    );
    try testing.expect(
        !uses("2**-1", "minuspow") and !uses(
            "-a*b**2",
            "minuspow",
        ) and !uses("a-b**2", "minuspow") and !uses("-(a**2)", "minuspow"),
    );
    try testing.expect(
        uses("a>1 && b>1", "andor") and uses("a||b", "andor") and !uses("a & b | c", "andor"),
    );
}
