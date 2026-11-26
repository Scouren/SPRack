//! References met before what they name: a netlist written a group of
//! statements at a time meets a name in a reference slot before the device
//! of that name. `Refs` holds the names wanted and the devices found, and
//! withdraws the entries a device met later answers.

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir");

const Allocator = std.mem.Allocator;

/// The references a netlist read as a stream makes (`.dc X`, `F1 a b X`):
/// every name in a reference slot, gathered before writing, and those of
/// them a device has been met with so far.
pub const Refs = struct {
    wanted: ir.CaselessSet = .empty,
    found: ir.CaselessSet = .empty,
    /// Entries saying a name is no device, made before such a device came.
    pending: std.ArrayList(struct { at: usize, name: []const u8 }) = .empty,

    /// Every name in a reference slot of `stmts`.
    pub fn want(r: *Refs, k: ir.Keep, stmts: []const ir.Stmt) Allocator.Error!void {
        for (stmts) |*s| {
            for (schema.info(s.kind).slots, 0..) |sl, i| {
                if (sl.ty == .ref and s.at(i) == .atom)
                    try ir.putName(&r.wanted, k.perm, k.src, s.at(i).atom);
            }
            try r.want(k, s.body);
        }
    }

    /// The devices of `stmts` whose names are wanted.
    pub fn add(r: *Refs, k: ir.Keep, stmts: []const ir.Stmt) Allocator.Error!void {
        if (r.wanted.count() == 0) return;
        for (stmts) |*s| {
            if (schema.info(s.kind).class == .device and s.get("name") == .atom and
                r.wanted.contains(s.get("name").atom))
                try ir.putName(&r.found, k.perm, k.src, s.get("name").atom);
            try r.add(k, s.body);
        }
    }

    /// Withdraw the entries a device met later answers.
    pub fn settle(r: *Refs, report: *ir.Report) void {
        var drop = r.pending.items;
        var n: usize = 0;
        var j: usize = 0;
        for (report.items.items, 0..) |d, i| {
            if (j < drop.len and drop[j].at == i) {
                defer j += 1;
                if (r.found.contains(drop[j].name)) continue;
            }
            report.items.items[n] = d;
            n += 1;
        }
        report.items.shrinkRetainingCapacity(n);
        drop = &.{};
    }
};
