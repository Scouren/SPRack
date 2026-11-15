//! Circuits a simulator cannot solve, found from the netlist's topology:
//! nodes with no DC path to ground (reached only through capacitors,
//! current sources or control inputs), and loops of voltage sources and
//! inductors. A grammar's `requires` lines say which of these its simulator
//! needs absent, and whether one is an error or a warning there.
//!
//! Each subcircuit is checked on its own, and the top level with each
//! instance standing for the DC paths its subcircuit makes between its
//! ports. A device whose DC behaviour depends on its model (a behavioural
//! source, a Verilog-A module, a transmission line, an instance of
//! something not defined here) joins all its terminals: it hides an alarm
//! rather than raise a false one.

const std = @import("std");
const ir = @import("ir.zig");
const schema = @import("schema.zig");
const grammar = @import("grammar.zig");
const Allocator = std.mem.Allocator;
const Stmt = ir.Stmt;
const Value = ir.Value;
const Topo = grammar.Topo;

const NodeMap = std.HashMapUnmanaged([]const u8, u32, ir.Caseless, std.hash_map.default_max_load_percentage);
const StmtMap = std.HashMapUnmanaged([]const u8, *const Stmt, ir.Caseless, std.hash_map.default_max_load_percentage);

/// Islands and loops reported per scope; the rest are counted.
const max_reports = 20;
/// Names listed per island or loop.
const max_names = 4;
const grounded = std.math.maxInt(u32);

/// For each port of a subcircuit, the first port its body joins it to at
/// DC (itself if none), or `grounded`.
const Summary = []const u32;

const Edge = struct { a: u32, b: u32, s: *const Stmt, volt: bool };
const Term = struct { node: u32, conducts: bool };

/// Union-find over the node indices of one scope.
const Sets = struct {
    up: std.ArrayList(u32) = .empty,

    fn find(u: *Sets, x: u32) u32 {
        var r = x;
        while (u.up.items[r] != r) r = u.up.items[r];
        var y = x;
        while (u.up.items[y] != r) {
            const next = u.up.items[y];
            u.up.items[y] = r;
            y = next;
        }
        return r;
    }

    fn join(u: *Sets, a: u32, b: u32) void {
        const x = u.find(a);
        const y = u.find(b);
        // The lower index is the root, so ground (0) always is one.
        if (x < y) u.up.items[y] = x else u.up.items[x] = y;
    }

    fn reset(u: *Sets, gpa: Allocator, n: usize) Allocator.Error!void {
        try u.up.resize(gpa, n);
        for (u.up.items, 0..) |*p, i| p.* = @intCast(i);
    }
};

/// The nodes of one subcircuit body or of the top level.
const Scope = struct {
    map: NodeMap = .empty,
    names: std.ArrayList([]const u8) = .empty,
    lines: std.ArrayList(u32) = .empty,
    dc: Sets = .{},
    edges: std.ArrayList(Edge) = .empty,
    /// Names of the sources and inductors in `edges`: a later definition
    /// of one (an `.alter`) replaces it, and makes no loop with it.
    edge_names: ir.CaselessSet = .empty,
    /// A line no rule understood may be a device: the scope is not checked.
    unread: bool = false,
    terms: std.ArrayList(Term) = .empty,

    fn deinit(sc: *Scope, gpa: Allocator) void {
        sc.map.deinit(gpa);
        sc.names.deinit(gpa);
        sc.lines.deinit(gpa);
        sc.dc.up.deinit(gpa);
        sc.edges.deinit(gpa);
        sc.edge_names.deinit(gpa);
        sc.terms.deinit(gpa);
    }
};

const Cx = struct {
    gpa: Allocator,
    arena: Allocator,
    g: *const grammar.Grammar,
    report: *ir.Report,
    subckts: StmtMap = .empty,
    globals: ir.CaselessSet = .empty,
    /// A subcircuit being summarized maps to null, so recursion stops.
    done: std.AutoHashMapUnmanaged(*const Stmt, ?Summary) = .empty,
    /// Every analysis skips the DC solve (UIC): nothing needs a DC path.
    no_op: bool = false,

    fn rule(cx: *const Cx, what: Topo) ?grammar.Require {
        for (cx.g.requires) |r| if (r.what == what) return r;
        return null;
    }
};

fn nodeName(v: Value) ?[]const u8 {
    return switch (v) {
        .atom => |a| a,
        .num => |n| if (n.exp10 == 0) n.digits() else null,
        else => null,
    };
}

fn isGround(name: []const u8) bool {
    return std.mem.eql(u8, name, "0") or std.ascii.eqlIgnoreCase(name, "gnd") or std.ascii.eqlIgnoreCase(name, "gnd!");
}

