//! A conditional block for a target that has none.
//!
//! When every branch of a block holds the same statements, one for one, and
//! they differ only in values that are numbers or expressions, the block is
//! one circuit with conditional values: those statements once, each
//! differing value a choice between the branches' values by the branches'
//! conditions. Nested blocks are merged inside out. Anything else (a
//! statement or a parameter in one branch only, another model or node, no
//! `else`, a model card or a subcircuit in a branch) is refused, with the
//! reason.
//!
//! A refused block in a subcircuit, when the subcircuit's own parameters
//! decide its conditions, is the subcircuit once for each branch (`split`):
//! the one the defaults select under the subcircuit's name, the others as
//! `<name>__<n>`, and an instance is the one its parameters select
//! (`choose`), in `split.zig`.
//!
//! Contents:
//! - `pub const Variant`
//! - `pub const Variants`
//! - `pub const Split`
//! - `pub const max_variants`
//! - `pub const chosen`
//! - `pub const Known`
//! - `pub const split`
//! - `pub const choose`
//! - `pub const Result = union(enum)`
//! - `pub fn paramsOf(v: ir.Value) []const ir.Param`
//! - `pub fn merge(arena: Allocator, st: *const ir.Stmt,
//!   form: expr.ChoiceForm) Allocator.Error!Result`

const std = @import("std");
const ir = @import("ir");
const schema = @import("schema");
const expr = @import("expr");
const split_file = @import("split.zig");

const Allocator = std.mem.Allocator;

pub const Variant = split_file.Variant;
pub const Variants = split_file.Variants;
pub const Split = split_file.Split;
pub const max_variants = split_file.max_variants;
pub const chosen = split_file.chosen;
pub const Known = split_file.Known;
pub const split = split_file.split;
pub const choose = split_file.choose;

pub const Result = union(enum) {
    merged: []ir.Stmt,
    /// Why the block is not the same statements with other values.
    refused: []const u8,
};

const Branch = struct { cond: ir.Value, stmts: []ir.Stmt, at: usize = 0 };

