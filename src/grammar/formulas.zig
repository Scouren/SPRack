//! Directives that hold a formula over slots: `convert` (what a slot of
//! this dialect is, as a function of canonical ones) and `omitted` (what
//! the dialect means by a slot left out).
//!
//! Contents:
//! - `pub fn convert(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn omitted(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`

const std = @import("std");
const schema = @import("schema");
const Kind = schema.Kind;
const context = @import("context.zig");
const tables = @import("tables.zig");
const types = @import("types.zig");
const C = context.C;
const Error = context.Error;
const args = context.args;
const condition = context.condition;
const dotted = context.dotted;
const kindOf = context.kindOf;
const parseDecimal = context.parseDecimal;
const slotNamed = context.slotNamed;
const Grammar = tables.Grammar;
const Convert = types.Convert;
const Omitted = types.Omitted;

/// `convert kind [slot=atom | a==b] : a = b [op c]`.
pub fn convert(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "convert is `convert kind [slot=atom] : a = b [op c]`",
        .{},
    );
    const ks = try args(c, no, rest[0..colon]);
    if (ks.len < 1 or ks.len > 2)
        return c.fail(no, "convert needs a kind and at most one condition", .{});
    const kind = try kindOf(c, no, ks[0]);
    var cv: Convert = .{ .kind = kind, .dst = 0, .src = 0 };
    var eq: ?[2]u8 = null;
    if (ks.len == 2) {
        if (std.mem.indexOf(u8, ks[1], "==")) |at| {
            eq = .{
                try slotNamed(c, no, kind, ks[1][0..at]),
                try slotNamed(c, no, kind, ks[1][at + 2 ..]),
            };
        } else cv.when_slot, cv.when_atom = try condition(c, no, kind, ks[1]);
    }
    const e = try args(c, no, rest[colon + 3 ..]);
    if (e.len < 3 or !std.mem.eql(u8, e[1], "="))
        return c.fail(no, "expected `a = b [op c]` after ':'", .{});
    cv.dst = try slotNamed(c, no, kind, e[0]);
    // `slotNamed` gives a slot of the kind.
    std.debug.assert(cv.dst < schema.info(kind).slots.len);
    if (eq) |pair| {
        try convertWrap(c, no, &cv, e, ks[1], pair);
    } else try convertOp(c, no, &cv, e);
    g.converts = try c.add(Convert, g.converts, cv);
}

/// `omitted kind slot[=0] [slot=atom] : formula [given slot] [zero value]`.
pub fn omitted(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "omitted is `omitted kind slot[=0] [slot=atom] : formula [given slot] [zero " ++
            "value]`",
        .{},
    );
    const ks = try args(c, no, rest[0..colon]);
    if (ks.len < 2 or ks.len > 3)
        return c.fail(no, "omitted needs a kind, a slot and at most one condition", .{});
    const kind = try kindOf(c, no, ks[0]);
    const zero = std.mem.endsWith(u8, ks[1], "=0");
    var text = std.mem.trim(u8, rest[colon + 3 ..], " \t");
    var o: Omitted = .{ .kind = kind, .slot = try slotNamed(c, no, kind, if (zero)
        ks[1][0 .. ks[1].len - 2]
    else
        ks[1]), .zero = zero, .text = "", .terms = &.{} };
    if (ks.len == 3) o.when_slot, o.when_atom = try condition(c, no, kind, ks[2]);
    if (std.mem.lastIndexOf(u8, text, " zero ")) |at| {
        if (!zero) return c.fail(no, "`zero value` needs the slot written `slot=0`", .{});
        o.zero_as = std.mem.trim(u8, text[at + 6 ..], " \t");
        text = std.mem.trim(u8, text[0..at], " \t");
    }
    if (std.mem.lastIndexOf(u8, text, " given ")) |at| {
        o.given = try slotNamed(c, no, kind, std.mem.trim(u8, text[at + 7 ..], " \t"));
        text = std.mem.trim(u8, text[0..at], " \t");
    }
    o.text = text;
    const f = try args(c, no, text);
    // Read left to right, so two operators need the first in
    // parentheses: `a`, `a + b`, `(a - b) / c`.
    if (f.len != 1 and f.len != 3 and f.len != 5)
        return c.fail(no, "an omitted formula is `a`, `a + b` or `(a - b) / c`", .{});
    o.terms = try omittedTerms(c, no, kind, f);
    // Each word of the formula is one term.
    std.debug.assert(o.terms.len == f.len);
    g.omitted = try c.add(Omitted, g.omitted, o);
}

// ---- private ----

