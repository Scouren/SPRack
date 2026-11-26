//! Circuits a simulator cannot solve, found from the netlist's topology:
//! nodes with no DC path to ground (reached only through capacitors,
//! current sources or control inputs), and loops of voltage sources and
//! inductors. A grammar's `requires` lines say which of these its simulator
//! needs absent, and whether one is an error or a warning there.
//!
//! Each subcircuit is checked on its own, and the top level with each
//! instance standing for the DC paths its subcircuit makes between its
//! ports, and for the paths of voltage sources and inductors between them:
//! a loop that runs through instances is found without flattening. A
//! device whose DC behaviour depends on its model (a behavioural source, a
//! Verilog-A module, a transmission line, an instance of
//! something not defined here) joins all its terminals: it hides an alarm
//! rather than raise a false one.
//!
//! Nothing is reported for a netlist with no analysis (a cell netlisted on
//! its own: nothing solves it as it stands), and a rule that lists analyses
//! only where one of them is present.

const std = @import("std");
const ir = @import("ir");
const schema = @import("schema");
const grammar = @import("grammar");
const Allocator = std.mem.Allocator;
const Stmt = ir.Stmt;
const Value = ir.Value;
const Topo = grammar.Topo;

/// A scope's nodes by name, as indices into its `names`: a netlist may
/// have millions of nodes.
const NodeMap = std.HashMapUnmanaged(u32, void, NodeCtx, std.hash_map.default_max_load_percentage);

const NodeCtx = struct {
    names: []const []const u8,

    pub fn hash(c: NodeCtx, i: u32) u64 {
        return ir.Caseless.hash(.{}, c.names[i]);
    }

    pub fn eql(_: NodeCtx, a: u32, b: u32) bool {
        return a == b;
    }
};

const ByName = struct {
    names: []const []const u8,

    pub fn hash(_: ByName, name: []const u8) u64 {
        return ir.Caseless.hash(.{}, name);
    }

    pub fn eql(c: ByName, name: []const u8, i: u32) bool {
        return std.ascii.eqlIgnoreCase(name, c.names[i]);
    }
};
/// Each subcircuit by name: the first definition of it.
const DefMap = std.HashMapUnmanaged(
    []const u8,
    *Def,
    ir.Caseless,
    std.hash_map.default_max_load_percentage,
);

/// `known`: summarized, or being summarized (`sum` null until done; it
/// stays null for a body this check cannot read). `stmt` goes away once
/// summarized when the netlist is read as a stream.
/// `early`: kept from before the stream, its definition not yet met.
/// `owed`: summarized with the report muted, so not yet reported on.
const Def = struct { stmt: ?*const Stmt, known: bool = false, sum: ?Summary = null, early: bool =
    false,
    owed: bool = false };

/// Islands and loops reported per scope; the rest are counted.
const max_reports = 20;
/// Names listed per island or loop.
const max_names = 4;
const grounded = std.math.maxInt(u32);

/// What an instance stands for in its parent: for each port, the first
/// port its body joins it to at DC (itself if none) or `grounded`; and a
/// forest of port pairs (`b` may be `grounded`) the body joins by a path of
/// voltage sources only, of inductors only, or of both (at most one edge
/// per port, so linear in the ports).
const Summary = struct { dc: []const u32, edges: []const PortEdge };
const PortEdge = struct { a: u32, b: u32, kind: Mix };

/// A voltage source or inductor, or an instance's path of them: its name,
/// line, and whether it is an instance.
const Edge = struct { a: u32, b: u32, name: []const u8, line: u32, inst: bool, kind: Mix };
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
    subckts: DefMap = .empty,
    globals: ir.CaselessSet = .empty,
    /// The netlist's text: a name in it needs no copy to outlive its
    /// statement. Null: the whole netlist is at hand, nothing is copied.
    src: ?[]const u8 = null,
    /// Every analysis skips the DC solve (UIC): nothing needs a DC path.
    no_op: bool = false,
    /// The analyses present; `tran` only for one that solves DC first.
    has: [schema.kind_count]bool = @splat(false),

    /// The rule for `what`, if the netlist has an analysis it lists.
    fn rule(cx: *const Cx, what: Topo) ?grammar.Require {
        const r = cx.anyRule(what) orelse return null;
        if (r.analyses.len == 0) return r;
        for (r.analyses) |k| if (cx.has[@backingInt(k)]) return r;
        return null;
    }

    /// The rule for `what` whichever analyses are present.
    fn anyRule(cx: *const Cx, what: Topo) ?grammar.Require {
        for (cx.g.requires) |r| if (r.what == what) return r;
        return null;
    }

    /// A name read from a statement, as long as the check needs it.
    fn keep(cx: *const Cx, name: []const u8) Allocator.Error![]const u8 {
        const src = cx.src orelse return name;
        return ir.keepText(cx.arena, src, name);
    }
};

