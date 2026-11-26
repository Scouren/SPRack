//! Devices and their models: the model a device names decides its kind, as
//! read (`resolveInstances`) and as written (`demoteToInstance`), and a
//! device whose model is of another kind is reported.
//!
//! Contents:
//! - `pub const unlisted_builtin`
//! - `pub fn checkModelKinds(arena: Allocator, nl: *const Netlist, report: *Report,
//!   env: ?*const Env) Allocator.Error!void`
//! - `pub fn collectFamilies(arena: Allocator, stmts: []const Stmt,
//!   out: *std.StringHashMapUnmanaged([]const u8), src: ?[]const u8) Allocator.Error!void`
//! - `pub fn checkKinds(stmts: []const Stmt, models: *const std.StringHashMapUnmanaged(Kind),
//!   names: *const std.StringHashMapUnmanaged([]const u8), report: *Report) Allocator.Error!void`
//! - `pub fn markUnlistedBuiltins(arena: Allocator, nl: *Netlist) Allocator.Error!void`
//! - `pub fn resolveInstances(arena: Allocator, nl: *Netlist,
//!   env: ?*const Env) Allocator.Error!void`
//! - `pub fn binBase(name: []const u8) ?[]const u8`
//! - `pub fn collectModels(arena: Allocator, stmts: []const Stmt,
//!   out: *std.StringHashMapUnmanaged(Kind), subckts: *CaselessSet,
//!   src: ?[]const u8) Allocator.Error!void`
//! - `pub fn sameSlots(a: Kind, b: Kind) bool`
//! - `pub fn retag(arena: Allocator, stmts: []Stmt,
//!   models: *const std.StringHashMapUnmanaged(Kind),
//!   subckts: *const CaselessSet) Allocator.Error!void`
//! - `pub fn demoteToInstance(arena: Allocator, s: *const Stmt) Allocator.Error!?Stmt`

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir.zig");
const Allocator = std.mem.Allocator;
const CaselessSet = ir.CaselessSet;
const Env = ir.Env;
const Kind = ir.Kind;
const Netlist = ir.Netlist;
const Param = ir.Param;
const Report = ir.Report;
const Stmt = ir.Stmt;
const Value = ir.Value;
const newStmt = ir.newStmt;
const putName = ir.putName;
const putValue = ir.putValue;

/// Readers that cannot tell a transistor from a subcircuit call by syntax
/// (Spectre, VACASK) produce `instance`. Where the master is a model declared
/// in the same netlist, retag the instance as the device that model is.
/// The family given to a model whose type the tables do not list, once a
/// lettered device (M, Q, D, ...) is seen to use it: such a model is one of
/// the simulator's own, not a Verilog-A module, and has no known name in
/// any other dialect.
pub const unlisted_builtin = "builtin";

/// A device whose model is declared in the same netlist as a different kind
/// of device (a D line on an NPN model) is a mistake in the source.
pub fn checkModelKinds(
    arena: Allocator,
    nl: *const Netlist,
    report: *Report,
    env: ?*const Env,
) Allocator.Error!void {
    var models: std.StringHashMapUnmanaged(Kind) = .empty;
    if (env) |e| {
        var it = e.models.iterator();
        while (it.next()) |kv| try models.put(arena, kv.key_ptr.*, kv.value_ptr.*);
    }
    var names: std.StringHashMapUnmanaged([]const u8) = .empty;
    var subckts: CaselessSet = .empty;
    try collectModels(arena, nl.stmts, &models, &subckts, null);
    try collectFamilies(arena, nl.stmts, &names, null);
    if (models.count() == 0) return;
    try checkKinds(nl.stmts, &models, &names, report);
}

/// Model name to family. With `src`, a name not in it is copied.
pub fn collectFamilies(
    arena: Allocator,
    stmts: []const Stmt,
    out: *std.StringHashMapUnmanaged([]const u8),
    src: ?[]const u8,
) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .model and s.get("family") == .atom and s.get("name") == .atom) {
            try putValue(out, arena, src, s.get("name").atom, s.get("family").atom);
        }
        try collectFamilies(arena, s.body, out, src);
    }
}

pub fn checkKinds(
    stmts: []const Stmt,
    models: *const std.StringHashMapUnmanaged(Kind),
    names: *const std.StringHashMapUnmanaged([]const u8),
    report: *Report,
) Allocator.Error!void {
    for (stmts) |*s| {
        try checkKinds(s.body, models, names, report);
        if (schema.info(s.kind).class != .device or s.kind == .instance) continue;
        const master = s.get("master");
        if (master != .atom) continue;
        const want = models.get(master.atom) orelse continue;
        if (want == s.kind or want == .device or s.kind == .device) continue;
        report.add(.warning, .invalid, s.line, "'{s}' is a {s} but its model '{s}' is " ++
            "declared as a {s} model", .{
            if (s.get("name") == .atom)
                s.get("name").atom
            else
                "?",
            @tagName(s.kind),
            master.atom,
            names.get(master.atom) orelse "?",
        });
    }
}

