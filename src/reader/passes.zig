//! The passes over a list of statements once it is read: parameters moved
//! back into their slots, bins flattened, segments and forms folded, the
//! analysis a `.measure` measures, moves and merges undone.

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const expr = @import("expr");
const dialects = @import("dialects");
const alters = @import("alters.zig");
const canon = @import("canon.zig");
const gatherAlters = alters.gatherAlters;
const mapModel = canon.mapModel;
const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Node = grammar.Node;
const Value = ir.Value;

pub fn bagEntryFor(nodes: []const Node, key: []const u8) ?grammar.BagEntry {
    for (nodes) |n| {
        if (n.tag == .bag) {
            for (n.bag) |e| {
                if ((e.form == .plain or e.form == .quoted) and e.tag_slot == grammar.no_slot and
                    std.mem.eql(
                        u8,
                        e.key,
                        key,
                    )) return e;
            }
        }
        if (bagEntryFor(n.kids, key)) |e| return e;
    }
    return null;
}

/// Does the statement say what the rule's `k=slot!` entries require? A
/// Spectre port's `r=` is its z0, a source's `r=` is not.
fn requiredMet(nodes: []const Node, st: *const ir.Stmt, params: []const ir.Param) bool {
    for (nodes) |n| {
        if (n.tag == .bag) for (n.bag) |e| {
            if (!e.required or st.at(e.slot) != .none) continue;
            for (params) |p| {
                if (std.mem.eql(u8, p.key, e.key)) break;
            } else return false;
        };
        if (!requiredMet(n.kids, st, params)) return false;
    }
    return true;
}

/// An instance retagged through its model (`v1 (1 0) v type="pulse" ...` where
/// `v` is a model of vsource) still has everything in `params`. Move the keys
/// this dialect's rule for that kind knows into their slots.
pub fn rebindParams(g: *const Grammar, arena: Allocator, stmts: []ir.Stmt) Allocator.Error!void {
    for (stmts) |*st| {
        try rebindParams(g, arena, st.body);
        if (schema.info(st.kind).class != .device or st.kind == .instance) continue;
        const pi = schema.slotOf(st.kind, "params") orelse continue;
        if (st.at(pi) != .params) continue;
        var kept: std.ArrayList(ir.Param) = .empty;
        for (st.at(pi).params) |p| {
            const entry = for (g.rules) |*rule| {
                if (rule.kind != st.kind or !requiredMet(rule.pat, st, st.at(pi).params)) continue;
                if (bagEntryFor(rule.pat, p.key)) |e| break e;
            } else null;
            const e = entry orelse {
                try kept.append(arena, p);
                continue;
            };
            if (st.at(e.slot) != .none) {
                try kept.append(arena, p);
                continue;
            }
            const want_atom = schema.info(st.kind).slots[e.slot].ty == .atom;
            try st.set(arena, e.slot, switch (p.val) {
                .expr => |x| if (want_atom) Value{ .atom = x } else p.val,
                .str => |x| if (want_atom) Value{ .atom = x } else p.val,
                else => p.val,
            });
        }
        try st.set(arena, pi, if (kept.items.len > 0)
            .{ .params = try kept.toOwnedSlice(arena) }
        else
            .none);
    }
}

fn isBound(v: Value) bool {
    return switch (v) {
        .none => false,
        .list => |l| l.len > 0,
        .params => |p| p.len > 0,
        else => true,
    };
}

/// A `move a.x -> b.y` in the grammar says where this dialect writes the
/// value. Reading puts it back where the canonical IR keeps it.
fn undoMoves(
    g: *const Grammar,
    arena: Allocator,
    list: *std.ArrayList(ir.Stmt),
    report: *ir.Report,
) Allocator.Error!void {
    for (g.moves) |mv| {
        if (mv.oneway) continue;
        var i: usize = 0;
        while (i < list.items.len) : (i += 1) {
            const st = &list.items[i];
            if (st.kind != mv.to or !isBound(st.at(mv.to_slot))) continue;
            const v = st.at(mv.to_slot);
            try st.set(arena, mv.to_slot, .none);
            const home = for (list.items) |*h| {
                if (h.kind == mv.from) break h;
            } else blk: {
                try list.insert(arena, i, try ir.newStmt(arena, mv.from, list.items[i].line));
                i += 1;
                break :blk &list.items[i - 1];
            };
            if (isBound(home.at(mv.from_slot)) and !home.at(mv.from_slot).eql(v)) {
                report.add(.warning, .caveat, list.items[i].line, "{s}.{s} is given more than " ++
                    "once with different values; the first is kept", .{
                    @tagName(mv.to), schema.info(mv.to).slots[mv.to_slot].name,
                });
                continue;
            }
            try home.set(arena, mv.from_slot, v);
        }
    }
}