const Merge = struct {
    arena: Allocator,
    form: expr.ChoiceForm,
    branches: []Branch,
    why: []const u8 = "",

    fn refuse(m: *Merge, comptime fmt: []const u8, args: anytype) Allocator.Error!bool {
        m.why = try std.fmt.allocPrint(m.arena, fmt, args);
        return false;
    }

    /// The value that is `vals[b]` in branch `b`.
    fn choice(m: *Merge, vals: []const ir.Value) Allocator.Error!ir.Value {
        std.debug.assert(vals.len == m.branches.len);
        var b = vals.len - 1;
        var text = try expr.canonText(m.arena, vals[b]);
        while (b > 0) {
            b -= 1;
            const c = try expr.canonText(m.arena, m.branches[b].cond);
            const v = try expr.canonText(m.arena, vals[b]);
            text = switch (m.form) {
                .ternary => try std.fmt.allocPrint(
                    m.arena,
                    "({s}) ? ({s}) : ({s})",
                    .{ c, v, text },
                ),
                .call => try std.fmt.allocPrint(m.arena, "if({s}, {s}, {s})", .{ c, v, text }),
            };
        }
        return .{ .expr = text };
    }

    /// One value for the branches' values, or false with `m.why`.
    fn value(
        m: *Merge,
        name: []const u8,
        what: []const u8,
        vals: []const ir.Value,
        out: *ir.Value,
    ) Allocator.Error!bool {
        const same = for (vals[1..]) |v| {
            if (!v.eql(vals[0])) break false;
        } else true;
        out.* = vals[0];
        if (same) return true;
        for (vals) |v| if (v != .num and v != .expr)
            return m.refuse(
                "'{s}' has a {s} that is not a number or an expression in every branch",
                .{ name, what },
            );
        out.* = try m.choice(vals);
        return true;
    }

    /// The statement that is `group[b]` in branch `b`, or false with `m.why`.
    fn stmt(m: *Merge, group: []const *const ir.Stmt, out: *ir.Stmt) Allocator.Error!bool {
        std.debug.assert(group.len == m.branches.len);
        const first = group[0];
        out.* = first.*;
        const name = if (first.get("name") == .atom)
            first.get("name").atom
        else
            @tagName(first.kind);
        for (group[1..]) |s| {
            if (s.kind != first.kind)
                return m.refuse(
                    "'{s}' stands in one branch where '{s}' stands in another",
                    .{ @tagName(first.kind), @tagName(s.kind) },
                );
            // Only a device's value: ngspice 45 takes a `.param` in a
            // branch whichever branch holds (measured), and no expression
            // was measured in an analysis or an option.
            if (schema.info(first.kind).class != .device and !s.eql(first))
                return m.refuse(
                    "'{s}' is not the same in every branch, and only a device's value is " ++
                        "written as a choice",
                    .{@tagName(first.kind)},
                );
        }
        if (schema.info(first.kind).class != .device) return true;
        const vals = try m.arena.alloc(ir.Value, group.len);
        try out.own(m.arena);
        for (schema.info(first.kind).slots, 0..) |sl, i| {
            for (group, vals) |s, *v| v.* = s.at(i);
            if (sl.ty == .params) {
                if (!try m.params(name, vals, i, out)) return false;
                continue;
            }
            const same = for (vals[1..]) |v| {
                if (!v.eql(vals[0])) break false;
            } else true;
            if (same) continue;
            if (sl.ty != .value or sl.list) return m.another(first.kind, name, sl, vals);
            for (vals) |v|
                if (v == .none)
                    return m.refuse("'{s}' has a {s} in one branch only", .{ name, sl.name });
            var v: ir.Value = undefined;
            if (!try m.value(name, sl.name, vals, &v)) return false;
            try out.set(m.arena, i, v);
        }
        return true;
    }

    /// The `params` slot `i` of a statement whose branches' values are
    /// `vals`, merged into `out`; or false with `m.why`.
    fn params(
        m: *Merge,
        name: []const u8,
        vals: []const ir.Value,
        i: usize,
        out: *ir.Stmt,
    ) Allocator.Error!bool {
        std.debug.assert(vals.len == m.branches.len);
        const ps = paramsOf(vals[0]);
        const merged = try m.arena.dupe(ir.Param, ps);
        const of = try m.arena.alloc(ir.Value, vals.len);
        for (ps, merged, 0..) |p, *mp, j| {
            for (vals, of) |v, *o| o.* = find(paramsOf(v), p.key, nthOf(ps, j)) orelse
                return m.refuse(
                    "'{s}' has parameter '{s}' in one branch only",
                    .{ name, p.key },
                );
            if (!try m.value(
                name,
                try std.fmt.allocPrint(m.arena, "parameter '{s}'", .{p.key}),
                of,
                &mp.val,
            )) return false;
        }
        for (vals[1..]) |v| for (paramsOf(v), 0..) |q, j| {
            if (find(ps, q.key, nthOf(paramsOf(v), j)) == null)
                return m.refuse(
                    "'{s}' has parameter '{s}' in one branch only",
                    .{ name, q.key },
                );
        };
        if (ps.len > 0) try out.set(m.arena, i, .{ .params = merged });
        return true;
    }

    /// False with `m.why`: slot `sl`, not a single value, differs between
    /// the branches' `vals`; the first two that differ are named.
    fn another(
        m: *Merge,
        kind: schema.Kind,
        name: []const u8,
        sl: schema.Slot,
        vals: []const ir.Value,
    ) Allocator.Error!bool {
        std.debug.assert(vals.len == m.branches.len);
        var a = vals[0];
        var b = for (vals[1..]) |v| {
            if (!v.eql(a)) break v;
        } else unreachable;
        // Of two lists, the first items that differ.
        if (a == .list and b == .list and a.list.len == b.list.len)
            for (a.list, b.list) |x, y| {
                if (x.eql(y)) continue;
                a = x;
                b = y;
                break;
            };
        return m.refuse("'{s}' has another {s} in another branch ({s}, {s})", .{
            name,
            switch (sl.ty) {
                .node => "node",
                .ident => if (kind == .instance) "model or subcircuit" else "model",
                else => sl.name,
            },
            try show(m.arena, a),
            try show(m.arena, b),
        });
    }

    /// The statements every branch holds, or false with `m.why`. A comment
    /// is no statement: each branch's are kept, ahead of the statement they
    /// stand before.
    fn all(m: *Merge, out: *std.ArrayList(ir.Stmt)) Allocator.Error!bool {
        std.debug.assert(m.branches.len >= 2);
        const group = try m.arena.alloc(*const ir.Stmt, m.branches.len);
        // Bounded by the longest branch: each round takes a statement from
        // every branch, until one ends.
        while (true) {
            var ended: usize = 0;
            for (m.branches, group) |*br, *g| {
                while (br.at < br.stmts.len and br.stmts[br.at].kind == .comment) : (br.at += 1)
                    try out.append(m.arena, br.stmts[br.at]);
                if (br.at == br.stmts.len) {
                    ended += 1;
                    continue;
                }
                g.* = &br.stmts[br.at];
                br.at += 1;
            }
            if (ended == m.branches.len) return true;
            if (ended > 0) return m.refuse("a statement is in one branch only", .{});
            const merged = try out.addOne(m.arena);
            if (!try m.stmt(group, merged)) return false;
        }
    }
};

