//! Random parameters between the two ways dialects say them.
//!
//! SPICE dialects vary a parameter by calling `agauss`, `gauss`, `aunif`
//! or `unif` in its expression. Spectre has no such functions: a parameter
//! is given its nominal value and varied in a `statistics` block, once per
//! run (`process`) or once per instance (`mismatch`). Before a netlist is
//! written, `prepare` turns one form into the other when the target only
//! has one of them:
//!
//! * into Spectre, `.param p = agauss(nom, a, n)` becomes `p = nom` and
//!   `vary p dist=gauss std=a/n`; any other call becomes a new parameter
//!   with a nominal value of 0 and a standard deviation of 1, varied per
//!   run at the top level and per instance inside a subcircuit, and the
//!   call is replaced by `nom + a/n * that parameter` (`variations.zig`);
//! * into SPICE, a process `vary p` on a parameter defined in the same list
//!   becomes `p = agauss(nom, std, 1)` (or `aunif`).
//!
//! What cannot be turned (a mismatch variation of a global parameter, a
//! correlation, a model parameter's variation) is left for the writer to
//! report.
//!
//! Contents:
//! - `pub const Stream`
//! - `pub fn prepare(arena: Allocator, g: *const Grammar, source: []const u8,
//!   stmts_in: []const Stmt, report: *ir.Report) Allocator.Error![]const Stmt`
//! - `pub fn asFunctions(g: *const Grammar, n: usize, report: *ir.Report) void`
//! - `pub fn changes(g: *const Grammar, stmts: []const Stmt) bool`
//! - `pub fn devLots(g: *const Grammar, source: []const u8) bool`
//! - `pub fn devLotKey(key: []const u8) ?enum`
//! - `pub fn usesDevLot(stmts: []const Stmt) bool`
//! - `pub fn devLot(arena: Allocator, stmts: []const Stmt, report: *ir.Report,
//!   n: *usize) Allocator.Error![]const Stmt`
//! - `pub fn checkReserved(g: *const Grammar, stmts: []const Stmt, report: *ir.Report) void`

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir");
const grammar = @import("grammar");
const variations = @import("variations.zig");
const Allocator = std.mem.Allocator;
const hasFunction = variations.hasFunction;
const Grammar = grammar.Grammar;
const Stmt = ir.Stmt;
const Value = ir.Value;

pub const Stream = variations.Stream;

pub fn prepare(
    arena: Allocator,
    g: *const Grammar,
    source: []const u8,
    stmts_in: []const Stmt,
    report: *ir.Report,
) Allocator.Error![]const Stmt {
    var stmts = stmts_in;
    var functions: usize = 0;
    if (devLots(g, source) and usesDevLot(stmts))
        stmts = try devLot(arena, stmts, report, &functions);
    checkReserved(g, stmts, report);
    if (!hasFunction(g, "agauss") and g.canWrite(.statistics) and g.canWrite(.vary))
        return variations.lower(arena, g, stmts, report);
    if (hasFunction(g, "agauss") and usesKind(stmts, .statistics))
        stmts = try fold(arena, g, stmts, report, &functions);
    asFunctions(g, functions, report);
    return stmts;
}

/// One note for the file, where a PDK has thousands: `n` parameters whose
/// variation (`dev/gauss=`, a `vary`) is now a random function in the
/// definition, which is what `g` reads back.
pub fn asFunctions(g: *const Grammar, n: usize, report: *ir.Report) void {
    if (n == 0 or !hasFunction(g, "agauss")) return;
    report.add(
        .info,
        .oneway,
        0,
        "{d} parameter{s} varied by a random function in the definition, in place of a " ++
            "variation given separately; {s} reads back the function, not the variation",
        .{ n, if (n == 1) "" else "s", g.name },
    );
}

/// Does `prepare` need every statement of the netlist at once for
/// `stmts`? Only to fold statistics blocks into random functions: `devLot`
/// changes a statement by itself, and `Stream` lowers them as they come.
pub fn changes(g: *const Grammar, stmts: []const Stmt) bool {
    return hasFunction(g, "agauss") and usesKind(stmts, .statistics);
}

/// Is `dev/gauss=` rewritten (`devLot`) on the way from `source` to `g`?
/// Not where `g` says a variation that way itself (`variation inline`).
pub fn devLots(g: *const Grammar, source: []const u8) bool {
    return !std.mem.eql(u8, g.name, source) and !g.variation_inline;
}

