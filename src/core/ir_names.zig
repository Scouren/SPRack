//! Names and copies: text kept past the line it was read from, deep copies
//! of values and statements, and the sets and maps of names that ignore case.
//!
//! Contents:
//! - `pub const Keep = struct`: `text`
//! - `pub const Caseless = struct`: `hash`, `eql`
//! - `pub const CaselessSet`
//! - `pub const NameSet = struct`: `count`, `getKey`, `contains`, `put`,
//!   `deinit`
//! - `pub fn keepText(perm: Allocator, src: []const u8, s: []const u8) Allocator.Error![]const u8`
//! - `pub fn cloneValue(k: Keep, v: Value) Allocator.Error!Value`
//! - `pub fn cloneStmt(k: Keep, st: *const Stmt) Allocator.Error!Stmt`
//! - `pub fn putName(set: anytype, arena: Allocator, src: ?[]const u8,
//!   name: []const u8) Allocator.Error!void`
//! - `pub fn putValue(map: anytype, arena: Allocator, src: ?[]const u8, name: []const u8,
//!   v: anytype) Allocator.Error!void`

const std = @import("std");
const ir = @import("ir.zig");
const Allocator = std.mem.Allocator;
const Param = ir.Param;
const Stmt = ir.Stmt;
const Value = ir.Value;

/// Where names go that must outlive the statements they were read from.
pub const Keep = struct {
    perm: Allocator,
    /// The netlist's own text, which outlives the statements read from it.
    /// Null where the statements themselves outlive what is kept (a
    /// netlist held in memory): nothing is copied.
    src: ?[]const u8,

    pub fn text(k: Keep, s: []const u8) Allocator.Error![]const u8 {
        return keepText(k.perm, k.src orelse return s, s);
    }
};