/// The index of a node, added if new; null for a vector bracket (XSPICE).
fn node(cx: *Cx, sc: *Scope, v: Value, line: u32) Allocator.Error!?u32 {
    const name = nodeName(v) orelse return null;
    if (std.mem.eql(u8, name, "[") or std.mem.eql(u8, name, "]")) return null;
    if (isGround(name)) return 0;
    const gop = try sc.map.getOrPut(cx.gpa, name);
    if (gop.found_existing) return gop.value_ptr.*;
    const i: u32 = @intCast(sc.names.items.len);
    gop.value_ptr.* = i;
    try sc.names.append(cx.gpa, name);
    try sc.lines.append(cx.gpa, line);
    try sc.dc.up.append(cx.gpa, i);
    // A global node is the top level's: take it as grounded.
    if (cx.globals.contains(name)) sc.dc.join(0, i);
    return i;
}

fn newScope(cx: *Cx) Allocator.Error!Scope {
    var sc: Scope = .{};
    try sc.names.append(cx.gpa, "0");
    try sc.lines.append(cx.gpa, 0);
    try sc.dc.up.append(cx.gpa, 0);
    return sc;
}

/// Whether the terminal in slot `slot` of a `kind` conducts at DC to the
/// device's other conducting terminals.
fn conducts(kind: schema.Kind, slot: []const u8) bool {
    return switch (kind) {
        .capacitor, .isource, .vccs, .cccs => false,
        // Two-terminal paths; control inputs do not conduct.
        .resistor, .inductor, .vsource, .diode, .bsource, .vcvs, .ccvs, .vswitch, .cswitch, .relay, .ctlsrc => std.mem.eql(u8, slot, "pos") or std.mem.eql(u8, slot, "neg"),
        .mosfet => !std.mem.eql(u8, slot, "g"),
        else => true,
    };
}

/// The device's terminals, into `sc.terms`. With `add` false, nodes not
/// yet in the scope are skipped.
fn terms(cx: *Cx, sc: *Scope, s: *const Stmt, add: bool) Allocator.Error![]const Term {
    sc.terms.clearRetainingCapacity();
    for (schema.info(s.kind).slots, 0..) |sl, i| {
        if (sl.ty != .node) continue;
        const v = s.at(i);
        const items: []const Value = if (v == .list) v.list else &.{v};
        for (items) |item| {
            const n = if (add) try node(cx, sc, item, s.line) else lookup(sc, item);
            if (n) |x| try sc.terms.append(cx.gpa, .{ .node = x, .conducts = conducts(s.kind, sl.name) });
        }
    }
    return sc.terms.items;
}

fn lookup(sc: *const Scope, v: Value) ?u32 {
    const name = nodeName(v) orelse return null;
    if (isGround(name)) return 0;
    return sc.map.get(name);
}

fn instanceSummary(cx: *Cx, s: *const Stmt) Allocator.Error!?Summary {
    if (s.kind != .instance) return null;
    const m = nodeName(s.get("master")) orelse return null;
    const def = cx.subckts.get(m) orelse return null;
    return summarize(cx, def);
}

/// Joins what conducts at DC and gathers the voltage sources and inductors.
/// The branches of a conditional all join (fewer alarms), but give no loop:
/// only one of them is in the circuit.
fn walk(cx: *Cx, sc: *Scope, stmts: []const Stmt, branch: bool) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .subckt) continue;
        if (s.kind == .@"opaque") sc.unread = true;
        if (s.body.len > 0) try walk(cx, sc, s.body, branch or s.kind == .cond_if);
        if (schema.info(s.kind).class != .device) continue;
        const sum = try instanceSummary(cx, s);
        const ts = try terms(cx, sc, s, true);
        if (sum) |group| {
            for (ts[0..@min(ts.len, group.len)], group[0..@min(ts.len, group.len)]) |t, gi| {
                sc.dc.join(t.node, if (gi == grounded) 0 else ts[gi].node);
            }
        } else {
            // A Verilog-A module or a cell defined elsewhere may also
            // reach ground inside (`V(out) <+ ...`): take it as reaching it.
            const inside = switch (s.kind) {
                .device, .xspice, .instance => true,
                else => false,
            };
            var first: ?u32 = if (inside) 0 else null;
            for (ts) |t| if (t.conducts) {
                if (first) |f| sc.dc.join(f, t.node) else first = t.node;
            };
        }
        const volt = switch (s.kind) {
            // An RF port (portnum) has its z0 in series: not a voltage source.
            .vsource => if (s.get("portnum") != .none) continue else true,
            .vcvs, .ccvs => true,
            .inductor => false,
            else => continue,
        };
        if (ts.len < 2 or !ts[0].conducts or !ts[1].conducts or branch) continue;
        if (nodeName(s.get("name"))) |name| {
            if ((try sc.edge_names.fetchPut(cx.gpa, name, {})) != null) continue;
        }
        try sc.edges.append(cx.gpa, .{ .a = ts[0].node, .b = ts[1].node, .s = s, .volt = volt });
    }
}

