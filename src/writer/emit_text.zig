//! Value text: one value of a statement → its text in the target's
//! spelling (numbers, expressions, signals, enumerated words, the
//! defaults a pattern fills in), with what the target cannot say or says
//! differently reported. Each is a method of `Emit` under the same name.
//!
//! Contents:
//! - `pub fn valueText(e: *Emit, v: Value, quoted: bool) Allocator.Error![]const u8`
//! - `pub fn meant(e: *Emit, canon_in: []const u8) Allocator.Error![]const u8`
//! - `pub fn exprText(e: *Emit, canon_in: []const u8) Allocator.Error![]const u8`
//! - `pub fn vectorText(e: *Emit, v: Value) Allocator.Error![]const u8`
//! - `pub fn checkNumber(e: *Emit, p: ir.Param) void`
//! - `pub fn semantics(e: *Emit, canon: []const u8, written: []const u8) void`
//! - `pub fn sourceGrammar(e: *const Emit) ?*const Grammar`
//! - `pub fn signalText(e: *Emit, canon: []const u8) Allocator.Error!?[]const u8`
//! - `pub fn slotText(e: *Emit, idx: u8, quoted: bool) Allocator.Error!?[]const u8`
//! - `pub fn isName(sl: schema.Slot) bool`
//! - `pub fn describe(e: *Emit, v: Value) Allocator.Error![]const u8`
//! - `pub fn expandDefault(e: *Emit, text: []const u8) Allocator.Error![]const u8`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const expr = @import("expr");
const reader = @import("reader");
const tables = @import("tables.zig");
const Emit = @import("emit.zig").Emit;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Value = ir.Value;
const spellingsOf = tables.spellingsOf;

pub fn valueText(e: *Emit, v: Value, quoted: bool) Allocator.Error![]const u8 {
    const cfg = &e.g.lex;
    // The values a device line is made of need no writer: a name is its
    // own text, and a number or an expression is at most one copy.
    switch (v) {
        .none => return "",
        .atom => |s| return if (quoted) std.mem.concat(e.arena, u8, &.{ "\"", s, "\"" }) else s,
        .num => |n| if (n.exp10 == 0) return n.digits(),
        .expr => |canon| {
            const s = try e.exprText(canon);
            // A bracketed vector a SPICE reader kept as text
            // (`hblin=[1, -1]`) is written as it was, not as arithmetic.
            if (s.len >= 2 and s[0] == '[' and s[s.len - 1] == ']') return s;
            if (cfg.bare_expr) {
                const needs_parens = std.mem.indexOfAny(u8, s, " \t") != null;
                return if (needs_parens) std.mem.concat(e.arena, u8, &.{ "(", s, ")" }) else s;
            }
            if (cfg.expr_delims.len == 0) return s;
            return std.mem.concat(
                e.arena,
                u8,
                &.{ cfg.expr_delims[0][0], s, cfg.expr_delims[0][1] },
            );
        },
        .str => |s| return std.mem.concat(e.arena, u8, &.{ "\"", s, "\"" }),
        .list, .params => {},
    }
    // A number gets this far only when it has an exponent to render.
    if (v == .num) assert(v.num.exp10 != 0);
    var aw: std.Io.Writer.Allocating = .init(e.arena);
    const w = &aw.writer;
    switch (v) {
        .none, .atom, .expr, .str => unreachable,
        .num => |n| lexer.renderNumber(w, cfg, n) catch return error.OutOfMemory,
        .list => |items| for (items, 0..) |it, i| {
            if (i > 0) w.writeByte(' ') catch return error.OutOfMemory;
            w.writeAll(try e.valueText(it, false)) catch return error.OutOfMemory;
        },
        .params => |ps| for (ps, 0..) |p, i| {
            if (i > 0) w.writeByte(' ') catch return error.OutOfMemory;
            e.checkNumber(p);
            if (p.val == .none) {
                w.writeAll(p.key) catch return error.OutOfMemory;
            } else w.print("{s}={s}", .{ p.key, try e.valueText(p.val, false) }) catch
                return error.OutOfMemory;
        },
    }
    return aw.written();
}

