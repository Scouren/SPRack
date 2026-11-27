//! Binned model cards: `nch.1`, `nch.2`, ... of a netlist → one model `nch`
//! whose body holds them, for a dialect that writes binned models as one
//! block (Spectre), and that block written: its header names the type,
//! each bin is a line.
//!
//! Contents:
//! - `pub fn binnedModel(w: *Writer, st: *const ir.Stmt) Error!void`
//! - `pub fn groupBins(arena: Allocator, stmts: []const ir.Stmt) Allocator.Error![]const ir.Stmt`

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir");
const blocks = @import("blocks.zig");
const output = @import("output.zig");
const cards = @import("cards.zig");
const statement = @import("statement.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Writer = statement.Writer;
const Error = Writer.Error;

/// Model cards `nch.1`, `nch.2`, ... grouped under `nch` by
/// `groupBins`: the block's header names the type, each bin is a line.
pub fn binnedModel(w: *Writer, st: *const ir.Stmt) Error!void {
    assert(st.kind == .model);
    const b = w.g.blockOf(.model).?;
    const a = w.arena;
    const ti = schema.slot(.model, "type");
    const ni = schema.slot(.model, "name");
    var bins: std.ArrayList(ir.Stmt) = .empty;
    var head = st.*;
    head.body = &.{};
    try head.own(a);
    for (st.body) |*child| {
        if (child.kind != .model) {
            try bins.append(a, child.*);
            continue;
        }
        const m = (cards.unmapModel(w, a, child) catch |err| switch (err) {
            error.Skip => continue,
            else => |e| return e,
        }) orelse continue;
        var bin = m;
        try bin.own(a);
        if (head.at(ti) == .none) try head.set(a, ti, m.at(ti));
        const full = child.get("name").atom;
        const dot = std.mem.lastIndexOfScalar(u8, full, '.').?;
        try bin.set(a, ni, .{ .atom = try std.fmt.allocPrint(a, "{s}:", .{full[dot + 1 ..]}) });
        try bin.set(a, ti, .none);
        try bins.append(a, bin);
    }
    var e = w.emitter(a, &head);
    if (!try e.seq(b.open)) {
        w.report.add(
            .@"error",
            .invalid,
            st.line,
            "model: required values missing for the {s} form",
            .{w.g.name},
        );
        return;
    }
    try output.lineTail(w, e.buf.items, st.tail);
    for (bins.items) |*bin| try blocks.stmt(w, bin);
    e.buf.clearRetainingCapacity();
    if (try e.seq(b.close)) try output.line(w, e.buf.items);
}

/// For a dialect that writes binned models as one block (Spectre), the
/// model cards `nch.1`, `nch.2`, ... of a list become one model `nch`
/// whose body holds them, where the first of them stood.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn groupBins(arena: Allocator, stmts: []const ir.Stmt) Allocator.Error![]const ir.Stmt {
    var groups: std.StringArrayHashMapUnmanaged(std.ArrayList(ir.Stmt)) = .empty;
    for (stmts) |*s| {
        const base = binBase(s) orelse continue;
        const gop = try groups.getOrPut(arena, base);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, s.*);
    }
    var any_body = false;
    for (stmts) |s| any_body = any_body or s.body.len > 0;
    if (groups.count() == 0 and !any_body) return stmts;
    var out: std.ArrayList(ir.Stmt) = .empty;
    var done: std.StringHashMapUnmanaged(void) = .empty;
    for (stmts) |*s| {
        if (binBase(s)) |base| {
            if ((try done.getOrPut(arena, base)).found_existing) continue;
            var parent = try ir.newStmt(arena, .model, s.line);
            try parent.set(arena, schema.slot(.model, "name"), .{ .atom = base });
            parent.body = groups.get(base).?.items;
            try out.append(arena, parent);
            continue;
        }
        var copy = s.*;
        if (s.body.len > 0) copy.body = @constCast(try groupBins(arena, s.body));
        try out.append(arena, copy);
    }
    assert(out.items.len <= stmts.len);
    return out.items;
}

// ---- private ----

/// `nch` of the model card `nch.12`, or null.
fn binBase(st: *const ir.Stmt) ?[]const u8 {
    if (st.kind != .model or st.get("name") != .atom) return null;
    return ir.binBase(st.get("name").atom);
}