fn summarize(cx: *Cx, def: *const Stmt) Allocator.Error!?Summary {
    if (cx.done.get(def)) |known| return known;
    try cx.done.put(cx.gpa, def, null);
    var sc = try newScope(cx);
    defer sc.deinit(cx.gpa);
    const ports = def.get("ports");
    const plist: []const Value = if (ports == .list) ports.list else &.{};
    var idx = try cx.arena.alloc(u32, plist.len);
    for (plist, 0..) |p, i| idx[i] = (try node(cx, &sc, p, def.line)) orelse 0;
    try walk(cx, &sc, def.body, false);
    // Not understood, it is a cell whose paths are not known (null).
    if (sc.unread) return null;
    const group = try cx.arena.alloc(u32, plist.len);
    for (idx, 0..) |n, i| {
        const r = sc.dc.find(n);
        group[i] = if (r == sc.dc.find(0)) grounded else for (idx[0..i], 0..) |m, j| {
            if (sc.dc.find(m) == r) break @intCast(j);
        } else @intCast(i);
    }
    const label = try cx.arena.print("subcircuit '{s}': ", .{nodeName(def.get("name")) orelse "?"});
    try finish(cx, &sc, def.body, idx, label);
    try cx.done.put(cx.gpa, def, group);
    return group;
}

const Island = struct {
    nodes: [max_names]u32 = undefined,
    n: usize = 0,
    devs: [max_names][]const u8 = undefined,
    ndev: usize = 0,
    line: u32 = 0,
    current: bool = false,
};

