//! Dialect-neutral netlist representation produced by every reader and
//! consumed by every writer.

const std = @import("std");
const schema = @import("schema.zig");
const Allocator = std.mem.Allocator;
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
        const s = std.fmt.bufPrint(&buf, "{s}e{d}", .{ n.digits(), n.exp10 }) catch return std.math.nan(f64);
        return std.fmt.parseFloat(f64, s) catch std.math.nan(f64);
    }
};

comptime {
    std.debug.assert(@sizeOf(Value) == 24);
}

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

comptime {
    std.debug.assert(schema.max_slots <= 64);
}

var no_values: [0]Value = .{};

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
        const i = schema.slotIndex(s.kind, slot) orelse return .none;
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

/// Where reading and writing keep their large temporary tables (the line
/// list, the token window, name sets): outside the arena, so that they are
/// freed as soon as they are done with. A variable so that a test can count
/// what they take.
pub var big: Allocator = std.heap.page_allocator;

/// `s` copied into `perm`, unless it is part of `src`, which outlives it.
/// A name read from a line that goes away is kept so.
pub fn keepText(perm: Allocator, src: []const u8, s: []const u8) Allocator.Error![]const u8 {
    const p = @intFromPtr(s.ptr);
    const lo = @intFromPtr(src.ptr);
    if (s.len == 0 or (p >= lo and p + s.len <= lo + src.len)) return s;
    return perm.dupe(u8, s);
}

/// Where names go that must outlive the statements they were read from.
pub const Keep = struct {
    perm: Allocator,
    src: []const u8,

    pub fn text(k: Keep, s: []const u8) Allocator.Error![]const u8 {
        return keepText(k.perm, k.src, s);
    }
};

/// A copy of `v` that shares nothing with the statement it came from but
/// the netlist's own text.
pub fn cloneValue(k: Keep, v: Value) Allocator.Error!Value {
    return switch (v) {
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
            for (ps, out) |x, *y| y.* = .{ .key = try k.text(x.key), .val = try cloneValue(k, x.val) };
            break :blk .{ .params = out };
        },
    };
}

/// A copy of `st`, its body included, as `cloneValue`.
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
pub fn putName(set: anytype, arena: Allocator, src: ?[]const u8, name: []const u8) Allocator.Error!void {
    const gop = try set.getOrPut(arena, name);
    if (!gop.found_existing) if (src) |t| {
        gop.key_ptr.* = try keepText(arena, t, name);
    };
}

/// As `putName`, for a map: the value is set whether the name is new or not.
pub fn putValue(map: anytype, arena: Allocator, src: ?[]const u8, name: []const u8, v: anytype) Allocator.Error!void {
    const gop = try map.getOrPut(arena, name);
    if (!gop.found_existing) if (src) |t| {
        gop.key_ptr.* = try keepText(arena, t, name);
    };
    gop.value_ptr.* = v;
}

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
pub const CaselessSet = std.HashMapUnmanaged([]const u8, void, Caseless, std.hash_map.default_max_load_percentage);

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
        const gop = try set.map.getOrPutContextAdapted(ir_big(), name, ByName{ .set = set }, Ctx{ .set = set });
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
    }

    pub fn deinit(set: *NameSet) void {
        set.map.deinit(ir_big());
        set.copies.deinit(ir_big());
    }
};

fn ir_big() Allocator {
    return big;
}

/// Note the model families that model cards in `stmts` (and their bodies) use.
pub fn markFamilies(stmts: []const Stmt, out: *[schema.families.len]bool) void {
    for (stmts) |*s| {
        markFamilies(s.body, out);
        if (s.kind != .model) continue;
        const fam = s.get("family");
        if (fam != .atom) continue;
        for (schema.families, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, fam.atom)) out[i] = true;
        }
    }
}

/// Marks a `comment` statement that stands for a blank line.
pub const blank_line = "\n";

