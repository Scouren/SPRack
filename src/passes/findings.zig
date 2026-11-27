//! The reports of the topology check (`topology.zig`): the islands of a
//! scope, the nodes that reach neither ground nor a port, with the devices
//! that cross into them; and the loops among its voltage sources and
//! inductors, each with a path of the elements that close it.
//!
//! Contents:
//! - `pub const Islands = struct`
//! - `pub fn finish(cx: *Cx, sc: *Scope, stmts: []const Stmt, ports: []const u32,
//!   label: []const u8) Allocator.Error!void`
//! - `pub fn findIslands(cx: *Cx, sc: *Scope, ports: []const u32,
//!   out: *Islands) Allocator.Error!bool`
//! - `pub fn finishFound(cx: *Cx, sc: *Scope, out: *Islands,
//!   label: []const u8) Allocator.Error!void`
//! - `pub fn crossings(cx: *Cx, sc: *Scope, stmts: []const Stmt,
//!   found: *std.AutoArrayHashMapUnmanaged(u32, Island)) Allocator.Error!void`

const std = @import("std");
const ir = @import("ir");
const schema = @import("schema");
const grammar = @import("grammar");
const topology = @import("topology.zig");
const Allocator = std.mem.Allocator;
const Stmt = ir.Stmt;
const Topo = grammar.Topo;
const Cx = topology.Cx;
const Scope = topology.Scope;
const Sets = topology.Sets;
const Edge = topology.Edge;
const Mix = topology.Mix;
const nodeName = topology.nodeName;
const terms = topology.terms;
const max_reports = topology.max_reports;
const max_names = topology.max_names;
const grounded = topology.grounded;

/// The islands of `sc`, while the devices crossing their boundary are
/// still to be named (`crossings`); then the report. An island fed by a
/// current source is reported under `cut`, any other under `dc`; a null
/// rule reports none.
pub const Islands = struct {
    found: std.AutoArrayHashMapUnmanaged(u32, Island) = .empty,
    more: usize = 0,
    dc: ?grammar.Require = null,
    cut: ?grammar.Require = null,
};

const Island = struct {
    nodes: [max_names]u32 = undefined,
    n: usize = 0,
    devs: [max_names][]const u8 = undefined,
    ndev: usize = 0,
    line: u32 = 0,
    current: bool = false,
};

/// Report the nodes of `sc` that reach neither ground nor a port, and the
/// loops among its voltage sources and inductors.
pub fn finish(
    cx: *Cx,
    sc: *Scope,
    stmts: []const Stmt,
    ports: []const u32,
    label: []const u8,
) Allocator.Error!void {
    var isl: Islands = .{};
    defer isl.found.deinit(cx.gpa);
    if (try findIslands(cx, sc, ports, &isl)) try crossings(cx, sc, stmts, &isl.found);
    try finishFound(cx, sc, &isl, label);
}

/// True when there are islands to report, whose crossings are wanted.
pub fn findIslands(cx: *Cx, sc: *Scope, ports: []const u32, out: *Islands) Allocator.Error!bool {
    if (cx.no_op) return false;
    out.dc = cx.rule(.@"dc-path");
    // An island fed by a current source follows its own `cutset` rule;
    // with none, the dc-path one with any analysis.
    out.cut = if (cx.anyRule(.cutset) != null) cx.rule(.cutset) else cx.anyRule(.@"dc-path");
    if (out.dc == null and out.cut == null) return false;
    const n = sc.names.items.len;
    // Ground, node 0, is in every scope.
    std.debug.assert(n > 0);
    const reach = try cx.gpa.alloc(bool, n);
    defer cx.gpa.free(reach);
    @memset(reach, false);
    reach[sc.dc.find(0)] = true;
    for (ports) |p| reach[sc.dc.find(p)] = true;
    const found = &out.found;
    var more: usize = 0;
    for (1..n) |i| {
        const r = sc.dc.find(@intCast(i));
        if (reach[r]) continue;
        const gop = try found.getOrPut(cx.gpa, r);
        if (!gop.found_existing) {
            if (found.count() > max_reports) {
                found.swapRemoveAt(found.count() - 1);
                reach[r] = true;
                more += 1;
                continue;
            }
            gop.value_ptr.* = .{ .line = sc.lines.items[i] };
        }
        const isl = gop.value_ptr;
        if (isl.n < max_names) isl.nodes[isl.n] = @intCast(i);
        isl.n += 1;
    }
    out.more = more;
    return found.count() > 0;
}

