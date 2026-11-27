//! A netlist written as modules that instantiate each other by named
//! ports, its top level one of them: a grammar's `modules` section
//! (structural Verilog). The words are the grammar's (`grammar.Modules`).
//!
//! Why a pass and not rules: what each line says is known only from the
//! whole netlist. A module holds no other, so the subcircuits are taken out
//! of where they stand and the top level is made a module; a port's
//! direction is what the instances inside do with it, through every level
//! (where none says, `inout`); a module declares its nets before its
//! instances, sorted; an instance names the ports of a definition that may
//! stand anywhere in the netlist, and joins the bits of a bus. A statement
//! of any other kind is written as the grammar says (`blocks.stmt`): a note
//! where it changes nothing there (`inert`), an error where it has no form
//! (`no`). An instance's parameters are not written, said once a kind.
//!
//! Contents:
//! - `pub fn write(w: *Writer, m: *const Modules, title: []const u8,
//!   stmts: []const ir.Stmt) Writer.Error!void`

const std = @import("std");
const grammar = @import("grammar");
const ir = @import("ir");
const blocks = @import("blocks.zig");
const output = @import("output.zig");
const statement = @import("statement.zig");
const emit = @import("emit.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Modules = grammar.Modules;
const Writer = statement.Writer;
const Error = Writer.Error;

/// What the instances of a module do with a port, a bit each.
const in_bit: u8 = 1;
const out_bit: u8 = 2;
const inout_bit: u8 = 4;

/// A subcircuit, its ports, and what is known of what each is for;
/// `given`: its `dirs` say, and win over what its instances do.
const Def = struct { st: *const ir.Stmt, ports: []const []const u8, uses: []u8, given: bool };

const Pair = [2][]const u8;

const M = struct {
    w: *Writer,
    m: *const Modules,
    a: Allocator,
    defs: []Def,
    /// The kinds whose parameters were said to be left out.
    told: [2]bool = .{ false, false },
};

/// Write `stmts`, the netlist, as modules: the top level (named by the
/// first word of `title`, else `top`), each subcircuit, then the text of
/// each leaf module the netlist gives (`verilog.code`), once a module.
pub fn write(w: *Writer, m: *const Modules, title: []const u8, stmts: []const ir.Stmt) Error!void {
    const a = w.arena;
    var defs: std.ArrayList(Def) = .empty;
    try collect(a, stmts, &defs);
    var x: M = .{ .w = w, .m = m, .a = a, .defs = defs.items };
    directions(&x);
    var first = std.mem.tokenizeAny(u8, title, " \t");
    const top = try topPorts(a, stmts);
    try module(&x, first.next() orelse "top", top.ports, top.uses, stmts);
    for (x.defs) |d| try module(&x, text(d.st.get("name")), d.ports, d.uses, d.st.body);
    var seen: std.ArrayList([]const u8) = .empty;
    try leaves(&x, stmts, &seen);
}

// ---- private ----

/// The top level's ports, from its `ports` statement (the last, where
/// several), with what its `dirs` say; none without one.
fn topPorts(a: Allocator, stmts: []const ir.Stmt) Allocator.Error!struct {
    ports: []const []const u8,
    uses: []const u8,
} {
    var ports: []const []const u8 = &.{};
    var uses: []u8 = &.{};
    for (stmts) |*st| {
        if (st.kind != .ports) continue;
        ports = try words(a, st.get("nodes"));
        const dirs = try words(a, st.get("dirs"));
        uses = try a.alloc(u8, ports.len);
        for (uses, 0..) |*u, i| u.* = if (i < dirs.len) bitOf(dirs[i]) else 0;
    }
    return .{ .ports = ports, .uses = uses };
}

// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
fn collect(a: Allocator, stmts: []const ir.Stmt, defs: *std.ArrayList(Def)) Allocator.Error!void {
    for (stmts) |*st| {
        if (st.kind == .subckt) {
            const ports = try words(a, st.get("ports"));
            const uses = try a.alloc(u8, ports.len);
            @memset(uses, 0);
            const dirs = try words(a, st.get("dirs"));
            const given = dirs.len == ports.len and dirs.len > 0;
            if (given) for (uses, dirs) |*u, d| {
                u.* = bitOf(d);
            };
            try defs.append(a, .{ .st = st, .ports = ports, .uses = uses, .given = given });
        }
        try collect(a, st.body, defs);
    }
}

/// The texts of a list of names; a value that is none is "".
fn words(a: Allocator, v: ir.Value) Allocator.Error![]const []const u8 {
    const items: []const ir.Value = switch (v) {
        .list => |l| l,
        .none => &.{},
        else => &.{v},
    };
    const out = try a.alloc([]const u8, items.len);
    for (out, items) |*o, it| o.* = text(it);
    return out;
}

fn text(v: ir.Value) []const u8 {
    return switch (v) {
        .atom, .str => |t| t,
        else => "",
    };
}

/// The direction word a port's uses give it: driven inside, an output;
/// only read, an input; else (both ways, or nothing says) an inout.
fn dirOf(m: *const Modules, uses: u8) []const u8 {
    if (uses & inout_bit != 0 or uses == 0) return m.dirs[2];
    return if (uses & out_bit != 0) m.dirs[1] else m.dirs[0];
}

fn bitOf(dir: []const u8) u8 {
    if (std.ascii.eqlIgnoreCase(dir, "in")) return in_bit;
    if (std.ascii.eqlIgnoreCase(dir, "out")) return out_bit;
    return inout_bit;
}

/// `name` as it may be written: itself, or between the escapes.
fn ident(x: *const M, name: []const u8) Allocator.Error![]const u8 {
    const m = x.m;
    const plain = name.len > 0 and inClass(m.first, name[0]) and for (name[1..]) |ch| {
        if (!inClass(m.rest, ch)) break false;
    } else true;
    if (plain) return name;
    return std.mem.concat(x.a, u8, &.{ m.escape_open, name, m.escape_close });
}

/// Is `ch` in `class`, characters and ranges `a-z`?
fn inClass(class: []const u8, ch: u8) bool {
    var i: usize = 0;
    while (i < class.len) : (i += 1) {
        if (i + 2 < class.len and class[i + 1] == '-') {
            if (ch >= class[i] and ch <= class[i + 2]) return true;
            i += 2;
        } else if (class[i] == ch) return true;
    }
    return false;
}

/// `template` with each `{key}` of `with` replaced by its text.
fn fill(a: Allocator, template: []const u8, with: []const Pair) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = template;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse break;
        try out.appendSlice(a, rest[0..open]);
        const key = rest[open + 1 .. close];
        for (with) |kv| {
            if (std.mem.eql(u8, kv[0], key)) break try out.appendSlice(a, kv[1]);
        } else try out.appendSlice(a, rest[open .. close + 1]);
        rest = rest[close + 1 ..];
    }
    try out.appendSlice(a, rest);
    return out.items;
}