/// What the other files of a project declare. A PDK spreads its models,
/// subcircuits and functions over many files; a file is read correctly only
/// when the reader knows the names the others define.
pub const Env = struct {
    /// Names of models and subcircuits, as written and lower-cased.
    declared: std.StringHashMapUnmanaged(void) = .empty,
    /// Model name to the device kind its family belongs to.
    models: std.StringHashMapUnmanaged(Kind) = .empty,
    /// Names of subcircuits.
    subckts: CaselessSet = .empty,
    /// Lower-cased names of user-defined functions.
    funcs: std.StringHashMapUnmanaged(void) = .empty,
    /// Statement kinds used anywhere in the project. The top netlist writes
    /// the boilerplate (`needs`) for all of them.
    used: [schema.kind_count]bool = @splat(false),
    /// Model families used anywhere in the project, by `schema.families` index.
    families: [schema.families.len]bool = @splat(false),

    /// Everything is copied into `arena`, so `stmts` may be freed afterwards.
    pub fn absorb(env: *Env, arena: Allocator, stmts: []const Stmt) Allocator.Error!void {
        markFamilies(stmts, &env.families);
        for (stmts) |*s| {
            env.used[@backingInt(s.kind)] = true;
            const name = s.get("name");
            if (name == .atom and (s.kind == .model or s.kind == .subckt)) {
                const own = try arena.dupe(u8, name.atom);
                try env.declared.put(arena, own, {});
                try env.declared.put(arena, try std.ascii.allocLowerString(arena, own), {});
                if (s.kind == .subckt) try env.subckts.put(arena, own, {});
                if (s.kind == .model) {
                    const fam = s.get("family");
                    const kind: ?Kind = if (fam == .atom) schema.familyKind(fam.atom) else if (s.get("type") == .atom) .device else null;
                    if (kind) |k| {
                        try env.models.put(arena, own, k);
                        if (binBase(own)) |base| {
                            try env.models.put(arena, base, k);
                            try env.declared.put(arena, base, {});
                            try env.declared.put(arena, try std.ascii.allocLowerString(arena, base), {});
                        }
                    }
                }
            }
            if (name == .atom and s.kind == .func) try env.funcs.put(arena, try std.ascii.allocLowerString(arena, name.atom), {});
            try env.absorb(arena, s.body);
        }
    }
};

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
    library: bool = false,
    /// Names differing only by case are one name although the dialect is
    /// case sensitive: the file said so (`header folded`), or part of it is
    /// in a dialect that folds case. A dialect that folds case implies it.
    folds_case: bool = false,
    stmts: []Stmt = &.{},

    pub fn eql(a: *const Netlist, b: *const Netlist) bool {
        if (a.stmts.len != b.stmts.len) return false;
        for (a.stmts, b.stmts) |*x, *y| if (!x.eql(y)) return false;
        return true;
    }
};

fn looseVal(s: *const Stmt, i: usize) Value {
    const sl = schema.info(s.kind).slots[i];
    if (schema.info(s.kind).class == .analysis and sl.ty == .name) return .none;
    return s.at(i);
}

/// A long line may be re-wrapped on the way out; blanks are not content.
fn sameWords(a: []const u8, b: []const u8) bool {
    var x = std.mem.tokenizeAny(u8, a, " \t\r\n");
    var y = std.mem.tokenizeAny(u8, b, " \t\r\n");
    while (true) {
        const p = x.next();
        const q = y.next();
        if (p == null or q == null) return p == null and q == null;
        if (!std.mem.eql(u8, p.?, q.?)) return false;
    }
}

/// An instance of a Verilog-A model is a `device` where the dialect marks it
/// (ngspice's N) and a plain `instance` where it does not.
fn looseKind(k: Kind) Kind {
    return if (k == .device) .instance else k;
}

/// Blanks in an expression are not content either: a writer adds them where
/// its dialect needs them (Spectre reads `a!=b` as the name `a!`).
fn sameSquashed(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and (a[i] == ' ' or a[i] == '\t')) i += 1;
        while (j < b.len and (b[j] == ' ' or b[j] == '\t')) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
    }
}

fn looseValueEql(a: Value, b: Value) bool {
    if (a == .expr and b == .expr) return sameSquashed(a.expr, b.expr);
    if (a == .list and b == .list) {
        if (a.list.len != b.list.len) return false;
        for (a.list, b.list) |x, y| if (!looseValueEql(x, y)) return false;
        return true;
    }
    if (a == .params and b == .params) {
        if (a.params.len != b.params.len) return false;
        for (a.params, b.params) |x, y| if (!std.mem.eql(u8, x.key, y.key) or !looseValueEql(x.val, y.val)) return false;
        return true;
    }
    return a.eql(b);
}

fn looseStmtEql(a: *const Stmt, b: *const Stmt) bool {
    if (looseKind(a.kind) != looseKind(b.kind)) return false;
    if (a.kind == .@"opaque" and !sameWords(a.raw, b.raw)) return false;
    for (0..schema.info(a.kind).slots.len) |i| if (!looseValueEql(looseVal(a, i), looseVal(b, i))) return false;
    return looseListEql(a.body, b.body);
}