pub fn finishFound(cx: *Cx, sc: *Scope, out: *Islands, label: []const u8) Allocator.Error!void {
    try reportIslands(cx, sc, out, label);
    if (sc.edges.items.len > 0) try loops(cx, sc, label);
}

/// Name, for each island, the devices that cross its boundary: they
/// connect it to the rest only through terminals that conduct no DC.
// tidy: allow(recursion) bounded by the nesting of blocks, which the reader caps at ir.max_depth
pub fn crossings(
    cx: *Cx,
    sc: *Scope,
    stmts: []const Stmt,
    found: *std.AutoArrayHashMapUnmanaged(u32, Island),
) Allocator.Error!void {
    std.debug.assert(found.count() <= max_reports);
    for (stmts) |*s| {
        if (s.kind == .subckt) continue;
        if (s.body.len > 0) try crossings(cx, sc, s.body, found);
        if (schema.info(s.kind).class != .device) continue;
        const ts = try terms(cx, sc, s, false);
        for (ts) |t| {
            const r = sc.dc.find(t.node);
            const isl = found.getPtr(r) orelse continue;
            const across = for (ts) |o| {
                if (sc.dc.find(o.node) != r) break true;
            } else false;
            if (!across) continue;
            const name = nodeName(s.get("name")) orelse "?";
            if (isl.ndev > 0 and isl.ndev <= max_names and std.mem.eql(
                u8,
                isl.devs[isl.ndev - 1],
                name,
            )) continue;
            if (isl.ndev < max_names) isl.devs[isl.ndev] = name;
            isl.ndev += 1;
            if (s.kind == .isource or s.kind == .vccs or s.kind == .cccs) isl.current = true;
        }
    }
}

// ---- private ----

fn list(
    arena: Allocator,
    names: []const []const u8,
    total: usize,
    quote: bool,
) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        if (quote) try out.append(arena, '\'');
        try out.appendSlice(arena, n);
        if (quote) try out.append(arena, '\'');
    }
    if (total > names.len) try out.print(arena, " and {d} more", .{total - names.len});
    return out.items;
}

fn reportIslands(cx: *Cx, sc: *Scope, out: *Islands, label: []const u8) Allocator.Error!void {
    // `findIslands` counts the islands past this, and keeps no more.
    std.debug.assert(out.found.count() <= max_reports);
    for (out.found.values()) |*isl| {
        const rq = (if (isl.current) out.cut else out.dc) orelse continue;
        var names: [max_names][]const u8 = undefined;
        const shown = @min(isl.n, max_names);
        for (isl.nodes[0..shown], 0..) |x, i| names[i] = sc.names.items[x];
        const nodes = try list(cx.arena, names[0..shown], isl.n, true);
        const devs = try list(cx.arena, isl.devs[0..@min(isl.ndev, max_names)], isl.ndev, false);
        const many = isl.n > 1;
        cx.report.add(if (rq.err)
            .@"error"
        else
            .warning, .invalid, isl.line, "{s}{s} {s} {s} no DC path to ground: {s}{s} {s} " ++
            "{s}, which conduct{s} no DC there{s}; {s}", .{
            label,
            if (many) "nodes" else "node",
            nodes,
            if (many) "have" else "has",
            if (isl.ndev == 0) "nothing reaches " else "only ",
            if (isl.ndev == 0) (if (many) "them" else "it") else devs,
            if (isl.ndev == 0) "but" else if (isl.ndev == 1) "reaches" else "reach",
            if (isl.ndev == 0) "devices" else if (many) "them" else "it",
            if (isl.ndev == 1) "s" else "",
            if (isl.current) ", and the currents of the sources into it must balance" else "",
            rq.reason,
        });
    }
    if (out.more > 0)
        if (out.dc) |rq|
            cx.report.add(if (rq.err)
                .@"error"
            else
                .warning, .invalid, 0, "{s}{d} more groups of nodes have no DC path to " ++
                "ground; {s}", .{ label, out.more, rq.reason });
}