/// A canonical expression in this dialect's spelling, with what it
/// cannot say (an error) and what it says differently (a caveat) reported.
/// A function the target lacks, said by what the source means by it
/// (`means`), one note a rewrite.
pub fn meant(e: *Emit, canon_in: []const u8) Allocator.Error![]const u8 {
    // `exprText` asks only for a statement another dialect wrote.
    assert(e.foreign);
    const sg = e.sourceGrammar() orelse return canon_in;
    var canon = canon_in;
    for (sg.means) |*m| {
        if (m.kind != null and m.kind.? != e.st.kind) continue;
        // A line for this kind wins over the general one.
        const specific = m.kind != null or for (sg.means) |o| {
            if (o.kind != null and o.kind.? == e.st.kind and std.mem.eql(u8, o.canon, m.canon))
                break false;
        } else true;
        if (!specific) continue;
        if (std.mem.eql(u8, m.canon, expr.canon_pow)) {
            canon = try powMeant(e, sg, m, canon_in, canon);
            continue;
        }
        if (spellingsOf(e.g.functions, m.canon) != null or !expr.uses(canon, m.canon)) continue;
        var n: usize = 0;
        const out = try expr.applyMeans(e.arena, canon, m, &n);
        if (n == 0) continue;
        if (!e.quiet)
            e.report.add(.info, .oneway, e.st.line, "expression '{s}': {s} has no {s}; " ++
                "written as what {s} means by it, {s}; it reads back in that form", .{
                canon_in, e.g.name, m.canon, sg.name, m.body,
            });
        canon = out;
    }
    return canon;
}

pub fn exprText(e: *Emit, canon_in: []const u8) Allocator.Error![]const u8 {
    var problems: std.ArrayList(expr.Problem) = .empty;
    const canon = if (e.foreign) try e.meant(canon_in) else canon_in;
    // A statement in the target's own dialect is written as it was read.
    if (!e.foreign) assert(canon.ptr == canon_in.ptr);
    const s = try expr.write(e.arena, e.g, canon, e.funcs, e.foreign, &problems);
    // What the source's functions mean differently, as it wrote them,
    // but for those written as what they mean (`means`).
    e.semantics(canon_in, canon);
    if (!e.quiet) for (problems.items) |pb| {
        if (pb.kind == .form) {
            e.report.add(.info, .oneway, e.st.line, "expression '{s}': {s} has no {s}, so " ++
                "the choice is written {s}; it reads back in that form", .{
                canon,                                                              e.g.name,
                if (std.mem.eql(u8, pb.text, "if"))
                    "?: operator"
                else
                    "if() function",
                if (std.mem.eql(u8, pb.text, "if")) "if(c, a, b)" else "c ? a : b",
            });
            continue;
        }
        if (pb.kind == .shadowed) {
            e.report.add(
                .@"error",
                .invalid,
                e.st.line,
                "expression '{s}': the parameter '{s}' is a variable of {s} under that " ++
                    "name, which takes the word for the variable; give the parameter " ++
                    "another name",
                .{ canon, pb.text, e.g.name },
            );
            continue;
        }
        const who = if (e.caps) |c| c.word(pb.text) else "";
        e.report.add(.@"error", .unsupported, e.st.line, "expression '{s}': {s} '{s}' has " ++
            "no spelling in {s}{s}{s}", .{
            canon,
            @tagName(pb.kind),
            pb.text,
            e.g.name,
            if (who.len > 0) ". Dialects that have it: " else "",
            who,
        });
    };
    return s;
}

/// The items of a `[...]` vector, with the dialect's separator.
pub fn vectorText(e: *Emit, v: Value) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (v.list, 0..) |it, i| {
        if (i > 0) try out.appendSlice(e.arena, e.g.lex.vector_sep);
        try out.appendSlice(e.arena, try e.valueText(it, false));
    }
    return out.items;
}