const Group = enum { circuit, analysis, control, options, skip };

fn groupOf(s: *const Stmt) Group {
    if (s.kind == .comment) return .skip;
    if (s.kind == .options) return .options;
    return switch (schema.info(s.kind).class) {
        .analysis => .analysis,
        .control => .control,
        else => .circuit,
    };
}

/// Options may be split over several statements, or filed under headings,
/// without meaning anything different: compare what they add up to.
fn optionsEql(a: []const Stmt, b: []const Stmt) bool {
    const slots = schema.info(.options).slots;
    const package = schema.slotIndex(.options, "package").?;
    for (slots, 0..) |sl, i| {
        if (i == package) continue;
        if (sl.ty == .params) {
            var ia: usize = 0;
            var ib: usize = 0;
            var pa: usize = 0;
            var pb: usize = 0;
            while (true) {
                while (ia < a.len and (a[ia].kind != .options or a[ia].at(i) != .params or pa >= a[ia].at(i).params.len)) : (pa = 0) ia += 1;
                while (ib < b.len and (b[ib].kind != .options or b[ib].at(i) != .params or pb >= b[ib].at(i).params.len)) : (pb = 0) ib += 1;
                if (ia == a.len or ib == b.len) {
                    if (ia != a.len or ib != b.len) return false;
                    break;
                }
                const x = a[ia].at(i).params[pa];
                const y = b[ib].at(i).params[pb];
                if (!std.mem.eql(u8, x.key, y.key) or !x.val.eql(y.val)) return false;
                pa += 1;
                pb += 1;
            }
            continue;
        }
        var va: Value = .none;
        var vb: Value = .none;
        for (a) |*s| if (s.kind == .options and s.at(i) != .none) {
            va = s.at(i);
        };
        for (b) |*s| if (s.kind == .options and s.at(i) != .none) {
            vb = s.at(i);
        };
        if (!va.eql(vb)) return false;
    }
    return true;
}

pub fn looseListEql(a: []const Stmt, b: []const Stmt) bool {
    // Analyses and control statements may sit anywhere among the devices
    // (VACASK keeps them in a block at the end): compare each group in its
    // own order.
    inline for (.{ Group.circuit, Group.analysis, Group.control }) |want| {
        var i: usize = 0;
        var j: usize = 0;
        while (true) {
            while (i < a.len and groupOf(&a[i]) != want) i += 1;
            while (j < b.len and groupOf(&b[j]) != want) j += 1;
            if (i == a.len or j == b.len) {
                if (i != a.len or j != b.len) return false;
                break;
            }
            if (!looseStmtEql(&a[i], &b[j])) return false;
            i += 1;
            j += 1;
        }
    }
    return optionsEql(a, b);
}

/// Same circuit and same analyses. Comments, analysis labels and the
/// position of analyses and control statements are not part of that.
pub fn sameCircuit(a: *const Netlist, b: *const Netlist) bool {
    return looseListEql(a.stmts, b.stmts);
}

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

pub const Severity = enum { info, warning, @"error" };

/// What kind of inexactness a report entry records. Tools that consume the
/// report should switch on this, not on the message text.
pub const Code = enum {
    /// Written with a write-only rule: reading the output back gives
    /// something else (HSPICE noise is an .AC line plus a .NOISE line).
    oneway,
    /// A source line no rule matched; written as a comment.
    untranslated,
    /// The target has no statement or model spelling for this at all.
    unsupported,
    /// A value had no place in the target statement and was left out.
    loss,
    /// The target needed a value the source did not give; one was made up.
    synthesized,
    /// Written faithfully, but the two simulators read it a little differently.
    caveat,
    /// An instance was renamed to satisfy the target's naming rules.
    rename,
    /// A label or boilerplate line with no meaning in the target was omitted.
    cosmetic,
    /// Malformed input or a name clash.
    invalid,
    /// Valid in both dialects, but each reads it differently.
    ambiguous,
};

