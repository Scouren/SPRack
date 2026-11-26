//! Rewriting the names of an expression: parameters renamed (`rename`) and
//! calls of a function replaced by its body (`applyMeans`).
//!
//! Contents:
//! - `pub fn rename(arena: Allocator, text: []const u8, renames: anytype,
//!   hit: *std.ArrayList([]const u8)) Allocator.Error![]const u8`
//! - `pub fn applyMeans(arena: Allocator, text: []const u8, m: anytype,
//!   n: *usize) Allocator.Error![]const u8`

const std = @import("std");
const schema = @import("schema");
const expr = @import("expr.zig");
const expr_scan = @import("expr_scan.zig");
const Allocator = std.mem.Allocator;
const argSpace = expr.argSpace;
const param_mark = expr.param_mark;
const isWordChar = expr_scan.isWordChar;
const matching = expr_scan.matching;
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

// ---- private ----

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