/// Hashes and compares names as an ASCII case-folding dialect reads them.
pub const Caseless = struct {
    pub fn hash(_: Caseless, s: []const u8) u64 {
        var h: std.hash.Wyhash = .init(0);
        var buf: [64]u8 = undefined;
        var i: usize = 0;
        while (i < s.len) : (i += buf.len) {
            const part = s[i..@min(s.len, i + buf.len)];
            h.update(std.ascii.lowerString(&buf, part));
        }
        return h.final();
    }

    pub fn eql(_: Caseless, a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

/// A set of names that ignores case. Each key is the spelling it was first
/// added with, so no lower-cased copy is ever made.
pub const CaselessSet = std.HashMapUnmanaged(
    []const u8,
    void,
    Caseless,
    std.hash_map.default_max_load_percentage,
);

/// A set of names that ignores case, as `CaselessSet`, at 9 bytes a name
/// rather than 17: each is kept as its offset and length in `src` (the
/// netlist's text), or, when it is not there, as an index into `copies`.
/// Each key is the spelling it was first added with.
pub const NameSet = struct {
    src: []const u8,
    /// Where names not in `src` are copied.
    perm: Allocator,
    copies: std.ArrayList([]const u8) = .empty,
    map: std.HashMapUnmanaged(u64, void, Ctx, std.hash_map.default_max_load_percentage) = .empty,

    const copied: u64 = 1 << 63;

    const Ctx = struct {
        set: *const NameSet,
        pub fn hash(c: Ctx, r: u64) u64 {
            return Caseless.hash(.{}, c.set.text(r));
        }
        pub fn eql(_: Ctx, a: u64, b: u64) bool {
            return a == b;
        }
    };

    const ByName = struct {
        set: *const NameSet,
        pub fn hash(_: ByName, name: []const u8) u64 {
            return Caseless.hash(.{}, name);
        }
        pub fn eql(c: ByName, name: []const u8, r: u64) bool {
            return std.ascii.eqlIgnoreCase(name, c.set.text(r));
        }
    };

    fn text(set: *const NameSet, r: u64) []const u8 {
        if (r & copied != 0) return set.copies.items[@intCast(r & ~copied)];
        const off: usize = @intCast(r >> 24);
        return set.src[off..][0..@intCast(r & 0xffffff)];
    }

    pub fn count(set: *const NameSet) usize {
        return set.map.count();
    }

    pub fn getKey(set: *const NameSet, name: []const u8) ?[]const u8 {
        const r = set.map.getKeyAdapted(name, ByName{ .set = set }) orelse return null;
        return set.text(r);
    }

    pub fn contains(set: *const NameSet, name: []const u8) bool {
        return set.map.containsAdapted(name, ByName{ .set = set });
    }

    /// Add `name` unless a spelling of it is there.
    pub fn put(set: *NameSet, name: []const u8) Allocator.Error!void {
        const gop = try set.map.getOrPutContextAdapted(
            ir_big(),
            name,
            ByName{ .set = set },
            Ctx{ .set = set },
        );
        if (gop.found_existing) return;
        const p = @intFromPtr(name.ptr);
        const lo = @intFromPtr(set.src.ptr);
        if (p >= lo and p + name.len <= lo + set.src.len and name.len < 1 << 24) {
            gop.key_ptr.* = (@as(u64, p - lo) << 24) | name.len;
        } else {
            gop.key_ptr.* = copied | set.copies.items.len;
            set.copies.append(ir_big(), try set.perm.dupe(u8, name)) catch |e| {
                set.map.removeByPtr(gop.key_ptr);
                return e;
            };
        }
        std.debug.assert(set.text(gop.key_ptr.*).len == name.len);
    }

    pub fn deinit(set: *NameSet) void {
        set.map.deinit(ir_big());
        set.copies.deinit(ir_big());
    }
};

/// `s` copied into `perm`, unless it is part of `src`, which outlives it.
/// A name read from a line that goes away is kept so.
pub fn keepText(perm: Allocator, src: []const u8, s: []const u8) Allocator.Error![]const u8 {
    const p = @intFromPtr(s.ptr);
    const lo = @intFromPtr(src.ptr);
    if (s.len == 0 or (p >= lo and p + s.len <= lo + src.len)) return s;
    return perm.dupe(u8, s);
}

/// A copy of `v` that shares nothing with the statement it came from but
/// the netlist's own text.
// tidy: allow(recursion) bounded by the nesting of a value's lists, ir.max_depth
pub fn cloneValue(k: Keep, v: Value) Allocator.Error!Value {
    const copy: Value = switch (v) {
        .none => .none,
        .atom => |x| .{ .atom = try k.text(x) },
        .expr => |x| .{ .expr = try k.text(x) },
        .str => |x| .{ .str = try k.text(x) },
        .num => |n| .{ .num = .init(try k.text(n.digits()), n.exp10) },
        .list => |l| blk: {
            const out = try k.perm.alloc(Value, l.len);
            for (l, out) |x, *y| y.* = try cloneValue(k, x);
            break :blk .{ .list = out };
        },
        .params => |ps| blk: {
            const out = try k.perm.alloc(Param, ps.len);
            for (ps, out) |x, *y|
                y.* = .{ .key = try k.text(x.key), .val = try cloneValue(k, x.val) };
            break :blk .{ .params = out };
        },
    };
    std.debug.assert(std.meta.activeTag(copy) == std.meta.activeTag(v));
    return copy;
}

/// A copy of `st`, its body included, as `cloneValue`.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn cloneStmt(k: Keep, st: *const Stmt) Allocator.Error!Stmt {
    var out = st.*;
    const vals = try k.perm.alloc(Value, st.values().len);
    for (st.values(), vals) |x, *y| y.* = try cloneValue(k, x);
    out.bound = vals.ptr;
    out.raw = try k.text(st.raw);
    out.tail = try k.text(st.tail);
    const body = try k.perm.alloc(Stmt, st.body.len);
    for (st.body, body) |*x, *y| y.* = try cloneStmt(k, x);
    out.body = body;
    return out;
}

/// Add `name` to `set`; with `src`, a name new to it is kept (`keepText`).
pub fn putName(
    set: anytype,
    arena: Allocator,
    src: ?[]const u8,
    name: []const u8,
) Allocator.Error!void {
    const gop = try set.getOrPut(arena, name);
    if (!gop.found_existing) if (src) |t| {
        gop.key_ptr.* = try keepText(arena, t, name);
    };
}

/// As `putName`, for a map: the value is set whether the name is new or not.
pub fn putValue(
    map: anytype,
    arena: Allocator,
    src: ?[]const u8,
    name: []const u8,
    v: anytype,
) Allocator.Error!void {
    const gop = try map.getOrPut(arena, name);
    if (!gop.found_existing) if (src) |t| {
        gop.key_ptr.* = try keepText(arena, t, name);
    };
    gop.value_ptr.* = v;
}

// ---- private ----

fn ir_big() Allocator {
    return ir.big;
}
