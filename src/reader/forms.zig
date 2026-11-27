//! Forms one dialect has for what the schema says another way, folded into
//! the canonical slots: HSPICE's multi-segment `.tran`, `.sn tres= period=`,
//! a Monte Carlo `list(...)` of trials, a percent glued to its number, and
//! Xyce's `Yr3_cmc` modules.
//!
//! Contents:
//! - `pub fn foldSegments(arena: Allocator, list: []ir.Stmt,
//!   report: *ir.Report) Allocator.Error!void`
//! - `pub fn foldModules(arena: Allocator, list: []ir.Stmt,
//!   all: []const ir.Stmt) Allocator.Error!void`
//! - `pub fn foldForms(arena: Allocator, list: []ir.Stmt, report: *ir.Report) Allocator.Error!void`

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Value = ir.Value;

/// A multi-segment `.tran tstep1 tstop1 tstep2 tstop2 ...` (HSPICE) runs to
/// the last stop. No other dialect has segments, so it is read as one run to
/// that stop at the smallest step. Numbers after the first pair that do not
/// rise are SPICE's start time and step ceiling: HSPICE reads the first
/// (measured: `.tran 1n 100n 90n` outputs from 90n, `.tran 1n 10n 0 1n`
/// stops at 10n, `.tran 1n 10n 2n 20n` at 20n) and takes the second as
/// nothing.
pub fn foldSegments(arena: Allocator, list: []ir.Stmt, report: *ir.Report) Allocator.Error!void {
    const seg = schema.slot(.tran, "segments");
    for (list) |*st| {
        if (st.kind != .tran or st.at(seg) != .list) continue;
        try foldTran(arena, st, report);
    }
}

/// Forms one dialect has for what the schema says another way, folded into
/// the canonical slots (bodies too):
///  - HSPICE `.sn tres= period=`: fund is 1/period and harms round(period/tres)
///    (the HSPICE quick reference: `.SN TONE=F1 NHARMS=Round(PERIOD/TRES)`).
///  - A Monte Carlo count written as `list(2 5)` (HSPICE `monte=list(...)`,
///    one value to its lexer): the trials so numbered.
/// Xyce's `Yr3_cmc n1 ...`: the module without its letter, and none at all
/// where the model card the instance names says it.
// tidy: allow(recursion) bounded by the nesting of bodies, which reading caps at ir.max_depth
pub fn foldModules(arena: Allocator, list: []ir.Stmt, all: []const ir.Stmt) Allocator.Error!void {
    const mi = schema.slot(.device, "module");
    for (list) |*st| {
        if (st.body.len > 0) try foldModules(arena, @constCast(st.body), all);
        if (st.kind != .device or st.at(mi) != .atom) continue;
        var m = st.at(mi).atom;
        if (m.len > 1 and (m[0] == 'y' or m[0] == 'Y')) m = m[1..];
        const master = if (st.get("master") == .atom) st.get("master").atom else "";
        const said = modelType(all, master);
        try st.set(arena, mi, if (said != null and std.ascii.eqlIgnoreCase(said.?, m))
            .none
        else
            Value{ .atom = m });
    }
}

// tidy: allow(recursion) bounded by the nesting of bodies, which reading caps at ir.max_depth
pub fn foldForms(arena: Allocator, list: []ir.Stmt, report: *ir.Report) Allocator.Error!void {
    for (list) |*st| {
        if (st.body.len > 0) try foldForms(arena, @constCast(st.body), report);
        switch (st.kind) {
            .pss => try foldPeriod(arena, st),
            .montecarlo => try foldTrials(arena, st, report),
            .vary => try foldPercent(arena, st),
            else => {},
        }
    }
}

// ---- private ----

/// The segments of one `.tran`, folded.
fn foldTran(arena: Allocator, st: *ir.Stmt, report: *ir.Report) Allocator.Error!void {
    const seg = schema.slot(.tran, "segments");
    const si = schema.slot(.tran, "step");
    const ti = schema.slot(.tran, "stop");
    assert(st.kind == .tran);
    var items = st.at(seg).list;
    try st.set(arena, seg, .none);
    // The pairs take a trailing UIC with them.
    const last: []const u8 = if (items.len == 0) "" else switch (items[items.len - 1]) {
        .atom, .expr, .str => |x| x,
        else => "",
    };
    if (std.ascii.eqlIgnoreCase(last, "uic")) {
        items = items[0 .. items.len - 1];
        try st.set(arena, schema.slot(.tran, "skip_dc"), .{ .atom = "yes" });
    }
    if (!rising(st.at(ti), items)) return startAndCeiling(arena, st, items, report);
    var step = st.at(si);
    if (step != .num) {
        report.add(
            .@"error",
            .invalid,
            st.line,
            "tran: a multi-segment .tran with an expression in it has no smallest step to " ++
                "run at",
            .{},
        );
        return;
    }
    var k: usize = 0;
    while (k < items.len) : (k += 2) {
        if (items[k].num.toFloat() < step.num.toFloat()) step = items[k];
    }
    try st.set(arena, si, step);
    try st.set(arena, ti, items[items.len - 1]);
    report.add(
        .warning,
        .caveat,
        st.line,
        "tran: a multi-segment .tran is one run to its last stop at its smallest step; " ++
            "the output is no longer sampled per segment",
        .{},
    );
}