/// A `merge a -> b` in the grammar: this dialect writes one statement as
/// two (HSPICE noise is `.ac` plus `.noise`). Reading makes them one again.
fn undoMerges(
    g: *const Grammar,
    arena: Allocator,
    list: *std.ArrayList(ir.Stmt),
) Allocator.Error!void {
    for (g.merges) |mg| {
        var i: usize = 0;
        while (i < list.items.len) : (i += 1) {
            if (list.items[i].kind != mg.into) continue;
            var j = i;
            const from = while (j > 0) {
                j -= 1;
                if (list.items[j].kind == mg.from) break j;
            } else continue;
            const src = list.items[from];
            const dst = &list.items[i];
            for (schema.info(mg.into).slots, 0..) |sl, k| {
                if (isBound(dst.at(k))) continue;
                const fk = schema.slotIndex(mg.from, sl.name) orelse continue;
                try dst.set(arena, k, src.at(fk));
            }
            // Only comments between: the two lines were one statement.
            // Unless the first says what the second has no slot for (an
            // .AC list of frequencies before an .LSTB): then it stays an
            // analysis of its own, so nothing is dropped.
            const fits = for (schema.info(mg.from).slots, 0..) |sl, k| {
                if (!isBound(src.at(k)) or std.mem.eql(u8, sl.name, "name")) continue;
                const dk = schema.slotIndex(mg.into, sl.name) orelse break false;
                if (!dst.at(dk).eql(src.at(k))) break false;
            } else true;
            const adjacent = fits and for (list.items[from + 1 .. i]) |st| {
                if (st.kind != .comment) break false;
            } else true;
            if (!adjacent) continue;
            if (dst.tail.len == 0) {
                dst.tail = src.tail;
                _ = list.orderedRemove(from);
            } else if (src.tail.len > 0) {
                list.items[from] = .{ .kind = .comment, .raw = src.tail, .line = src.line };
                continue;
            } else _ = list.orderedRemove(from);
            i -= 1;
        }
    }
}

/// Several option statements under one heading are one set of options.
pub fn mergeOptions(arena: Allocator, list: *std.ArrayList(ir.Stmt)) Allocator.Error!void {
    const package = schema.slot(.options, "package");
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        if (list.items[i].kind != .options) continue;
        var j = i + 1;
        while (j < list.items.len) {
            const b = list.items[j];
            if (b.kind != .options or !list.items[i].at(package).eql(b.at(package))) {
                j += 1;
                continue;
            }
            const a = &list.items[i];
            for (schema.info(.options).slots, 0..) |sl, k| {
                if (!isBound(b.at(k))) continue;
                if (sl.ty == .params and a.at(k) == .params) {
                    try a.set(
                        arena,
                        k,
                        .{
                            .params = try std.mem.concat(
                                arena,
                                ir.Param,
                                &.{ a.at(k).params, b.at(k).params },
                            ),
                        },
                    );
                } else try a.set(arena, k, b.at(k)); // a later option overrides an earlier one
            }
            if (a.tail.len == 0) a.tail = b.tail;
            _ = list.orderedRemove(j);
        }
    }
}

/// A binned model block (`model nch bsim4 { 1: ... }`) is the model cards
/// `nch.1`, `nch.2`, ... of the SPICE dialects, each with the block's type.
pub fn flattenBins(
    g: *const Grammar,
    arena: Allocator,
    list: *std.ArrayList(ir.Stmt),
    report: *ir.Report,
) Allocator.Error!void {
    const ni = schema.slot(.model, "name");
    const ti = schema.slot(.model, "type");
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        const parent = list.items[i];
        if (parent.kind != .model or parent.body.len == 0) continue;
        const bins = parent.body;
        for (bins) |*bin| {
            if (bin.kind != .model or bin.get("name") != .atom) continue;
            const label = std.mem.trimEnd(u8, bin.get("name").atom, ":");
            try bin.set(
                arena,
                ni,
                .{
                    .atom = try std.fmt.allocPrint(
                        arena,
                        "{s}.{s}",
                        .{ parent.get("name").atom, label },
                    ),
                },
            );
            try bin.set(arena, ti, parent.at(ti));
            try mapModel(arena, g, bin, report);
        }
        _ = list.orderedRemove(i);
        try list.insertSlice(arena, i, bins);
        i += bins.len - 1;
    }
}

/// A Monte Carlo statement with no body of its own (Xyce `.sampling`)
/// runs every analysis of the netlist.
fn gatherMonteCarlo(arena: Allocator, list: *std.ArrayList(ir.Stmt)) Allocator.Error!void {
    for (list.items) |st| {
        if (st.kind == .montecarlo and st.body.len == 0) break;
    } else return;
    var body: std.ArrayList(ir.Stmt) = .empty;
    var i: usize = 0;
    while (i < list.items.len) {
        if (schema.info(list.items[i].kind).class == .analysis and
            list.items[i].kind != .montecarlo and list.items[i].kind != .alter)
        {
            try body.append(arena, list.orderedRemove(i));
        } else i += 1;
    }
    for (list.items) |*st| {
        if (st.kind == .montecarlo and st.body.len == 0) {
            st.body = try body.toOwnedSlice(arena);
            break;
        }
    }
}