/// `items` joined by the grammar's `join`.
fn joined(x: *const M, items: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |it, i| {
        if (i > 0) try out.appendSlice(x.a, x.m.join);
        try out.appendSlice(x.a, it);
    }
    return out.items;
}

/// The definition an instance names, by its exact name.
fn find(x: *const M, master: []const u8) ?*Def {
    for (x.defs) |*d| if (std.mem.eql(u8, text(d.st.get("name")), master)) return d;
    return null;
}

/// What each subcircuit does with its ports. Each pass learns from the
/// instances one level further down; there are no more levels than
/// subcircuits.
fn directions(x: *M) void {
    for (0..x.defs.len + 1) |_| {
        var news = false;
        for (x.defs) |*d| for (d.st.body) |*st| {
            if (learn(x, d, st)) news = true;
        };
        if (!news) return;
    }
}

/// What `st`, inside `d`, does with `d`'s ports; true where it is news.
fn learn(x: *const M, d: *Def, st: *const ir.Stmt) bool {
    const nodes = st.get("nodes");
    if (nodes != .list or d.given) return false;
    var news = false;
    for (nodes.list, 0..) |n, i| {
        const bits = use(x, st, i);
        if (bits == 0) continue;
        for (d.ports, d.uses) |p, *u| {
            if (!std.mem.eql(u8, p, text(n)) or u.* | bits == u.*) continue;
            u.* |= bits;
            news = true;
        }
    }
    return news;
}