pub fn nodeName(v: Value) ?[]const u8 {
    return switch (v) {
        .atom => |a| a,
        .num => |n| if (n.exp10 == 0) n.digits() else null,
        else => null,
    };
}

fn isGround(name: []const u8) bool {
    return std.mem.eql(
        u8,
        name,
        "0",
    ) or std.ascii.eqlIgnoreCase(name, "gnd") or std.ascii.eqlIgnoreCase(name, "gnd!");
}

/// The index of a node, added if new; null for a vector bracket (XSPICE).
fn node(cx: *Cx, sc: *Scope, v: Value, line: u32) Allocator.Error!?u32 {
    const name = nodeName(v) orelse return null;
    if (std.mem.eql(u8, name, "[") or std.mem.eql(u8, name, "]")) return null;
    if (isGround(name)) return 0;
    const names = sc.names.items;
    const gop = try sc.map.getOrPutContextAdapted(
        cx.gpa,
        name,
        ByName{ .names = names },
        NodeCtx{ .names = names },
    );
    if (gop.found_existing) return gop.key_ptr.*;
    const i: u32 = @intCast(sc.names.items.len);
    gop.key_ptr.* = i;
    try sc.names.append(cx.gpa, try cx.keep(name));
    try sc.lines.append(cx.gpa, line);
    try sc.dc.up.append(cx.gpa, i);
    // A global node is the top level's: take it as grounded.
    if (cx.globals.contains(name)) sc.dc.join(0, i);
    return i;
}

fn newScope(cx: *Cx) Allocator.Error!Scope {
    var sc: Scope = .{};
    errdefer sc.deinit(cx.gpa);
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
        .resistor, .inductor, .vsource, .diode, .bsource, .vcvs, .ccvs, .vswitch, .cswitch, .relay, .ctlsrc => std.mem.eql(
            u8,
            slot,
            "pos",
        ) or std.mem.eql(u8, slot, "neg"),
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
            if (n) |x|
                try sc.terms.append(cx.gpa, .{ .node = x, .conducts = conducts(s.kind, sl.name) });
        }
    }
    return sc.terms.items;
}

fn lookup(sc: *const Scope, v: Value) ?u32 {
    const name = nodeName(v) orelse return null;
    if (isGround(name)) return 0;
    return sc.map.getKeyAdapted(name, ByName{ .names = sc.names.items });
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
        if (sum) |su| {
            const group = su.dc;
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
        if (branch) continue;
        if (sum) |su| {
            if (su.edges.len == 0 or !try fresh(cx, sc, s)) continue;
            for (su.edges) |pe| {
                if (pe.a >= ts.len or (pe.b != grounded and pe.b >= ts.len)) continue;
                const b = if (pe.b == grounded) 0 else ts[pe.b].node;
                try sc.edges.append(cx.gpa, try edgeOf(cx, ts[pe.a].node, b, s, pe.kind));
            }
            continue;
        }
        const kind: Mix = switch (s.kind) {
            // An RF port (portnum) has its z0 in series: not a voltage source.
            .vsource => if (s.get("portnum") != .none) continue else .volt,
            .vcvs, .ccvs => .volt,
            .inductor => .induct,
            else => continue,
        };
        if (ts.len < 2 or !ts[0].conducts or !ts[1].conducts) continue;
        if (!try fresh(cx, sc, s)) continue;
        try sc.edges.append(cx.gpa, try edgeOf(cx, ts[0].node, ts[1].node, s, kind));
    }
}

fn edgeOf(cx: *Cx, a: u32, b: u32, s: *const Stmt, kind: Mix) Allocator.Error!Edge {
    return .{
        .a = a,
        .b = b,
        .name = try cx.keep(nodeName(s.get("name")) orelse "?"),
        .line = s.line,
        .inst = s.kind == .instance,
        .kind = kind,
    };
}