/// Do the numbers after the step and stop make rising step and stop pairs?
fn rising(stop0: Value, items: []const Value) bool {
    return items.len >= 2 and items.len % 2 == 0 and for (0..items.len / 2) |k| {
        const prev = if (k == 0) stop0 else items[2 * k - 1];
        const step = items[2 * k];
        const stop = items[2 * k + 1];
        if (prev != .num or step != .num or stop != .num or
            stop.num.toFloat() <= prev.num.toFloat())
            break false;
    } else true;
}

/// Numbers after the step and stop that are no segments: a start time and
/// a step ceiling, HSPICE taking the first and not the second.
fn startAndCeiling(
    arena: Allocator,
    st: *ir.Stmt,
    items: []const Value,
    report: *ir.Report,
) Allocator.Error!void {
    assert(st.kind == .tran);
    if (items.len > 2) {
        report.add(
            .@"error",
            .invalid,
            st.line,
            "tran: {d} numbers after the step and stop are neither rising step and " ++
                "stop pairs nor a start time and a step ceiling",
            .{items.len},
        );
        return;
    }
    if (items.len > 0) try st.set(arena, schema.slot(.tran, "start"), items[0]);
    // Measured (docs/verification.md 4.18): the same samples with
    // and without it; `.option delmax` is what caps the step.
    if (items.len > 1)
        report.add(
            .info,
            .caveat,
            st.line,
            "tran: HSPICE takes a fourth .TRAN number that is no second segment as " ++
                "nothing (its step cap is .OPTION DELMAX), so it is left out",
            .{},
        );
}

// tidy: allow(recursion) bounded by the nesting of bodies, which reading caps at ir.max_depth
fn modelType(stmts: []const ir.Stmt, name: []const u8) ?[]const u8 {
    for (stmts) |*s| {
        if (s.kind == .model and s.get("name") == .atom and std.ascii.eqlIgnoreCase(
            s.get("name").atom,
            name,
        ) and s.get("type") == .atom) return s.get("type").atom;
        if (modelType(s.body, name)) |t| return t;
    }
    return null;
}

fn numText(arena: Allocator, v: Value) Allocator.Error![]const u8 {
    return switch (v) {
        .num => |n| try std.fmt.allocPrint(arena, "{s}e{d}", .{ n.digits(), n.exp10 }),
        .expr, .atom, .str => |x| x,
        else => "0",
    };
}

fn floatNum(arena: Allocator, f: f64) Allocator.Error!Value {
    return .{ .num = ir.Number.init(try std.fmt.allocPrint(arena, "{d}", .{f}), 0) };
}

fn foldPeriod(arena: Allocator, st: *ir.Stmt) Allocator.Error!void {
    assert(st.kind == .pss);
    const pi = schema.slot(.pss, "period");
    const ri = schema.slot(.pss, "tres");
    const period = st.at(pi);
    const tres = st.at(ri);
    if (period == .none) return;
    try st.set(arena, pi, .none);
    try st.set(arena, ri, .none);
    const fi = schema.slot(.pss, "fund");
    const hi = schema.slot(.pss, "harms");
    if (period == .num) {
        try st.set(arena, fi, try floatNum(arena, 1.0 / period.num.toFloat()));
    } else try st.set(arena, fi, .{
        .expr = try std.fmt.allocPrint(arena, "1/({s})", .{try numText(arena, period)}),
    });
    if (tres == .none) return;
    if (period == .num and tres == .num) {
        try st.set(
            arena,
            hi,
            try floatNum(arena, @round(period.num.toFloat() / tres.num.toFloat())),
        );
    } else try st.set(arena, hi, .{ .expr = try std.fmt.allocPrint(
        arena,
        "nint(({s})/({s}))",
        .{ try numText(arena, period), try numText(arena, tres) },
    ) });
}

/// HSPICE `is=10%`, the percent glued to the number: as `is=10 %`.
fn foldPercent(arena: Allocator, st: *ir.Stmt) Allocator.Error!void {
    const si = schema.slot(.vary, "std");
    const v = st.at(si);
    const t: []const u8 = switch (v) {
        .expr, .atom => |x| std.mem.trim(u8, x, " "),
        else => return,
    };
    if (t.len < 2 or t[t.len - 1] != '%') return;
    const digits = std.mem.trim(u8, t[0 .. t.len - 1], " ");
    _ = std.fmt.parseFloat(f64, digits) catch return;
    try st.set(arena, si, .{ .num = ir.Number.init(digits, 0) });
    try st.set(arena, schema.slot(.vary, "rel"), .{ .atom = "yes" });
}

fn foldTrials(arena: Allocator, st: *ir.Stmt, report: *ir.Report) Allocator.Error!void {
    assert(st.kind == .montecarlo);
    const ri = schema.slot(.montecarlo, "runs");
    const v = st.at(ri);
    if (v != .expr) return;
    const e = std.mem.trim(u8, v.expr, " ");
    if (e.len < 6 or !std.ascii.startsWithIgnoreCase(e, "list(") or e[e.len - 1] != ')') return;
    var items: std.ArrayList(Value) = .empty;
    var it = std.mem.tokenizeAny(u8, e[5 .. e.len - 1], " ,");
    while (it.next()) |w| {
        const n = std.fmt.parseInt(u32, w, 10) catch {
            report.add(
                .@"error",
                .invalid,
                st.line,
                "montecarlo: '{s}' in {s} is not a run number",
                .{ w, e },
            );
            return;
        };
        _ = n;
        try items.append(arena, .{ .num = ir.Number.init(w, 0) });
    }
    if (items.items.len == 0) return;
    try st.set(arena, ri, .none);
    try st.set(arena, schema.slot(.montecarlo, "trials"), .{ .list = items.items });
}
