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

pub const Stmt = struct {
    kind: Kind,
    /// One entry per slot of `kind`, in schema order.
    vals: []Value = &.{},
    body: []Stmt = &.{},
    /// Source text of a statement no rule matched.
    raw: []const u8 = "",
    line: u32 = 0,
    /// Trailing comment on the statement's line.
    tail: []const u8 = "",
    /// The dialect this statement was read in, when it is not the
    /// netlist's (a block of text added to a circuit built in Python).
    /// Empty: the netlist's. A target of the same dialect writes the
    /// statement's private values (options, analysis parameters) as they are.
    dialect: []const u8 = "",

    pub fn get(s: *const Stmt, comptime slot: []const u8) Value {
        const i = schema.slotIndex(s.kind, slot) orelse return .none;
        return s.vals[i];
    }

    pub fn eql(a: *const Stmt, b: *const Stmt) bool {
        if (a.kind != b.kind or a.vals.len != b.vals.len or a.body.len != b.body.len) return false;
        if (a.kind == .@"opaque" and !std.mem.eql(u8, a.raw, b.raw)) return false;
        for (a.vals, b.vals) |x, y| if (!x.eql(y)) return false;
        for (a.body, b.body) |*x, *y| if (!x.eql(y)) return false;
        return true;
    }
};

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
    /// Lower-cased names of user-defined functions.
    funcs: std.StringHashMapUnmanaged(void) = .empty,
    /// Statement kinds used anywhere in the project. The top netlist writes
    /// the boilerplate (`needs`) for all of them.
    used: [schema.kind_count]bool = @splat(false),

    /// Everything is copied into `arena`, so `stmts` may be freed afterwards.
    pub fn absorb(env: *Env, arena: Allocator, stmts: []const Stmt) Allocator.Error!void {
        for (stmts) |*s| {
            env.used[@backingInt(s.kind)] = true;
            const name = s.get("name");
            if (name == .atom and (s.kind == .model or s.kind == .subckt)) {
                const own = try arena.dupe(u8, name.atom);
                try env.declared.put(arena, own, {});
                try env.declared.put(arena, try std.ascii.allocLowerString(arena, own), {});
                if (s.kind == .model) {
                    const fam = s.get("family");
                    if (fam == .atom) {
                        if (schema.familyKind(fam.atom)) |k| try env.models.put(arena, own, k);
                    } else if (s.get("type") == .atom) try env.models.put(arena, own, .device);
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
    return s.vals[i];
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

fn looseStmtEql(a: *const Stmt, b: *const Stmt) bool {
    if (looseKind(a.kind) != looseKind(b.kind) or a.vals.len != b.vals.len) return false;
    if (a.kind == .@"opaque" and !sameWords(a.raw, b.raw)) return false;
    for (0..a.vals.len) |i| if (!looseVal(a, i).eql(looseVal(b, i))) return false;
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
                while (ia < a.len and (a[ia].kind != .options or a[ia].vals[i] != .params or pa >= a[ia].vals[i].params.len)) : (pa = 0) ia += 1;
                while (ib < b.len and (b[ib].kind != .options or b[ib].vals[i] != .params or pb >= b[ib].vals[i].params.len)) : (pb = 0) ib += 1;
                if (ia == a.len or ib == b.len) {
                    if (ia != a.len or ib != b.len) return false;
                    break;
                }
                const x = a[ia].vals[i].params[pa];
                const y = b[ib].vals[i].params[pb];
                if (!std.mem.eql(u8, x.key, y.key) or !x.val.eql(y.val)) return false;
                pa += 1;
                pb += 1;
            }
            continue;
        }
        var va: Value = .none;
        var vb: Value = .none;
        for (a) |*s| if (s.kind == .options and s.vals[i] != .none) {
            va = s.vals[i];
        };
        for (b) |*s| if (s.kind == .options and s.vals[i] != .none) {
            vb = s.vals[i];
        };
        if (!va.eql(vb)) return false;
    }
    return true;
}

fn looseListEql(a: []const Stmt, b: []const Stmt) bool {
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
    const vals = try arena.alloc(Value, schema.info(kind).slots.len);
    @memset(vals, .none);
    return .{ .kind = kind, .vals = vals, .line = line };
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

pub const Diag = struct { sev: Severity, code: Code, line: u32, msg: []const u8 };

/// Everything a translation did that was not exact. Nothing is dropped
/// without an entry here.
pub const Report = struct {
    arena: Allocator,
    items: std.ArrayList(Diag) = .empty,

    pub fn init(arena: Allocator) Report {
        return .{ .arena = arena };
    }

    pub fn add(r: *Report, sev: Severity, code: Code, line: u32, comptime fmt: []const u8, args: anytype) void {
        const msg = r.arena.print(fmt, args) catch return;
        r.items.append(r.arena, .{ .sev = sev, .code = code, .line = line, .msg = msg }) catch {};
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
    try collectModels(arena, nl.stmts, &models);
    try collectFamilies(arena, nl.stmts, &names);
    if (models.count() == 0) return;
    try checkKinds(nl.stmts, &models, &names, report);
}

fn collectFamilies(arena: Allocator, stmts: []const Stmt, out: *std.StringHashMapUnmanaged([]const u8)) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .model and s.get("family") == .atom and s.get("name") == .atom) {
            try out.put(arena, s.get("name").atom, s.get("family").atom);
        }
        try collectFamilies(arena, s.body, out);
    }
}

