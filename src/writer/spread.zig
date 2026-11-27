//! Sweeps over analyses: a `spread` block's rule written as the end of
//! each analysis it holds, whether the kind's own line says it whole, and
//! the check that a one-line `.step` sweeps every analysis, and a
//! statement said once for each analysis (`each`).
//!
//! Contents:
//! - `pub fn checkSteps(w: *Writer, stmts: []const ir.Stmt) void`
//! - `pub fn spread(w: *Writer, st: *const ir.Stmt) Error!void`
//! - `pub fn fits(w: *Writer, st: *const ir.Stmt) Error!bool`
//! - `pub fn each(w: *Writer, st: *const ir.Stmt) Error!bool`

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir");
const blocks = @import("blocks.zig");
const statement = @import("statement.zig");
const assert = std.debug.assert;
const Writer = statement.Writer;
const Error = Writer.Error;

/// Where a step is one line that sweeps every analysis of the netlist, a
/// step that sweeps only some of them cannot be said.
pub fn checkSteps(w: *Writer, stmts: []const ir.Stmt) void {
    for (w.g.blocks) |b| if (b.kind == .step) return;
    var step: ?*const ir.Stmt = null;
    var outside = false;
    for (stmts) |*s| {
        if (s.kind == .alter) continue;
        if (s.kind != .step) {
            outside = outside or schema.info(s.kind).class == .analysis;
        } else if (step == null) step = s else outside = true;
    }
    const st = step orelse return;
    assert(st.kind == .step);
    // HSPICE's .TEMP list in a deck with no analysis: nothing to repeat.
    if (st.body.len == 0 and !std.mem.eql(u8, w.sourceOf(st), w.g.name))
        w.report.add(
            .@"error",
            .invalid,
            st.line,
            "step: the netlist has no analysis for the {s} sweep to repeat",
            .{w.g.name},
        );
    if (outside and !w.g.isSpread(.step))
        w.report.add(
            .@"error",
            .invalid,
            st.line,
            "step: a {s} sweep applies to every analysis of the netlist; this one leaves " ++
                "some out",
            .{w.g.name},
        );
}

/// `spread`: the block's own rule ends each statement of its body.
pub fn spread(w: *Writer, st: *const ir.Stmt) Error!void {
    var head = st.*;
    head.body = &.{};
    w.ending = true;
    const captured = capture(w, &head);
    w.ending = false;
    const suffix = std.mem.trim(u8, try captured, " \n");
    for (st.body) |*child| {
        if (schema.info(child.kind).class != .analysis) {
            try blocks.stmt(w, child);
            continue;
        }
        const text = std.mem.trimEnd(u8, try capture(w, child), "\n");
        try w.out.print("{s} {s}\n", .{ text, suffix });
    }
}

/// Does one of the kind's own rules (not an ending) say `st` whole?
pub fn fits(w: *Writer, st: *const ir.Stmt) Error!bool {
    var head = st.*;
    head.body = &.{};
    for (w.g.rules) |*rule| {
        if (rule.kind != st.kind or rule.dir == .read or w.g.isEnding(rule)) continue;
        if (!w.g.ruleHere(rule, w.within)) continue;
        var e = w.emitter(w.arena, &head);
        e.quiet = true;
        if (try e.seq(rule.pat) and try e.lossCount() == 0) return true;
    }
    return false;
}

/// A statement the target says only for an analysis (`each save ->
/// print.analysis ...`): written as the other kind once for each of the
/// analyses the netlist runs, an `oneway` info. False, and nothing
/// written, where it runs none of them or a value has no place there.
pub fn each(w: *Writer, st: *const ir.Stmt) Error!bool {
    const e = for (w.g.eaches) |*e| {
        if (e.from == st.kind) break e;
    } else return false;
    // The grammar's compiler takes an `each` line only with an analysis.
    assert(e.per.len > 0);
    var out = try ir.newStmt(w.arena, e.to, st.line);
    out.dialect = st.dialect;
    out.tail = st.tail;
    for (schema.info(st.kind).slots, 0..) |sl, i| {
        if (st.at(i) == .none) continue;
        const j = schema.slotIndex(e.to, sl.name) orelse return false;
        try out.set(w.arena, j, st.at(i));
    }
    var said: std.ArrayList(u8) = .empty;
    for (e.per) |k| if (w.used[@backingInt(k)]) {
        try said.print(w.arena, "{s}{s}", .{ if (said.items.len > 0) ", " else "", @tagName(k) });
    };
    if (said.items.len == 0) return false;
    w.report.add(.info, .oneway, st.line, "{s}: written as a {s} for each analysis the " ++
        "netlist runs ({s}): {s}", .{ @tagName(st.kind), @tagName(e.to), said.items, e.text });
    for (e.per) |k| if (w.used[@backingInt(k)]) {
        var one = out;
        try one.own(w.arena);
        try one.set(w.arena, e.slot, .{ .atom = @tagName(k) });
        try blocks.stmt(w, &one);
    };
    return true;
}

// ---- private ----

/// What `blocks.stmt` writes for `st`, as text.
fn capture(w: *Writer, st: *const ir.Stmt) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(w.arena);
    const saved = w.out;
    w.out = &aw.writer;
    defer w.out = saved;
    try blocks.stmt(w, st);
    return aw.written();
}
