//! Alter runs, between the ways dialects say them.
//!
//! An `alter` reruns every analysis of the netlist with the edits in its
//! body, on top of those of the alters before it (measured so in HSPICE,
//! Spectre, VACASK and ngspice, `docs/verification.md` 7). Before a netlist
//! is written, `prepare` puts the alters last and, by what the target can
//! say:
//!
//! * a block or a line followed by the edits (Spectre `altergroup`, HSPICE
//!   `.alter`): kept; where analyses run where they stand (`rerun alter`)
//!   the netlist's analyses are written again after each alter;
//! * a rule that names `keys`, `vals` and `temp` (VACASK `alter`, ngspice
//!   `alterparam`): each alter is flattened into parameter changes and the
//!   temperature; anything else in it is an error;
//! * no alter but a `step` over a `data` table (Xyce): one row per run,
//!   parameters and temperature only.

const std = @import("std");
const schema = @import("schema.zig");
const ir = @import("ir.zig");
const grammar = @import("grammar.zig");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Stmt = ir.Stmt;
const Value = ir.Value;
const Param = ir.Param;

pub fn prepare(arena: Allocator, g: *const Grammar, stmts: []const Stmt, report: *ir.Report) Allocator.Error![]const Stmt {
    for (stmts) |s| {
        if (s.kind == .alter) break;
    } else return stmts;
    var rest: std.ArrayList(Stmt) = .empty;
    var alters: std.ArrayList(Stmt) = .empty;
    for (stmts) |s| try (if (s.kind == .alter) &alters else &rest).append(arena, s);
    if (!g.canWrite(.alter)) {
        if (g.canWrite(.step) and g.canWrite(.data)) return dataStep(arena, g, rest.items, alters.items, report);
        // The writer reports each as unsupported; its edits are not the netlist's.
        for (alters.items) |*a| a.body = &.{};
        try rest.appendSlice(arena, alters.items);
        return rest.items;
    }
    if (writesSlot(g, "keys")) {
        var flat: std.ArrayList(Stmt) = .empty;
        // A dialect that reruns nothing by itself runs the netlist first.
        if (!g.isRerun(.alter)) try flat.append(arena, .{ .kind = .alter, .line = alters.items[0].line });
        var temp: Value = .none;
        for (alters.items) |*a| {
            const f = try flatten(arena, g, a, &temp, report) orelse continue;
            try flat.append(arena, f);
        }
        alters = flat;
    } else if (g.blockOf(.alter) != null) {
        try checkNew(arena, g, rest.items, alters.items, report);
    }
    if (g.isRerun(.alter)) {
        var analyses: std.ArrayList(Stmt) = .empty;
        for (rest.items) |s| if (isAnalysis(&s)) try analyses.append(arena, s);
        const name = schema.slotIndex(.alter, "name").?;
        for (alters.items) |a| {
            var head = a;
            // A label is a name in a block dialect; an HSPICE title may be words.
            if (a.at(name) == .atom and !isIdent(a.at(name).atom)) {
                try head.own(arena);
                try head.set(arena, name, .none);
            }
            try rest.append(arena, head);
            for (analyses.items) |s| try rest.append(arena, try unnamed(arena, s));
        }
    } else try rest.appendSlice(arena, alters.items);
    return rest.items;
}

fn isAnalysis(s: *const Stmt) bool {
    return schema.info(s.kind).class == .analysis and s.kind != .alter;
}

fn isIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// A copy of an analysis without its label, so that the rerun gets a name
/// of its own.
fn unnamed(arena: Allocator, s: Stmt) Allocator.Error!Stmt {
    var out = s;
    try out.own(arena);
    out.tail = "";
    if (schema.slotIndex(s.kind, "name")) |i| try out.set(arena, i, .none);
    var body = try arena.alloc(Stmt, s.body.len);
    for (s.body, 0..) |b, i| body[i] = if (isAnalysis(&b)) try unnamed(arena, b) else b;
    out.body = body;
    return out;
}

fn mentions(nodes: []const grammar.Node, slot: u8) bool {
    for (nodes) |n| {
        if (n.slot == slot) return true;
        for (n.bag) |e| if (e.slot == slot or e.slot2 == slot) return true;
        if (mentions(n.kids, slot)) return true;
    }
    return false;
}