/// The passes of a translation that report, in the order a netlist read
/// and written whole runs them (`Report.phase`).
pub const Phase = struct {
    pub const read: u8 = 0;
    pub const finish: u8 = 1;
    pub const bodies: u8 = 2;
    pub const bins: u8 = 3;
    pub const segments: u8 = 4;
    pub const kinds: u8 = 5;
    /// `sprack project`'s rewriting of include paths.
    pub const project: u8 = 6;
    pub const case: u8 = 7;
    pub const params: u8 = 8;
    pub const renames: u8 = 9;
    pub const masters: u8 = 10;
    pub const topology: u8 = 11;
    pub const fill: u8 = 12;
    pub const checks: u8 = 13;
    pub const checks_source: u8 = 14;
    pub const options: u8 = 15;
    pub const stats: u8 = 16;
    pub const pz: u8 = 17;
    pub const ceilings: u8 = 18;
    pub const write: u8 = 19;
    pub const caveat: u8 = 20;
};

/// `phase`: the pass that made the entry (`Report.phase`).
pub const Diag = struct { sev: Severity, code: Code, line: u32, msg: []const u8, phase: u8 = 0 };

/// Everything a translation did that was not exact. Nothing is dropped
/// without an entry here.
pub const Report = struct {
    arena: Allocator,
    items: std.ArrayList(Diag) = .empty,
    /// The pass adding entries now. A netlist read and written whole runs
    /// each pass over every statement in turn, so its entries come out in
    /// pass order; a stream runs every pass on one statement at a time and
    /// sorts by this at the end (`sortPhases`) to give the same order.
    phase: u8 = 0,
    /// A pass whose entries another makes again: nothing is recorded.
    mute: bool = false,

    pub fn init(arena: Allocator) Report {
        return .{ .arena = arena };
    }

    pub fn add(r: *Report, sev: Severity, code: Code, line: u32, comptime fmt: []const u8, args: anytype) void {
        if (r.mute) return;
        const msg = r.arena.print(fmt, args) catch return;
        r.items.append(r.arena, .{ .sev = sev, .code = code, .line = line, .msg = msg, .phase = r.phase }) catch {};
    }

    /// Entries from `from` on in pass order, each pass's in the order made.
    pub fn sortPhases(r: *Report, from: usize) void {
        std.sort.block(Diag, r.items.items[from..], {}, struct {
            fn lt(_: void, a: Diag, b: Diag) bool {
                return a.phase < b.phase;
            }
        }.lt);
    }

    pub fn countCode(r: *const Report, code: Code) usize {
        var n: usize = 0;
        for (r.items.items) |d| n += @intFromBool(d.code == code);
        return n;
    }

    pub fn count(r: *const Report, sev: Severity) usize {
        var n: usize = 0;
        for (r.items.items) |d| n += @intFromBool(d.sev == sev);
        return n;
    }

    pub fn hasErrors(r: *const Report) bool {
        return r.count(.@"error") > 0;
    }

    pub fn contains(r: *const Report, sev: Severity, needle: []const u8) bool {
        for (r.items.items) |d| {
            if (d.sev == sev and std.mem.indexOf(u8, d.msg, needle) != null) return true;
        }
        return false;
    }

    pub fn print(r: *const Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (r.items.items) |d| {
            if (d.line > 0) {
                try w.print("{s}[{s}]: line {d}: {s}\n", .{ @tagName(d.sev), @tagName(d.code), d.line, d.msg });
            } else {
                try w.print("{s}[{s}]: {s}\n", .{ @tagName(d.sev), @tagName(d.code), d.msg });
            }
        }
    }
};

/// A device whose model is declared in the same netlist as a different kind
/// of device (a D line on an NPN model) is a mistake in the source.
pub fn checkModelKinds(arena: Allocator, nl: *const Netlist, report: *Report, env: ?*const Env) Allocator.Error!void {
    var models: std.StringHashMapUnmanaged(Kind) = .empty;
    if (env) |e| {
        var it = e.models.iterator();
        while (it.next()) |kv| try models.put(arena, kv.key_ptr.*, kv.value_ptr.*);
    }
    var names: std.StringHashMapUnmanaged([]const u8) = .empty;
    var subckts: CaselessSet = .empty;
    try collectModels(arena, nl.stmts, &models, &subckts, null);
    try collectFamilies(arena, nl.stmts, &names, null);
    if (models.count() == 0) return;
    try checkKinds(nl.stmts, &models, &names, report);
}

/// Model name to family. With `src`, a name not in it is copied.
pub fn collectFamilies(arena: Allocator, stmts: []const Stmt, out: *std.StringHashMapUnmanaged([]const u8), src: ?[]const u8) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .model and s.get("family") == .atom and s.get("name") == .atom) {
            try putValue(out, arena, src, s.get("name").atom, s.get("family").atom);
        }
        try collectFamilies(arena, s.body, out, src);
    }
}