pub fn markUnlistedBuiltins(arena: Allocator, nl: *Netlist) Allocator.Error!void {
    var models: std.StringHashMapUnmanaged(*Stmt) = .empty;
    try collectUnlisted(arena, nl.stmts, &models);
    if (models.count() > 0) try markUsers(arena, nl.stmts, &models);
}

pub fn resolveInstances(arena: Allocator, nl: *Netlist, env: ?*const Env) Allocator.Error!void {
    var models: std.StringHashMapUnmanaged(Kind) = .empty;
    var subckts: CaselessSet = .empty;
    if (env) |e| {
        var it = e.models.iterator();
        while (it.next()) |kv| try models.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        var si = e.subckts.keyIterator();
        while (si.next()) |k| try subckts.put(arena, k.*, {});
    }
    try collectModels(arena, nl.stmts, &models, &subckts, null);
    if (models.count() == 0) return;
    try retag(arena, nl.stmts, &models, &subckts);
}

/// `nch` of the model name `nch.12`: SPICE bins a model by numbered
/// cards, and an instance names the base.
pub fn binBase(name: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    if (dot == 0 or dot + 1 == name.len) return null;
    for (name[dot + 1 ..]) |c| if (!std.ascii.isDigit(c)) return null;
    return name[0..dot];
}

/// With `src`, a name not in it is copied (the statements go away).
pub fn collectModels(
    arena: Allocator,
    stmts: []const Stmt,
    out: *std.StringHashMapUnmanaged(Kind),
    subckts: *CaselessSet,
    src: ?[]const u8,
) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .subckt and s.get("name") == .atom)
            try putName(subckts, arena, src, s.get("name").atom);
        if (s.kind == .model) {
            const fam = s.get("family");
            const name = s.get("name");
            var kind: ?Kind = null;
            if (fam == .atom and name == .atom) {
                kind = schema.familyKind(fam.atom);
            } else if (name == .atom and s.get("type") == .atom) {
                // A model type the tables do not know, typically a Verilog-A module.
                kind = .device;
            }
            if (kind) |k| {
                try putValue(out, arena, src, name.atom, k);
                if (binBase(name.atom)) |base| try putValue(out, arena, src, base, k);
            }
        }
        try collectModels(arena, s.body, out, subckts, src);
    }
}

pub fn sameSlots(a: Kind, b: Kind) bool {
    const x = schema.info(a).slots;
    const y = schema.info(b).slots;
    if (x.len != y.len) return false;
    for (x, y) |p, q|
        if (!std.mem.eql(u8, p.name, q.name) or p.ty != q.ty or p.list != q.list) return false;
    return true;
}

pub fn retag(
    arena: Allocator,
    stmts: []Stmt,
    models: *const std.StringHashMapUnmanaged(Kind),
    subckts: *const CaselessSet,
) Allocator.Error!void {
    for (stmts) |*s| {
        try retag(arena, s.body, models, subckts);
        // One element letter, two device kinds told apart by the model
        // (HSPICE writes a MESFET as a J element with a MESFET level).
        if (s.kind != .instance and s.kind != .device and schema.info(s.kind).class == .device) {
            const m = s.get("master");
            const want = if (m == .atom) models.get(m.atom) orelse continue else continue;
            if (want != s.kind and want != .device and sameSlots(s.kind, want)) s.kind = want;
            continue;
        }
        // An instance of a Verilog-A module (ngspice N) whose model is of a
        // family the tables know is that family's device, as an instance is.
        if (s.kind != .instance and s.kind != .device) continue;
        const master = s.get("master");
        // A subcircuit of the name wins over a model of it.
        if (master != .atom or subckts.contains(master.atom)) continue;
        const target = models.get(master.atom) orelse continue;
        if (target == .device) {
            s.kind = .device;
            continue;
        }
        const nodes = s.get("nodes");
        if (nodes != .list) continue;
        const slots = schema.info(target).slots;
        var want: usize = 0;
        for (slots) |sl| want += @intFromBool(sl.ty == .node and !sl.list);
        // A BJT may leave its substrate node off.
        // The substrate, bulk and thermal terminals are optional.
        // A source's port reference is only a balanced port's.
        const least: usize = if (target == .bjt or target == .mosfet)
            3
        else if (target == .vsource or target == .isource) 2 else want;
        const ok = nodes.list.len >= least and nodes.list.len <= want;
        if (!ok) continue;
        var out = try newStmt(arena, target, s.line);
        out.tail = s.tail;
        var buf: [schema.max_slots]Value = @splat(.none);
        const vals = buf[0..slots.len];
        var n: usize = 0;
        for (slots, 0..) |sl, i| {
            if (sl.ty == .node and !sl.list) {
                if (n < nodes.list.len) vals[i] = nodes.list[n];
                n += 1;
            } else if (std.mem.eql(u8, sl.name, "name")) {
                vals[i] = s.get("name");
            } else if (std.mem.eql(u8, sl.name, "master")) {
                vals[i] = master;
            } else if (sl.ty == .params) {
                vals[i] = s.get("params");
            }
        }
        // What a SPICE line says positionally (`D1 a k dmod 2`) an instance
        // line says by name (`area=2`): put it where the device kind keeps it.
        const pi = schema.slotOf(target, "params");
        if (pi != null and vals[pi.?] == .params) {
            var kept: std.ArrayList(Param) = .empty;
            for (vals[pi.?].params) |p| {
                const si = schema.slotIndex(target, p.key);
                if (si != null and slots[si.?].ty == .value and !slots[si.?].list and
                    vals[si.?] == .none and p.val != .none)
                {
                    vals[si.?] = p.val;
                } else try kept.append(arena, p);
            }
            vals[pi.?] = if (kept.items.len > 0)
                .{ .params = try kept.toOwnedSlice(arena) }
            else
                .none;
        }
        try out.pack(arena, vals);
        s.* = out;
    }
}