fn loops(cx: *Cx, sc: *Scope, label: []const u8) Allocator.Error!void {
    std.debug.assert(sc.edges.items.len > 0);
    const n = sc.names.items.len;
    var v: Sets = .{};
    var l: Sets = .{};
    var vl: Sets = .{};
    defer v.up.deinit(cx.gpa);
    defer l.up.deinit(cx.gpa);
    defer vl.up.deinit(cx.gpa);
    try v.reset(cx.gpa, n);
    try l.reset(cx.gpa, n);
    try vl.reset(cx.gpa, n);
    var shown: usize = 0;
    var more = [_]usize{ 0, 0, 0 };
    for (sc.edges.items, 0..) |e, k| {
        if (e.a == e.b) continue;
        const own: ?*Sets = switch (e.kind) {
            .volt => &v,
            .induct => &l,
            .both => null,
        };
        const mix: ?Mix = if (own != null and own.?.find(e.a) == own.?.find(e.b))
            e.kind
        else if (vl.find(e.a) == vl.find(e.b)) .both else null;
        if (own) |o| o.join(e.a, e.b);
        vl.join(e.a, e.b);
        const m = mix orelse continue;
        const what: Topo = switch (m) {
            .volt => .@"no-vloop",
            .both => .@"no-vlloop",
            .induct => .@"no-lloop",
        };
        // A transient that starts without a DC solve integrates through
        // inductors; only a loop of voltage sources stays singular.
        if (cx.no_op and m != .volt) continue;
        const rq = cx.rule(what) orelse continue;
        if (shown == max_reports) {
            more[@backingInt(m)] += 1;
            continue;
        }
        shown += 1;
        var names: std.ArrayList([]const u8) = .empty;
        try path(cx, sc, sc.edges.items[0..k], m, e, &names);
        try names.append(cx.arena, try edgeName(cx, sc, e));
        cx.report.add(if (rq.err)
            .@"error"
        else
            .warning, .invalid, e.line, "{s}{s} form a loop of {s} through '{s}' and '{s}'; {s}", .{
            label,
            try list(cx.arena, names.items, names.items.len, false),
            switch (m) {
                .volt => "voltage sources",
                .both => "voltage sources and inductors",
                .induct => "inductors",
            },
            sc.names.items[e.a],
            sc.names.items[e.b],
            rq.reason,
        });
    }
    for (more, 0..) |c, i| if (c > 0) {
        const what: Topo = @fromBackingInt(@intCast(@backingInt(Topo.@"no-vloop") + i));
        const rq = cx.rule(what) orelse continue;
        cx.report.add(if (rq.err)
            .@"error"
        else
            .warning, .invalid, 0, "{s}{d} more such loops; {s}", .{ label, c, rq.reason });
    };
}

/// The elements of a path from `closing.a` to `closing.b` among `edges` of the mix.
/// ponytail: rescans the edge list per BFS level, O(edges * depth) per
/// loop and at most `max_reports` loops; build an adjacency list if a
/// netlist ever has very many voltage sources and inductors.
fn path(
    cx: *Cx,
    sc: *const Scope,
    edges: []const Edge,
    m: Mix,
    closing: Edge,
    out: *std.ArrayList([]const u8),
) Allocator.Error!void {
    const from = closing.a;
    const to = closing.b;
    // `loops` skips an element whose two ends are one node.
    std.debug.assert(from != to);
    var via: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer via.deinit(cx.gpa);
    try via.put(cx.gpa, from, grounded);
    var grew = true;
    while (grew and !via.contains(to)) {
        grew = false;
        for (edges, 0..) |e, i| {
            if (m != .both and e.kind != m) continue;
            const ina = via.contains(e.a);
            if (ina == via.contains(e.b)) continue;
            try via.put(cx.gpa, if (ina) e.b else e.a, i);
            grew = true;
        }
    }
    var at = to;
    while (via.get(at)) |i| {
        if (i == grounded) break;
        const e = edges[i];
        try out.append(cx.arena, try edgeName(cx, sc, e));
        at = if (e.a == at) e.b else e.a;
    }
}

/// An element's name; an instance's with the nodes its path joins, `X1(a,b)`.
fn edgeName(cx: *Cx, sc: *const Scope, e: Edge) Allocator.Error![]const u8 {
    if (!e.inst) return e.name;
    return cx.arena.print("{s}({s},{s})", .{ e.name, sc.names.items[e.a], sc.names.items[e.b] });
}
