//! A model card's parameters crossing dialects: the parameters of a card
//! read in one dialect → the target's names and numbers for the family
//! (the `modelparams` tables of the two dialects), with a parameter the
//! target's card does not take, or takes one of where the source has two
//! that differ, said and not written.
//!
//! Contents:
//! - `pub fn cardParams(w: *Writer, a: Allocator, st: *const ir.Stmt, family: []const u8,
//!   ps: *std.ArrayList(ir.Param), own: usize) Allocator.Error!void`

const std = @import("std");
const grammar = @import("grammar");
const ir = @import("ir");
const expr = @import("expr");
const tables = @import("tables.zig");
const statement = @import("statement.zig");
const Emit = @import("emit.zig").Emit;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Spellings = grammar.Spellings;
const Value = ir.Value;
const spellingsOf = tables.spellingsOf;
const spellingCanon = tables.spellingCanon;
const Writer = statement.Writer;

/// One card's parameters on their way: the card, its family, the
/// source's grammar and the target's table for the family.
const Card = struct {
    w: *Writer,
    a: Allocator,
    st: *const ir.Stmt,
    family: []const u8,
    sg: *const Grammar,
    to: []const Spellings,
    name: []const u8,
    em: *Emit,
};

/// A parameter under its canonical name and value; `wrote` is the key it
/// was written by. `as_is`: the source's table does not list it, so it is
/// copied.
const Canon = struct { p: ir.Param, wrote: []const u8, as_is: bool = false, done: bool = false };

/// The parameters of a model card, `ps` from `own` on, against the
/// `modelparams` tables of the two dialects for the family, when both
/// have one: each gets the target's spelling and number. One the
/// source's model does not take by the name written is not written, and
/// neither are those the target has one parameter for when they differ.
pub fn cardParams(
    w: *Writer,
    a: Allocator,
    st: *const ir.Stmt,
    family: []const u8,
    ps: *std.ArrayList(ir.Param),
    own: usize,
) Allocator.Error!void {
    assert(own <= ps.items.len);
    const to = w.g.modelParamsOf(family) orelse return;
    const only = w.g.modelParamsOnly(family);
    const sg = w.sourceGrammar(st) orelse return;
    // A card the target refuses by one value (a diode's level=3) is
    // another model there: its other names are not checked against
    // this one's.
    if (refusedByValue(w.g, family, ps.items[own..])) return;
    // A source with no table: every name as it is written, against a
    // table that lists all the target's card takes.
    const from = sg.modelParamsOf(family) orelse if (only) &.{} else return;
    var em = w.emitter(a, st);
    const cd: Card = .{
        .w = w,
        .a = a,
        .st = st,
        .family = family,
        .sg = sg,
        .to = to,
        .name = st.get("name").atom,
        .em = &em,
    };
    const cs = try canonical(cd, from, ps.items[own..]);
    ps.shrinkRetainingCapacity(own);
    // A corner where one of the two computes something else, once a card.
    if (sg != w.g) sayEdge(cd, cs);
    for (cs, 0..) |*c, i| {
        if (c.done) continue;
        const e = (if (c.as_is) null else spellingsOf(to, c.p.key)) orelse {
            try unlisted(cd, only, c.*, ps);
            continue;
        };
        if (!e.halved) {
            try renamed(cd, e, c.*, ps);
            continue;
        }
        try merged(cd, e, cs[i..], ps);
    }
}

// ---- private ----

/// Whether one of `ps` has the value a `noparam ... error` line of the
/// target refuses the family's card by.
fn refusedByValue(g: *const Grammar, family: []const u8, ps: []const ir.Param) bool {
    for (g.noparams) |np| {
        if (!np.err or np.value.len == 0 or !std.mem.eql(u8, np.family, family)) continue;
        const want = std.fmt.parseFloat(f64, np.value) catch continue;
        for (ps) |p| {
            if (std.ascii.eqlIgnoreCase(p.key, np.key) and p.val == .num and
                p.val.num.toFloat() == want) return true;
        }
    }
    return false;
}