pub fn checkKinds(stmts: []const Stmt, models: *const std.StringHashMapUnmanaged(Kind), names: *const std.StringHashMapUnmanaged([]const u8), report: *Report) Allocator.Error!void {
    for (stmts) |*s| {
        try checkKinds(s.body, models, names, report);
        if (schema.info(s.kind).class != .device or s.kind == .instance) continue;
        const master = s.get("master");
        if (master != .atom) continue;
        const want = models.get(master.atom) orelse continue;
        if (want == s.kind or want == .device or s.kind == .device) continue;
        report.add(.warning, .invalid, s.line, "'{s}' is a {s} but its model '{s}' is declared as a {s} model", .{
            if (s.get("name") == .atom) s.get("name").atom else "?", @tagName(s.kind), master.atom, names.get(master.atom) orelse "?",
        });
    }
}

/// Readers that cannot tell a transistor from a subcircuit call by syntax
/// (Spectre, VACASK) produce `instance`. Where the master is a model declared
/// in the same netlist, retag the instance as the device that model is.
/// The family given to a model whose type the tables do not list, once a
/// lettered device (M, Q, D, ...) is seen to use it: such a model is one of
/// the simulator's own, not a Verilog-A module, and has no known name in
/// any other dialect.
pub const unlisted_builtin = "builtin";

fn collectUnlisted(arena: Allocator, stmts: []Stmt, out: *std.StringHashMapUnmanaged(*Stmt)) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .model and s.get("family") == .none and s.get("type") == .atom and s.get("name") == .atom) {
            try out.put(arena, s.get("name").atom, s);
        }
        try collectUnlisted(arena, s.body, out);
    }
}

fn markUsers(arena: Allocator, stmts: []const Stmt, models: *const std.StringHashMapUnmanaged(*Stmt)) Allocator.Error!void {
    for (stmts) |*s| {
        try markUsers(arena, s.body, models);
        if (schema.info(s.kind).class != .device or s.kind == .instance or s.kind == .device) continue;
        const master = s.get("master");
        if (master != .atom) continue;
        const m = models.get(master.atom) orelse continue;
        try m.set(arena, schema.slotIndex(.model, "family").?, .{ .atom = unlisted_builtin });
    }
}

pub fn markUnlistedBuiltins(arena: Allocator, nl: *Netlist) Allocator.Error!void {
    var models: std.StringHashMapUnmanaged(*Stmt) = .empty;
    try collectUnlisted(arena, nl.stmts, &models);
    if (models.count() > 0) try markUsers(arena, nl.stmts, &models);
}

pub fn resolveInstances(arena: Allocator, nl: *Netlist, env: ?*const Env) Allocator.Error!void {
    var models: std.StringHashMapUnmanaged(Kind) = .empty;
    var subckts: CaselessSet = .empty;
    if (env) |e| {
        var it = e.models.iterator();
        while (it.next()) |kv| try models.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        var si = e.subckts.keyIterator();
        while (si.next()) |k| try subckts.put(arena, k.*, {});
    }
    try collectModels(arena, nl.stmts, &models, &subckts, null);
    if (models.count() == 0) return;
    try retag(arena, nl.stmts, &models, &subckts);
}

/// `nch` of the model name `nch.12`: SPICE bins a model by numbered
/// cards, and an instance names the base.
pub fn binBase(name: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    if (dot == 0 or dot + 1 == name.len) return null;
    for (name[dot + 1 ..]) |c| if (!std.ascii.isDigit(c)) return null;
    return name[0..dot];
}

/// With `src`, a name not in it is copied (the statements go away).
pub fn collectModels(arena: Allocator, stmts: []const Stmt, out: *std.StringHashMapUnmanaged(Kind), subckts: *CaselessSet, src: ?[]const u8) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .subckt and s.get("name") == .atom) try putName(subckts, arena, src, s.get("name").atom);
        if (s.kind == .model) {
            const fam = s.get("family");
            const name = s.get("name");
            var kind: ?Kind = null;
            if (fam == .atom and name == .atom) {
                kind = schema.familyKind(fam.atom);
            } else if (name == .atom and s.get("type") == .atom) {
                // A model type the tables do not know, typically a Verilog-A module.
                kind = .device;
            }
            if (kind) |k| {
                try putValue(out, arena, src, name.atom, k);
                if (binBase(name.atom)) |base| try putValue(out, arena, src, base, k);
            }
        }
        try collectModels(arena, s.body, out, subckts, src);
    }
}