/// `version=3.3.0`: one simulator's lenient reading of a malformed
/// number is no other's.
pub fn checkNumber(e: *Emit, p: ir.Param) void {
    const raw: []const u8 = switch (p.val) {
        .atom => |x| x,
        .expr => |x| x,
        .str => |x| x,
        else => "",
    };
    if (e.foreign and !e.quiet and e.g.lex.strict_numbers and malformedNumber(raw)) {
        e.report.add(
            .@"error",
            .invalid,
            e.st.line,
            "{s}={s} is not a number; {s} does not read it",
            .{ p.key, raw, e.g.name },
        );
    }
}

/// A function or operator that one side of a translation evaluates
/// differently (`differs` in either grammar): a caveat, never silence.
/// `written`: `canon` as it is written, functions the target lacks said
/// by what they mean; a function gone from it is not a caveat, and
/// one the meaning brought in is the meaning's, not the source's.
pub fn semantics(e: *Emit, canon: []const u8, written: []const u8) void {
    if (e.quiet or !e.foreign) return;
    for ([_]?*const Grammar{ e.g, e.sourceGrammar() }) |og| {
        const g = og orelse continue;
        for (g.differs) |d| {
            if (expr.uses(canon, d.canon) and said(e, g, d.canon, canon, written)) {
                e.report.add(
                    .warning,
                    .caveat,
                    e.st.line,
                    "expression '{s}': {s} in {s}: {s}",
                    .{ canon, d.canon, g.name, d.text },
                );
            }
        }
    }
}

/// The built-in grammar the statement was read with, if any.
pub fn sourceGrammar(e: *const Emit) ?*const Grammar {
    const c = e.caps orelse return null;
    for (c.grammars) |*g| if (std.mem.eql(u8, g.name, e.source)) return g;
    return null;
}

/// A value as shown in messages: no dialect delimiters around it.
pub fn signalText(e: *Emit, canon: []const u8) Allocator.Error!?[]const u8 {
    var args: [3][]const u8 = undefined;
    const form, const n = reader.signalParts(canon, &args) orelse return null;
    assert(n <= args.len);
    for (e.g.signals) |sf| {
        if (!std.mem.eql(u8, sf.form, form)) continue;
        var out: std.ArrayList(u8) = .empty;
        var k: usize = 0;
        var i: usize = 0;
        while (i < sf.template.len) : (i += 1) {
            const c = sf.template[i];
            if (c != '%') {
                try out.append(e.arena, c);
                continue;
            }
            // `%2`: that name, not the next one.
            var at = k;
            if (i + 1 < sf.template.len and sf.template[i + 1] >= '1' and
                sf.template[i + 1] <= '3')
            {
                at = sf.template[i + 1] - '1';
                i += 1;
            }
            if (at < n) try pathText(e, &out, args[at]);
            k += 1;
        }
        if (k == n) return out.items;
    }
    return null;
}

/// The text of a bound slot, or null (with `why` set) when this dialect
/// has no spelling for the value.
pub fn slotText(e: *Emit, idx: u8, quoted: bool) Allocator.Error!?[]const u8 {
    assert(idx < schema.info(e.st.kind).slots.len);
    const v = e.val(idx);
    const sl = e.slot(idx);
    if (sl.ty == .atom and v == .atom) {
        if (e.g.enumOf(e.st.kind, idx)) |em| return enumText(e, sl, v.atom, em, quoted);
    }
    if (sl.ty == .signal) return signalSlot(e, idx);
    if (e.g.names) |*n| if (isName(sl)) return try e.valueText(try tables.escapedValue(
        e.arena,
        n,
        v,
    ), quoted);
    return try e.valueText(v, quoted);
}

/// Does `sl` hold the name of an instance, a net, a subcircuit or a model,
/// which the grammar's `names` section escapes?
pub fn isName(sl: schema.Slot) bool {
    return switch (sl.ty) {
        .name, .node, .ref => true,
        .ident => std.mem.eql(u8, sl.name, "master"),
        else => false,
    };
}