/// Canonical names and values of `ps` by the source's table `from`: a
/// parameter the target halves is said, and one the source's model does
/// not take by the name written is said and dropped.
fn canonical(cd: Card, from: []const Spellings, ps: []const ir.Param) Allocator.Error![]Canon {
    var cs: std.ArrayList(Canon) = .empty;
    for (ps) |p| {
        var halves: std.ArrayList(ir.Param) = .empty;
        var taken = false;
        const before = cs.items.len;
        for (from) |*e| {
            for (e.spellings) |sp| {
                if (std.ascii.eqlIgnoreCase(sp, p.key)) break;
            } else continue;
            taken = true;
            // A number at an exponent a scale suffix can spell (500n).
            const half: Value = if (!e.halved)
                p.val
            else if (p.val == .num)
                try expr.arith(cd.a, .mul, p.val, .{ .num = .init("5", -1) })
            else
                try expr.halve(cd.a, p.val);
            const c: ir.Param = .{ .key = e.canon, .val = half };
            try cs.append(cd.a, .{ .p = c, .wrote = if (e.halved) e.canon else p.key });
            if (e.halved) try halves.append(cd.a, c);
        }
        assert(taken == (cs.items.len > before));
        if (halves.items.len > 0) {
            const was = try cd.em.describe(.{ .params = &.{p} });
            const now = try cd.em.describe(.{ .params = halves.items });
            cd.w.report.add(.info, .rename, cd.st.line, "model '{s}': {s} of {s} is {s}, " ++
                "each half its value", .{ cd.name, was, cd.sg.name, now });
        }
        if (taken) continue;
        if (spellingsOf(from, p.key)) |e| {
            cd.w.report.add(
                .warning,
                .loss,
                cd.st.line,
                "model '{s}': {s} not written: the {s} model of {s} does not take it; " ++
                    "that parameter is '{s}' there",
                .{ cd.name, p.key, cd.family, cd.sg.name, e.spellings[0] },
            );
            continue;
        }
        try cs.append(cd.a, .{ .p = p, .wrote = p.key, .as_is = true });
    }
    return cs.items;
}

/// The first of `cs` whose value one of the two dialects computes
/// otherwise at a corner (an `edge` line), said.
fn sayEdge(cd: Card, cs: []const Canon) void {
    for (cs) |c| {
        if (c.as_is) continue;
        const text = cd.w.g.edgeText(cd.family, c.p.key) orelse
            cd.sg.edgeText(cd.family, c.p.key) orelse continue;
        cd.w.report.add(
            .warning,
            .caveat,
            cd.st.line,
            "model '{s}': {s}: {s}",
            .{ cd.name, c.p.key, text },
        );
        return;
    }
}

/// A name the target's card does not take: not written where the
/// target's table lists all its card takes. One a `noparam` line names is
/// left to that line.
fn unlisted(cd: Card, only: bool, c: Canon, ps: *std.ArrayList(ir.Param)) Allocator.Error!void {
    assert(c.as_is or spellingsOf(cd.to, c.p.key) == null);
    const g = cd.w.g;
    const named = for (g.noparams) |np| {
        if (std.mem.eql(u8, np.family, cd.family) and (std.ascii.eqlIgnoreCase(np.key, c.p.key) or
            std.ascii.eqlIgnoreCase(np.key, c.wrote))) break true;
    } else false;
    // A card's level picks the simulator's model, in every dialect.
    const level = std.ascii.eqlIgnoreCase(c.p.key, "level");
    const listed = c.as_is and spellingCanon(cd.to, c.p.key) != null;
    if (only and !named and !level and !listed) {
        const takes_list = try takesList(cd.a, cd.to);
        const given = try cd.em.describe(
            .{ .params = &.{.{ .key = c.wrote, .val = c.p.val }} },
        );
        cd.w.report.add(.@"error", .loss, cd.st.line, "model '{s}': {s} not written: " ++
            "the {s} card of {s} takes no such parameter; it takes {s}", .{
            cd.name, given, cd.family, g.name, takes_list,
        });
        return;
    }
    // Under the name it was written by: the canonical one may
    // mean something else to a target that does not list it,
    // unless a `noparam` line of the target names it.
    const refused = for (g.noparams) |np| {
        if (std.mem.eql(u8, np.family, cd.family) and
            std.ascii.eqlIgnoreCase(np.key, c.p.key)) break true;
    } else false;
    try ps.append(cd.a, .{ .key = if (refused) c.p.key else c.wrote, .val = c.p.val });
}

