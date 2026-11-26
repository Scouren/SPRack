//! Exact arithmetic on values (`arith`, `halve`) and what a grammar's
//! `threshold` and `convert` lines do with it to a statement's values.
//!
//! Contents:
//! - `pub const Op = enum`
//! - `pub const Thresholds`
//! - `pub fn canonText(arena: Allocator, v: ir.Value) Allocator.Error![]const u8`
//! - `pub fn arith(arena: Allocator, op: Op, a: ir.Value, b: ir.Value) Allocator.Error!ir.Value`
//! - `pub fn halve(arena: Allocator, v: ir.Value) Allocator.Error!ir.Value`
//! - `pub fn convert(arena: Allocator, g: *const Grammar, stmts: []ir.Stmt,
//!   forward: bool) Allocator.Error!void`
//! - `pub fn convertFlat(arena: Allocator, g: *const Grammar, stmts: []ir.Stmt,
//!   forward: bool) Allocator.Error!void`

const std = @import("std");
const grammar = @import("grammar");
const ir = @import("ir");
const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const testing = std.testing;

pub const Op = enum { add, sub, recip, mul, div };

pub const Thresholds =
    struct { params: []const ir.Param, changed: bool = false, no_half: bool = false };

/// Apply a grammar's `threshold` line for `family` to a model card's
/// parameters. `forward` (writing) turns SPICE's midpoint and half-width into
/// on and off levels; otherwise (reading) the levels go back. `no_half` says
/// a midpoint came with no hysteresis, which gives equal levels.
pub fn thresholds(
    arena: Allocator,
    g: *const Grammar,
    family: []const u8,
    params: []const ir.Param,
    forward: bool,
) Allocator.Error!Thresholds {
    const th = for (g.thresholds) |*t| {
        if (std.mem.eql(u8, t.family, family)) break t;
    } else return .{ .params = params };
    const a_key, const b_key = if (forward) .{ th.mid, th.half } else .{ th.on, th.off };
    var a: ir.Value = .none;
    var b: ir.Value = .none;
    var rest: std.ArrayList(ir.Param) = .empty;
    var at: usize = 0; // the pair goes where the first of the two was
    for (params) |p| {
        if (std.ascii.eqlIgnoreCase(p.key, a_key) or std.ascii.eqlIgnoreCase(p.key, b_key)) {
            if (a == .none and b == .none) at = rest.items.len;
        }
        if (std.ascii.eqlIgnoreCase(p.key, a_key)) {
            a = p.val;
        } else if (std.ascii.eqlIgnoreCase(p.key, b_key)) {
            b = p.val;
        } else try rest.append(arena, p);
    }
    if (a == .none) return .{ .params = params };
    if (forward) {
        // on = mid + half, off = mid - half
        const no_half = b == .none or (b == .num and decimal(b.num) != null and decimal(b.num).?[0] == 0);
        const h: ir.Value = if (b == .none) .{ .num = .init("0", 0) } else b;
        try rest.insertSlice(arena, at, &.{
            .{ .key = th.on, .val = try arith(arena, .add, a, h) },
            .{ .key = th.off, .val = try arith(arena, .sub, a, h) },
        });
        return .{ .params = rest.items, .changed = true, .no_half = no_half };
    }
    // mid = (on + off) / 2, half = (on - off) / 2
    if (b == .none) return .{ .params = params };
    try rest.insertSlice(arena, at, &.{
        .{ .key = th.mid, .val = try halve(arena, try arith(arena, .add, a, b)) },
        .{ .key = th.half, .val = try halve(arena, try arith(arena, .sub, a, b)) },
    });
    return .{ .params = rest.items, .changed = true };
}

/// A number or an expression as canonical expression text.
pub fn canonText(arena: Allocator, v: ir.Value) Allocator.Error![]const u8 {
    return switch (v) {
        .num => |n| if (n.exp10 == 0)
            n.digits()
        else
            try std.fmt.allocPrint(arena, "{s}e{d}", .{ n.digits(), n.exp10 }),
        .expr => |s| s,
        .atom => |s| s,
        else => "0",
    };
}

