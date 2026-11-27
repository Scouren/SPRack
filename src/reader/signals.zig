//! Signals: a dialect's spelling of `v(a,b)` or `i(vdd)` matched against
//! the templates of its `signals` section, to and from the canonical form.
//!
//! Contents:
//! - `pub fn signalCanon(arena: Allocator, g: *const Grammar,
//!   text: []const u8) Allocator.Error!?[]const u8`
//! - `pub fn signalParts(text: []const u8, args: *[3][]const u8) ?struct`
//! - `pub fn signalSpace(form: []const u8, k: usize) ?Space`
//! - `pub fn isVersion(s: []const u8) bool`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const expr = @import("expr");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Space = schema.Space;

/// The canonical spelling of a signal written in this dialect, or null if
/// the dialect's `signals` section has no form for it.
pub fn signalCanon(
    arena: Allocator,
    g: *const Grammar,
    text: []const u8,
) Allocator.Error!?[]const u8 {
    const folded = if (g.lex.case_sensitive) text else try std.ascii.allocLowerString(arena, text);
    var args: [3][]const u8 = undefined;
    for (g.signals) |sf| {
        // An expression is told by its syntax, not by a template.
        if (std.mem.eql(u8, sf.form, "expr")) continue;
        const n = matchTemplate(sf.template, folded, text, &args) orelse continue;
        assert(n <= args.len);
        if (std.mem.eql(u8, sf.form, "all")) return "all";
        // A terminal (`ID(M1)`'s D) is no name: one spelling, the folded one.
        if (!g.lex.case_sensitive) for (args[0..n], 0..) |*a, k| {
            if (signalSpace(sf.form, k) == null) a.* = try std.ascii.allocLowerString(arena, a.*);
        };
        const name = if (std.mem.eql(u8, sf.form, "vdiff")) "v" else sf.form;
        var out: std.ArrayList(u8) = .empty;
        try out.print(arena, "{s}(", .{name});
        for (args[0..n], 0..) |a, i| {
            if (i > 0) try out.append(arena, ',');
            try out.appendSlice(arena, a);
        }
        try out.append(arena, ')');
        return out.items;
    }
    return null;
}

/// Split canonical `name(a,b)` into its form and arguments.
pub fn signalParts(text: []const u8, args: *[3][]const u8) ?struct { []const u8, usize } {
    if (std.mem.eql(u8, text, "all")) return .{ "all", 0 };
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    if (text[text.len - 1] != ')') return null;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text[open + 1 .. text.len - 1], ',');
    while (it.next()) |a| {
        if (n == args.len) return null;
        args[n] = a;
        n += 1;
    }
    const name = text[0..open];
    return .{ if (std.mem.eql(u8, name, "v") and n == 2) "vdiff" else name, n };
}

/// The space of the `k`th name of a signal of this form: the nodes of a
/// voltage, the device of a current or of a parameter (`p`). The terminal
/// of `ix` and the parameter of `p` are no names.
pub fn signalSpace(form: []const u8, k: usize) ?Space {
    if (form.len == 0) return null;
    if (form[0] == 'v') return .node;
    const device = form[0] == 'i' or std.mem.eql(u8, form, "p");
    return if (device and k == 0) .instance else null;
}

/// A dotted version number, `3.3.0`: digits with two or more dots.
pub fn isVersion(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isDigit(s[0])) return false;
    var dots: usize = 0;
    for (s) |c| {
        if (c == '.') dots += 1 else if (!std.ascii.isDigit(c)) return false;
    }
    return dots >= 2;
}

// ---- private ----

/// Match `text` against a template such as `v(%,%)`; `%` stands for a name.
fn matchTemplate(
    tmpl: []const u8,
    folded: []const u8,
    raw: []const u8,
    args: *[3][]const u8,
) ?usize {
    var it = std.mem.splitScalar(u8, tmpl, '%');
    const head = it.first();
    if (!std.mem.startsWith(u8, folded, head)) return null;
    var pos = head.len;
    var n: usize = 0;
    var seen: usize = 0;
    while (it.next()) |whole| {
        // `%2`: the second name, where this dialect gives them in another order.
        var lit = whole;
        var at = n;
        if (lit.len > 0 and lit[0] >= '1' and lit[0] <= '3') {
            at = lit[0] - '1';
            lit = lit[1..];
        }
        const last = it.peek() == null;
        const end = if (last) blk: {
            if (folded.len < pos + lit.len or !std.mem.endsWith(u8, folded[pos..], lit))
                return null;
            break :blk folded.len - lit.len;
        } else std.mem.indexOfPos(u8, folded, pos, lit) orelse return null;
        if (end <= pos or n == args.len) return null;
        if (std.mem.indexOfAny(u8, raw[pos..end], "(), \t") != null) return null;
        args[at] = raw[pos..end];
        seen = @max(seen, at + 1);
        n += 1;
        pos = end + lit.len;
    }
    assert(n <= args.len);
    return if (pos == folded.len and seen == n) n else null;
}
