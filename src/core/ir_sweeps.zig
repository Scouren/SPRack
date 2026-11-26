//! Sweeps in canonical form: what a `dc` or `step` sweeps, and which
//! analyses a `step` takes.
//!
//! Contents:
//! - `pub fn principalParam(kind: Kind) ?[]const u8`
//! - `pub fn resolveSweeps(arena: Allocator, nl: *Netlist) Allocator.Error!void`
//! - `pub fn hasSweep(stmts: []const Stmt) bool`
//! - `pub fn gatherSteps(arena: Allocator, stmts: []Stmt) Allocator.Error![]Stmt`

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir.zig");
const Allocator = std.mem.Allocator;
const Caseless = ir.Caseless;
const CaselessSet = ir.CaselessSet;
const Kind = ir.Kind;
const Netlist = ir.Netlist;
const Stmt = ir.Stmt;

const KindMap = std.HashMapUnmanaged(
    []const u8,
    Kind,
    Caseless,
    std.hash_map.default_max_load_percentage,
);

/// The slots of a sweep that name what it sweeps: an instance (`src`), a
/// parameter of the netlist (`param`), the temperature (`v`), and the
/// instance's parameter (`devparam`, empty where the sweep has none).
const Target = struct {
    src: []const u8,
    param: []const u8,
    v: []const u8,
    devparam: []const u8,
};

/// What a sweep sweeps, and the outer loop of a DC sweep of two.
const sweep_one: Target = .{ .src = "src", .param = "param", .v = "var", .devparam = "devparam" };
const sweep_two: Target = .{ .src = "src2", .param = "param2", .v = "var2", .devparam = "" };

/// A step that sets any of these is not a plain outer loop of a DC sweep.
const step_own = [_][]const u8{ "values", "data", "devparam", "params" };

/// A DC sweep that sets any of these has an outer loop already.
const dc_outer = [_][]const u8{ "src2", "param2", "var2" };

/// A step's slot, and the DC sweep's slot of its outer loop that it becomes.
const step_to_dc = [_][2][]const u8{
    .{ "src", "src2" },     .{ "param", "param2" },   .{ "var", "var2" },
    .{ "start", "start2" }, .{ "stop", "stop2" },     .{ "step", "step2" },
    .{ "sweep", "sweep2" }, .{ "points", "points2" },
};

/// The instance parameter a sweep of an instance changes when it names
/// none: a source's dc value, a resistor's resistance.
pub fn principalParam(kind: Kind) ?[]const u8 {
    return switch (kind) {
        .vsource, .isource => "dc",
        .resistor => "r",
        .capacitor => "c",
        .inductor => "l",
        else => null,
    };
}

/// Puts the sweeps of a netlist (`dc`, `step`) in canonical form. A swept
/// name that is no instance but a parameter of the netlist is a parameter
/// sweep (`.dc rv ...`), and `temp` is the temperature; an instance
/// parameter that is the instance's own value is not said. A `step` with no
/// body takes every analysis beside it (`.step` applies to the whole netlist).
pub fn resolveSweeps(arena: Allocator, nl: *Netlist) Allocator.Error!void {
    if (!hasSweep(nl.stmts)) return;
    var insts: KindMap = .empty;
    var params: CaselessSet = .empty;
    try sweepNames(arena, nl.stmts, &insts, &params, true);
    try fixSweeps(arena, nl.stmts, &insts, &params);
    nl.stmts = try gatherSteps(arena, nl.stmts);
    try foldSteps(arena, nl.stmts);
}

// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn hasSweep(stmts: []const Stmt) bool {
    for (stmts) |*s| if (s.kind == .dc or s.kind == .step or hasSweep(s.body)) return true;
    return false;
}

