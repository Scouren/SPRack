//! Dialect-neutral netlist representation produced by every reader and
//! consumed by every writer. The statement and its values are here; what
//! is done with them is in the files below, re-exported under the same
//! names.
//!
//! Contents:
//! - `pub const Kind`
//! - `pub const Number = struct`: `init`, `digits`, `toFloat`
//! - `pub const Param = struct`
//! - `pub const Value = union(enum)`: `isNone`, `eql`
//! - `pub const Stmt = struct`: `at`, `get`, `values`, `set`, `pack`,
//!   `unpack`, `store`, `own`, `eql`
//! - `pub const max_input: usize`, `pub const max_depth: usize`
//! - `pub var big: Allocator`
//! - `pub const blank_line`
//! - `pub const ReadOptions = struct`
//! - `pub const Netlist = struct`: `eql`
//! - `pub fn countStmts(stmts: []const Stmt, kind: ?Kind) usize`
//! - `pub fn newStmt(arena: Allocator, kind: Kind, line: u32) Allocator.Error!Stmt`
//! - from `ir_names.zig`: `keepText`, `Keep`, `cloneValue`, `cloneStmt`,
//!   `putName`, `putValue`, `Caseless`, `CaselessSet`, `NameSet`
//! - from `ir_report.zig`: `Severity`, `Code`, `Phase`, `Diag`, `Report`
//! - from `ir_loose.zig`: `looseListEql`, `sameCircuit`
//! - from `ir_env.zig`: `markFamilies`, `Env`, `holdsCond`
//! - from `ir_models.zig`: `checkModelKinds`, `collectFamilies`, `checkKinds`,
//!   `unlisted_builtin`, `markUnlistedBuiltins`, `resolveInstances`, `binBase`,
//!   `collectModels`, `sameSlots`, `retag`, `demoteToInstance`
//! - from `ir_sweeps.zig`: `principalParam`, `resolveSweeps`, `hasSweep`,
//!   `gatherSteps`

const std = @import("std");
const schema = @import("schema");
const Allocator = std.mem.Allocator;
const ir_sweeps = @import("ir_sweeps.zig");
const ir_models = @import("ir_models.zig");
const ir_env = @import("ir_env.zig");
const ir_loose = @import("ir_loose.zig");
const ir_report = @import("ir_report.zig");
const ir_names = @import("ir_names.zig");

pub const principalParam = ir_sweeps.principalParam;
pub const resolveSweeps = ir_sweeps.resolveSweeps;
pub const hasSweep = ir_sweeps.hasSweep;
pub const gatherSteps = ir_sweeps.gatherSteps;
pub const checkModelKinds = ir_models.checkModelKinds;
pub const collectFamilies = ir_models.collectFamilies;
pub const checkKinds = ir_models.checkKinds;
pub const unlisted_builtin = ir_models.unlisted_builtin;
pub const markUnlistedBuiltins = ir_models.markUnlistedBuiltins;
pub const resolveInstances = ir_models.resolveInstances;
pub const binBase = ir_models.binBase;
pub const collectModels = ir_models.collectModels;
pub const sameSlots = ir_models.sameSlots;
pub const retag = ir_models.retag;
pub const demoteToInstance = ir_models.demoteToInstance;
pub const markFamilies = ir_env.markFamilies;
pub const Env = ir_env.Env;
pub const holdsCond = ir_env.holdsCond;
pub const looseListEql = ir_loose.looseListEql;
pub const sameCircuit = ir_loose.sameCircuit;
pub const Severity = ir_report.Severity;
pub const Code = ir_report.Code;
pub const Phase = ir_report.Phase;
pub const Diag = ir_report.Diag;
pub const Report = ir_report.Report;
pub const keepText = ir_names.keepText;
pub const Keep = ir_names.Keep;
pub const cloneValue = ir_names.cloneValue;
pub const cloneStmt = ir_names.cloneStmt;
pub const putName = ir_names.putName;
pub const putValue = ir_names.putValue;
pub const Caseless = ir_names.Caseless;
pub const CaselessSet = ir_names.CaselessSet;
pub const NameSet = ir_names.NameSet;

pub const Kind = schema.Kind;

/// A decimal literal kept as text, so translation never rounds:
/// `1.5p` is digits "1.5", exp10 -12, in every dialect.
pub const Number = struct {
    /// The digits as written, sign and decimal point included. Stored as a
    /// pointer and a 32-bit length so a `Value` is 24 bytes, not 32.
    ptr: [*]const u8,
    len: u32,
    exp10: i32,

    pub fn init(text: []const u8, exp10: i32) Number {
        return .{ .ptr = text.ptr, .len = @intCast(text.len), .exp10 = exp10 };
    }

    pub fn digits(n: Number) []const u8 {
        return n.ptr[0..n.len];
    }

    pub fn toFloat(n: Number) f64 {
        var buf: [96]u8 = undefined;
        const s = std.fmt.bufPrint(
            &buf,
            "{s}e{d}",
            .{ n.digits(), n.exp10 },
        ) catch return std.math.nan(f64);
        return std.fmt.parseFloat(f64, s) catch std.math.nan(f64);
    }
};

