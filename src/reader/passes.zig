//! The passes over a list of statements once it is read: parameters moved
//! back into their slots, bins flattened, segments and forms folded, the
//! analysis a `.measure` measures, moves and merges undone.
//!
//! Contents:
//! - `pub fn bagEntryFor(nodes: []const Node, key: []const u8) ?grammar.BagEntry`
//! - `pub fn rebindParams(g: *const Grammar, arena: Allocator,
//!   stmts: []ir.Stmt) Allocator.Error!void`
//! - `pub fn mergeOptions(arena: Allocator, list: *std.ArrayList(ir.Stmt)) Allocator.Error!void`
//! - `pub fn flattenBins(g: *const Grammar, arena: Allocator, list: *std.ArrayList(ir.Stmt),
//!   report: *ir.Report) Allocator.Error!void`
//! - `pub fn lastAnalysis(list: []const ir.Stmt, before: ?[]const u8) ?[]const u8`
//! - `pub fn measureWith(arena: Allocator, list: []ir.Stmt,
//!   last: ?[]const u8) Allocator.Error!void`
//! - `pub fn normalizeLists(g: *const Grammar, arena: Allocator, stmts: []ir.Stmt,
//!   report: *ir.Report) Allocator.Error![]ir.Stmt`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const expr = @import("expr");
const dialects = @import("dialects");
const alters = @import("alters.zig");
const canon = @import("canon.zig");
const forms = @import("forms.zig");
const assert = std.debug.assert;
const gatherAlters = alters.gatherAlters;
const foldSegments = forms.foldSegments;
const foldForms = forms.foldForms;
const foldModules = forms.foldModules;
const mapModel = canon.mapModel;
const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Node = grammar.Node;
const Value = ir.Value;

// tidy: allow(recursion) bounded by the nesting of a pattern (the grammar parser's max_depth)
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

/// An instance retagged through its model (`v1 (1 0) v type="pulse" ...` where
/// `v` is a model of vsource) still has everything in `params`. Move the keys
/// this dialect's rule for that kind knows into their slots.
// tidy: allow(recursion) bounded by the nesting of bodies, which reading caps at ir.max_depth
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
        assert(kept.items.len <= st.at(pi).params.len);
        try st.set(arena, pi, if (kept.items.len > 0)
            .{ .params = try kept.toOwnedSlice(arena) }
        else
            .none);
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
            assert(j > i);
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
        assert(bins.len > 0);
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

// tidy: allow(recursion) bounded by the nesting of bodies, which reading caps at ir.max_depth
pub fn normalizeLists(
    g: *const Grammar,
    arena: Allocator,
    stmts: []ir.Stmt,
    report: *ir.Report,
) Allocator.Error![]ir.Stmt {
    // Edited in place: a copy of the top-level list would be as large as
    // every statement header in the netlist.
    var list: std.ArrayList(ir.Stmt) = .fromOwnedSlice(stmts);
    assert(list.items.len == stmts.len);
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

// ---- private ----

/// Does the statement say what the rule's `k=slot!` entries require? A
/// Spectre port's `r=` is its z0, a source's `r=` is not.
// tidy: allow(recursion) bounded by the nesting of a pattern (the grammar parser's max_depth)
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
        // The grammar names each slot of a move by its kind's schema.
        assert(mv.to_slot < schema.info(mv.to).slots.len);
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
            assert(from < i);
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

/// A Monte Carlo statement with no body of its own (Xyce `.sampling`)
/// runs every analysis of the netlist.
fn gatherMonteCarlo(arena: Allocator, list: *std.ArrayList(ir.Stmt)) Allocator.Error!void {
    for (list.items) |st| {
        if (st.kind == .montecarlo and st.body.len == 0) break;
    } else return;
    const n = list.items.len;
    var body: std.ArrayList(ir.Stmt) = .empty;
    var i: usize = 0;
    while (i < list.items.len) {
        if (schema.info(list.items[i].kind).class == .analysis and
            list.items[i].kind != .montecarlo and list.items[i].kind != .alter)
        {
            try body.append(arena, list.orderedRemove(i));
        } else i += 1;
    }
    // Every analysis moved, none lost.
    assert(body.items.len + list.items.len == n);
    for (list.items) |*st| {
        if (st.kind == .montecarlo and st.body.len == 0) {
            st.body = try body.toOwnedSlice(arena);
            break;
        }
    }
}

/// A `.measure` that names no analysis (HSPICE) measures the last analysis
/// of the netlist.
fn measureAnalysis(arena: Allocator, list: []ir.Stmt) Allocator.Error!void {
    return measureWith(arena, list, lastAnalysis(list, null));
}