pub fn sameSlots(a: Kind, b: Kind) bool {
    const x = schema.info(a).slots;
    const y = schema.info(b).slots;
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p.name, q.name) or p.ty != q.ty or p.list != q.list) return false;
    return true;
}

pub fn retag(arena: Allocator, stmts: []Stmt, models: *const std.StringHashMapUnmanaged(Kind), subckts: *const CaselessSet) Allocator.Error!void {
    for (stmts) |*s| {
        try retag(arena, s.body, models, subckts);
        // One element letter, two device kinds told apart by the model
        // (HSPICE writes a MESFET as a J element with a MESFET level).
        if (s.kind != .instance and schema.info(s.kind).class == .device) {
            const m = s.get("master");
            const want = if (m == .atom) models.get(m.atom) orelse continue else continue;
            if (want != s.kind and want != .device and sameSlots(s.kind, want)) s.kind = want;
            continue;
        }
        if (s.kind != .instance) continue;
        const master = s.get("master");
        // A subcircuit of the name wins over a model of it.
        if (master != .atom or subckts.contains(master.atom)) continue;
        const target = models.get(master.atom) orelse continue;
        if (target == .device) {
            s.kind = .device;
            continue;
        }
        const nodes = s.get("nodes");
        if (nodes != .list) continue;
        const slots = schema.info(target).slots;
        var want: usize = 0;
        for (slots) |sl| want += @intFromBool(sl.ty == .node and !sl.list);
        // A BJT may leave its substrate node off.
        // The substrate, bulk and thermal terminals are optional.
        const least: usize = if (target == .bjt or target == .mosfet) 3 else want;
        const ok = nodes.list.len >= least and nodes.list.len <= want;
        if (!ok) continue;
        var out = try newStmt(arena, target, s.line);
        out.tail = s.tail;
        var buf: [schema.max_slots]Value = @splat(.none);
        const vals = buf[0..slots.len];
        var n: usize = 0;
        for (slots, 0..) |sl, i| {
            if (sl.ty == .node and !sl.list) {
                if (n < nodes.list.len) vals[i] = nodes.list[n];
                n += 1;
            } else if (std.mem.eql(u8, sl.name, "name")) {
                vals[i] = s.get("name");
            } else if (std.mem.eql(u8, sl.name, "master")) {
                vals[i] = master;
            } else if (sl.ty == .params) {
                vals[i] = s.get("params");
            }
        }
        // What a SPICE line says positionally (`D1 a k dmod 2`) an instance
        // line says by name (`area=2`): put it where the device kind keeps it.
        const pi = schema.slotIndex(target, "params");
        if (pi != null and vals[pi.?] == .params) {
            var kept: std.ArrayList(Param) = .empty;
            for (vals[pi.?].params) |p| {
                const si = schema.slotIndex(target, p.key);
                if (si != null and slots[si.?].ty == .value and !slots[si.?].list and vals[si.?] == .none and p.val != .none) {
                    vals[si.?] = p.val;
                } else try kept.append(arena, p);
            }
            vals[pi.?] = if (kept.items.len > 0) .{ .params = try kept.toOwnedSlice(arena) } else .none;
        }
        try out.pack(arena, vals);
        s.* = out;
    }
}

/// The reverse of `resolveInstances`, for writers whose dialect has no
/// dedicated statement for a device kind: spell it as a generic instance.
/// Returns null when that would lose a value (a resistor's `r`, say).
pub fn demoteToInstance(arena: Allocator, s: *const Stmt) Allocator.Error!?Stmt {
    if (schema.info(s.kind).class != .device or s.kind == .instance) return null;
    if (schema.slotIndex(s.kind, "master") == null) return null;
    if (s.kind == .device) {
        var same = s.*;
        same.kind = .instance;
        return same;
    }
    var out = try newStmt(arena, .instance, s.line);
    out.tail = s.tail;
    var buf: [schema.max_slots]Value = @splat(.none);
    const vals = buf[0..schema.info(.instance).slots.len];
    var nodes: std.ArrayList(Value) = .empty;
    var params: std.ArrayList(Param) = .empty;
    var extra: usize = 0;
    for (schema.info(s.kind).slots, 0..) |sl, i| {
        const v = s.at(i);
        if (v == .none) continue;
        if (sl.ty == .node) {
            try nodes.append(arena, v);
        } else if (std.mem.eql(u8, sl.name, "name")) {
            vals[schema.slotIndex(.instance, "name").?] = v;
        } else if (std.mem.eql(u8, sl.name, "master")) {
            vals[schema.slotIndex(.instance, "master").?] = v;
        } else if (sl.ty == .params) {
            if (v == .params) try params.appendSlice(arena, v.params);
        } else if (sl.ty == .value) {
            // `D1 a k dmod 2` says area positionally; an instance says area=2.
            try params.insert(arena, extra, .{ .key = sl.name, .val = v });
            extra += 1;
        } else return null;
    }
    if (vals[schema.slotIndex(.instance, "master").?] == .none) return null;
    vals[schema.slotIndex(.instance, "nodes").?] = .{ .list = try nodes.toOwnedSlice(arena) };
    if (params.items.len > 0) vals[schema.slotIndex(.instance, "params").?] = .{ .params = try params.toOwnedSlice(arena) };
    try out.pack(arena, vals);
    return out;
}