fn list(arena: Allocator, names: []const []const u8, total: usize, quote: bool) Allocator.Error![]const u8 {
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

/// Report the nodes of `sc` that reach neither ground nor a port, and the
/// loops among its voltage sources and inductors.
fn finish(cx: *Cx, sc: *Scope, stmts: []const Stmt, ports: []const u32, label: []const u8) Allocator.Error!void {
    if (cx.rule(.@"dc-path")) |rq| if (!cx.no_op) try islands(cx, sc, stmts, ports, label, rq);
    if (sc.edges.items.len > 0) try loops(cx, sc, label);
}

fn islands(cx: *Cx, sc: *Scope, stmts: []const Stmt, ports: []const u32, label: []const u8, rq: grammar.Require) Allocator.Error!void {
    const n = sc.names.items.len;
    const reach = try cx.gpa.alloc(bool, n);
    defer cx.gpa.free(reach);
    @memset(reach, false);
    reach[sc.dc.find(0)] = true;
    for (ports) |p| reach[sc.dc.find(p)] = true;
    var found: std.AutoArrayHashMapUnmanaged(u32, Island) = .empty;
    defer found.deinit(cx.gpa);
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
    if (found.count() == 0) return;
    try crossings(cx, sc, stmts, &found);
    for (found.values()) |*isl| {
        var names: [max_names][]const u8 = undefined;
        const shown = @min(isl.n, max_names);
        for (isl.nodes[0..shown], 0..) |x, i| names[i] = sc.names.items[x];
        const nodes = try list(cx.arena, names[0..shown], isl.n, true);
        const devs = try list(cx.arena, isl.devs[0..@min(isl.ndev, max_names)], isl.ndev, false);
        const many = isl.n > 1;
        cx.report.add(if (rq.err) .@"error" else .warning, .invalid, isl.line, "{s}{s} {s} {s} no DC path to ground: {s}{s} {s} {s}, which conduct{s} no DC there{s}; {s}", .{
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
    if (more > 0) cx.report.add(if (rq.err) .@"error" else .warning, .invalid, 0, "{s}{d} more groups of nodes have no DC path to ground; {s}", .{ label, more, rq.reason });
}

/// Name, for each island, the devices that cross its boundary: they
/// connect it to the rest only through terminals that conduct no DC.
fn crossings(cx: *Cx, sc: *Scope, stmts: []const Stmt, found: *std.AutoArrayHashMapUnmanaged(u32, Island)) Allocator.Error!void {
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
            if (isl.ndev > 0 and isl.ndev <= max_names and std.mem.eql(u8, isl.devs[isl.ndev - 1], name)) continue;
            if (isl.ndev < max_names) isl.devs[isl.ndev] = name;
            isl.ndev += 1;
            if (s.kind == .isource or s.kind == .vccs or s.kind == .cccs) isl.current = true;
        }
    }
}

const Mix = enum { volt, both, induct };

fn loops(cx: *Cx, sc: *Scope, label: []const u8) Allocator.Error!void {
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
        const own = if (e.volt) &v else &l;
        const mix: ?Mix = if (own.find(e.a) == own.find(e.b))
            (if (e.volt) .volt else .induct)
        else if (vl.find(e.a) == vl.find(e.b)) .both else null;
        own.join(e.a, e.b);
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
        try path(cx, sc.edges.items[0..k], m, e.a, e.b, &names);
        try names.append(cx.arena, nodeName(e.s.get("name")) orelse "?");
        cx.report.add(if (rq.err) .@"error" else .warning, .invalid, e.s.line, "{s}{s} form a loop of {s} through '{s}' and '{s}'; {s}", .{
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
        const rq = cx.rule(what).?;
        cx.report.add(if (rq.err) .@"error" else .warning, .invalid, 0, "{s}{d} more such loops; {s}", .{ label, c, rq.reason });
    };
}

/// The elements of a path from `from` to `to` among `edges` of the mix.
/// ponytail: rescans the edge list per BFS level, O(edges * depth) per
/// loop and at most `max_reports` loops; build an adjacency list if a
/// netlist ever has very many voltage sources and inductors.
fn path(cx: *Cx, edges: []const Edge, m: Mix, from: u32, to: u32, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    var via: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer via.deinit(cx.gpa);
    try via.put(cx.gpa, from, grounded);
    var grew = true;
    while (grew and !via.contains(to)) {
        grew = false;
        for (edges, 0..) |e, i| {
            if ((m == .volt and !e.volt) or (m == .induct and e.volt)) continue;
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
        try out.append(cx.arena, nodeName(e.s.get("name")) orelse "?");
        at = if (e.a == at) e.b else e.a;
    }
}

fn collect(cx: *Cx, stmts: []const Stmt) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .subckt) {
            if (nodeName(s.get("name"))) |name| {
                const gop = try cx.subckts.getOrPut(cx.gpa, name);
                if (!gop.found_existing) gop.value_ptr.* = s;
            }
        }
        if (s.kind == .global and s.get("nodes") == .list) {
            for (s.get("nodes").list) |v| if (nodeName(v)) |name| try cx.globals.put(cx.gpa, name, {});
        }
        try collect(cx, s.body);
    }
}

/// Whether the netlist has analyses and every one starts without a DC
/// solve (a transient with UIC).
fn skipsOp(stmts: []const Stmt, any: *bool) bool {
    for (stmts) |*s| {
        if (s.kind == .subckt) continue;
        if (s.body.len > 0 and !skipsOp(s.body, any)) return false;
        if (schema.info(s.kind).class != .analysis or s.kind == .step or s.kind == .montecarlo) continue;
        any.* = true;
        const uic = s.get("skip_dc");
        if (s.kind != .tran or uic != .atom or !std.mem.eql(u8, uic.atom, "yes")) return false;
    }
    return true;
}

/// Report what of the netlist's topology `g` says its simulator cannot
/// solve. Tables go to `gpa` and are freed; messages to `arena`.
pub fn check(gpa: Allocator, arena: Allocator, nl: *const ir.Netlist, g: *const grammar.Grammar, report: *ir.Report) Allocator.Error!void {
    if (g.requires.len == 0) return;
    var cx: Cx = .{ .gpa = gpa, .arena = arena, .g = g, .report = report };
    defer cx.subckts.deinit(gpa);
    defer cx.globals.deinit(gpa);
    defer cx.done.deinit(gpa);
    try collect(&cx, nl.stmts);
    var any = false;
    cx.no_op = skipsOp(nl.stmts, &any) and any;
    // Every definition, in the order written; instances reuse the summary.
    var it = cx.subckts.valueIterator();
    var defs: std.ArrayList(*const Stmt) = .empty;
    defer defs.deinit(gpa);
    while (it.next()) |d| try defs.append(gpa, d.*);
    std.mem.sortUnstable(*const Stmt, defs.items, {}, struct {
        fn lt(_: void, a: *const Stmt, b: *const Stmt) bool {
            return a.line < b.line;
        }
    }.lt);
    for (defs.items) |d| _ = try summarize(&cx, d);
    // A library's top level is a fragment of some other netlist's.
    if (nl.library) return;
    var sc = try newScope(&cx);
    defer sc.deinit(gpa);
    try walk(&cx, &sc, nl.stmts, false);
    if (!sc.unread) try finish(&cx, &sc, nl.stmts, &.{}, "");
}