/// False for a second definition of a name already in `sc.edges` (an `.alter`).
fn fresh(cx: *Cx, sc: *Scope, s: *const Stmt) Allocator.Error!bool {
    const name = nodeName(s.get("name")) orelse return true;
    const gop = try sc.edge_names.getOrPut(cx.gpa, name);
    if (gop.found_existing) return false;
    gop.key_ptr.* = try cx.keep(name);
    return true;
}

/// The port pairs the body of `sc` joins by voltage sources, inductors or
/// both: for each relation, each port to the first of its class (ground
/// first), skipping a pair the edges so far already join, so the edges
/// form a forest and make no loop of their own in the parent.
fn portEdges(cx: *Cx, sc: *Scope, idx: []const u32) Allocator.Error![]const PortEdge {
    if (sc.edges.items.len == 0) return &.{};
    const kinds = [_]Mix{ .volt, .induct, .both };
    var sets: [3]Sets = .{ .{}, .{}, .{} };
    defer for (&sets) |*u| u.up.deinit(cx.gpa);
    for (&sets) |*u| try u.reset(cx.gpa, sc.names.items.len);
    for (sc.edges.items) |e| for (&sets, kinds) |*u, k| {
        if (k == .both or k == e.kind) u.join(e.a, e.b);
    };
    const gnd: u32 = @intCast(idx.len);
    var ports: Sets = .{};
    defer ports.up.deinit(cx.gpa);
    try ports.reset(cx.gpa, idx.len + 1);
    var first: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer first.deinit(cx.gpa);
    var out: std.ArrayList(PortEdge) = .empty;
    for (&sets, kinds) |*u, k| {
        first.clearRetainingCapacity();
        try first.put(cx.gpa, u.find(0), gnd);
        for (idx, 0..) |n, i| {
            // A port that is ground, or another port's node, is a wire:
            // not a path this check can name.
            if (n == 0) continue;
            const gop = try first.getOrPut(cx.gpa, u.find(n));
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(i);
                continue;
            }
            const j = gop.value_ptr.*;
            if (j != gnd and idx[j] == n) continue;
            if (ports.find(@intCast(i)) == ports.find(j)) continue;
            ports.join(@intCast(i), j);
            try out.append(cx.arena, if (j == gnd)
                .{ .a = @intCast(i), .b = grounded, .kind = k }
            else
                .{ .a = j, .b = @intCast(i), .kind = k });
        }
    }
    return out.items;
}

fn summarize(cx: *Cx, d: *Def) Allocator.Error!?Summary {
    // Summarized unheard, it is summarized again where the report is
    // heard: there a whole netlist's check says what it found.
    if (d.known and (!d.owed or cx.report.mute)) return d.sum;
    d.known = true;
    d.owed = cx.report.mute;
    d.sum = null;
    const def = d.stmt.?;
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
    const sum: Summary = .{ .dc = group, .edges = try portEdges(cx, &sc, idx) };
    const label = try cx.arena.print("subcircuit '{s}': ", .{nodeName(def.get("name")) orelse "?"});
    try finish(cx, &sc, def.body, idx, label);
    d.sum = sum;
    return sum;
}

const Island = struct {
    nodes: [max_names]u32 = undefined,
    n: usize = 0,
    devs: [max_names][]const u8 = undefined,
    ndev: usize = 0,
    line: u32 = 0,
    current: bool = false,
};

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