/// What the instance `st` does with its node `i`, as far as known.
fn use(x: *const M, st: *const ir.Stmt, i: usize) u8 {
    switch (st.kind) {
        .verilog => {
            const dirs = st.get("dirs");
            if (dirs != .list or i >= dirs.list.len) return inout_bit;
            return bitOf(text(dirs.list[i]));
        },
        .instance => {
            const d = find(x, text(st.get("master"))) orelse return 0;
            return if (i < d.uses.len) d.uses[i] else 0;
        },
        else => return 0,
    }
}

/// One module: its first line, its ports, its nets, its statements.
fn module(
    x: *M,
    name: []const u8,
    ports: []const []const u8,
    uses: []const u8,
    body: []const ir.Stmt,
) Error!void {
    assert(ports.len == uses.len);
    const m = x.m;
    const a = x.a;
    const said = try a.alloc([]const u8, ports.len);
    for (said, ports) |*s, p| s.* = try ident(x, p);
    try line(x, m.open, &.{ .{ "name", try ident(x, name) }, .{ "ports", try joined(x, said) } });
    for (said, uses) |p, u| try line(x, m.port, &.{ .{ "dir", dirOf(m, u) }, .{ "port", p } });
    for (try nets(x, ports, body)) |n| try line(x, m.net, &.{.{ "net", try ident(x, n) }});
    for (body) |*st| switch (st.kind) {
        .subckt, .ports => {},
        .instance, .verilog => try instance(x, st),
        else => try blocks.stmt(x.w, st),
    };
    try output.line(x.w, m.close);
}

/// The nets the instances of `body` name that are not `ports`, sorted, once each.
fn nets(x: *const M, ports: []const []const u8, body: []const ir.Stmt) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (body) |*st| {
        if (st.kind != .instance and st.kind != .verilog) continue;
        for (try words(x.a, st.get("nodes"))) |n| {
            const port = for (ports) |p| {
                if (std.mem.eql(u8, p, n)) break true;
            } else false;
            if (!port and n.len > 0) try out.append(x.a, n);
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, p: []const u8, q: []const u8) bool {
            return std.mem.lessThan(u8, p, q);
        }
    }.lt);
    var n: usize = 0;
    for (out.items) |it| {
        if (n > 0 and std.mem.eql(u8, out.items[n - 1], it)) continue;
        out.items[n] = it;
        n += 1;
    }
    // Each net once: no more than were met.
    assert(n <= out.items.len);
    return out.items[0..n];
}

/// One instance, its nets by the names of the ports they are on.
fn instance(x: *M, st: *const ir.Stmt) Error!void {
    // `module` writes only these as instances.
    assert(st.kind == .instance or st.kind == .verilog);
    const a = x.a;
    const nodes = try words(a, st.get("nodes"));
    var pins: std.ArrayList([]const u8) = .empty;
    var master = text(st.get("master"));
    if (st.kind == .instance) {
        const d = find(x, master) orelse
            return refuse(x, st, "the subcircuit it instantiates is not in the netlist, " ++
                "so its ports have no names");
        if (d.ports.len != nodes.len)
            return refuse(x, st, "its nodes are not one for each port of its subcircuit");
        for (d.ports, nodes) |p, n| try pins.append(a, try pin(x, p, try ident(x, n)));
    } else {
        const ports = try words(a, st.get("pins"));
        if (ports.len != nodes.len)
            return refuse(x, st, "its pins do not name the port of each node");
        try buses(x, ports, nodes, &pins);
        master = leafName(st);
    }
    paramsLeft(x, st);
    try line(x, x.m.instance, &.{
        .{ "master", try ident(x, master) },
        .{ "name", try ident(x, text(st.get("name"))) },
        .{ "pins", try joined(x, pins.items) },
    });
}