// b1: sweeps

/// The instance parameter a sweep of an instance changes when it names
/// none: a source's dc value, a resistor's resistance.
pub fn principalParam(kind: Kind) ?[]const u8 {
    return switch (kind) {
        .vsource, .isource => "dc",
        .resistor => "r",
        .capacitor => "c",
        .inductor => "l",
        else => null,
    };
}

const KindMap = std.HashMapUnmanaged([]const u8, Kind, Caseless, std.hash_map.default_max_load_percentage);

/// Puts the sweeps of a netlist (`dc`, `step`) in canonical form. A swept
/// name that is no instance but a parameter of the netlist is a parameter
/// sweep (`.dc rv ...`), and `temp` is the temperature; an instance
/// parameter that is the instance's own value is not said. A `step` with no
/// body takes every analysis beside it (`.step` applies to the whole netlist).
pub fn resolveSweeps(arena: Allocator, nl: *Netlist) Allocator.Error!void {
    if (!hasSweep(nl.stmts)) return;
    var insts: KindMap = .empty;
    var params: CaselessSet = .empty;
    try sweepNames(arena, nl.stmts, &insts, &params, true);
    try fixSweeps(arena, nl.stmts, &insts, &params);
    nl.stmts = try gatherSteps(arena, nl.stmts);
    try foldSteps(arena, nl.stmts);
}

/// A step around one DC sweep of a single loop, by start, stop and step
/// or points, is that sweep's outer loop (Spectre writes a nested DC sweep so).
fn foldSteps(arena: Allocator, stmts: []Stmt) Allocator.Error!void {
    for (stmts) |*s| {
        try foldSteps(arena, s.body);
        if (s.kind != .step or s.body.len != 1 or s.body[0].kind != .dc) continue;
        const dc = &s.body[0];
        const own = [_][]const u8{ "values", "data", "devparam", "params" };
        const outer = [_][]const u8{ "src2", "param2", "var2" };
        const ok = for (own) |n| {
            if (s.at(schema.slotIndex(.step, n).?) != .none) break false;
        } else for (outer) |n| {
            if (dc.at(schema.slotIndex(.dc, n).?) != .none) break false;
        } else true;
        if (!ok) continue;
        var out = dc.*;
        try out.own(arena);
        const pairs = [_][2][]const u8{ .{ "src", "src2" }, .{ "param", "param2" }, .{ "var", "var2" }, .{ "start", "start2" }, .{ "stop", "stop2" }, .{ "step", "step2" }, .{ "sweep", "sweep2" }, .{ "points", "points2" } };
        for (pairs) |p| try out.set(arena, schema.slotIndex(.dc, p[1]).?, s.at(schema.slotIndex(.step, p[0]).?));
        s.* = out;
    }
}

pub fn hasSweep(stmts: []const Stmt) bool {
    for (stmts) |*s| if (s.kind == .dc or s.kind == .step or hasSweep(s.body)) return true;
    return false;
}

fn sweepNames(arena: Allocator, stmts: []const Stmt, insts: *KindMap, params: *CaselessSet, top: bool) Allocator.Error!void {
    for (stmts) |*s| {
        if (schema.info(s.kind).class == .device and s.get("name") == .atom) try insts.put(arena, s.get("name").atom, s.kind);
        if (top and s.kind == .param and s.get("params") == .params) {
            for (s.get("params").params) |p| try params.put(arena, p.key, {});
        }
        // A subcircuit's parameters are not the netlist's.
        try sweepNames(arena, s.body, insts, params, top and s.kind != .subckt);
    }
}