pub fn paramsOf(v: ir.Value) []const ir.Param {
    return if (v == .params) v.params else &.{};
}

/// The statements that say the `cond_if` block `st` without a block, each
/// value that differs between the branches written as a choice in `form`.
// tidy: allow(recursion) bounded by the nesting of blocks, which the reader caps at ir.max_depth
pub fn merge(arena: Allocator, st: *const ir.Stmt, form: expr.ChoiceForm) Allocator.Error!Result {
    std.debug.assert(st.kind == .cond_if);
    var branches: std.ArrayList(Branch) = .empty;
    var cur: std.ArrayList(ir.Stmt) = .empty;
    var cond = st.get("cond");
    if (cond == .none) return .{ .refused = "it has no condition" };
    for (st.body) |*c| switch (c.kind) {
        .cond_elif, .cond_else => {
            // Only the last branch may be the `else`.
            if (cond == .none) return .{ .refused = "a branch follows its else" };
            try branches.append(arena, .{ .cond = cond, .stmts = cur.items });
            cur = .empty;
            cond = if (c.kind == .cond_elif) c.get("cond") else .none;
            if (c.kind == .cond_elif and cond == .none)
                return .{ .refused = "a branch has no condition" };
        },
        .cond_if => switch (try merge(arena, c, form)) {
            .merged => |in| try cur.appendSlice(arena, in),
            .refused => |why| return .{
                .refused = try std.fmt.allocPrint(
                    arena,
                    "in the block at line {d} inside it, {s}",
                    .{ c.line, why },
                ),
            },
        },
        .model => return .{ .refused = "a branch holds a model card" },
        .subckt => return .{ .refused = "a branch holds a subcircuit" },
        else => {
            if (c.body.len > 0)
                return .{
                    .refused = try std.fmt.allocPrint(
                        arena,
                        "a branch holds a {s} block",
                        .{@tagName(c.kind)},
                    ),
                };
            try cur.append(arena, c.*);
        },
    };
    if (cond != .none) return .{ .refused = "it has no else branch" };
    try branches.append(arena, .{ .cond = cond, .stmts = cur.items });
    var m: Merge = .{ .arena = arena, .form = form, .branches = branches.items };
    var out: std.ArrayList(ir.Stmt) = .empty;
    if (!try m.all(&out)) return .{ .refused = m.why };
    return .{ .merged = out.items };
}

// ---- private ----

fn show(arena: Allocator, v: ir.Value) Allocator.Error![]const u8 {
    return switch (v) {
        .none => "none",
        .list => |l| try std.fmt.allocPrint(arena, "{d} of them", .{l.len}),
        .str => |s| try std.fmt.allocPrint(arena, "'{s}'", .{s}),
        else => try std.fmt.allocPrint(arena, "'{s}'", .{try expr.canonText(arena, v)}),
    };
}

/// How many parameters before `ps[j]` have its key.
fn nthOf(ps: []const ir.Param, j: usize) usize {
    var n: usize = 0;
    for (ps[0..j]) |p| {
        if (std.mem.eql(u8, p.key, ps[j].key)) n += 1;
    }
    return n;
}

/// The value of the `nth` parameter of that key.
fn find(ps: []const ir.Param, key: []const u8, nth_in: usize) ?ir.Value {
    var nth = nth_in;
    for (ps) |p| {
        if (!std.mem.eql(u8, p.key, key)) continue;
        if (nth == 0) return p.val;
        nth -= 1;
    }
    return null;
}