/// Steps without a body take every analysis of their list: the first step
/// the second, the last one the analyses. The first written is the outer loop.
pub fn gatherSteps(arena: Allocator, stmts: []Stmt) Allocator.Error![]Stmt {
    var first: ?usize = null;
    var analyses: usize = 0;
    for (stmts, 0..) |*s, i| {
        if (s.kind == .step and s.body.len == 0 and first == null) first = i;
        if (s.kind != .step and schema.runs(s.kind)) analyses += 1;
    }
    if (first == null or analyses == 0) return stmts;
    var out: std.ArrayList(Stmt) = .empty;
    var chain: std.ArrayList(Stmt) = .empty;
    var inner: std.ArrayList(Stmt) = .empty;
    var slot: usize = 0;
    for (stmts) |s| {
        if (s.kind == .step and s.body.len == 0) {
            if (chain.items.len == 0) slot = out.items.len;
            if (chain.items.len == 0) try out.append(arena, s);
            try chain.append(arena, s);
        } else if (s.kind != .step and schema.runs(s.kind)) {
            try inner.append(arena, s);
        } else try out.append(arena, s);
    }
    // Innermost first: each step's body is the next one.
    var body = try inner.toOwnedSlice(arena);
    var n = chain.items.len;
    while (n > 0) : (n -= 1) {
        var st = chain.items[n - 1];
        st.body = body;
        body = try arena.dupe(Stmt, &.{st});
    }
    std.debug.assert(chain.items.len > 0);
    out.items[slot] = body[0];
    return out.toOwnedSlice(arena);
}

// ---- private ----

/// A step around one DC sweep of a single loop, by start, stop and step
/// or points, is that sweep's outer loop (Spectre writes a nested DC sweep so).
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
fn foldSteps(arena: Allocator, stmts: []Stmt) Allocator.Error!void {
    for (stmts) |*s| {
        try foldSteps(arena, s.body);
        if (s.kind != .step or s.body.len != 1 or s.body[0].kind != .dc) continue;
        const dc = &s.body[0];
        const ok = for (step_own) |n| {
            if (s.at(schema.slotIndex(.step, n).?) != .none) break false;
        } else for (dc_outer) |n| {
            if (dc.at(schema.slotIndex(.dc, n).?) != .none) break false;
        } else true;
        if (!ok) continue;
        var out = dc.*;
        try out.own(arena);
        for (step_to_dc) |p|
            try out.set(
                arena,
                schema.slotIndex(.dc, p[1]).?,
                s.at(schema.slotIndex(.step, p[0]).?),
            );
        std.debug.assert(out.kind == .dc);
        s.* = out;
    }
}

// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
fn sweepNames(
    arena: Allocator,
    stmts: []const Stmt,
    insts: *KindMap,
    params: *CaselessSet,
    top: bool,
) Allocator.Error!void {
    for (stmts) |*s| {
        if (schema.info(s.kind).class == .device and s.get("name") == .atom)
            try insts.put(arena, s.get("name").atom, s.kind);
        if (top and s.kind == .param and s.get("params") == .params) {
            for (s.get("params").params) |p| try params.put(arena, p.key, {});
        }
        // A subcircuit's parameters are not the netlist's.
        try sweepNames(arena, s.body, insts, params, top and s.kind != .subckt);
    }
}

// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
fn fixSweeps(
    arena: Allocator,
    stmts: []Stmt,
    insts: *const KindMap,
    params: *const CaselessSet,
) Allocator.Error!void {
    for (stmts) |*s| {
        try fixSweeps(arena, s.body, insts, params);
        if (s.kind != .dc and s.kind != .step) continue;
        try s.own(arena);
        try fixTarget(arena, s, sweep_one, insts, params);
        if (s.kind == .dc) try fixTarget(arena, s, sweep_two, insts, params);
    }
}

fn fixTarget(
    arena: Allocator,
    s: *Stmt,
    t: Target,
    insts: *const KindMap,
    params: *const CaselessSet,
) Allocator.Error!void {
    std.debug.assert(schema.runs(s.kind));
    const si = schema.slotIndex(s.kind, t.src).?;
    const name = switch (s.at(si)) {
        .atom => |a| a,
        else => return,
    };
    if (insts.get(name)) |kind| {
        if (t.devparam.len == 0) return;
        const di = schema.slotIndex(s.kind, t.devparam).?;
        const dp = s.at(di);
        const own = principalParam(kind) orelse return;
        if (dp == .atom and std.ascii.eqlIgnoreCase(dp.atom, own)) try s.set(arena, di, .none);
        return;
    }
    // The parameter's own spelling: `name` was read as an instance's.
    if (params.getKey(name)) |key| {
        try s.set(arena, schema.slotIndex(s.kind, t.param).?, .{ .atom = key });
    } else if (std.ascii.eqlIgnoreCase(name, "temp")) {
        try s.set(arena, schema.slotIndex(s.kind, t.v).?, .{ .atom = "temp" });
    } else return;
    try s.set(arena, si, .none);
}