/// Report the nodes of `sc` that reach neither ground nor a port, and the
/// loops among its voltage sources and inductors.
fn finish(
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

/// The islands of `sc`, while the devices crossing their boundary are
/// still to be named (`crossings`); then the report. An island fed by a
/// current source is reported under `cut`, any other under `dc`; a null
/// rule reports none.
const Islands = struct {
    found: std.AutoArrayHashMapUnmanaged(u32, Island) = .empty,
    more: usize = 0,
    dc: ?grammar.Require = null,
    cut: ?grammar.Require = null,
};

/// True when there are islands to report, whose crossings are wanted.
fn findIslands(cx: *Cx, sc: *Scope, ports: []const u32, out: *Islands) Allocator.Error!bool {
    if (cx.no_op) return false;
    out.dc = cx.rule(.@"dc-path");
    // An island fed by a current source follows its own `cutset` rule;
    // with none, the dc-path one with any analysis.
    out.cut = if (cx.anyRule(.cutset) != null) cx.rule(.cutset) else cx.anyRule(.@"dc-path");
    if (out.dc == null and out.cut == null) return false;
    const n = sc.names.items.len;
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

fn finishFound(cx: *Cx, sc: *Scope, out: *Islands, label: []const u8) Allocator.Error!void {
    try reportIslands(cx, sc, out, label);
    if (sc.edges.items.len > 0) try loops(cx, sc, label);
}

fn reportIslands(cx: *Cx, sc: *Scope, out: *Islands, label: []const u8) Allocator.Error!void {
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

/// Name, for each island, the devices that cross its boundary: they
/// connect it to the rest only through terminals that conduct no DC.
fn crossings(
    cx: *Cx,
    sc: *Scope,
    stmts: []const Stmt,
    found: *std.AutoArrayHashMapUnmanaged(u32, Island),
) Allocator.Error!void {
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
        try path(cx, sc, sc.edges.items[0..k], m, e.a, e.b, &names);
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

/// The elements of a path from `from` to `to` among `edges` of the mix.
/// ponytail: rescans the edge list per BFS level, O(edges * depth) per
/// loop and at most `max_reports` loops; build an adjacency list if a
/// netlist ever has very many voltage sources and inductors.
fn path(
    cx: *Cx,
    sc: *const Scope,
    edges: []const Edge,
    m: Mix,
    from: u32,
    to: u32,
    out: *std.ArrayList([]const u8),
) Allocator.Error!void {
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

/// Adds the subcircuits `stmts` define to `cx.subckts`, each new one to
/// `defs` too, and its global nodes to `cx.globals`.
fn collect(cx: *Cx, stmts: []const Stmt, defs: *std.ArrayList(*Def)) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .subckt) {
            if (nodeName(s.get("name"))) |name| {
                const gop = try cx.subckts.getOrPut(cx.gpa, name);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try cx.keep(name);
                    const d = try cx.arena.create(Def);
                    d.* = .{ .stmt = s };
                    gop.value_ptr.* = d;
                    try defs.append(cx.gpa, d);
                } else if (gop.value_ptr.*.early) {
                    gop.value_ptr.*.early = false;
                    try defs.append(cx.gpa, gop.value_ptr.*);
                }
            }
        }
        if (s.kind == .global and s.get("nodes") == .list) {
            for (s.get("nodes").list) |v| if (nodeName(v)) |name| {
                const gop = try cx.globals.getOrPut(cx.gpa, name);
                if (!gop.found_existing) gop.key_ptr.* = try cx.keep(name);
            };
        }
        try collect(cx, s.body, defs);
    }
}

/// Summarize, in the order written, the definitions `collect` found.
fn summarizeAll(cx: *Cx, defs: []*Def) Allocator.Error!void {
    std.mem.sortUnstable(*Def, defs, {}, struct {
        fn lt(_: void, a: *Def, b: *Def) bool {
            return a.stmt.?.line < b.stmt.?.line;
        }
    }.lt);
    for (defs) |d| _ = try summarize(cx, d);
}

/// What the analyses of a netlist say about the check: whether there is
/// one, whether every one skips the DC solve, and which there are.
pub const Facts = struct {
    any: bool = false,
    /// Every analysis skips the DC solve (UIC): nothing needs a DC path.
    no_op: bool = true,
    /// The analyses present; `tran` only for one that solves DC first.
    has: [schema.kind_count]bool = @splat(false),

    /// Marks the analyses in `stmts` (a transient with UIC is not `tran`).
    pub fn add(f: *Facts, stmts: []const Stmt) void {
        for (stmts) |*s| {
            if (s.kind == .subckt) continue;
            f.add(s.body);
            if (schema.info(s.kind).class != .analysis) continue;
            switch (s.kind) {
                .step, .montecarlo, .alter => continue,
                else => {},
            }
            f.any = true;
            const uic = s.get("skip_dc");
            if (s.kind == .tran and uic == .atom and std.mem.eql(u8, uic.atom, "yes")) continue;
            f.no_op = false;
            f.has[@backingInt(s.kind)] = true;
        }
    }
};

/// The check run on a netlist read as a stream, a few statements at a time
/// that go away after (`group`). Subcircuits are summarized as they come;
/// one that an instance names before its definition comes is given to
/// `init`. The top level is walked as it comes. Its islands need their
/// crossings, so the statements again, before `end` reports them.
pub const Stream = struct {
    cx: Cx,
    top: Scope,
    defs: std.ArrayList(*Def) = .empty,
    library: bool,
    isl: Islands = .{},

    /// Null when `g` requires nothing, or the netlist has no analysis.
    /// `globals`: every node the netlist's `.global` lines name. `early`:
    /// the subcircuits needed before their definitions come, which outlive
    /// the stream.
    pub fn init(
        gpa: Allocator,
        arena: Allocator,
        g: *const grammar.Grammar,
        report: *ir.Report,
        src: []const u8,
        library: bool,
        facts: Facts,
        globals: []const []const u8,
        early: []const Stmt,
    ) Allocator.Error!?Stream {
        if (g.requires.len == 0 or !facts.any) return null;
        var cx: Cx = .{
            .gpa = gpa,
            .arena = arena,
            .g = g,
            .report = report,
            .src = src,
            .no_op = facts.no_op,
            .has = facts.has,
        };
        errdefer {
            cx.subckts.deinit(gpa);
            cx.globals.deinit(gpa);
        }
        for (globals) |n| try cx.globals.put(gpa, try cx.keep(n), {});
        for (early) |*st| {
            const d = try arena.create(Def);
            d.* = .{ .stmt = st, .early = true };
            try cx.subckts.put(gpa, try cx.keep(nodeName(st.get("name")).?), d);
        }
        return .{ .cx = cx, .top = try newScope(&cx), .library = library };
    }

    pub fn group(s: *Stream, stmts: []const Stmt) Allocator.Error!void {
        s.defs.clearRetainingCapacity();
        try collect(&s.cx, stmts, &s.defs);
        try summarizeAll(&s.cx, s.defs.items);
        for (s.defs.items) |d| d.stmt = null;
        if (s.library) return;
        // A subcircuit first met here, before its definition, is summarized
        // unheard: a whole netlist's check reports on it where it stands.
        const report = s.cx.report;
        const muted = report.mute;
        report.mute = true;
        defer report.mute = muted;
        try walk(&s.cx, &s.top, stmts, false);
    }

    /// After the last group: true when the top level has islands, whose
    /// crossings `cross` must then be given every group again.
    pub fn islands(s: *Stream) Allocator.Error!bool {
        if (s.library or s.top.unread) return false;
        return findIslands(&s.cx, &s.top, &.{}, &s.isl);
    }

    pub fn cross(s: *Stream, stmts: []const Stmt) Allocator.Error!void {
        try crossings(&s.cx, &s.top, stmts, &s.isl.found);
    }

    pub fn end(s: *Stream) Allocator.Error!void {
        if (s.library or s.top.unread) return;
        try finishFound(&s.cx, &s.top, &s.isl, "");
    }

    /// The tables are outside the arena: after `end`, or an error before it.
    pub fn deinit(s: *Stream) void {
        const gpa = s.cx.gpa;
        s.isl.found.deinit(gpa);
        s.top.deinit(gpa);
        s.defs.deinit(gpa);
        s.cx.subckts.deinit(gpa);
        s.cx.globals.deinit(gpa);
    }
};

/// Report what of the netlist's topology `g` says its simulator cannot
/// solve. Tables go to `gpa` and are freed; messages to `arena`.
pub fn check(
    gpa: Allocator,
    arena: Allocator,
    nl: *const ir.Netlist,
    g: *const grammar.Grammar,
    report: *ir.Report,
) Allocator.Error!void {
    if (g.requires.len == 0) return;
    var cx: Cx = .{ .gpa = gpa, .arena = arena, .g = g, .report = report };
    defer cx.subckts.deinit(gpa);
    defer cx.globals.deinit(gpa);
    var facts: Facts = .{};
    facts.add(nl.stmts);
    cx.no_op = facts.no_op;
    cx.has = facts.has;
    // A cell netlisted on its own: how it will be used is not known.
    if (!facts.any) return;
    // Every definition, in the order written; instances reuse the summary.
    var defs: std.ArrayList(*Def) = .empty;
    defer defs.deinit(gpa);
    try collect(&cx, nl.stmts, &defs);
    try summarizeAll(&cx, defs.items);
    // A library's top level is a fragment of some other netlist's.
    if (nl.library) return;
    var sc = try newScope(&cx);
    defer sc.deinit(gpa);
    try walk(&cx, &sc, nl.stmts, false);
    if (!sc.unread) try finish(&cx, &sc, nl.stmts, &.{}, "");
}
