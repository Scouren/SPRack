//! A subcircuit once for each branch of the conditional blocks in its body
//! that `cond.merge` refuses, when the subcircuit's own parameters decide
//! their conditions (`split`): the one the defaults select under the
//! subcircuit's name, the others as `<name>__<n>`; an instance is the one
//! its parameters select (`choose`). `cond.zig` exports them.
//!
//! Contents:
//! - `pub const Variant = struct`
//! - `pub const Variants = struct`
//! - `pub const Split = union(enum)`
//! - `pub const max_variants`
//! - `pub const chosen`
//! - `pub const Known = struct`
//! - `pub fn split(arena: Allocator, st_in: *const ir.Stmt, form: ?expr.ChoiceForm,
//!   declared: *const std.StringHashMapUnmanaged(void),
//!   known: []const Known) Allocator.Error!Split`
//! - `pub fn choose(arena: Allocator, vs: *const Variants, params: []const ir.Param,
//!   stop: *[]const u8) Allocator.Error!?[]const u8`
//! - `get`, of the struct inside `passDown`: the lower-cased lookup
//!   `expr.rename` calls

const std = @import("std");
const ir = @import("ir");
const schema = @import("schema");
const expr = @import("expr");
const merging = @import("cond.zig");

const Allocator = std.mem.Allocator;

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

/// The `raw` of an instance `passDown` names a variant for.
pub const chosen = "\x00chosen";

/// A subcircuit written once for each branch, for `split` of a subcircuit
/// that holds an instance of it.
pub const Known = struct { name: []const u8, variants: *const Variants };

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
    fn both(
        sp: *Splitter,
        a: []const u8,
        comptime fmt: []const u8,
        b: []const u8,
    ) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(sp.arena, "{s}{s}" ++ fmt, .{ a, if (a.len > 0)
            " && "
        else
            "", b });
    }

    /// `body` under `cond`, once for every choice of a branch in each block
    /// of it that is refused; or false with `sp.why`.
    // tidy: allow(recursion) bounded by the body's blocks, nested too: each call takes one out
    fn expand(sp: *Splitter, body: []ir.Stmt, cond: []const u8) Allocator.Error!bool {
        std.debug.assert(sp.list.items.len <= max_variants);
        const at = for (body, 0..) |*s, i| {
            if (s.kind != .cond_if) continue;
            if (sp.form) |f| if (try merging.merge(sp.arena, s, f) == .merged) continue;
            break i;
        } else {
            if (sp.list.items.len == max_variants)
                return sp.refuse("that would be more than {d} subcircuits", .{max_variants});
            try sp.list.append(sp.arena, .{ .cond = cond, .body = body });
            return true;
        };
        const block = &body[at];
        if (sp.line == 0) sp.line = block.line;
        sp.more = sp.more or block.line != sp.line;
        // ngspice 45 takes a `.param` in a branch whichever branch holds
        // (measured); nothing but a device was measured as conditional.
        if (!onlyDevices(block.body))
            return sp.refuse(
                "a branch of the block at line {d} holds something other than devices",
                .{block.line},
            );
        var not = cond;
        var c = block.get("cond");
        var from: usize = 0;
        var i: usize = 0;
        // Bounded by the block's statements: it breaks at their end.
        while (true) : (i += 1) {
            const end = i == block.body.len;
            if (!end and block.body[i].kind != .cond_elif and block.body[i].kind != .cond_else)
                continue;
            // The branch `block.body[from..i]`, under `c` and none before it.
            var here = not;
            if (c != .none) {
                const text = try expr.canonText(sp.arena, c);
                var stop: []const u8 = "";
                if (expr.eval(text, sp.params, &stop, 0) == null)
                    return sp.refuse(
                        "'{s}' in the condition '{s}' is not a number, an operator or one of " ++
                            "the subcircuit's own parameters",
                        .{ stop, text },
                    );
                here = try sp.both(not, "({s})", text);
                not = try sp.both(not, "!({s})", text);
            } else if (!end or from == 0 or block.body[from - 1].kind != .cond_else) {
                return sp.refuse(
                    "the block at line {d} has a branch with no condition that is not its " ++
                        "closing else",
                    .{block.line},
                );
            }
            if (!try sp.expand(
                try std.mem.concat(
                    sp.arena,
                    ir.Stmt,
                    &.{ body[0..at], block.body[from..i], body[at + 1 ..] },
                ),
                here,
            )) return false;
            if (end) break;
            c = block.body[i].get("cond");
            from = i + 1;
        }
        // No `else`: where no branch holds, the block is nothing.
        if (c != .none)
            return sp.expand(
                try std.mem.concat(sp.arena, ir.Stmt, &.{ body[0..at], body[at + 1 ..] }),
                not,
            );
        return true;
    }
};