pub fn describe(e: *Emit, v: Value) Allocator.Error![]const u8 {
    return switch (v) {
        .expr => |s| s,
        .params => |ps| blk: {
            var out: std.ArrayList(u8) = .empty;
            for (ps, 0..) |p, i| {
                if (i > 0) try out.append(e.arena, ' ');
                if (p.val == .none)
                    try out.appendSlice(e.arena, p.key)
                else
                    try out.print(e.arena, "{s}={s}", .{ p.key, try e.describe(p.val) });
            }
            break :blk out.items;
        },
        else => e.valueText(v, false),
    };
}

/// Default text may refer to other slots (`$stop`) and to the ordinal of
/// this statement among its kind (`$#`).
pub fn expandDefault(e: *Emit, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '$') {
            try out.append(e.arena, text[i]);
            i += 1;
            continue;
        }
        if (i + 1 < text.len and text[i + 1] == '#') {
            try out.print(e.arena, "{d}", .{e.ordinal});
            i += 2;
            continue;
        }
        if (i + 1 < text.len and text[i + 1] == '+') {
            // `$+values`: how many items the list slot holds.
            var j = i + 2;
            while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_'))
                j += 1;
            const v = if (schema.slotIndex(e.st.kind, text[i + 2 .. j])) |si|
                e.st.at(si)
            else
                Value.none;
            try out.print(e.arena, "{d}", .{if (v == .list) v.list.len else 0});
            i = j;
            continue;
        }
        var j = i + 1;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) j += 1;
        if (schema.slotIndex(e.st.kind, text[i + 1 .. j])) |si| {
            // Inside a delimited expression the value goes in raw.
            const v = e.st.at(si);
            const raw: []const u8 = switch (v) {
                .none => "0",
                .expr => |s| s,
                .num => |n| if (n.exp10 == 0)
                    n.digits()
                else
                    try e.arena.print("{s}e{d}", .{ n.digits(), n.exp10 }),
                else => try e.valueText(v, false),
            };
            try out.appendSlice(e.arena, raw);
        } else try out.appendSlice(e.arena, text[i..j]);
        i = j;
    }
    // Every step stops at the end of the text, never past it.
    assert(i == text.len);
    return out.toOwnedSlice(e.arena);
}

// ---- private ----

/// A name in a signal, onto `out`: each segment of a path (`B[0].y`)
/// escaped as the grammar's `names` section escapes a name, `.` kept.
fn pathText(e: *Emit, out: *std.ArrayList(u8), path: []const u8) Allocator.Error!void {
    const n = if (e.g.names) |*nm| nm else return out.appendSlice(e.arena, path);
    var it = std.mem.splitScalar(u8, path, '.');
    var first = true;
    while (it.next()) |seg| : (first = false) {
        if (!first) try out.append(e.arena, '.');
        try out.appendSlice(e.arena, try tables.escaped(e.arena, n, seg));
    }
}

/// `canon` with the source's power operator written as what it means
/// (`means x ** y = ...`), unless the target means the same by it.
fn powMeant(
    e: *Emit,
    sg: *const Grammar,
    m: *const grammar.Means,
    canon_in: []const u8,
    canon: []const u8,
) Allocator.Error![]const u8 {
    const same = for (e.g.means) |o| {
        if (std.mem.eql(u8, o.canon, m.canon) and std.mem.eql(u8, o.body, m.body)) break true;
    } else false;
    if (same) return canon;
    var n: usize = 0;
    const out = try expr.applyPowMeans(e.arena, canon, m, &n);
    if (n == 0) return canon;
    if (!e.quiet)
        e.report.add(.info, .oneway, e.st.line, "expression '{s}': {s}'s x ** y is {s}, " ++
            "and {s}'s power is not; written as that; it reads back in that form", .{
            canon_in, sg.name, m.body, e.g.name,
        });
    return out;
}

/// Does `written` still say what `differs <name>` of grammar `g` is about?
fn said(
    e: *const Emit,
    g: *const Grammar,
    name: []const u8,
    canon: []const u8,
    written: []const u8,
) bool {
    if (g != e.g and std.mem.eql(u8, name, "pow")) {
        // The operator and the function apart: either may be written as what it means.
        const op = std.mem.indexOf(u8, canon, expr.canon_pow) != null and
            std.mem.indexOf(u8, written, expr.canon_pow) != null;
        return op or (expr.calls(canon, "pow") and expr.calls(written, "pow"));
    }
    // How the source reads its text: no meaning written changes that.
    if (g != e.g and std.mem.eql(u8, name, "negpow")) return true;
    return expr.uses(written, name);
}