/// The reverse of `resolveInstances`, for writers whose dialect has no
/// dedicated statement for a device kind: spell it as a generic instance.
/// Returns null when that would lose a value (a resistor's `r`, say).
pub fn demoteToInstance(arena: Allocator, s: *const Stmt) Allocator.Error!?Stmt {
    if (schema.info(s.kind).class != .device or s.kind == .instance) return null;
    if (schema.slotOf(s.kind, "master") == null) return null;
    if (s.kind == .device) {
        var same = s.*;
        same.kind = .instance;
        return same;
    }
    var out = try newStmt(arena, .instance, s.line);
    out.tail = s.tail;
    var buf: [schema.max_slots]Value = @splat(.none);
    const vals = buf[0..schema.info(.instance).slots.len];
    var nodes: std.ArrayList(Value) = .empty;
    var params: std.ArrayList(Param) = .empty;
    var extra: usize = 0;
    for (schema.info(s.kind).slots, 0..) |sl, i| {
        const v = s.at(i);
        if (v == .none) continue;
        if (sl.ty == .node) {
            try nodes.append(arena, v);
        } else if (std.mem.eql(u8, sl.name, "name")) {
            vals[schema.slot(.instance, "name")] = v;
        } else if (std.mem.eql(u8, sl.name, "master")) {
            vals[schema.slot(.instance, "master")] = v;
        } else if (sl.ty == .params) {
            if (v == .params) try params.appendSlice(arena, v.params);
        } else if (sl.ty == .value) {
            // `D1 a k dmod 2` says area positionally; an instance says area=2.
            try params.insert(arena, extra, .{ .key = sl.name, .val = v });
            extra += 1;
        } else return null;
    }
    if (vals[schema.slot(.instance, "master")] == .none) return null;
    vals[schema.slot(.instance, "nodes")] = .{ .list = try nodes.toOwnedSlice(arena) };
    if (params.items.len > 0)
        vals[schema.slot(.instance, "params")] = .{ .params = try params.toOwnedSlice(arena) };
    try out.pack(arena, vals);
    return out;
}

// ---- private ----

fn collectUnlisted(
    arena: Allocator,
    stmts: []Stmt,
    out: *std.StringHashMapUnmanaged(*Stmt),
) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .model and s.get("family") == .none and s.get("type") == .atom and
            s.get("name") == .atom)
        {
            try out.put(arena, s.get("name").atom, s);
        }
        try collectUnlisted(arena, s.body, out);
    }
}

fn markUsers(
    arena: Allocator,
    stmts: []const Stmt,
    models: *const std.StringHashMapUnmanaged(*Stmt),
) Allocator.Error!void {
    for (stmts) |*s| {
        try markUsers(arena, s.body, models);
        if (schema.info(s.kind).class != .device or s.kind == .instance or s.kind == .device)
            continue;
        const master = s.get("master");
        if (master != .atom) continue;
        const m = models.get(master.atom) orelse continue;
        try m.set(arena, schema.slot(.model, "family"), .{ .atom = unlisted_builtin });
    }
}