/// The first spelling of every name of the target's table, once each.
fn takesList(a: Allocator, to: []const Spellings) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (to, 0..) |t, k| {
        const dup = for (to[0..k]) |u| {
            if (std.ascii.eqlIgnoreCase(u.spellings[0], t.spellings[0])) break true;
        } else false;
        if (dup) continue;
        if (out.items.len > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, t.spellings[0]);
    }
    return out.items;
}

/// A name the target spells one way: written so, and said when that is
/// not the spelling it was written by.
fn renamed(
    cd: Card,
    e: *const Spellings,
    c: Canon,
    ps: *std.ArrayList(ir.Param),
) Allocator.Error!void {
    const spelled = e.spellings[0];
    const same = std.ascii.eqlIgnoreCase(spelled, c.wrote);
    if (!same) cd.w.report.add(
        .info,
        .rename,
        cd.st.line,
        "model '{s}': the parameter '{s}' is spelled '{s}' in {s}",
        .{ cd.name, c.wrote, spelled, cd.w.g.name },
    );
    try ps.append(cd.a, .{ .key = if (same) c.wrote else spelled, .val = c.p.val });
}

/// One parameter here for every canonical name of `e`'s spelling: they
/// must agree, one left out being 0, and are written as twice the one
/// value. `rest` is the card's parameters from the first of them on.
fn merged(
    cd: Card,
    e: *const Spellings,
    rest: []Canon,
    ps: *std.ArrayList(ir.Param),
) Allocator.Error!void {
    assert(e.halved);
    const a = cd.a;
    var value: ?Value = null;
    var same = true;
    var names: std.ArrayList(u8) = .empty;
    var shown: std.ArrayList(ir.Param) = .empty;
    for (cd.to) |*t| {
        if (!t.halved or !std.mem.eql(u8, t.spellings[0], e.spellings[0])) continue;
        if (names.items.len > 0) try names.appendSlice(a, " and ");
        try names.appendSlice(a, t.canon);
        var v: Value = .{ .num = .init("0", 0) };
        // The last of a name, as the simulators take a card.
        for (rest) |*o|
            if (!o.as_is and std.ascii.eqlIgnoreCase(o.p.key, t.canon)) {
                v = o.p.val;
                o.done = true;
                try shown.append(a, .{ .key = o.wrote, .val = v });
            };
        if (value) |first| same = same and v.eql(first) else value = v;
    }
    const was = try cd.em.describe(.{ .params = shown.items });
    if (!same) return sayUnequal(cd, e, was, names.items);
    const twice: ir.Param = .{
        .key = e.spellings[0],
        .val = try expr.arith(a, .mul, value.?, .{ .num = .init("2", 0) }),
    };
    const now = try cd.em.describe(.{ .params = &.{twice} });
    if (!std.mem.eql(u8, was, now))
        cd.w.report.add(
            .info,
            .rename,
            cd.st.line,
            "model '{s}': {s} is written {s}, twice the value: {s} has the one " ++
                "parameter for {s}",
            .{ cd.name, was, now, cd.w.g.name, names.items },
        );
    try ps.append(a, twice);
}

/// The parameters `was` the target has the one parameter of `e` for, not
/// equal: not written, with what each dialect computes for it.
fn sayUnequal(
    cd: Card,
    e: *const Spellings,
    was: []const u8,
    names: []const u8,
) Allocator.Error!void {
    const g = cd.w.g;
    var why: std.ArrayList(u8) = .empty;
    if (g.computesText(cd.family, e.canon)) |t|
        try why.print(cd.a, ": {s} computes {s}", .{ g.name, t });
    if (cd.sg.computesText(cd.family, e.canon)) |t|
        try why.print(cd.a, "; {s} computes {s}", .{ cd.sg.name, t });
    cd.w.report.add(.@"error", .loss, cd.st.line, "model '{s}': {s} not written: {s} has " ++
        "the one parameter '{s}' for {s}, and they are not equal here (one left out " ++
        "is 0){s}", .{
        cd.name, was, g.name, e.spellings[0], names, why.items,
    });
}
