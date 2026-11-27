//! Rewriting the names of an expression: parameters renamed (`rename`) and
//! calls of a function replaced by its body (`applyMeans`), or powers
//! (`applyPowMeans`).
//!
//! Contents:
//! - `pub fn rename(arena: Allocator, text: []const u8, renames: anytype,
//!   hit: *std.ArrayList([]const u8)) Allocator.Error![]const u8`
//! - `pub fn applyMeans(arena: Allocator, text: []const u8, m: anytype,
//!   n: *usize) Allocator.Error![]const u8`
//! - `pub fn applyPowMeans(arena: Allocator, text: []const u8, m: anytype,
//!   n: *usize) Allocator.Error![]const u8`

const std = @import("std");
const schema = @import("schema");
const expr = @import("expr.zig");
const expr_scan = @import("expr_scan.zig");
const Allocator = std.mem.Allocator;
const argSpace = expr.argSpace;
const param_mark = expr.param_mark;
const isWordChar = expr_scan.isWordChar;
const canon_pow = expr.canon_pow;
const matching = expr_scan.matching;
const numberEnd = expr_scan.numberEnd;
const nextIsCall = expr_scan.nextIsCall;
const topLevel = expr_scan.topLevel;
const wordEnd = expr_scan.wordEnd;

/// `text` with each word `renames` names written as its new name, where the
/// word is a parameter: not the name of a call, and not a node or a branch
/// inside a probe (`v()`, `i()`, `vdb()`, `id()`: `argSpace`). `hit` gets
/// each word renamed. The same slice when there is none.
pub fn rename(
    arena: Allocator,
    text: []const u8,
    renames: anytype,
    hit: *std.ArrayList([]const u8),
) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var copied: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        std.debug.assert(copied <= i);
        const c = text[i];
        if (c == '"' or c == '\'') {
            i = (std.mem.indexOfScalarPos(u8, text, i + 1, c) orelse text.len - 1) + 1;
            continue;
        }
        // A marked parameter (`param_mark`): renamed as itself, the mark
        // dropped, since the new name is no variable's.
        const marked = c == param_mark;
        if (marked) {
            const j = wordEnd(text, i + 1);
            const word = text[i + 1 .. j];
            const at = i;
            i = j;
            const to = renames.get(word) orelse continue;
            try out.appendSlice(arena, text[copied..at]);
            try out.appendSlice(arena, to);
            try hit.append(arena, word);
            copied = j;
            continue;
        }
        if (!(std.ascii.isAlphabetic(c) or c == '_' or c == '$') or (i > 0 and
            isWordChar(text[i - 1])))
        {
            i += 1;
            continue;
        }
        const j = wordEnd(text, i);
        const word = text[i..j];
        i = j;
        // A variable's own word is the variable, never a parameter.
        if (schema.isVariable(word)) continue;
        if (nextIsCall(text, j)) {
            if (argSpace(word) != .param) {
                const open = std.mem.indexOfScalarPos(u8, text, j, '(').?;
                i = (matching(text, open) orelse text.len - 1) + 1;
            }
            continue;
        }
        const to = renames.get(word) orelse continue;
        try out.appendSlice(arena, text[copied .. j - word.len]);
        try out.appendSlice(arena, to);
        try hit.append(arena, word);
        copied = j;
    }
    if (copied == 0) return text;
    try out.appendSlice(arena, text[copied..]);
    return out.items;
}

