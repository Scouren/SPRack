//! Losses: what a written statement held and its pattern had no place
//! for → counted (to choose between rules) and reported (once the rule
//! is chosen), with the caveats either grammar attaches to a slot.
//!
//! Contents:
//! - `pub fn lost(e: *Emit, idx: u8) Allocator.Error!bool`
//! - `pub fn inert(e: *const Emit, key: []const u8) Allocator.Error!?[]const u8`
//! - `pub fn lossCount(e: *Emit) Allocator.Error!usize`
//! - `pub fn reportLosses(e: *Emit) Allocator.Error!void`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const emit = @import("emit.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Emit = emit.Emit;
const Value = ir.Value;
const reasonFor = emit.reasonFor;

pub fn lost(e: *Emit, idx: u8) Allocator.Error!bool {
    if (!e.present(idx) or e.isUsed(idx)) return false;
    // The heading alone carries nothing a foreign dialect needs.
    if (e.foreign and std.mem.eql(u8, e.slot(idx).name, "package")) return false;
    // What this dialect assumes anyway need not be said.
    return !e.isImplied(idx);
}

/// Why the source dialect's parameter changes no result (`inert`), if it does not.
/// Why the source dialect's `key` of this statement changes no result
/// (its `inert` line), with `{to}` in it the dialect being written.
pub fn inert(e: *const Emit, key: []const u8) Allocator.Error!?[]const u8 {
    const sg = e.sourceGrammar() orelse return null;
    const text = sg.inertReason(e.st.kind, key) orelse return null;
    return try reasonFor(e.arena, text, e.g.name);
}

pub fn lossCount(e: *Emit) Allocator.Error!usize {
    var n: usize = e.lost_flags;
    for (0..schema.info(e.st.kind).slots.len) |i| n += @intFromBool(try e.lost(@intCast(i)));
    return n;
}

pub fn reportLosses(e: *Emit) Allocator.Error!void {
    reportCaveats(e);
    if (e.lost_flags > 0) reportFlags(e);
    for (0..schema.info(e.st.kind).slots.len) |i| {
        const v = e.st.at(i);
        const idx: u8 = @intCast(i);
        if (!try e.lost(idx)) continue;
        // What is lost is what no rule wrote.
        assert(!e.isUsed(idx));
        const label = schema.info(e.st.kind).class == .analysis and e.slot(idx).ty == .name;
        if (label) {
            e.report.add(
                .info,
                .cosmetic,
                e.st.line,
                "{s}: {s} does not name its analyses; the label '{s}' is not written",
                .{ @tagName(e.st.kind), e.g.name, try e.describe(v) },
            );
            continue;
        }
        if (e.slot(idx).ty == .params and v == .params) {
            try reportParams(e, v);
            continue;
        }
        // The target says the slot changes nothing there (`inert kind
        // slot : text`): a note, not an error.
        if (e.g.inertReason(e.st.kind, e.slot(idx).name)) |text| {
            e.report.add(.info, .loss, e.st.line, "{s}.{s} = {s} is not written: {s}", .{
                @tagName(e.st.kind),                    e.slot(idx).name, try e.describe(v),
                try reasonFor(e.arena, text, e.g.name),
            });
            continue;
        }
        const why = e.g.slotAbsentReason(e.st.kind, idx);
        e.report.add(.@"error", .loss, e.st.line, "{s}.{s} = {s} has no spelling in " ++
            "{s}{s}{s}", .{
            @tagName(e.st.kind), e.slot(idx).name, try e.describe(v), e.g.name,
            if (why != null)
                ": "
            else
                "",
            why orelse "",
        });
    }
}

// ---- private ----

/// The target's caveats on writing a slot the rule wrote, the source's on
/// reading it.
fn reportCaveats(e: *Emit) void {
    const src: []const grammar.Caveat = if (e.sourceGrammar()) |sg| sg.caveats else &.{};
    for ([_][]const grammar.Caveat{ e.g.caveats, src }, [_]bool{ false, true }) |cs, read|
        for (cs) |c| {
            if (c.read == read and e.foreign and c.kind == e.st.kind and e.isUsed(c.slot)) {
                // The grammar names a slot of the caveat's kind, the statement's.
                assert(c.slot < schema.info(e.st.kind).slots.len);
                if (c.suffix.len > 0) {
                    const v = e.st.at(c.slot);
                    const t: []const u8 = switch (v) {
                        .str, .atom, .expr => |x| x,
                        else => "",
                    };
                    if (!std.ascii.endsWithIgnoreCase(t, c.suffix)) continue;
                }
                // Text carried verbatim is the source's syntax, not the
                // target's: an error (a measure's spec that ngspice refuses).
                if (e.slot(c.slot).ty == .text) {
                    e.report.add(
                        .@"error",
                        .invalid,
                        e.st.line,
                        "{s}.{s}: {s}; it is {s} text, written as it was",
                        .{ @tagName(e.st.kind), e.slot(c.slot).name, c.text, e.source },
                    );
                } else e.report.add(
                    .warning,
                    .caveat,
                    e.st.line,
                    "{s}.{s}: {s}",
                    .{ @tagName(e.st.kind), e.slot(c.slot).name, c.text },
                );
            }
        };
}

/// Each bare flag of the statement, where a rule had no way to write one.
fn reportFlags(e: *Emit) void {
    assert(e.lost_flags > 0);
    for (e.st.values()) |v| {
        if (v != .params) continue;
        for (v.params) |p| {
            if (p.val == .none)
                e.report.add(
                    .@"error",
                    .loss,
                    e.st.line,
                    "{s}: the flag '{s}' has no spelling in {s}",
                    .{ @tagName(e.st.kind), p.key, e.g.name },
                );
        }
    }
}

/// One entry per parameter: each is a separate thing the target cannot say.
fn reportParams(e: *Emit, v: Value) Allocator.Error!void {
    assert(v == .params);
    for (v.params) |p| {
        if (try e.inert(p.key)) |why| {
            e.report.add(
                .info,
                .loss,
                e.st.line,
                "{s}: '{s}' is not written: {s}",
                .{ @tagName(e.st.kind), try e.describe(.{ .params = &.{p} }), why },
            );
            continue;
        }
        e.report.add(.@"error", .loss, e.st.line, "{s}: '{s}' has no spelling in " ++
            "{s}", .{
            @tagName(e.st.kind), try e.describe(.{ .params = &.{p} }), e.g.name,
        });
    }
}