/// `p=nom dev/gauss=s` (per device) and `lot/gauss=s` (per run), or
/// `/unif`: an entry of its own after the parameter it varies.
pub fn devLotKey(key: []const u8) ?enum { gauss, unif } {
    const slash = std.mem.indexOfScalar(u8, key, '/') orelse return null;
    const who = key[0..slash];
    if (!std.ascii.eqlIgnoreCase(who, "dev") and !std.ascii.eqlIgnoreCase(who, "lot")) return null;
    const dist = key[slash + 1 ..];
    if (std.ascii.eqlIgnoreCase(dist, "gauss")) return .gauss;
    if (std.ascii.eqlIgnoreCase(dist, "unif")) return .unif;
    return null;
}

// tidy: allow(recursion) bounded by the nesting of blocks, which the reader caps at ir.max_depth
pub fn usesDevLot(stmts: []const Stmt) bool {
    for (stmts) |*s| {
        if (s.kind == .param and s.get("params") == .params) {
            for (s.get("params").params) |p| if (devLotKey(p.key) != null) return true;
        }
        if (usesDevLot(s.body)) return true;
    }
    return false;
}

/// `p=nom dev/gauss=s` as `p=agauss(nom, s, 1)`, which the rest of this
/// file and every dialect with agauss() understand.
/// `n` counts them, for `asFunctions`.
// tidy: allow(recursion) bounded by the nesting of blocks, which the reader caps at ir.max_depth
pub fn devLot(
    arena: Allocator,
    stmts: []const Stmt,
    report: *ir.Report,
    n: *usize,
) Allocator.Error![]const Stmt {
    const out = try arena.dupe(Stmt, stmts);
    const pi = schema.slot(.param, "params");
    for (out) |*st| {
        if (st.body.len > 0) st.body = @constCast(try devLot(arena, st.body, report, n));
        if (st.kind != .param or st.at(pi) != .params) continue;
        var ps: std.ArrayList(ir.Param) = .empty;
        var changed = false;
        for (st.at(pi).params) |p| {
            const dist = devLotKey(p.key) orelse {
                try ps.append(arena, p);
                continue;
            };
            if (ps.items.len == 0) {
                try ps.append(arena, p);
                continue;
            }
            const prev = &ps.items[ps.items.len - 1];
            const nom = try valueText(arena, prev.val);
            const s = try valueText(arena, p.val);
            prev.val = .{ .expr = switch (dist) {
                .gauss => try std.fmt.allocPrint(arena, "agauss({s}, {s}, 1)", .{ nom, s }),
                .unif => try std.fmt.allocPrint(arena, "aunif({s}, {s})", .{ nom, s }),
            } };
            changed = true;
            n.* += 1;
            report.add(
                .warning,
                .caveat,
                st.line,
                "{s}={s} on parameter '{s}': written as a random function in its definition, " ++
                    "so it is drawn per instance inside a subcircuit and per run at the top " ++
                    "level, whatever dev or lot said",
                .{ p.key, s, prev.key },
            );
        }
        if (!changed) continue;
        try st.own(arena);
        try st.set(arena, pi, .{ .params = ps.items });
    }
    std.debug.assert(out.len == stmts.len);
    return out;
}

/// A parameter named like a variable the target keeps for itself is
/// refused there. What is left of them after `writer.renameParams`: a name
/// that is a variable everywhere (`time`).
// tidy: allow(recursion) bounded by the nesting of blocks, which the reader caps at ir.max_depth
pub fn checkReserved(g: *const Grammar, stmts: []const Stmt, report: *ir.Report) void {
    if (g.reserved.len == 0) return;
    for (stmts) |*s| {
        checkReserved(g, s.body, report);
        if (s.kind != .param and s.kind != .subckt) continue;
        const v = s.get("params");
        if (v != .params) continue;
        reservedIn(g, s.line, v.params, report);
    }
}

// ---- private ----

/// `checkReserved` for the parameters of one statement.
fn reservedIn(g: *const Grammar, line: u32, params: []const ir.Param, report: *ir.Report) void {
    for (params) |p| for (g.reserved) |r| for (r.names) |n| {
        if (std.ascii.eqlIgnoreCase(n, p.key))
            report.add(
                .@"error",
                .invalid,
                line,
                "parameter '{s}': {s}; rename it",
                .{ p.key, r.reason },
            );
    };
}

// tidy: allow(recursion) bounded by the nesting of blocks, which the reader caps at ir.max_depth
fn usesKind(stmts: []const Stmt, kind: schema.Kind) bool {
    for (stmts) |*s| if (s.kind == kind or usesKind(s.body, kind)) return true;
    return false;
}