/// `a + b`, `a - b`, `a * b`, `a / b` or `1 / a`, exact when both are plain
/// numbers (for `1 / a`, when `a` is a power of ten; for `a / b`, when `b`
/// has no prime factor but 2 and 5); otherwise a canonical expression.
pub fn arith(arena: Allocator, op: Op, a: ir.Value, b: ir.Value) Allocator.Error!ir.Value {
    const da = if (a == .num) decimal(a.num) else null;
    const db = if (b == .num) decimal(b.num) else null;
    switch (op) {
        .recip => if (da) |x| {
            var m = if (x[0] < 0) -x[0] else x[0];
            var k: i32 = 0;
            while (m >= 10 and @rem(m, 10) == 0) : (k += 1) m = @divExact(m, 10);
            if (m == 1) return .{ .num = .init(if (x[0] < 0) "-1" else "1", -(x[1] + k)) };
        },
        .mul => if (da != null and db != null) exact: {
            var m = std.math.mul(i128, da.?[0], db.?[0]) catch break :exact;
            var ex = da.?[1] + db.?[1];
            while (m != 0 and @rem(m, 10) == 0) : (ex += 1) m = @divExact(m, 10);
            while (m != 0 and @mod(ex, 3) != 0) : (ex -= 1) m *= 10;
            return .{ .num = .init(try std.fmt.allocPrint(arena, "{d}", .{m}), ex) };
        },
        // Exact by a divisor with no prime factor but 2 and 5: a / 2 is
        // a * 5 / 10.
        .div => if (da != null and db != null) exact: {
            var d = db.?[0];
            var m = da.?[0];
            var ex = da.?[1] - db.?[1];
            if (d == 0) break :exact;
            if (d < 0) {
                d = -d;
                m = -m;
            }
            while (@rem(d, 10) == 0) : (ex -= 1) d = @divExact(d, 10);
            while (@rem(d, 2) == 0) : (ex -= 1) {
                d = @divExact(d, 2);
                m = std.math.mul(i128, m, 5) catch break :exact;
            }
            while (@rem(d, 5) == 0) : (ex -= 1) {
                d = @divExact(d, 5);
                m = std.math.mul(i128, m, 2) catch break :exact;
            }
            if (d != 1) break :exact;
            while (m != 0 and @rem(m, 10) == 0) : (ex += 1) m = @divExact(m, 10);
            while (m != 0 and @mod(ex, 3) != 0) : (ex -= 1) m *= 10;
            return .{ .num = .init(try std.fmt.allocPrint(arena, "{d}", .{m}), ex) };
        },
        .add, .sub => if (da != null and db != null) exact: {
            const e = @min(da.?[1], db.?[1]);
            const ma = std.math.mul(
                i128,
                da.?[0],
                std.math.powi(i128, 10, @as(i128, da.?[1] - e)) catch break :exact,
            ) catch break :exact;
            const mb = std.math.mul(
                i128,
                db.?[0],
                std.math.powi(i128, 10, @as(i128, db.?[1] - e)) catch break :exact,
            ) catch break :exact;
            var m = (if (op == .add)
                std.math.add(i128, ma, mb)
            else
                std.math.sub(i128, ma, mb)) catch break :exact;
            var ex = e;
            // Fewest digits, at an exponent a scale suffix can spell (900n, 1u).
            while (m != 0 and @rem(m, 10) == 0) : (ex += 1) m = @divExact(m, 10);
            while (m != 0 and @mod(ex, 3) != 0) : (ex -= 1) m *= 10;
            return .{ .num = .init(try std.fmt.allocPrint(arena, "{d}", .{m}), ex) };
        },
    }
    const ta = try canonText(arena, a);
    return .{ .expr = switch (op) {
        .recip => try std.fmt.allocPrint(arena, "1/({s})", .{ta}),
        .add => try std.fmt.allocPrint(arena, "{s} + ({s})", .{ ta, try canonText(arena, b) }),
        .sub => try std.fmt.allocPrint(arena, "{s} - ({s})", .{ ta, try canonText(arena, b) }),
        .mul => try std.fmt.allocPrint(arena, "({s}) * ({s})", .{ ta, try canonText(arena, b) }),
        .div => try std.fmt.allocPrint(arena, "({s}) / ({s})", .{ ta, try canonText(arena, b) }),
    } };
}

/// Half a value: exact for a decimal number, else an expression.
pub fn halve(arena: Allocator, v: ir.Value) Allocator.Error!ir.Value {
    if (v == .num) if (decimal(v.num)) |x| {
        const m = std.math.mul(i128, x[0], 5) catch return .{
            .expr = try std.fmt.allocPrint(arena, "({s})/2", .{try canonText(arena, v)}),
        };
        return .{ .num = .init(try std.fmt.allocPrint(arena, "{d}", .{m}), x[1] - 1) };
    };
    return .{ .expr = try std.fmt.allocPrint(arena, "({s})/2", .{try canonText(arena, v)}) };
}

