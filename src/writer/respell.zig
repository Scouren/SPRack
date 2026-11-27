//! Respelled nets: a grammar's `respell` lines say which characters a node
//! of a kind may not hold there, and what each is written as (ngspice cuts
//! a node at `[` and `]` on an XSPICE A line). Such a net is renamed in its
//! whole scope, the top level or a subcircuit with its ports: every
//! statement there that names it as a node, a signal or an initial value.
//! A new name that another net of the scope already has gets `_` after it
//! until it is new. An info note a net.
//!
//! Contents:
//! - `pub fn holds(g: *const Grammar, st: *const ir.Stmt) bool`
//! - `pub fn apply(w: *Writer, stmts: []const ir.Stmt) Writer.Error![]const ir.Stmt`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const statement = @import("statement.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Respell = grammar.Respell;
const Value = ir.Value;
const Writer = statement.Writer;
const Error = Writer.Error;

/// Old name to new, in the order met.
const Map = std.StringArrayHashMapUnmanaged([]const u8);
const Seen = std.StringHashMapUnmanaged(void);

/// Does `st`, a top-level statement, name a net the target respells (in
/// it, or in a block it holds that is no subcircuit)? The top level is
/// then a scope that must be read whole.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn holds(g: *const Grammar, st: *const ir.Stmt) bool {
    for (st.body) |*child| if (child.kind != .subckt and holds(g, child)) return true;
    const r = ruleOf(g, st.kind) orelse return false;
    for (schema.info(st.kind).slots, 0..) |sl, i| {
        if (sl.ty != .node) continue;
        const v = st.at(i);
        for (items(&v)) |it| if (it == .atom and respelled(r, it.atom)) return true;
    }
    return false;
}

/// `stmts`, the top level, with the nets of each scope respelled.
pub fn apply(w: *Writer, stmts: []const ir.Stmt) Error![]const ir.Stmt {
    if (w.g.respells.len == 0) return stmts;
    return scope(w, null, stmts);
}

// ---- private ----

/// The statements of one scope with its nets respelled. `head`, a copy of
/// the subcircuit they are the body of, has its ports respelled too.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
fn scope(w: *Writer, head: ?*ir.Stmt, stmts: []const ir.Stmt) Error![]ir.Stmt {
    const a = w.arena;
    var seen: Seen = .empty;
    if (head) |h| try collect(a, h, &seen);
    try collectAll(a, stmts, &seen);
    var map: Map = .empty;
    try find(w, stmts, &seen, &map);
    if (head) |h| try renameNodes(a, h, &map);
    const out = try a.dupe(ir.Stmt, stmts);
    for (out) |*st| try renameIn(w, st, &map);
    return out;
}

/// `st`, a copy, with the nets of `map` renamed; a subcircuit is a scope
/// of its own.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
fn renameIn(w: *Writer, st: *ir.Stmt, map: *const Map) Error!void {
    const a = w.arena;
    try st.own(a);
    if (st.kind == .subckt) {
        st.body = try scope(w, st, st.body);
        return;
    }
    if (map.count() > 0) try renameNodes(a, st, map);
    if (st.body.len == 0) return;
    const body = try a.dupe(ir.Stmt, st.body);
    for (body) |*child| try renameIn(w, child, map);
    st.body = body;
}

/// Every net `st` names, but those of a subcircuit's body.
fn collect(a: Allocator, st: *const ir.Stmt, seen: *Seen) Allocator.Error!void {
    for (schema.info(st.kind).slots, 0..) |sl, i| {
        if (sl.ty != .node) continue;
        const v = st.at(i);
        for (items(&v)) |it| if (it == .atom) try seen.put(a, it.atom, {});
    }
}

// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
fn collectAll(a: Allocator, stmts: []const ir.Stmt, seen: *Seen) Allocator.Error!void {
    for (stmts) |*st| {
        if (st.kind == .subckt) continue;
        try collect(a, st, seen);
        try collectAll(a, st.body, seen);
    }
}

/// The nets of the scope a statement of a respelled kind names with a
/// character it may not hold, and their new names, each said.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
fn find(w: *Writer, stmts: []const ir.Stmt, seen: *Seen, map: *Map) Error!void {
    const a = w.arena;
    // Every new name is a net of the scope from then on.
    defer assert(seen.count() >= map.count());
    for (stmts) |*st| {
        if (st.kind == .subckt) continue;
        try find(w, st.body, seen, map);
        const r = ruleOf(w.g, st.kind) orelse continue;
        for (schema.info(st.kind).slots, 0..) |sl, i| {
            if (sl.ty != .node) continue;
            const v = st.at(i);
            for (items(&v)) |it| {
                if (it != .atom or !respelled(r, it.atom) or map.contains(it.atom)) continue;
                const new = try fresh(a, try spelled(a, r, it.atom), seen);
                try seen.put(a, new, {});
                try map.put(a, it.atom, new);
                w.report.add(.info, .rename, st.line, "node '{s}' is written '{s}' in {s}, " ++
                    "wherever its scope names it: {s}", .{ it.atom, new, w.g.name, r.reason });
            }
        }
    }
}