/// A word of an enumerated slot in this dialect's spelling, or null (with
/// `why` set) for a foreign word it has none for.
fn enumText(
    e: *Emit,
    sl: schema.Slot,
    atom: []const u8,
    em: *const grammar.EnumMap,
    quoted: bool,
) Allocator.Error!?[]const u8 {
    assert(sl.ty == .atom);
    const sp = for (em.pairs) |pr| {
        if (std.mem.eql(u8, pr.canon, atom)) break pr.spelling;
    } else blk: {
        // A value this dialect's own reader let through goes
        // back out as it came in.
        if (!e.foreign) break :blk atom;
        e.why = try e.arena.print("{s} = {s}", .{ sl.name, atom });
        return null;
    };
    // `bdf=gear`: a spelling that reads back as another value.
    for (em.pairs) |pr| if (std.mem.eql(u8, pr.spelling, sp)) {
        if (!std.mem.eql(u8, pr.canon, atom) and !e.quiet)
            e.report.add(
                .info,
                .oneway,
                e.st.line,
                "{s}.{s} = {s} is written as {s}, which reads back as {s}",
                .{ @tagName(e.st.kind), sl.name, atom, sp, pr.canon },
            );
        break;
    };
    return if (quoted) try e.arena.print("\"{s}\"", .{sp}) else sp;
}

/// The signals of a signal slot, blank-separated, or null (with `why`
/// set) for one this dialect cannot name.
fn signalSlot(e: *Emit, idx: u8) Allocator.Error!?[]const u8 {
    assert(e.slot(idx).ty == .signal);
    const v = e.val(idx);
    const items: []const Value = if (v == .list) v.list else &.{v};
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |it, i| {
        if (i > 0) try out.append(e.arena, ' ');
        if (it == .atom) {
            const t = (try e.signalText(it.atom)) orelse {
                e.why = try e.arena.print("the signal {s}", .{it.atom});
                return null;
            };
            try out.appendSlice(e.arena, t);
        } else if (it == .expr) {
            if (!try signalExpr(e, &out, it)) return null;
        } else try out.appendSlice(e.arena, try e.valueText(it, false));
    }
    return out.items;
}

/// A signal given as an expression, onto `out`; false (with `why` set)
/// where this dialect has no way to say it.
fn signalExpr(e: *Emit, out: *std.ArrayList(u8), it: Value) Allocator.Error!bool {
    assert(it == .expr);
    // `expr = "par('%')"` says how; where expressions have no
    // delimiters nothing tells one from a node name.
    const tmpl = for (e.g.signals) |sf| {
        if (std.mem.eql(u8, sf.form, "expr")) break sf.template;
    } else "";
    if (tmpl.len == 0 and e.g.lex.bare_expr) {
        e.why = try e.arena.print("the signal expression {s}", .{it.expr});
        return false;
    }
    if (tmpl.len == 0) {
        try out.appendSlice(e.arena, try e.valueText(it, false));
        return true;
    }
    var problems: std.ArrayList(expr.Problem) = .empty;
    const body = try expr.write(e.arena, e.g, it.expr, e.funcs, e.foreign, &problems);
    if (problems.items.len > 0) {
        e.why = try e.arena.print("the signal expression {s}", .{it.expr});
        return false;
    }
    const pct = std.mem.indexOfScalar(u8, tmpl, '%').?;
    try out.print(e.arena, "{s}{s}{s}", .{ tmpl[0..pct], body, tmpl[pct + 1 ..] });
    return true;
}

/// `3.3.0`: digits with more than one point.
fn malformedNumber(t: []const u8) bool {
    if (t.len == 0 or !std.ascii.isDigit(t[0])) return false;
    var dots: usize = 0;
    for (t) |c| {
        if (c == '.') dots += 1 else if (!std.ascii.isDigit(c)) return false;
    }
    return dots > 1;
}