fn fixSweeps(arena: Allocator, stmts: []Stmt, insts: *const KindMap, params: *const CaselessSet) Allocator.Error!void {
    for (stmts) |*s| {
        try fixSweeps(arena, s.body, insts, params);
        if (s.kind != .dc and s.kind != .step) continue;
        try s.own(arena);
        try fixTarget(arena, s, "src", "param", "var", "devparam", insts, params);
        if (s.kind == .dc) try fixTarget(arena, s, "src2", "param2", "var2", "", insts, params);
    }
}

fn fixTarget(arena: Allocator, s: *Stmt, src: []const u8, param: []const u8, v: []const u8, devparam: []const u8, insts: *const KindMap, params: *const CaselessSet) Allocator.Error!void {
    const si = schema.slotIndex(s.kind, src).?;
    const name = switch (s.at(si)) {
        .atom => |a| a,
        else => return,
    };
    if (insts.get(name)) |kind| {
        if (devparam.len == 0) return;
        const di = schema.slotIndex(s.kind, devparam).?;
        const dp = s.at(di);
        const own = principalParam(kind) orelse return;
        if (dp == .atom and std.ascii.eqlIgnoreCase(dp.atom, own)) try s.set(arena, di, .none);
        return;
    }
    if (params.contains(name)) {
        try s.set(arena, schema.slotIndex(s.kind, param).?, .{ .atom = name });
    } else if (std.ascii.eqlIgnoreCase(name, "temp")) {
        try s.set(arena, schema.slotIndex(s.kind, v).?, .{ .atom = "temp" });
    } else return;
    try s.set(arena, si, .none);
}

/// Steps without a body take every analysis of their list: the first step
/// the second, the last one the analyses. The first written is the outer loop.
pub fn gatherSteps(arena: Allocator, stmts: []Stmt) Allocator.Error![]Stmt {
    var first: ?usize = null;
    var analyses: usize = 0;
    for (stmts, 0..) |*s, i| {
        if (s.kind == .step and s.body.len == 0 and first == null) first = i;
        if (s.kind != .step and s.kind != .alter and schema.info(s.kind).class == .analysis) analyses += 1;
    }
    if (first == null or analyses == 0) return stmts;
    var out: std.ArrayList(Stmt) = .empty;
    var chain: std.ArrayList(Stmt) = .empty;
    var inner: std.ArrayList(Stmt) = .empty;
    var slot: usize = 0;
    for (stmts) |s| {
        if (s.kind == .step and s.body.len == 0) {
            if (chain.items.len == 0) slot = out.items.len;
            if (chain.items.len == 0) try out.append(arena, s);
            try chain.append(arena, s);
        } else if (schema.info(s.kind).class == .analysis and s.kind != .step and s.kind != .alter) {
            try inner.append(arena, s);
        } else try out.append(arena, s);
    }
    // Innermost first: each step's body is the next one.
    var body = try inner.toOwnedSlice(arena);
    var n = chain.items.len;
    while (n > 0) : (n -= 1) {
        var st = chain.items[n - 1];
        st.body = body;
        body = try arena.dupe(Stmt, &.{st});
    }
    out.items[slot] = body[0];
    return out.toOwnedSlice(arena);
}

test "number equality ignores spelling" {
    const a: Value = .{ .num = .init("1000", 0) };
    const b: Value = .{ .num = .init("1", 3) };
    try std.testing.expect(a.eql(b));
}

test "the same circuit: blanks in an expression are not content, anything else is" {
    try std.testing.expect(sameSquashed("(a<b) && (a!=b)", "(a<b)&&(a != b)"));
    try std.testing.expect(sameSquashed("", " \t"));
    try std.testing.expect(!sameSquashed("a!=b", "a==b"));
    try std.testing.expect(!sameSquashed("a b", "a"));
    const x: Value = .{ .params = &.{.{ .key = "t", .val = .{ .list = &.{.{ .expr = "a != b" }} } }} };
    const y: Value = .{ .params = &.{.{ .key = "t", .val = .{ .list = &.{.{ .expr = "a!=b" }} } }} };
    try std.testing.expect(looseValueEql(x, y) and !x.eql(y));
    // Only an expression: a name, a string or a key with a blank is another.
    try std.testing.expect(!looseValueEql(.{ .atom = "a b" }, .{ .atom = "ab" }));
    try std.testing.expect(!looseValueEql(.{ .expr = "a" }, .{ .atom = "a" }));
}