fn writesSlot(g: *const Grammar, name: []const u8) bool {
    const slot = schema.slotIndex(.alter, name).?;
    for (g.rules) |*r| if (r.kind == .alter and r.dir != .read and mentions(r.pat, slot)) return true;
    return false;
}

/// ` 'name'`, or nothing for an alter without one: for messages.
fn label(arena: Allocator, a: *const Stmt) Allocator.Error![]const u8 {
    return if (a.get("name") == .atom) arena.print(" '{s}'", .{a.get("name").atom}) else "";
}

/// The parameters an alter changes and the temperature it sets, or the
/// first statement of its body that is neither.
const Edits = struct { params: []const Param, temp: Value, other: ?*const Stmt };

fn edits(arena: Allocator, a: *const Stmt) Allocator.Error!Edits {
    var ps: std.ArrayList(Param) = .empty;
    var temp: Value = .none;
    const ti = schema.slotIndex(.options, "temp").?;
    for (a.body) |*s| switch (s.kind) {
        .comment => {},
        .param => if (s.get("params") == .params) try ps.appendSlice(arena, s.get("params").params),
        .options => {
            for (schema.info(.options).slots, 0..) |sl, i| {
                if (i != ti and s.at(i) != .none and !std.mem.eql(u8, sl.name, "package")) return .{ .params = ps.items, .temp = temp, .other = s };
            }
            if (s.at(ti) != .none) temp = s.at(ti);
        },
        else => return .{ .params = ps.items, .temp = temp, .other = s },
    };
    return .{ .params = ps.items, .temp = temp, .other = null };
}

fn refuse(arena: Allocator, g: *const Grammar, a: *const Stmt, other: *const Stmt, how: []const u8, report: *ir.Report) Allocator.Error!void {
    report.add(.@"error", .unsupported, other.line, "alter{s} cannot be written for {s}: {s} changes only parameters and the temperature, not a {s}", .{
        try label(arena, a), g.name, how, @tagName(other.kind),
    });
}

/// The alter as `keys`/`vals` and the temperature. The temperature is the
/// latest set by any alter so far: ngspice's `reset` forgets it.
fn flatten(arena: Allocator, g: *const Grammar, a: *const Stmt, temp: *Value, report: *ir.Report) Allocator.Error!?Stmt {
    const e = try edits(arena, a);
    if (e.other) |o| {
        try refuse(arena, g, a, o, "the form this grammar writes", report);
        return null;
    }
    if (e.temp != .none) temp.* = e.temp;
    var out: Stmt = .{ .kind = .alter, .line = a.line, .tail = a.tail };
    try out.set(arena, schema.slotIndex(.alter, "name").?, a.get("name"));
    var keys: std.ArrayList(Value) = .empty;
    var vals: std.ArrayList(Value) = .empty;
    for (e.params) |p| {
        try keys.append(arena, .{ .atom = p.key });
        try vals.append(arena, p.val);
    }
    if (keys.items.len > 0) {
        try out.set(arena, schema.slotIndex(.alter, "keys").?, .{ .list = keys.items });
        try out.set(arena, schema.slotIndex(.alter, "vals").?, .{ .list = vals.items });
    }
    try out.set(arena, schema.slotIndex(.alter, "temp").?, temp.*);
    return out;
}

/// An alter block changes instances; it cannot add one (Spectre refuses
/// it), nor an analysis.
fn checkNew(arena: Allocator, g: *const Grammar, rest: []const Stmt, alters: []const Stmt, report: *ir.Report) Allocator.Error!void {
    for (alters) |*a| for (a.body) |*s| {
        if (isAnalysis(s)) report.add(.@"error", .unsupported, s.line, "alter{s}: {s} reruns the netlist's analyses after an alter; one the alter adds has no {s} form", .{ try label(arena, a), g.name, g.name });
        if (schema.info(s.kind).class != .device or s.get("name") != .atom) continue;
        const name = s.get("name").atom;
        const known = for (rest) |*r| {
            if (schema.info(r.kind).class == .device and r.get("name") == .atom and std.ascii.eqlIgnoreCase(r.get("name").atom, name)) break true;
        } else false;
        if (!known) report.add(.@"error", .unsupported, s.line, "alter{s}: {s} '{s}' is not in the netlist, and a {s} alter can only change an instance it has", .{ try label(arena, a), @tagName(s.kind), name, g.name });
    };
}