/// The subcircuit `st` as one subcircuit for each branch of the conditional
/// blocks in its body that `merge` refuses (every block when `form` is
/// null: the target has no choice either). Only when the subcircuit's own
/// parameters decide every condition; `declared` holds the names taken,
/// lower-cased.
pub fn split(
    arena: Allocator,
    st_in: *const ir.Stmt,
    form: ?expr.ChoiceForm,
    declared: *const std.StringHashMapUnmanaged(void),
    known: []const Known,
) Allocator.Error!Split {
    std.debug.assert(st_in.kind == .subckt);
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
    try params.appendSlice(arena, merging.paramsOf(st.get("params")));
    // A later value of a name is its default, the header's too (ngspice
    // 45, measured), as where they are written on the header.
    for (st.body) |*s| if (s.kind == .param) next: for (merging.paramsOf(s.get("params"))) |p| {
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
        if (declared.contains(try std.ascii.allocLowerString(arena, v.name)))
            return .{ .clash = v.name };
    }
    return .{
        .variants = .{
            .params = params.items,
            .list = sp.list.items,
            .line = sp.line,
            .more = sp.more,
        },
    };
}

/// The name of the one of `vs` that an instance with `params` is. Null when
/// that takes a parameter the instance gives as something other than a
/// number, which `stop` then names: an expression there is one of the
/// instance's surroundings, not of the subcircuit's parameters.
pub fn choose(
    arena: Allocator,
    vs: *const Variants,
    params: []const ir.Param,
    stop: *[]const u8,
) Allocator.Error!?[]const u8 {
    const all = try arena.alloc(ir.Param, params.len + vs.params.len);
    for (params, all[0..params.len]) |p, *o|
        o.* = .{ .key = p.key, .val = if (p.val == .num or constant(p.val)) p.val else .none };
    @memcpy(all[params.len..], vs.params);
    for (vs.list) |v| {
        if ((expr.eval(v.cond, all, stop, 0) orelse return null) != 0) return v.name;
    }
    return null;
}

// ---- private ----

/// Only devices, comments and blocks of those.
// tidy: allow(recursion) bounded by the nesting of blocks, which the reader caps at ir.max_depth
fn onlyDevices(stmts: []const ir.Stmt) bool {
    for (stmts) |*s| switch (s.kind) {
        .comment, .cond_elif, .cond_else => {},
        .cond_if => if (!onlyDevices(s.body)) return false,
        else => if (schema.info(s.kind).class != .device or s.body.len > 0) return false,
    };
    return true;
}

/// An expression that names no parameter (`{1}`, `'2-1'`): its number.
fn constant(v: ir.Value) bool {
    if (v != .expr) return false;
    var stop: []const u8 = "";
    return expr.eval(v.expr, &.{}, &stop, 0) != null;
}

/// Does `text` (a variant's condition) name the parameter `key`?
fn namesAny(text: []const u8, key: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (!(std.ascii.isAlphabetic(text[i]) or text[i] == '_')) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or
            text[j] == '_' or text[j] == '.' or text[j] == '$')) j += 1;
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
fn passDown(
    arena: Allocator,
    body: []const ir.Stmt,
    known: []const Known,
) Allocator.Error!?[]ir.Stmt {
    var out: ?[]ir.Stmt = null;
    for (body, 0..) |*s, i| {
        if (s.kind != .instance or s.get("master") != .atom) continue;
        const k = for (known) |*k| {
            if (std.ascii.eqlIgnoreCase(k.name, s.get("master").atom)) break k;
        } else continue;
        const given = merging.paramsOf(s.get("params"));
        // A deciding value that is neither a number nor constant.
        const open = open: for (given) |p| {
            if (p.val == .num or constant(p.val)) continue;
            for (k.variants.list) |v| if (namesAny(v.cond, p.key)) break :open true;
        } else false;
        if (!open) continue;
        // The instance's values in place of the subcircuit's parameters;
        // the subcircuit's own defaults for the rest.
        var subst: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (k.variants.params) |p|
            try subst.put(
                arena,
                try std.ascii.allocLowerString(arena, p.key),
                try std.fmt.allocPrint(arena, "({s})", .{try expr.canonText(arena, p.val)}),
            );
        for (given) |p|
            try subst.put(
                arena,
                try std.ascii.allocLowerString(arena, p.key),
                try std.fmt.allocPrint(arena, "({s})", .{try expr.canonText(arena, p.val)}),
            );
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
                try block.set(arena, schema.slot(.cond_if, "cond"), .{ .expr = c });
            } else if (vi + 1 < k.variants.list.len) {
                var el = try ir.newStmt(arena, .cond_elif, s.line);
                try el.set(arena, schema.slot(.cond_elif, "cond"), .{ .expr = c });
                try kids.append(arena, el);
            } else {
                try kids.append(arena, try ir.newStmt(arena, .cond_else, s.line));
            }
            var inst = s.*;
            try inst.own(arena);
            try inst.set(arena, schema.slot(.instance, "master"), .{ .atom = v.name });
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
    if (out) |o| std.debug.assert(o.len == body.len);
    return out;
}
