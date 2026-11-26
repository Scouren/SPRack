//! `.alter`: the statements after each alter as its body, and the analyses
//! written again after one dropped where they are the netlist's own.

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const passes = @import("passes.zig");
const bagEntryFor = passes.bagEntryFor;
const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;

/// `.alter` (HSPICE): every statement after it, up to the next one, is its
/// body. Where analyses run where they stand (`rerun alter`, Spectre), an
/// alter is followed by the analyses again: those that are the netlist's
/// own are dropped, one-change alters (`a1 alter dev=r1 param=r value=2k`)
/// become bodies, and alters with no analysis between them are one.
pub fn gatherAlters(
    g: *const Grammar,
    arena: Allocator,
    list: *std.ArrayList(ir.Stmt),
    report: *ir.Report,
) Allocator.Error!void {
    const at = for (list.items, 0..) |st, i| {
        if (st.kind == .alter) break i;
    } else return;
    if (!g.isRerun(.alter)) {
        if (g.blockOf(.alter) != null) return;
        var out: std.ArrayList(ir.Stmt) = .fromOwnedSlice(
            try arena.dupe(ir.Stmt, list.items[0..at]),
        );
        var i = at;
        while (i < list.items.len) {
            var alt = list.items[i];
            var j = i + 1;
            while (j < list.items.len and list.items[j].kind != .alter) j += 1;
            if (alt.body.len == 0) alt.body = try arena.dupe(ir.Stmt, list.items[i + 1 .. j]);
            try out.append(arena, alt);
            i = j;
        }
        list.* = out;
        return;
    }
    // One change each: the body is the edited copy.
    for (list.items[at..], at..) |*alt, i| {
        if (alt.kind != .alter or alt.get("param") != .atom) continue;
        try alt.own(arena);
        const edit = try oneChange(g, arena, list.items[0..i], alt, report) orelse continue;
        alt.body = try arena.dupe(ir.Stmt, &.{edit});
        for ([_][]const u8{ "dev", "mod", "param", "value" }) |n|
            try alt.set(arena, schema.slotIndex(.alter, n).?, .none);
    }
    var base: std.ArrayList(ir.Stmt) = .empty;
    var rest: std.ArrayList(ir.Stmt) = .empty;
    var alters: std.ArrayList(ir.Stmt) = .empty;
    // Where in `rest` the analyses since the last alter are.
    var run: std.ArrayList(usize) = .empty;
    for (list.items, 0..) |st, i| {
        const analysis = schema.runs(st.kind);
        if (i < at) {
            if (analysis) try base.append(arena, st);
            try rest.append(arena, st);
        } else if (st.kind == .alter) {
            if (alters.items.len > 0 and run.items.len == 0) {
                // No analysis since the last alter: the same rerun.
                const last = &alters.items[alters.items.len - 1];
                last.body = try std.mem.concat(arena, ir.Stmt, &.{ last.body, st.body });
                continue;
            }
            try dropRerun(arena, &rest, &run, base.items, alters.items, report);
            try alters.append(arena, st);
        } else {
            if (analysis) try run.append(arena, rest.items.len);
            try rest.append(arena, st);
        }
    }
    try dropRerun(arena, &rest, &run, base.items, alters.items, report);
    try rest.appendSlice(arena, alters.items);
    list.* = rest;
}

/// The analyses written after an alter: dropped when they are the
/// netlist's own, which every alter reruns.
fn dropRerun(
    arena: Allocator,
    rest: *std.ArrayList(ir.Stmt),
    run: *std.ArrayList(usize),
    base: []const ir.Stmt,
    alters: []const ir.Stmt,
    report: *ir.Report,
) Allocator.Error!void {
    defer run.clearRetainingCapacity();
    if (alters.len == 0) return;
    var got: std.ArrayList(ir.Stmt) = .empty;
    for (run.items) |k| try got.append(arena, rest.items[k]);
    if (ir.looseListEql(got.items, base)) {
        var n = run.items.len;
        while (n > 0) {
            n -= 1;
            _ = rest.orderedRemove(run.items[n]);
        }
        return;
    }
    const alt = alters[alters.len - 1];
    report.add(
        .@"error",
        .invalid,
        alt.line,
        "alter '{s}': the analyses after it are not those of the netlist, which an alter " ++
            "reruns; they are kept as analyses of the netlist",
        .{if (alt.get("name") == .atom) alt.get("name").atom else "?"},
    );
}

/// A one-change alter (`dev=` or `mod=`, `param=`, `value=`) as the
/// statement it changes, edited: an instance or a model card, a parameter,
/// or the temperature.
fn oneChange(
    g: *const Grammar,
    arena: Allocator,
    before: []const ir.Stmt,
    alt: *const ir.Stmt,
    report: *ir.Report,
) Allocator.Error!?ir.Stmt {
    const key = alt.get("param").atom;
    const val = alt.get("value");
    const target: ?[]const u8 = switch (alt.get("dev")) {
        .atom => |a| a,
        else => if (alt.get("mod") == .atom) alt.get("mod").atom else null,
    };
    const name = target orelse {
        var st = try ir.newStmt(arena, if (std.mem.eql(u8, key, "temp"))
            .options
        else
            .param, alt.line);
        if (st.kind == .options) {
            try st.set(arena, schema.slot(.options, "temp"), val);
        } else try st.set(arena, schema.slot(.param, "params"), .{ .params = try arena.dupe(ir.Param, &.{.{ .key = key, .val = val }}) });
        return st;
    };
    // The latest version: an earlier alter's copy, else the netlist's.
    var found: ?ir.Stmt = null;
    for (before) |*st| {
        if (st.kind == .alter) {
            for (st.body) |*b| if (namedAs(b, name)) {
                found = b.*;
            };
        } else if (namedAs(st, name)) found = st.*;
    }
    var st = found orelse {
        report.add(
            .@"error",
            .invalid,
            alt.line,
            "alter: the netlist has no instance or model '{s}'",
            .{name},
        );
        return null;
    };
    try st.own(arena);
    st.body = &.{};
    st.line = alt.line;
    st.tail = "";
    if (st.kind != .model) {
        for (g.rules) |*rule| {
            if (rule.kind != st.kind) continue;
            const e = bagEntryFor(rule.pat, key) orelse continue;
            try st.set(arena, e.slot, val);
            return st;
        }
    }
    const pi = schema.slotOf(st.kind, "params") orelse {
        report.add(
            .@"error",
            .invalid,
            alt.line,
            "alter: {s} '{s}' has no parameter '{s}' here",
            .{ @tagName(st.kind), name, key },
        );
        return null;
    };
    var ps: std.ArrayList(ir.Param) = .empty;
    if (st.at(pi) == .params) try ps.appendSlice(arena, st.at(pi).params);
    for (ps.items) |*p| {
        if (std.mem.eql(u8, p.key, key)) {
            p.val = val;
            break;
        }
    } else try ps.append(arena, .{ .key = key, .val = val });
    try st.set(arena, pi, .{ .params = ps.items });
    return st;
}

fn namedAs(st: *const ir.Stmt, name: []const u8) bool {
    if (st.kind != .model and schema.info(st.kind).class != .device) return false;
    return st.get("name") == .atom and std.mem.eql(u8, st.get("name").atom, name);
}