/// Apply a grammar's `convert` lines in place: `forward` turns canonical
/// values into the dialect's (writing), otherwise the dialect's into
/// canonical ones (reading, in reverse order). Values are copied before
/// they change; bodies are walked too.
pub fn convert(
    arena: Allocator,
    g: *const Grammar,
    stmts: []ir.Stmt,
    forward: bool,
) Allocator.Error!void {
    if (g.converts.len == 0) return;
    for (stmts) |*st| if (st.body.len > 0) {
        st.body = try arena.dupe(ir.Stmt, st.body);
        try convert(arena, g, st.body, forward);
    };
    try convertFlat(arena, g, stmts, forward);
}

/// `convert` on these statements, not on what their bodies hold: for a pass
/// that visits every body itself (the reader's), where `convert` at each
/// level would copy everything below it again.
pub fn convertFlat(
    arena: Allocator,
    g: *const Grammar,
    stmts: []ir.Stmt,
    forward: bool,
) Allocator.Error!void {
    if (g.converts.len == 0) return;
    for (stmts) |*st| {
        var copied = false;
        for (0..g.converts.len) |n| {
            const cv = g.converts[if (forward) n else g.converts.len - 1 - n];
            if (cv.kind != st.kind) continue;
            if (cv.when_slot != grammar.no_slot) {
                const w = st.at(cv.when_slot);
                if (w != .atom or !std.mem.eql(u8, w.atom, cv.when_atom)) continue;
            }
            if (cv.op == .wrap) {
                // Forward: a == b becomes l = [a]. Back: a one-item l with no a.
                const a = st.at(cv.src);
                const l = st.at(cv.dst);
                if (forward and (a == .none or !a.eql(st.at(cv.when_eq)))) continue;
                if (!forward and (a != .none or l != .list or l.list.len != 1)) continue;
                if (!copied) {
                    try st.own(arena);
                    copied = true;
                }
                if (forward) {
                    try st.set(arena, cv.dst, .{ .list = try arena.dupe(ir.Value, &.{a}) });
                    try st.set(arena, cv.src, .none);
                } else {
                    try st.set(arena, cv.src, l.list[0]);
                    try st.set(arena, cv.dst, .none);
                }
                continue;
            }
            const from = if (forward) cv.src else cv.dst;
            const to = if (forward) cv.dst else cv.src;
            const v = st.at(from);
            if (v == .none) continue;
            const arg: ir.Value = if (cv.arg_slot != grammar.no_slot)
                st.at(cv.arg_slot)
            else if (cv.arg_num.len > 0) .{ .num = .init(cv.arg_num, 0) } else .none;
            const out: ir.Value = switch (cv.op) {
                .copy => v,
                .recip => try arith(arena, .recip, v, .none),
                .wrap => unreachable,
                // A missing operand counts as zero: nothing to do.
                .sub, .add => if (arg == .none)
                    continue
                else
                    try arith(arena, if ((cv.op == .sub) == forward) .sub else .add, v, arg),
                .mul, .div => if (arg == .none)
                    continue
                else
                    try arith(arena, if ((cv.op == .mul) == forward) .mul else .div, v, arg),
            };
            if (!copied) {
                try st.own(arena);
                copied = true;
            }
            if (cv.op == .copy) try st.set(arena, from, .none);
            try st.set(arena, to, out);
        }
    }
}

// ---- private ----

/// A plain number as an integer times a power of ten, when it fits.
fn decimal(n: ir.Number) ?struct { i128, i32 } {
    var m: i128 = 0;
    var e = n.exp10;
    var neg = false;
    var point = false;
    for (n.digits(), 0..) |c, i| switch (c) {
        '-', '+' => {
            if (i != 0) return null;
            neg = c == '-';
        },
        '.' => {
            if (point) return null;
            point = true;
        },
        '0'...'9' => {
            m = std.math.add(
                i128,
                std.math.mul(i128, m, 10) catch return null,
                c - '0',
            ) catch return null;
            if (point) e -= 1;
        },
        else => return null,
    };
    return .{ if (neg) -m else m, e };
}

test "convert arithmetic is exact where it can be" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = try arith(a, .sub, .{ .num = .init("1", -6) }, .{ .num = .init("100", -9) });
    try testing.expectEqualStrings("900", d.num.digits());
    try testing.expectEqual(-9, d.num.exp10);
    const r = try arith(a, .recip, .{ .num = .init("1", 6) }, .none);
    try testing.expectEqual(-6, r.num.exp10);
    // 1/3 is not a decimal: it stays an expression.
    try testing.expectEqualStrings(
        "1/(3)",
        (try arith(a, .recip, .{ .num = .init("3", 0) }, .none)).expr,
    );
    try testing.expectEqualStrings(
        "w - (1e-9)",
        (try arith(a, .sub, .{ .expr = "w" }, .{ .num = .init("1", -9) })).expr,
    );
}