/// A multi-segment `.tran tstep1 tstop1 tstep2 tstop2 ...` (HSPICE) runs to
/// the last stop. No other dialect has segments, so it is read as one run to
/// that stop at the smallest step. Numbers after the first pair that do not
/// rise are SPICE's start time and step ceiling: HSPICE reads the first
/// (measured: `.tran 1n 100n 90n` outputs from 90n, `.tran 1n 10n 0 1n`
/// stops at 10n, `.tran 1n 10n 2n 20n` at 20n) and takes the second as
/// nothing.
pub fn foldSegments(arena: Allocator, list: []ir.Stmt, report: *ir.Report) Allocator.Error!void {
    const seg = schema.slot(.tran, "segments");
    const si = schema.slot(.tran, "step");
    const ti = schema.slot(.tran, "stop");
    for (list) |*st| {
        if (st.kind != .tran or st.at(seg) != .list) continue;
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
        const rises = items.len >= 2 and items.len % 2 == 0 and for (0..items.len / 2) |k| {
            const prev = if (k == 0) st.at(ti) else items[2 * k - 1];
            const step = items[2 * k];
            const stop = items[2 * k + 1];
            if (prev != .num or step != .num or stop != .num or
                stop.num.toFloat() <= prev.num.toFloat())
                break false;
        } else true;
        if (!rises) {
            if (items.len > 2) {
                report.add(
                    .@"error",
                    .invalid,
                    st.line,
                    "tran: {d} numbers after the step and stop are neither rising step and " ++
                        "stop pairs nor a start time and a step ceiling",
                    .{items.len},
                );
                continue;
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
            continue;
        }
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
            continue;
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
}

/// Forms one dialect has for what the schema says another way, folded into
/// the canonical slots (bodies too):
///  - HSPICE `.sn tres= period=`: fund is 1/period and harms round(period/tres)
///    (the HSPICE quick reference: `.SN TONE=F1 NHARMS=Round(PERIOD/TRES)`).
///  - A Monte Carlo count written as `list(2 5)` (HSPICE `monte=list(...)`,
///    one value to its lexer): the trials so numbered.
/// Xyce's `Yr3_cmc n1 ...`: the module without its letter, and none at all
/// where the model card the instance names says it.
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
    } else try st.set(arena, fi, .{ .expr = try std.fmt.allocPrint(arena, "1/({s})", .{try numText(arena, period)}) });
    if (tres == .none) return;
    if (period == .num and tres == .num) {
        try st.set(
            arena,
            hi,
            try floatNum(arena, @round(period.num.toFloat() / tres.num.toFloat())),
        );
    } else try st.set(arena, hi, .{ .expr = try std.fmt.allocPrint(arena, "nint(({s})/({s}))", .{ try numText(arena, period), try numText(arena, tres) }) });
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

/// A `.measure` that names no analysis (HSPICE) measures the last analysis
/// of the netlist.
fn measureAnalysis(arena: Allocator, list: []ir.Stmt) Allocator.Error!void {
    return measureWith(arena, list, lastAnalysis(list, null));
}

/// The last analysis a `.measure` may measure, of `list` and after `before`.
pub fn lastAnalysis(list: []const ir.Stmt, before: ?[]const u8) ?[]const u8 {
    var last = before;
    for (list) |st| switch (st.kind) {
        .tran, .ac, .dc => last = @tagName(st.kind),
        else => {},
    };
    return last;
}

pub fn measureWith(arena: Allocator, list: []ir.Stmt, last: ?[]const u8) Allocator.Error!void {
    const ai = schema.slot(.measure, "analysis");
    const name = last orelse return;
    for (list) |*st| {
        if (st.kind == .measure and st.at(ai) == .none) try st.set(arena, ai, .{ .atom = name });
    }
}

pub fn normalizeLists(
    g: *const Grammar,
    arena: Allocator,
    stmts: []ir.Stmt,
    report: *ir.Report,
) Allocator.Error![]ir.Stmt {
    // Edited in place: a copy of the top-level list would be as large as
    // every statement header in the netlist.
    var list: std.ArrayList(ir.Stmt) = .fromOwnedSlice(stmts);
    for (list.items) |*st| {
        if (st.body.len > 0) st.body = try normalizeLists(g, arena, st.body, report);
    }
    try flattenBins(g, arena, &list, report);
    try gatherMonteCarlo(arena, &list);
    try foldSegments(arena, list.items, report);
    try foldForms(arena, list.items, report);
    try foldModules(arena, list.items, list.items);
    try measureAnalysis(arena, list.items);
    try gatherAlters(g, arena, &list, report);
    try expr.convertFlat(arena, g, list.items, false);
    try undoMoves(g, arena, &list, report);
    try undoMerges(g, arena, &list);
    try mergeOptions(arena, &list);
    return list.toOwnedSlice(arena);
}
