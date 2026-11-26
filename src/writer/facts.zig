//! What the survey learns of the netlist that a card's spelling depends
//! on: statements in → for each model, the fewest and the most terminals
//! of the instances that name it (`when nodes>=n`), and the Verilog-A
//! module a model card is of.
//!
//! Contents:
//! - `pub const Terminals = struct`
//! - `pub const TerminalMap`
//! - `pub fn collectTerminals(a: Allocator, stmts: []const ir.Stmt, out: *TerminalMap,
//!   src: ?[]const u8) Allocator.Error!void`
//! - `pub fn terminalCount(st: *const ir.Stmt) u32`
//! - `pub fn collectModules(arena: Allocator, stmts: []const ir.Stmt,
//!   out: *std.StringHashMapUnmanaged([]const u8)) Allocator.Error!void`

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// The fewest and the most terminals of the instances that name a model.
pub const Terminals = struct { min: u32, max: u32 };

/// Model name → `Terminals`, case folded.
pub const TerminalMap = std.HashMapUnmanaged(
    []const u8,
    Terminals,
    ir.Caseless,
    std.hash_map.default_max_load_percentage,
);

/// For every model an instance of `stmts` names, the fewest and the most
/// terminals of those instances (`when nodes>=n`).
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn collectTerminals(
    a: Allocator,
    stmts: []const ir.Stmt,
    out: *TerminalMap,
    src: ?[]const u8,
) Allocator.Error!void {
    for (stmts) |*s| {
        if (schema.info(s.kind).class == .device)
            if (schema.slotOf(s.kind, "master")) |mi| if (s.at(mi) == .atom) {
                const n = terminalCount(s);
                const gop = try out.getOrPut(a, s.at(mi).atom);
                if (gop.found_existing) {
                    gop.value_ptr.min = @min(gop.value_ptr.min, n);
                    gop.value_ptr.max = @max(gop.value_ptr.max, n);
                } else {
                    if (src) |t| gop.key_ptr.* = try ir.keepText(a, t, s.at(mi).atom);
                    gop.value_ptr.* = .{ .min = n, .max = n };
                }
                assert(gop.value_ptr.min <= gop.value_ptr.max);
            };
        try collectTerminals(a, s.body, out, src);
    }
}

/// How many terminals a device statement connects.
pub fn terminalCount(st: *const ir.Stmt) u32 {
    var n: u32 = 0;
    for (schema.info(st.kind).slots, 0..) |sl, i| {
        if (sl.ty != .node) continue;
        switch (st.at(i)) {
            .list => |l| n += @intCast(l.len),
            .none => {},
            else => n += 1,
        }
    }
    return n;
}

/// For every model card of `stmts` that is of a Verilog-A module (a type
/// and no family), the module's name.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn collectModules(
    arena: Allocator,
    stmts: []const ir.Stmt,
    out: *std.StringHashMapUnmanaged([]const u8),
) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .model and s.get("family") == .none and s.get("type") == .atom and
            s.get("name") == .atom)
            try out.put(arena, s.get("name").atom, s.get("type").atom);
        try collectModules(arena, s.body, out);
    }
}