/// Every call of `m.canon` in `text` as `m.body`, each argument put in
/// parentheses where the body names it; `n` counts the calls rewritten.
// tidy: allow(recursion) depth is the nesting of calls in the expression; nothing but
// the length of its text bounds it
pub fn applyMeans(
    arena: Allocator,
    text: []const u8,
    m: anytype,
    n: *usize,
) Allocator.Error![]const u8 {
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
        const starts = (std.ascii.isAlphabetic(c) or c == '_') and
            (i == 0 or !isWordChar(text[i - 1]));
        if (!starts) {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        const j = wordEnd(text, i);
        const word = text[i..j];
        if (!std.mem.eql(u8, word, m.canon) or !nextIsCall(text, j)) {
            try out.appendSlice(arena, word);
            i = j;
            continue;
        }
        const open = std.mem.indexOfScalarPos(u8, text, j, '(').?;
        const close = matching(text, open) orelse {
            try out.appendSlice(arena, text[i..]);
            break;
        };
        std.debug.assert(close > open);
        // The arguments, themselves rewritten.
        var args: std.ArrayList([]const u8) = .empty;
        var from = open + 1;
        // Until the last argument, the one no comma ends.
        while (true) {
            const comma = topLevel(text[0..close], from, ',');
            const end = comma orelse close;
            try args.append(
                arena,
                try applyMeans(arena, std.mem.trim(u8, text[from..end], " \t"), m, n),
            );
            if (comma == null) break;
            from = end + 1;
        }
        if (args.items.len != m.args.len) {
            try out.appendSlice(arena, text[i .. close + 1]);
            i = close + 1;
            continue;
        }
        try substitute(arena, &out, m.body, m.args, args.items);
        n.* += 1;
        i = close + 1;
    }
    return out.items;
}

/// Every `x ** y` in `text` as `m.body` (`means x ** y = ...`), the
/// operands as ngspice takes them: the power binds before a unary minus
/// and from the left, `2**3**2` is 64 (docs/verification.md 4.44). `n`
/// counts the powers rewritten.
pub fn applyPowMeans(
    arena: Allocator,
    text: []const u8,
    m: anytype,
    n: *usize,
) Allocator.Error![]const u8 {
    return powMeans(arena, text, m.body, m.args, n);
}

// ---- private ----

/// `applyPowMeans` for the meaning `body` of `params`.
// tidy: allow(recursion) depth is the nesting of parentheses in the expression; nothing
// but the length of its text bounds it
fn powMeans(
    arena: Allocator,
    text: []const u8,
    body: []const u8,
    params: []const []const u8,
    n: *usize,
) Allocator.Error![]const u8 {
    // Inside parentheses first: each operand is then one primary.
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
        if (c == '(') if (matching(text, i)) |close| {
            const inner = try powMeans(arena, text[i + 1 .. close], body, params, n);
            try out.print(arena, "({s})", .{inner});
            i = close + 1;
            continue;
        };
        try out.append(arena, c);
        i += 1;
    }
    var cur = out.items;
    while (topLevelPow(cur)) |at| {
        const lo = powBase(cur, at);
        const hi = powExponent(cur, at + canon_pow.len);
        std.debug.assert(lo <= at);
        if (lo == at or hi == at + canon_pow.len) break;
        var next: std.ArrayList(u8) = .empty;
        try next.appendSlice(arena, cur[0..lo]);
        const operands = [_][]const u8{
            ungroup(cur[lo..at]),
            ungroup(cur[at + canon_pow.len .. hi]),
        };
        try substitute(arena, &next, body, params, &operands);
        try next.appendSlice(arena, cur[hi..]);
        cur = next.items;
        n.* += 1;
    }
    return cur;
}

/// The first `**` outside parentheses and quotes.
fn topLevelPow(text: []const u8) ?usize {
    var from: usize = 0;
    while (topLevel(text, from, '*')) |at| : (from = at + 2) {
        if (at + 1 < text.len and text[at + 1] == '*') return at;
    }
    return null;
}