fn checkKinds(stmts: []const Stmt, models: *const std.StringHashMapUnmanaged(Kind), names: *const std.StringHashMapUnmanaged([]const u8), report: *Report) Allocator.Error!void {
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

fn markUsers(stmts: []const Stmt, models: *const std.StringHashMapUnmanaged(*Stmt)) void {
    for (stmts) |*s| {
        markUsers(s.body, models);
        if (schema.info(s.kind).class != .device or s.kind == .instance or s.kind == .device) continue;
        const master = s.get("master");
        if (master != .atom) continue;
        const m = models.get(master.atom) orelse continue;
        m.vals[schema.slotIndex(.model, "family").?] = .{ .atom = unlisted_builtin };
    }
}

pub fn markUnlistedBuiltins(arena: Allocator, nl: *Netlist) Allocator.Error!void {
    var models: std.StringHashMapUnmanaged(*Stmt) = .empty;
    try collectUnlisted(arena, nl.stmts, &models);
    if (models.count() > 0) markUsers(nl.stmts, &models);
}

pub fn resolveInstances(arena: Allocator, nl: *Netlist, env: ?*const Env) Allocator.Error!void {
    var models: std.StringHashMapUnmanaged(Kind) = .empty;
    if (env) |e| {
        var it = e.models.iterator();
        while (it.next()) |kv| try models.put(arena, kv.key_ptr.*, kv.value_ptr.*);
    }
    try collectModels(arena, nl.stmts, &models);
    if (models.count() == 0) return;
    try retag(arena, nl.stmts, &models);
}

fn collectModels(arena: Allocator, stmts: []const Stmt, out: *std.StringHashMapUnmanaged(Kind)) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .model) {
            const fam = s.get("family");
            const name = s.get("name");
            if (fam == .atom and name == .atom) {
                if (schema.familyKind(fam.atom)) |k| try out.put(arena, name.atom, k);
            } else if (name == .atom and s.get("type") == .atom) {
                // A model type the tables do not know, typically a Verilog-A module.
                try out.put(arena, name.atom, .device);
            }
        }
        try collectModels(arena, s.body, out);
    }
}

fn retag(arena: Allocator, stmts: []Stmt, models: *const std.StringHashMapUnmanaged(Kind)) Allocator.Error!void {
    for (stmts) |*s| {
        try retag(arena, s.body, models);
        if (s.kind != .instance) continue;
        const master = s.get("master");
        if (master != .atom) continue;
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
        var n: usize = 0;
        for (slots, 0..) |sl, i| {
            if (sl.ty == .node and !sl.list) {
                if (n < nodes.list.len) out.vals[i] = nodes.list[n];
                n += 1;
            } else if (std.mem.eql(u8, sl.name, "name")) {
                out.vals[i] = s.get("name");
            } else if (std.mem.eql(u8, sl.name, "master")) {
                out.vals[i] = master;
            } else if (sl.ty == .params) {
                out.vals[i] = s.get("params");
            }
        }
        // What a SPICE line says positionally (`D1 a k dmod 2`) an instance
        // line says by name (`area=2`): put it where the device kind keeps it.
        const pi = schema.slotIndex(target, "params");
        if (pi != null and out.vals[pi.?] == .params) {
            var kept: std.ArrayList(Param) = .empty;
            for (out.vals[pi.?].params) |p| {
                const si = schema.slotIndex(target, p.key);
                if (si != null and slots[si.?].ty == .value and !slots[si.?].list and out.vals[si.?] == .none and p.val != .none) {
                    out.vals[si.?] = p.val;
                } else try kept.append(arena, p);
            }
            out.vals[pi.?] = if (kept.items.len > 0) .{ .params = try kept.toOwnedSlice(arena) } else .none;
        }
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
    var nodes: std.ArrayList(Value) = .empty;
    var params: std.ArrayList(Param) = .empty;
    var extra: usize = 0;
    for (schema.info(s.kind).slots, 0..) |sl, i| {
        const v = s.vals[i];
        if (v == .none) continue;
        if (sl.ty == .node) {
            try nodes.append(arena, v);
        } else if (std.mem.eql(u8, sl.name, "name")) {
            out.vals[schema.slotIndex(.instance, "name").?] = v;
        } else if (std.mem.eql(u8, sl.name, "master")) {
            out.vals[schema.slotIndex(.instance, "master").?] = v;
        } else if (sl.ty == .params) {
            if (v == .params) try params.appendSlice(arena, v.params);
        } else if (sl.ty == .value) {
            // `D1 a k dmod 2` says area positionally; an instance says area=2.
            try params.insert(arena, extra, .{ .key = sl.name, .val = v });
            extra += 1;
        } else return null;
    }
    if (out.get("master") == .none) return null;
    out.vals[schema.slotIndex(.instance, "nodes").?] = .{ .list = try nodes.toOwnedSlice(arena) };
    if (params.items.len > 0) out.vals[schema.slotIndex(.instance, "params").?] = .{ .params = try params.toOwnedSlice(arena) };
    return out;
}

test "number equality ignores spelling" {
    const a: Value = .{ .num = .init("1000", 0) };
    const b: Value = .{ .num = .init("1", 3) };
    try std.testing.expect(a.eql(b));
}