/// The nodes of a leaf by port: a port of several bits joined as a bus.
fn buses(
    x: *const M,
    ports: []const []const u8,
    nodes: []const []const u8,
    pins: *std.ArrayList([]const u8),
) Allocator.Error!void {
    assert(ports.len == nodes.len);
    var i: usize = 0;
    while (i < nodes.len) {
        var j = i + 1;
        while (j < nodes.len and std.mem.eql(u8, ports[j], ports[i])) j += 1;
        const said = try x.a.alloc([]const u8, j - i);
        for (said, nodes[i..j]) |*s, n| s.* = try ident(x, n);
        const net = if (j - i == 1) said[0] else try std.mem.concat(
            x.a,
            u8,
            &.{ x.m.bus_open, try joined(x, said), x.m.bus_close },
        );
        try pins.append(x.a, try pin(x, ports[i], net));
        i = j;
    }
}

fn pin(x: *const M, port: []const u8, net: []const u8) Allocator.Error![]const u8 {
    return fill(x.a, x.m.pin, &.{ .{ "port", try ident(x, port) }, .{ "net", net } });
}

/// The module a leaf instantiates: `module`, else the stem of `file`,
/// else its model.
fn leafName(st: *const ir.Stmt) []const u8 {
    const module_name = text(st.get("module"));
    if (module_name.len > 0) return module_name;
    const file = text(st.get("file"));
    const base = file[if (std.mem.lastIndexOfAny(u8, file, "/\\")) |i| i + 1 else 0..];
    const stem = base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];
    return if (stem.len > 0) stem else text(st.get("master"));
}

/// An instance's parameters are not written: said once a kind, in the
/// words of the grammar's `inert kind params` line.
fn paramsLeft(x: *M, st: *const ir.Stmt) void {
    const v = st.get("params");
    if (v != .params or v.params.len == 0) return;
    const k = @intFromBool(st.kind == .verilog);
    if (x.told[k]) return;
    x.told[k] = true;
    const why = x.w.g.inertReason(st.kind, "params") orelse "";
    x.w.report.add(.info, .loss, st.line, "{s}: parameters are not written: {s}", .{
        @tagName(st.kind), emit.reasonFor(x.a, why, x.w.g.name) catch why,
    });
}

/// An instance that cannot be written: an error, and a comment where it stood.
fn refuse(x: *M, st: *const ir.Stmt, why: []const u8) Error!void {
    const name = text(st.get("name"));
    x.w.report.add(.@"error", .invalid, st.line, "{s} '{s}' cannot be written for {s}: {s}", .{
        @tagName(st.kind), name, x.w.g.name, why,
    });
    try output.comment(x.w, try x.a.print("[sprack] not written: {s} {s}", .{
        @tagName(st.kind), name,
    }));
}

fn line(x: *M, template: []const u8, with: []const Pair) Error!void {
    try output.line(x.w, try fill(x.a, template, with));
}

/// The text of each leaf module the netlist gives, once a module.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
fn leaves(x: *M, stmts: []const ir.Stmt, seen: *std.ArrayList([]const u8)) Error!void {
    for (stmts) |*st| {
        try leaves(x, st.body, seen);
        if (st.kind != .verilog) continue;
        const code = text(st.get("code"));
        const name = leafName(st);
        if (code.len == 0) continue;
        const known = for (seen.items) |s| {
            if (std.mem.eql(u8, s, name)) break true;
        } else false;
        if (known) continue;
        try seen.append(x.a, name);
        try output.line(x.w, std.mem.trimEnd(u8, code, "\n"));
    }
}