/// `l = [a]` under the condition `a==b`: `a` written as the one item of `l`.
fn convertWrap(
    c: *C,
    no: u32,
    cv: *Convert,
    e: []const []const u8,
    cond: []const u8,
    pair: [2]u8,
) Error!void {
    // `pair` was read from a condition with "==" in it.
    std.debug.assert(std.mem.indexOf(u8, cond, "==") != null);
    const inner = if (e.len == 3 and e[2].len > 2 and e[2][0] == '[' and
        e[2][e[2].len - 1] == ']')
        e[2][1 .. e[2].len - 1]
    else
        "";
    if (inner.len == 0 or !std.mem.eql(
        u8,
        inner,
        cond[0..std.mem.indexOf(u8, cond, "==").?],
    ))
        return c.fail(no, "with `a==b` the conversion is `l = [a]`", .{});
    if (!schema.info(cv.kind).slots[cv.dst].list)
        return c.fail(no, "`l = [a]` needs a list slot", .{});
    cv.op = .wrap;
    cv.src = pair[0];
    cv.when_eq = pair[1];
}

/// `a = b`, `a = a - c` (or `+`, `*`, `/`) or `a = 1 / a`.
fn convertOp(c: *C, no: u32, cv: *Convert, e: []const []const u8) Error!void {
    // `convert` takes `a = ...` and at least one word after it.
    std.debug.assert(e.len >= 3);
    const kind = cv.kind;
    if (e.len == 3) {
        cv.src = try slotNamed(c, no, kind, e[2]);
    } else if (e.len == 5 and std.mem.eql(u8, e[2], "1") and std.mem.eql(u8, e[3], "/")) {
        cv.op = .recip;
        cv.src = try slotNamed(c, no, kind, e[4]);
        if (cv.src != cv.dst)
            return c.fail(no, "`a = 1 / b` needs a and b to be the same slot", .{});
    } else if (e.len == 5 and e[3].len == 1 and
        std.mem.indexOfScalar(u8, "-+*/", e[3][0]) != null)
    {
        cv.op = switch (e[3][0]) {
            '-' => .sub,
            '+' => .add,
            '*' => .mul,
            else => .div,
        };
        cv.src = try slotNamed(c, no, kind, e[2]);
        if (cv.src != cv.dst)
            return c.fail(no, "`a = b - c` needs a and b to be the same slot", .{});
        if (schema.slotIndex(kind, e[4])) |si| {
            cv.arg_slot = si;
        } else {
            _ = try parseDecimal(c, no, e[4]);
            cv.arg_num = e[4];
        }
    } else return c.fail(no, "expected `a = b`, `a = a - c`, `a = a + c`, `a = a * " ++
        "c`, `a = a / c` or `a = 1 / a`", .{});
}

/// The words of an omitted formula as terms, operands first: each
/// operator goes after its second operand.
fn omittedTerms(c: *C, no: u32, kind: Kind, f: []const []const u8) Error![]const Omitted.Term {
    var terms: []const Omitted.Term = &.{};
    for (f, 0..) |tok, i| {
        const term = try omittedTerm(c, no, kind, f.len, i, tok);
        if (i % 2 == 0 and i > 0) {
            const op = terms[terms.len - 1];
            terms = try c.add(Omitted.Term, terms[0 .. terms.len - 1], term);
            terms = try c.add(Omitted.Term, terms, op);
        } else terms = try c.add(Omitted.Term, terms, term);
    }
    return terms;
}

/// Word `i` of an omitted formula of `len` words: an operator at an odd
/// place, else a whole number, a `kind.slot` or a slot of the statement.
fn omittedTerm(
    c: *C,
    no: u32,
    kind: Kind,
    len: usize,
    i: usize,
    tok: []const u8,
) Error!Omitted.Term {
    // `args` gives no empty word.
    std.debug.assert(tok.len > 0);
    var t = tok;
    if (len == 5 and i == 0 and t[0] == '(') t = t[1..];
    if (len == 5 and i == 2 and t[t.len - 1] == ')') t = t[0 .. t.len - 1];
    if (len == 5 and (i == 0 or i == 2) and t.len == tok.len)
        return c.fail(
            no,
            "an omitted formula with two operators is `(a - b) / c`",
            .{},
        );
    return if (i % 2 == 1)
        .{ .op = if (t.len != 1)
            return c.fail(no, "expected + - * or /, found '{s}'", .{t})
        else switch (t[0]) {
            '+' => .add,
            '-' => .sub,
            '*' => .mul,
            '/' => .div,
            else => return c.fail(no, "expected + - * or /, found '{s}'", .{t}),
        } }
    else if (t.len > 0 and std.ascii.isDigit(t[0]))
        .{ .num = if (std.mem.indexOfNone(u8, t, "0123456789") == null)
            t
        else
            return c.fail(no, "a number in an omitted formula is a whole one, " ++
                "found '{s}'", .{t}) }
    else if (std.mem.indexOfScalar(u8, t, '.') != null) first: {
        const fk, const fs = try dotted(c, no, t);
        break :first .{ .first = .{ .kind = fk, .slot = fs } };
    } else .{ .slot = try slotNamed(c, no, kind, t) };
}