pub const Param = struct { key: []const u8, val: Value };

pub const Value = union(enum) {
    none,
    atom: []const u8,
    num: Number,
    /// Expression text with numeric literals already in plain `1.5e-12` form.
    expr: []const u8,
    str: []const u8,
    list: []const Value,
    params: []const Param,

    pub fn isNone(v: Value) bool {
        return v == .none;
    }

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        // Each arm reads `b` as the variant `a` is.
        std.debug.assert(std.meta.activeTag(a) == std.meta.activeTag(b));
        return switch (a) {
            .none => true,
            .atom => |x| std.mem.eql(u8, x, b.atom),
            .num => |x| x.toFloat() == b.num.toFloat(),
            .expr => |x| std.mem.eql(u8, x, b.expr),
            .str => |x| std.mem.eql(u8, x, b.str),
            .list => |x| blk: {
                if (x.len != b.list.len) break :blk false;
                for (x, b.list) |p, q| if (!p.eql(q)) break :blk false;
                break :blk true;
            },
            .params => |x| blk: {
                if (x.len != b.params.len) break :blk false;
                for (x, b.params) |p, q| {
                    if (!std.mem.eql(u8, p.key, q.key) or !p.val.eql(q.val)) break :blk false;
                }
                break :blk true;
            },
        };
    }
};

pub const Stmt = struct {
    kind: Kind,
    /// Values are stored sparsely: bit `i` is set when slot `i` of `kind`
    /// has an entry in `bound`, in slot order. A device gives a few of its
    /// slots (a source has 33), and a large netlist is mostly devices.
    mask: u64 = 0,
    bound: [*]Value = &no_values,
    body: []Stmt = &.{},
    /// Source text of a statement no rule matched.
    raw: []const u8 = "",
    line: u32 = 0,
    /// Trailing comment on the statement's line.
    tail: []const u8 = "",
    /// The dialect this statement was read in, when it is not the
    /// netlist's (a block of text added to a circuit built in Python), as
    /// an index into the process's dialect table (`root.dialectName`).
    /// 0: the netlist's. A target of the same dialect writes the
    /// statement's private values (options, analysis parameters) as they are.
    dialect: u8 = 0,

    fn bit(i: usize) u64 {
        return @as(u64, 1) << @intCast(i);
    }

    /// The value in slot `i`, `.none` if the slot was not given.
    pub fn at(s: *const Stmt, i: usize) Value {
        if (s.mask & bit(i) == 0) return .none;
        return s.bound[@popCount(s.mask & (bit(i) - 1))];
    }

    pub fn get(s: *const Stmt, comptime slot: []const u8) Value {
        const i = schema.slotOf(s.kind, slot) orelse return .none;
        return s.at(i);
    }

    /// The values given, in slot order, without their slot numbers.
    pub fn values(s: *const Stmt) []Value {
        return s.bound[0..@popCount(s.mask)];
    }

    /// Writes in place when slot `i` is given, so a copy of the statement
    /// that shares `bound` sees it: call `own` on the copy first.
    pub fn set(s: *Stmt, arena: Allocator, i: usize, v: Value) Allocator.Error!void {
        const k = @popCount(s.mask & (bit(i) - 1));
        if (s.mask & bit(i) != 0) {
            s.bound[k] = v;
            return;
        }
        if (v == .none) return;
        const old = s.values();
        const out = try arena.alloc(Value, old.len + 1);
        @memcpy(out[0..k], old[0..k]);
        out[k] = v;
        @memcpy(out[k + 1 ..], old[k..]);
        s.bound = out.ptr;
        s.mask |= bit(i);
    }

    /// Store one value per slot of `kind`, `.none` for a slot not given.
    pub fn pack(s: *Stmt, arena: Allocator, dense: []const Value) Allocator.Error!void {
        var mask: u64 = 0;
        for (dense, 0..) |v, i| {
            if (v != .none) mask |= bit(i);
        }
        const out = try arena.alloc(Value, @popCount(mask));
        var k: usize = 0;
        for (dense) |v| {
            if (v == .none) continue;
            out[k] = v;
            k += 1;
        }
        s.mask = mask;
        s.bound = out.ptr;
    }

    /// One value per slot of `kind`, written into `buf`.
    pub fn unpack(s: *const Stmt, buf: *[schema.max_slots]Value) []Value {
        const n = schema.info(s.kind).slots.len;
        for (buf[0..n], 0..) |*v, i| v.* = s.at(i);
        return buf[0..n];
    }

    /// Write back what `unpack` gave, after editing it. Slots already given
    /// are written in place; only a newly given one costs a new array.
    pub fn store(s: *Stmt, arena: Allocator, dense: []const Value) Allocator.Error!void {
        if (s.mask == 0) return s.pack(arena, dense);
        for (dense, 0..) |v, i| try s.set(arena, i, v);
    }

    /// Give this statement its own copy of its values.
    pub fn own(s: *Stmt, arena: Allocator) Allocator.Error!void {
        s.bound = (try arena.dupe(Value, s.values())).ptr;
    }

    pub fn eql(a: *const Stmt, b: *const Stmt) bool {
        if (a.kind != b.kind or a.body.len != b.body.len) return false;
        if (a.kind == .@"opaque" and !std.mem.eql(u8, a.raw, b.raw)) return false;
        for (0..schema.info(a.kind).slots.len) |i| if (!a.at(i).eql(b.at(i))) return false;
        for (a.body, b.body) |*x, *y| if (!x.eql(y)) return false;
        return true;
    }
};