/// `name` with `_` after it until no net of the scope has it.
fn fresh(a: Allocator, name: []const u8, seen: *const Seen) Allocator.Error![]const u8 {
    var out = name;
    // Each pass is one longer; there are no more taken names than nets.
    for (0..seen.count() + 1) |_| {
        if (!seen.contains(out)) return out;
        out = try std.mem.concat(a, u8, &.{ out, "_" });
    }
    unreachable;
}

/// The node slots, signals and initial values of `st` under their new names.
fn renameNodes(a: Allocator, st: *ir.Stmt, map: *const Map) Allocator.Error!void {
    for (schema.info(st.kind).slots, 0..) |sl, i| {
        const v = st.at(i);
        const new: ?Value = switch (sl.ty) {
            .node => try mapped(a, v, map, false),
            .signal => try mapped(a, v, map, true),
            // `.ic v(q[0])=0.5`: its keys are the nets.
            .params => if (st.kind == .ic or st.kind == .nodeset)
                try keysMapped(a, v, map)
            else
                null,
            else => null,
        };
        if (new) |n| try st.set(a, i, n);
    }
}

/// `v` with its names (or the arguments of its signals) renamed; null
/// where none is.
fn mapped(a: Allocator, v: Value, map: *const Map, signals: bool) Allocator.Error!?Value {
    if (v != .list) return mappedOne(a, v, map, signals);
    var changed = false;
    const out = try a.alloc(Value, v.list.len);
    for (out, v.list) |*o, it| if (try mappedOne(a, it, map, signals)) |n| {
        o.* = n;
        changed = true;
    } else {
        o.* = it;
    };
    assert(out.len == v.list.len);
    return if (changed) .{ .list = out } else null;
}

fn mappedOne(a: Allocator, v: Value, map: *const Map, signals: bool) Allocator.Error!?Value {
    if (v != .atom) return null;
    const t = v.atom;
    const n = if (signals) try signal(a, t, map) else map.get(t) orelse t;
    return if (n.ptr == t.ptr) null else .{ .atom = n };
}

/// `v(q[0],a)` with each argument `map` names renamed: the same text where
/// none is.
fn signal(a: Allocator, text: []const u8, map: *const Map) Allocator.Error![]const u8 {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return text;
    // A `(` was found: the text is not empty.
    assert(text.len > open);
    if (text[text.len - 1] != ')') return text;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, text[0 .. open + 1]);
    var changed = false;
    var args = std.mem.splitScalar(u8, text[open + 1 .. text.len - 1], ',');
    var first = true;
    while (args.next()) |arg| {
        if (!first) try out.append(a, ',');
        first = false;
        const new = map.get(arg) orelse arg;
        changed = changed or new.ptr != arg.ptr;
        try out.appendSlice(a, new);
    }
    try out.append(a, ')');
    return if (changed) out.items else text;
}

fn keysMapped(a: Allocator, v: Value, map: *const Map) Allocator.Error!?Value {
    if (v != .params) return null;
    const ps = try a.dupe(ir.Param, v.params);
    var changed = false;
    for (ps) |*p| if (map.get(p.key)) |new| {
        p.key = new;
        changed = true;
    };
    return if (changed) .{ .params = ps } else null;
}

fn ruleOf(g: *const Grammar, kind: schema.Kind) ?*const Respell {
    for (g.respells) |*r| if (r.kind == kind) return r;
    return null;
}

/// Does `name` hold a character `r` respells? A name that is one of them
/// alone is the form's own (the `[` of an XSPICE vector), not a net.
fn respelled(r: *const Respell, name: []const u8) bool {
    for (r.pairs) |p| if (std.mem.eql(u8, name, p[0])) return false;
    for (r.pairs) |p| if (std.mem.indexOf(u8, name, p[0]) != null) return true;
    return false;
}

/// `name` with each character `r` names written as it says.
fn spelled(a: Allocator, r: *const Respell, name: []const u8) Allocator.Error![]const u8 {
    assert(respelled(r, name));
    var out = name;
    for (r.pairs) |p| out = try std.mem.replaceOwned(u8, a, out, p[0], p[1]);
    return out;
}

/// The items of a list, or the value alone.
fn items(v: *const Value) []const Value {
    return switch (v.*) {
        .list => |l| l,
        .none => &.{},
        else => v[0..1],
    };
}