/// Xyce: a `.data` table with one row for the netlist and one per alter,
/// each with every change so far, and a `.step` over it around the analyses.
fn dataStep(arena: Allocator, g: *const Grammar, rest: []const Stmt, alters: []const Stmt, report: *ir.Report) Allocator.Error![]const Stmt {
    var cols: std.ArrayList([]const u8) = .empty;
    var runs: std.ArrayList(Edits) = .empty;
    var with_temp = false;
    for (alters) |*a| {
        const e = try edits(arena, a);
        if (e.other) |o| {
            try refuse(arena, g, a, o, "the .step over a .data table an alter is written as there", report);
            continue;
        }
        try runs.append(arena, e);
        with_temp = with_temp or e.temp != .none;
        for (e.params) |p| {
            for (cols.items) |c| {
                if (std.ascii.eqlIgnoreCase(c, p.key)) break;
            } else try cols.append(arena, p.key);
        }
    }
    if (runs.items.len == 0) return rest;
    if (cols.items.len == 0 and !with_temp) {
        report.add(.@"error", .unsupported, alters[0].line, "alter: the alters change nothing, and {s} writes alters as the rows of a .data table", .{g.name});
        return rest;
    }
    var row: std.ArrayList(Value) = .empty;
    for (cols.items) |c| try row.append(arena, baseValue(rest, c) orelse {
        report.add(.@"error", .unsupported, alters[0].line, "alter: '{s}' is not a parameter of the netlist, so a {s} .data column cannot change it", .{ c, g.name });
        return rest;
    });
    if (with_temp) {
        const t = baseTemp(rest) orelse blk: {
            report.add(.warning, .caveat, alters[0].line, "alter: the netlist sets no temperature; its run is written at 27 degrees, {s}'s default", .{g.name});
            break :blk Value{ .num = .init("27", 0) };
        };
        try row.append(arena, t);
    }
    var values: std.ArrayList(Value) = .empty;
    try values.appendSlice(arena, row.items);
    for (runs.items) |e| {
        for (e.params) |p| {
            for (cols.items, 0..) |c, i| if (std.ascii.eqlIgnoreCase(c, p.key)) {
                row.items[i] = p.val;
            };
        }
        if (e.temp != .none) row.items[cols.items.len] = e.temp;
        try values.appendSlice(arena, row.items);
    }
    for (values.items) |v| if (v != .num) {
        report.add(.@"error", .unsupported, alters[0].line, "alter: {s} .data rows hold numbers, and a value here is an expression", .{g.name});
        return rest;
    };
    const table = "alters";
    var names: std.ArrayList(Value) = .empty;
    for (cols.items) |c| try names.append(arena, .{ .atom = c });
    if (with_temp) try names.append(arena, .{ .atom = "temp" });
    var data: Stmt = .{ .kind = .data, .line = alters[0].line };
    try data.set(arena, schema.slotIndex(.data, "name").?, .{ .atom = table });
    try data.set(arena, schema.slotIndex(.data, "cols").?, .{ .list = names.items });
    try data.set(arena, schema.slotIndex(.data, "values").?, .{ .list = values.items });
    var step: Stmt = .{ .kind = .step, .line = alters[0].line };
    try step.set(arena, schema.slotIndex(.step, "data").?, .{ .atom = table });
    var body: std.ArrayList(Stmt) = .empty;
    var out: std.ArrayList(Stmt) = .empty;
    var at: ?usize = null;
    for (rest) |s| {
        if (isAnalysis(&s)) {
            if (at == null) at = out.items.len;
            try body.append(arena, s);
        } else try out.append(arena, s);
    }
    step.body = body.items;
    try out.insertSlice(arena, at orelse out.items.len, &.{ data, step });
    report.add(.info, .oneway, alters[0].line, "alter: {s} has no alter; the runs are a .step over the .data table '{s}', one row each, which reads back as a step", .{ g.name, table });
    return out.items;
}

/// The value the netlist gives a parameter, at the top level.
fn baseValue(stmts: []const Stmt, key: []const u8) ?Value {
    var v: ?Value = null;
    for (stmts) |s| {
        if (s.kind != .param or s.get("params") != .params) continue;
        for (s.get("params").params) |p| if (std.ascii.eqlIgnoreCase(p.key, key)) {
            v = p.val;
        };
    }
    return v;
}

fn baseTemp(stmts: []const Stmt) ?Value {
    var v: ?Value = null;
    for (stmts) |s| if (s.kind == .options and s.get("temp") != .none) {
        v = s.get("temp");
    };
    return v;
}