/// The most an input file may hold, a netlist or an included file: a larger
/// one, or one that is not a regular file or a pipe (`/dev/zero`), is
/// refused with a report entry rather than read until memory runs out.
pub const max_input: usize = 1 << 30;

/// How deep blocks may nest: subcircuits, conditional blocks, a JSON
/// `body` or list. Deeper, the rest is refused with an `invalid` entry,
/// not a stack overflow.
pub const max_depth: usize = 100;

/// Where reading and writing keep their large temporary tables (the line
/// list, the token window, name sets): outside the arena, so that they are
/// freed as soon as they are done with. A variable so that a test can count
/// what they take.
///
/// Under the thread sanitizer (`zig build -Dtsan`) it is libc's: the page
/// allocator grows a table with mremap, which the sanitizer does not
/// follow, so a page one thread gave back and another was given reads as
/// a race between the two (111 such reports on sky130, none after).
pub var big: Allocator = if (@import("builtin").sanitize_thread)
    // tidy: allow(global-allocator-in-library) the one allocator for large tables, as above
    std.heap.c_allocator
else
    // tidy: allow(global-allocator-in-library) the one allocator for large tables, as above
    std.heap.page_allocator;

/// Marks a `comment` statement that stands for a blank line.
pub const blank_line = "\n";

/// How a file is to be read.
pub const ReadOptions = struct {
    env: ?*const Env = null,
    /// An included file or a model library: no title line, and when
    /// written, no title, preamble or end marker either.
    library: bool = false,
};

pub const Netlist = struct {
    title: []const u8 = "",
    /// Name of the dialect this was read from.
    dialect: []const u8 = "",
    /// The dialect whose defaults the netlist means where it sets none
    /// (the temperature), when that is not `dialect`'s: a circuit built on
    /// a PDK means its PDK's. Empty: `dialect`'s.
    defaults: []const u8 = "",
    library: bool = false,
    /// Names differing only by case are one name although the dialect is
    /// case sensitive: the file said so (`header folded`), or part of it is
    /// in a dialect that folds case. A dialect that folds case implies it.
    folds_case: bool = false,
    stmts: []Stmt = &.{},
    /// What files this netlist names but does not hold declare (a PDK's
    /// libraries), where it says so itself: the `env` of its JSON form.
    env: ?*const Env = null,

    pub fn eql(a: *const Netlist, b: *const Netlist) bool {
        if (a.stmts.len != b.stmts.len) return false;
        for (a.stmts, b.stmts) |*x, *y| if (!x.eql(y)) return false;
        return true;
    }
};

comptime {
    // A slice and its tag: 24 bytes on a 64-bit target, no more on a 32-bit one.
    std.debug.assert(@sizeOf(Value) <= 24);
}

comptime {
    std.debug.assert(schema.max_slots <= 64);
}

var no_values: [0]Value = .{};

// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn countStmts(stmts: []const Stmt, kind: ?Kind) usize {
    var n: usize = 0;
    for (stmts) |*s| {
        if (kind == null and s.kind == .comment) continue;
        if (kind == null or s.kind == kind.?) n += 1;
        n += countStmts(s.body, kind);
    }
    return n;
}

pub fn newStmt(arena: Allocator, kind: Kind, line: u32) Allocator.Error!Stmt {
    _ = arena;
    return .{ .kind = kind, .line = line };
}

test "number equality ignores spelling" {
    const a: Value = .{ .num = .init("1000", 0) };
    const b: Value = .{ .num = .init("1", 3) };
    try std.testing.expect(a.eql(b));
}

test {
    _ = ir_env;
    _ = ir_loose;
    _ = ir_models;
    _ = ir_names;
    _ = ir_report;
    _ = ir_sweeps;
}
