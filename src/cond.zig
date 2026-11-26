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
//! (`choose`).

const std = @import("std");
const ir = @import("ir");
const schema = @import("schema");
const expr = @import("expr");

const Allocator = std.mem.Allocator;

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
        var b = vals.len - 1;
        var text = try expr.canonText(m.arena, vals[b]);
        while (b > 0) {
            b -= 1;
            const c = try expr.canonText(m.arena, m.branches[b].cond);
            const v = try expr.canonText(m.arena, vals[b]);
            text = switch (m.form) {
                .ternary => try std.fmt.allocPrint(m.arena, "({s}) ? ({s}) : ({s})", .{ c, v, text }),
                .call => try std.fmt.allocPrint(m.arena, "if({s}, {s}, {s})", .{ c, v, text }),
            };
        }
        return .{ .expr = text };
    }

    /// One value for the branches' values, or false with `m.why`.
    fn value(m: *Merge, name: []const u8, what: []const u8, vals: []const ir.Value, out: *ir.Value) Allocator.Error!bool {
        const same = for (vals[1..]) |v| {
            if (!v.eql(vals[0])) break false;
        } else true;
        out.* = vals[0];
        if (same) return true;
        for (vals) |v| if (v != .num and v != .expr)
            return m.refuse("'{s}' has a {s} that is not a number or an expression in every branch", .{ name, what });
        out.* = try m.choice(vals);
        return true;
    }

    /// The statement that is `group[b]` in branch `b`, or false with `m.why`.
    fn stmt(m: *Merge, group: []const *const ir.Stmt, out: *ir.Stmt) Allocator.Error!bool {
        const first = group[0];
        out.* = first.*;
        const name = if (first.get("name") == .atom) first.get("name").atom else @tagName(first.kind);
        for (group[1..]) |s| {
            if (s.kind != first.kind) return m.refuse("'{s}' stands in one branch where '{s}' stands in another", .{ @tagName(first.kind), @tagName(s.kind) });
            // Only a device's value: ngspice 45 takes a `.param` in a
            // branch whichever branch holds (measured), and no expression
            // was measured in an analysis or an option.
            if (schema.info(first.kind).class != .device and !s.eql(first))
                return m.refuse("'{s}' is not the same in every branch, and only a device's value is written as a choice", .{@tagName(first.kind)});
        }
        if (schema.info(first.kind).class != .device) return true;
        const vals = try m.arena.alloc(ir.Value, group.len);
        try out.own(m.arena);
        for (schema.info(first.kind).slots, 0..) |sl, i| {
            for (group, vals) |s, *v| v.* = s.at(i);
            if (sl.ty == .params) {
                const ps = paramsOf(vals[0]);
                const merged = try m.arena.dupe(ir.Param, ps);
                const of = try m.arena.alloc(ir.Value, group.len);
                for (ps, merged, 0..) |p, *mp, j| {
                    for (vals, of) |v, *o| o.* = find(paramsOf(v), p.key, nthOf(ps, j)) orelse
                        return m.refuse("'{s}' has parameter '{s}' in one branch only", .{ name, p.key });
                    if (!try m.value(name, try std.fmt.allocPrint(m.arena, "parameter '{s}'", .{p.key}), of, &mp.val)) return false;
                }
                for (vals[1..]) |v| for (paramsOf(v), 0..) |q, j| {
                    if (find(ps, q.key, nthOf(paramsOf(v), j)) == null)
                        return m.refuse("'{s}' has parameter '{s}' in one branch only", .{ name, q.key });
                };
                if (ps.len > 0) try out.set(m.arena, i, .{ .params = merged });
                continue;
            }
            const same = for (vals[1..]) |v| {
                if (!v.eql(vals[0])) break false;
            } else true;
            if (same) continue;
            if (sl.ty != .value or sl.list) {
                var a = vals[0];
                var b = for (vals[1..]) |v| {
                    if (!v.eql(a)) break v;
                } else unreachable;
                // Of two lists, the first items that differ.
                if (a == .list and b == .list and a.list.len == b.list.len) for (a.list, b.list) |x, y| {
                    if (x.eql(y)) continue;
                    a = x;
                    b = y;
                    break;
                };
                return m.refuse("'{s}' has another {s} in another branch ({s}, {s})", .{
                    name,
                    switch (sl.ty) {
                        .node => "node",
                        .ident => if (first.kind == .instance) "model or subcircuit" else "model",
                        else => sl.name,
                    },
                    try show(m.arena, a),
                    try show(m.arena, b),
                });
            }
            for (vals) |v| if (v == .none) return m.refuse("'{s}' has a {s} in one branch only", .{ name, sl.name });
            var v: ir.Value = undefined;
            if (!try m.value(name, sl.name, vals, &v)) return false;
            try out.set(m.arena, i, v);
        }
        return true;
    }

    /// The statements every branch holds, or false with `m.why`. A comment
    /// is no statement: each branch's are kept, ahead of the statement they
    /// stand before.
    fn all(m: *Merge, out: *std.ArrayList(ir.Stmt)) Allocator.Error!bool {
        const group = try m.arena.alloc(*const ir.Stmt, m.branches.len);
        while (true) {
            var ended: usize = 0;
            for (m.branches, group) |*br, *g| {
                while (br.at < br.stmts.len and br.stmts[br.at].kind == .comment) : (br.at += 1) try out.append(m.arena, br.stmts[br.at]);
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

fn show(arena: Allocator, v: ir.Value) Allocator.Error![]const u8 {
    return switch (v) {
        .none => "none",
        .list => |l| try std.fmt.allocPrint(arena, "{d} of them", .{l.len}),
        .str => |s| try std.fmt.allocPrint(arena, "'{s}'", .{s}),
        else => try std.fmt.allocPrint(arena, "'{s}'", .{try expr.canonText(arena, v)}),
    };
}

fn paramsOf(v: ir.Value) []const ir.Param {
    return if (v == .params) v.params else &.{};
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

/// The statements that say the `cond_if` block `st` without a block, each
/// value that differs between the branches written as a choice in `form`.
pub fn merge(arena: Allocator, st: *const ir.Stmt, form: expr.ChoiceForm) Allocator.Error!Result {
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
            if (c.kind == .cond_elif and cond == .none) return .{ .refused = "a branch has no condition" };
        },
        .cond_if => switch (try merge(arena, c, form)) {
            .merged => |in| try cur.appendSlice(arena, in),
            .refused => |why| return .{ .refused = try std.fmt.allocPrint(arena, "in the block at line {d} inside it, {s}", .{ c.line, why }) },
        },
        .model => return .{ .refused = "a branch holds a model card" },
        .subckt => return .{ .refused = "a branch holds a subcircuit" },
        else => {
            if (c.body.len > 0) return .{ .refused = try std.fmt.allocPrint(arena, "a branch holds a {s} block", .{@tagName(c.kind)}) };
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

/// One subcircuit of a `split`.
pub const Variant = struct {
    name: []const u8 = "",
    /// Canonical expression text over the subcircuit's parameters: an
    /// instance is this one where it is true.
    cond: []const u8,
    body: []ir.Stmt,
};

pub const Variants = struct {
    /// The subcircuit's own parameters: its header's, then its body's.
    params: []const ir.Param,
    list: []Variant,
    /// The first block they are the branches of, and whether there are more.
    line: u32,
    more: bool,
};

pub const Split = union(enum) {
    /// No block in the body is refused.
    none,
    /// Why the subcircuit is not written once for each branch.
    refused: []const u8,
    /// The name one of them would take, declared already.
    clash: []const u8,
    variants: Variants,
};

/// No subcircuit is written as more than this many.
pub const max_variants = 8;

const Splitter = struct {
    arena: Allocator,
    form: ?expr.ChoiceForm,
    params: []const ir.Param,
    list: std.ArrayList(Variant) = .empty,
    line: u32 = 0,
    more: bool = false,
    why: []const u8 = "",

    fn refuse(sp: *Splitter, comptime fmt: []const u8, args: anytype) Allocator.Error!bool {
        sp.why = try std.fmt.allocPrint(sp.arena, fmt, args);
        return false;
    }

    /// `a` and `b` both, `a` being every condition so far.
    fn both(sp: *Splitter, a: []const u8, comptime fmt: []const u8, b: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(sp.arena, "{s}{s}" ++ fmt, .{ a, if (a.len > 0) " && " else "", b });
    }

    /// `body` under `cond`, once for every choice of a branch in each block
    /// of it that is refused; or false with `sp.why`.
    fn expand(sp: *Splitter, body: []ir.Stmt, cond: []const u8) Allocator.Error!bool {
        const at = for (body, 0..) |*s, i| {
            if (s.kind != .cond_if) continue;
            if (sp.form) |f| if (try merge(sp.arena, s, f) == .merged) continue;
            break i;
        } else {
            if (sp.list.items.len == max_variants) return sp.refuse("that would be more than {d} subcircuits", .{max_variants});
            try sp.list.append(sp.arena, .{ .cond = cond, .body = body });
            return true;
        };
        const block = &body[at];
        if (sp.line == 0) sp.line = block.line;
        sp.more = sp.more or block.line != sp.line;
        // ngspice 45 takes a `.param` in a branch whichever branch holds
        // (measured); nothing but a device was measured as conditional.
        if (!onlyDevices(block.body)) return sp.refuse("a branch of the block at line {d} holds something other than devices", .{block.line});
        var not = cond;
        var c = block.get("cond");
        var from: usize = 0;
        var i: usize = 0;
        while (true) : (i += 1) {
            const end = i == block.body.len;
            if (!end and block.body[i].kind != .cond_elif and block.body[i].kind != .cond_else) continue;
            // The branch `block.body[from..i]`, under `c` and none before it.
            var here = not;
            if (c != .none) {
                const text = try expr.canonText(sp.arena, c);
                var stop: []const u8 = "";
                if (expr.eval(text, sp.params, &stop, 0) == null)
                    return sp.refuse("'{s}' in the condition '{s}' is not a number, an operator or one of the subcircuit's own parameters", .{ stop, text });
                here = try sp.both(not, "({s})", text);
                not = try sp.both(not, "!({s})", text);
            } else if (!end or from == 0 or block.body[from - 1].kind != .cond_else) {
                return sp.refuse("the block at line {d} has a branch with no condition that is not its closing else", .{block.line});
            }
            if (!try sp.expand(try std.mem.concat(sp.arena, ir.Stmt, &.{ body[0..at], block.body[from..i], body[at + 1 ..] }), here)) return false;
            if (end) break;
            c = block.body[i].get("cond");
            from = i + 1;
        }
        // No `else`: where no branch holds, the block is nothing.
        if (c != .none) return sp.expand(try std.mem.concat(sp.arena, ir.Stmt, &.{ body[0..at], body[at + 1 ..] }), not);
        return true;
    }
};

/// Only devices, comments and blocks of those.
fn onlyDevices(stmts: []const ir.Stmt) bool {
    for (stmts) |*s| switch (s.kind) {
        .comment, .cond_elif, .cond_else => {},
        .cond_if => if (!onlyDevices(s.body)) return false,
        else => if (schema.info(s.kind).class != .device or s.body.len > 0) return false,
    };
    return true;
}

/// The subcircuit `st` as one subcircuit for each branch of the conditional
/// blocks in its body that `merge` refuses (every block when `form` is
/// null: the target has no choice either). Only when the subcircuit's own
/// parameters decide every condition; `declared` holds the names taken,
/// lower-cased.
pub fn split(arena: Allocator, st_in: *const ir.Stmt, form: ?expr.ChoiceForm, declared: *const std.StringHashMapUnmanaged(void), known: []const Known) Allocator.Error!Split {
    // An instance of a subcircuit written once for each branch, which its
    // parent's parameters decide, is a block of the parent's.
    var passed: ir.Stmt = undefined;
    const st = if (try passDown(arena, st_in.body, known)) |b| blk: {
        passed = st_in.*;
        passed.body = b;
        break :blk &passed;
    } else st_in;
    for (st.body) |*s| {
        if (s.kind == .cond_if and st.get("name") == .atom) break;
    } else return .none;
    var params: std.ArrayList(ir.Param) = .empty;
    try params.appendSlice(arena, paramsOf(st.get("params")));
    // A later value of a name is its default, the header's too (ngspice
    // 45, measured), as where they are written on the header.
    for (st.body) |*s| if (s.kind == .param) next: for (paramsOf(s.get("params"))) |p| {
        for (params.items) |*q| if (std.ascii.eqlIgnoreCase(q.key, p.key)) {
            q.val = p.val;
            continue :next;
        };
        try params.append(arena, p);
    };
    var sp: Splitter = .{ .arena = arena, .form = form, .params = params.items };
    if (!try sp.expand(st.body, "")) return .{ .refused = sp.why };
    if (sp.list.items.len < 2) return .none;
    const name = st.get("name").atom;
    var kept = false;
    var n: usize = 0;
    for (sp.list.items) |*v| {
        var stop: []const u8 = "";
        // What the defaults select keeps the name: a netlist that relies
        // on them means what it meant.
        if (!kept and (expr.eval(v.cond, params.items, &stop, 0) orelse 0) != 0) {
            v.name = name;
            kept = true;
            continue;
        }
        n += 1;
        v.name = try std.fmt.allocPrint(arena, "{s}__{d}", .{ name, n });
        if (declared.contains(try std.ascii.allocLowerString(arena, v.name))) return .{ .clash = v.name };
    }
    return .{ .variants = .{ .params = params.items, .list = sp.list.items, .line = sp.line, .more = sp.more } };
}

/// An expression that names no parameter (`{1}`, `'2-1'`): its number.
fn constant(v: ir.Value) bool {
    if (v != .expr) return false;
    var stop: []const u8 = "";
    return expr.eval(v.expr, &.{}, &stop, 0) != null;
}

/// The `raw` of an instance `passDown` names a variant for.
pub const chosen = "\x00chosen";

/// A subcircuit written once for each branch, for `split` of a subcircuit
/// that holds an instance of it.
pub const Known = struct { name: []const u8, variants: *const Variants };

/// Does `text` (a variant's condition) name the parameter `key`?
fn namesAny(text: []const u8, key: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (!(std.ascii.isAlphabetic(text[i]) or text[i] == '_')) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_' or text[j] == '.' or text[j] == '$')) j += 1;
        if (std.ascii.eqlIgnoreCase(text[i..j], key)) return true;
        i = j;
    }
    return false;
}

/// An instance of a subcircuit in `known` whose deciding values are
/// expressions of names around it (the parent's parameters, `xds=xds`):
/// a conditional block with one branch for each of the subcircuit's
/// variants, its condition the variant's with the instance's values put
/// in, the instance in it naming that variant. The parent can then be
/// written once for each branch as for any block (`expand`). Null: no
/// such instance in `body`.
fn passDown(arena: Allocator, body: []const ir.Stmt, known: []const Known) Allocator.Error!?[]ir.Stmt {
    var out: ?[]ir.Stmt = null;
    for (body, 0..) |*s, i| {
        if (s.kind != .instance or s.get("master") != .atom) continue;
        const k = for (known) |*k| {
            if (std.ascii.eqlIgnoreCase(k.name, s.get("master").atom)) break k;
        } else continue;
        const given = paramsOf(s.get("params"));
        // A deciding value that is neither a number nor constant.
        const open = open: for (given) |p| {
            if (p.val == .num or constant(p.val)) continue;
            for (k.variants.list) |v| if (namesAny(v.cond, p.key)) break :open true;
        } else false;
        if (!open) continue;
        // The instance's values in place of the subcircuit's parameters;
        // the subcircuit's own defaults for the rest.
        var subst: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (k.variants.params) |p| try subst.put(arena, try std.ascii.allocLowerString(arena, p.key), try std.fmt.allocPrint(arena, "({s})", .{try expr.canonText(arena, p.val)}));
        for (given) |p| try subst.put(arena, try std.ascii.allocLowerString(arena, p.key), try std.fmt.allocPrint(arena, "({s})", .{try expr.canonText(arena, p.val)}));
        const Lower = struct {
            map: *const std.StringHashMapUnmanaged([]const u8),
            a: Allocator,
            pub fn get(l: @This(), key: []const u8) ?[]const u8 {
                const low = std.ascii.allocLowerString(l.a, key) catch return null;
                return l.map.get(low);
            }
        };
        var block = try ir.newStmt(arena, .cond_if, s.line);
        var kids: std.ArrayList(ir.Stmt) = .empty;
        for (k.variants.list, 0..) |v, vi| {
            var hit: std.ArrayList([]const u8) = .empty;
            const c = try expr.rename(arena, v.cond, Lower{ .map = &subst, .a = arena }, &hit);
            if (vi == 0) {
                try block.set(arena, schema.slotIndex(.cond_if, "cond").?, .{ .expr = c });
            } else if (vi + 1 < k.variants.list.len) {
                var el = try ir.newStmt(arena, .cond_elif, s.line);
                try el.set(arena, schema.slotIndex(.cond_elif, "cond").?, .{ .expr = c });
                try kids.append(arena, el);
            } else {
                try kids.append(arena, try ir.newStmt(arena, .cond_else, s.line));
            }
            var inst = s.*;
            try inst.own(arena);
            try inst.set(arena, schema.slotIndex(.instance, "master").?, .{ .atom = v.name });
            // Its subcircuit is chosen: the writer takes the name as it is.
            inst.raw = chosen;
            try kids.append(arena, inst);
        }
        block.body = kids.items;
        const list = out orelse blk: {
            out = try arena.dupe(ir.Stmt, body);
            break :blk out.?;
        };
        list[i] = block;
    }
    return out;
}

/// The name of the one of `vs` that an instance with `params` is. Null when
/// that takes a parameter the instance gives as something other than a
/// number, which `stop` then names: an expression there is one of the
/// instance's surroundings, not of the subcircuit's parameters.
pub fn choose(arena: Allocator, vs: *const Variants, params: []const ir.Param, stop: *[]const u8) Allocator.Error!?[]const u8 {
    const all = try arena.alloc(ir.Param, params.len + vs.params.len);
    for (params, all[0..params.len]) |p, *o| o.* = .{ .key = p.key, .val = if (p.val == .num or constant(p.val)) p.val else .none };
    @memcpy(all[params.len..], vs.params);
    for (vs.list) |v| {
        if ((expr.eval(v.cond, all, stop, 0) orelse return null) != 0) return v.name;
    }
    return null;
}