/// Process variations of parameters defined in the same list, as random
/// functions in their definitions. Whatever is left keeps its statistics
/// block, for the writer to report.
// tidy: allow(recursion) bounded by the nesting of blocks, which the reader caps at ir.max_depth
fn fold(
    arena: Allocator,
    g: *const Grammar,
    stmts: []const Stmt,
    report: *ir.Report,
    n: *usize,
) Allocator.Error![]const Stmt {
    std.debug.assert(hasFunction(g, "agauss"));
    var out: std.ArrayList(Stmt) = .empty;
    try out.appendSlice(arena, stmts);
    for (out.items) |*st| {
        if (st.body.len > 0 and st.kind != .statistics)
            st.body = @constCast(try fold(arena, g, st.body, report, n));
    }
    var i: usize = 0;
    while (i < out.items.len) {
        const st = &out.items[i];
        if (st.kind != .statistics) {
            i += 1;
            continue;
        }
        var groups: std.ArrayList(Stmt) = .empty;
        for (st.body) |grp| {
            if (grp.kind != .statgroup or !std.mem.eql(u8, atomOf(grp.get("scope")), "process")) {
                try groups.append(arena, grp);
                continue;
            }
            var kept: std.ArrayList(Stmt) = .empty;
            for (grp.body) |*v| {
                if (v.kind != .vary or !try foldOne(arena, out.items, v, report)) {
                    try kept.append(arena, v.*);
                } else n.* += 1;
            }
            if (kept.items.len == 0) continue;
            var copy = grp;
            copy.body = kept.items;
            try groups.append(arena, copy);
        }
        var any = false;
        for (groups.items) |grp| any = any or grp.kind != .comment;
        if (!any) {
            // The emptied block goes. Its own parameters have no place in
            // any grammar, and do not go with it unsaid.
            if (st.get("params") == .params) for (st.get("params").params) |p| {
                const val = if (p.val == .none) "" else try valueText(arena, p.val);
                report.add(
                    .@"error",
                    .loss,
                    st.line,
                    "statistics: '{s}{s}{s}' has no spelling in {s}",
                    .{ p.key, if (p.val == .none) "" else "=", val, g.name },
                );
            };
            _ = out.orderedRemove(i);
            continue;
        }
        st.body = groups.items;
        i += 1;
    }
    return out.items;
}

fn atomOf(v: Value) []const u8 {
    return if (v == .atom) v.atom else "";
}

fn foldOne(
    arena: Allocator,
    list: []Stmt,
    v: *const Stmt,
    report: *ir.Report,
) Allocator.Error!bool {
    std.debug.assert(v.kind == .vary);
    if (v.get("model") != .none or v.get("param") != .atom) return false;
    if (v.get("params") != .none) return false;
    const name = v.get("param").atom;
    const dist = atomOf(v.get("dist"));
    const gaussian = dist.len == 0 or std.mem.eql(u8, dist, "gauss");
    if (!gaussian and !std.mem.eql(u8, dist, "unif")) return false;
    const spread = if (gaussian) v.get("std") else v.get("range");
    if (spread == .none) return false;
    const pi = schema.slot(.param, "params");
    for (list) |*st| {
        if (st.kind != .param or st.at(pi) != .params) continue;
        for (st.at(pi).params, 0..) |p, k| {
            if (!std.ascii.eqlIgnoreCase(p.key, name)) continue;
            const ps = try arena.dupe(ir.Param, st.at(pi).params);
            const nom = try valueText(arena, p.val);
            const s = try valueText(arena, spread);
            ps[k].val = .{ .expr = if (gaussian)
                try std.fmt.allocPrint(arena, "agauss({s}, {s}, 1)", .{ nom, s })
            else
                try std.fmt.allocPrint(arena, "aunif({s}, {s})", .{ nom, s }) };
            try st.own(arena);
            try st.set(arena, pi, .{ .params = ps });
            report.add(
                .warning,
                .caveat,
                v.line,
                "vary {s}: written as a random function in the parameter's definition; " ++
                    "ngspice draws a new value on every run, where a statistics variation " ++
                    "keeps the nominal value outside a Monte Carlo analysis",
                .{name},
            );
            return true;
        }
    }
    return false;
}

fn valueText(arena: Allocator, v: Value) Allocator.Error![]const u8 {
    return switch (v) {
        .num => |n| if (n.exp10 == 0)
            n.digits()
        else
            try std.fmt.allocPrint(arena, "{s}e{d}", .{ n.digits(), n.exp10 }),
        .expr, .atom, .str => |s| s,
        else => "0",
    };
}

test {
    // The tests of the file this one exports from.
    _ = variations;
}