/// Where the base of the power at `at` starts: a name, a number, a call
/// or a group; a minus before it is not its own.
fn powBase(text: []const u8, at: usize) usize {
    std.debug.assert(at <= text.len);
    var k = at;
    while (k > 0 and text[k - 1] == ' ') k -= 1;
    if (k > 0 and text[k - 1] == ')') {
        var depth: usize = 0;
        while (k > 0) {
            k -= 1;
            if (text[k] == ')') depth += 1;
            if (text[k] == '(') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
    }
    while (k > 0 and (isWordChar(text[k - 1]) or text[k - 1] == param_mark)) {
        k -= 1;
        k = mantissaStart(text, k);
    }
    return k;
}

/// At `k`, the first digit of a number's exponent after its sign (`1e-3`):
/// where the number starts; any other `k` as it is.
fn mantissaStart(text: []const u8, k: usize) usize {
    if (k < 2 or !std.ascii.isDigit(text[k])) return k;
    if (text[k - 1] != '-' and text[k - 1] != '+') return k;
    if (text[k - 2] != 'e' and text[k - 2] != 'E') return k;
    const e = k - 2;
    var d = e;
    while (d > 0 and (std.ascii.isDigit(text[d - 1]) or text[d - 1] == '.')) d -= 1;
    return if (d < e and (d == 0 or !isWordChar(text[d - 1]))) d else k;
}

/// Where the exponent of a power, from `from`, ends: a signed name,
/// number, call or group.
fn powExponent(text: []const u8, from: usize) usize {
    var j = from;
    while (j < text.len and (text[j] == ' ' or text[j] == '-' or text[j] == '+')) j += 1;
    const start = j;
    if (j < text.len and text[j] == param_mark) j += 1;
    const number = j < text.len and (std.ascii.isDigit(text[j]) or text[j] == '.');
    j = if (number) numberEnd(text, j) else wordEnd(text, j);
    if (j < text.len and text[j] == '(') j = (matching(text, j) orelse return from) + 1;
    return if (j == start) from else j;
}

/// An operand without the parentheses around the whole of it.
fn ungroup(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len > 1 and t[0] == '(' and matching(t, 0) == t.len - 1) return t[1 .. t.len - 1];
    return t;
}

/// `body` onto `out`, each of its `params` replaced by that argument of
/// `args`; in parentheses unless it is one call.
fn substitute(
    arena: Allocator,
    out: *std.ArrayList(u8),
    body: []const u8,
    params: []const []const u8,
    args: []const []const u8,
) Allocator.Error!void {
    std.debug.assert(args.len == params.len);
    const wrap = !atomic(body);
    if (wrap) try out.append(arena, '(');
    var k: usize = 0;
    while (k < body.len) {
        const bc = body[k];
        if ((std.ascii.isAlphabetic(bc) or bc == '_') and
            (k == 0 or !isWordChar(body[k - 1])))
        {
            const e = wordEnd(body, k);
            const w = body[k..e];
            const at = for (params, 0..) |p, pi| {
                if (std.mem.eql(u8, p, w)) break pi;
            } else null;
            if (at) |pi| {
                const arg = args[pi];
                if (wholeArgument(body, k, e) or atomic(arg))
                    try out.appendSlice(arena, arg)
                else
                    try out.print(arena, "({s})", .{arg});
            } else try out.appendSlice(arena, w);
            k = e;
            continue;
        }
        try out.append(arena, bc);
        k += 1;
    }
    if (wrap) try out.append(arena, ')');
}

/// The word `body[k..e]` is a whole argument of a call in the body, which
/// needs no parentheses.
fn wholeArgument(body: []const u8, k: usize, e: usize) bool {
    const before = std.mem.trimEnd(u8, body[0..k], " \t");
    const after = std.mem.trimStart(u8, body[e..], " \t");
    const last = if (before.len > 0) before[before.len - 1] else 0;
    const opens = before.len > 0 and (last == '(' or last == ',');
    return opens and after.len > 0 and (after[0] == ')' or after[0] == ',');
}

/// A name, a number or one call: nothing an operator around it could split.
fn atomic(text: []const u8) bool {
    if (text.len == 0) return false;
    if (wordEnd(text, 0) == text.len) return true;
    const j = wordEnd(text, 0);
    if (j == 0 or j >= text.len or text[j] != '(') return false;
    return matching(text, j) == text.len - 1;
}
