//! Names: the statements of a netlist → the names they declare and use, the
//! clashes the target would refuse (a parameter defined twice, a model and a
//! subcircuit of one name, names that differ only in case, more analyses
//! than it runs), and the statements with a clashing name renamed.
//!
//! Each function is a pass of the writer (`root.zig` runs them in order):
//! statements in, statements or report entries out.

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const dialects = @import("dialects");
const expr = @import("expr");
const lexer = @import("lexer");
const stats = @import("stats");
const tables = @import("tables.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Kind = schema.Kind;
const Value = ir.Value;

/// What a pass that renames works with: where the statements it copies and
/// the names it must remember live, the dialect being written, and where
/// its entries go.
pub const Pass = struct {
    /// Lives as long as the statements the pass returns.
    arena: Allocator,
    /// Lives as long as the translation: names reported once are kept here.
    perm: Allocator,
    g: *const Grammar,
    report: *ir.Report,
};

/// A device still using a name both a model and a subcircuit define after
/// `renameMasters` (one it could not reach): an error.
pub fn uniqueMasters(
    arena: Allocator,
    stmts: []const ir.Stmt,
    env: ?*const ir.Env,
    report: *ir.Report,
    g: *const Grammar,
) Allocator.Error!void {
    var models: ir.CaselessSet = .empty;
    var subckts: ir.CaselessSet = .empty;
    var told: ir.CaselessSet = .empty;
    try collectMasters(arena, stmts, &models, &subckts, null);
    if (env) |e| {
        var it = e.models.keyIterator();
        while (it.next()) |k| try models.put(arena, ir.binBase(k.*) orelse k.*, {});
        var si = e.subckts.keyIterator();
        while (si.next()) |k| try subckts.put(arena, k.*, {});
    }
    try clashes(arena, stmts, &models, &subckts, &told, report, g);
}

/// A map from names, ignoring case.
pub const CaselessMap = std.HashMapUnmanaged(
    []const u8,
    []const u8,
    ir.Caseless,
    std.hash_map.default_max_load_percentage,
);

/// The model cards `renames` names, and the devices that use them as a
/// model (by their SPICE letter), under their new names; subcircuit
/// instances keep theirs. Each name is reported once.
pub fn renameMasters(
    w: Pass,
    stmts: []ir.Stmt,
    renames: *const CaselessMap,
    told: *ir.CaselessSet,
) Allocator.Error![]ir.Stmt {
    var list: ?[]ir.Stmt = null;
    for (stmts, 0..) |*st, i| {
        var cur = st.*;
        var changed = false;
        if (st.body.len > 0) {
            const b = try renameMasters(w, st.body, renames, told);
            if (b.ptr != st.body.ptr) {
                cur.body = b;
                changed = true;
            }
        }
        const class = schema.info(st.kind).class;
        const slot: ?u8 = if (st.kind == .model)
            (comptime schema.slotOf(.model, "name"))
        else if (class == .device and st.kind != .instance)
            schema.slotOf(st.kind, "master")
        else
            null;
        if (slot) |si| if (cur.at(si) == .atom) {
            const old = cur.at(si).atom;
            const base = if (st.kind == .model) ir.binBase(old) orelse old else old;
            if (renames.get(base)) |new| {
                try cur.own(w.arena);
                try cur.set(
                    w.arena,
                    si,
                    .{ .atom = try std.mem.concat(w.arena, u8, &.{ new, old[base.len..] }) },
                );
                changed = true;
                const gop = try told.getOrPut(w.perm, base);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try w.perm.dupe(u8, base);
                    w.report.add(
                        .info,
                        .rename,
                        st.line,
                        "'{s}' names both a model and a subcircuit: the model is written as " ++
                            "'{s}', and so is every device that uses it as a model; {s}",
                        .{ base, new, w.g.unique_master },
                    );
                }
            }
        };
        if (changed) {
            if (list == null) list = try w.arena.dupe(ir.Stmt, stmts);
            list.?[i] = cur;
        }
    }
    return list orelse stmts;
}

/// The parameter names `stmts` define that start with a name the dialect
/// keeps for itself (`reserved`): those `reservedRenames` renames, and the
/// names a new one could clash with. With `src`, a name not in it is copied.
pub fn collectReserved(
    arena: Allocator,
    g: *const Grammar,
    stmts: []const ir.Stmt,
    out: *ir.CaselessSet,
    src: ?[]const u8,
) Allocator.Error!void {
    if (g.reserved.len == 0) return;
    for (stmts) |*s| {
        try collectReserved(arena, g, s.body, out, src);
        if ((s.kind != .param and s.kind != .subckt) or s.get("params") != .params) continue;
        for (s.get("params").params) |p| for (g.reserved) |r| for (r.names) |n| {
            if (std.ascii.startsWithIgnoreCase(p.key, n)) try ir.putName(out, arena, src, p.key);
        };
    }
}

/// The parameters `renames` names under their new names: where they are
/// defined (`.param`, a subcircuit's header), given to a subcircuit, and
/// used in an expression. Each is reported once.
pub fn renameParams(
    w: Pass,
    stmts: []ir.Stmt,
    renames: *const CaselessMap,
    told: *ir.CaselessSet,
) Allocator.Error![]ir.Stmt {
    var list: ?[]ir.Stmt = null;
    for (stmts, 0..) |*st, i| {
        var cur = st.*;
        var changed = false;
        if (st.body.len > 0) {
            const b = try renameParams(w, st.body, renames, told);
            if (b.ptr != st.body.ptr) {
                cur.body = b;
                changed = true;
            }
        }
        var hit: std.ArrayList([]const u8) = .empty;
        const keys = st.kind == .param or st.kind == .subckt or st.kind == .instance;
        for (schema.info(st.kind).slots, 0..) |sl, si| {
            // Slots that name a parameter: a function's arguments, what a
            // sweep sweeps, a data table's columns, what an alter sets.
            const words = (st.kind == .func and std.mem.eql(u8, sl.name, "args")) or
                ((st.kind == .dc or st.kind == .step) and (std.mem.eql(u8, sl.name, "param") or std.mem.eql(u8, sl.name, "param2"))) or
                (st.kind == .data and std.mem.eql(u8, sl.name, "cols")) or
                (st.kind == .alter and (std.mem.eql(u8, sl.name, "param") or std.mem.eql(u8, sl.name, "keys")));
            const v = try renamedValue(
                w.arena,
                st.at(@intCast(si)),
                renames,
                keys,
                words,
                &hit,
            ) orelse continue;
            if (!changed or cur.body.ptr != st.body.ptr) try cur.own(w.arena);
            try cur.set(w.arena, @intCast(si), v);
            changed = true;
        }
        for (hit.items) |old| {
            const gop = try told.getOrPut(w.perm, old);
            if (gop.found_existing) continue;
            gop.key_ptr.* = try w.perm.dupe(u8, old);
            const why = why: for (w.g.reserved) |r| {
                for (r.names) |n| if (std.ascii.eqlIgnoreCase(n, old)) break :why r.reason;
            } else "";
            w.report.add(
                .info,
                .rename,
                st.line,
                "parameter '{s}' is written as '{s}', where it is defined and wherever it is " ++
                    "used: {s}",
                .{ old, renames.get(old).?, why },
            );
        }
        if (changed) {
            if (list == null) list = try w.arena.dupe(ir.Stmt, stmts);
            list.?[i] = cur;
        }
    }
    return list orelse stmts;
}

/// With `src`, a name not in it is copied (the statements go away).
pub fn collectMasters(
    arena: Allocator,
    stmts: []const ir.Stmt,
    models: *ir.CaselessSet,
    subckts: *ir.CaselessSet,
    src: ?[]const u8,
) Allocator.Error!void {
    for (stmts) |*s| {
        const n = s.get("name");
        if (n == .atom) {
            if (s.kind == .subckt) try ir.putName(subckts, arena, src, n.atom);
            // `nch.1`, `nch.2`: bins of the model `nch`.
            if (s.kind == .model)
                try ir.putName(models, arena, src, ir.binBase(n.atom) orelse n.atom);
        }
        try collectMasters(arena, s.body, models, subckts, src);
    }
}

/// `masterRenames` for the models and subcircuits `collectMasters` found.
pub fn renamesOf(
    arena: Allocator,
    models_in: *const ir.CaselessSet,
    subckts_in: *const ir.CaselessSet,
    env: ?*const ir.Env,
) Allocator.Error!CaselessMap {
    var models = try models_in.clone(arena);
    var subckts = try subckts_in.clone(arena);
    var taken: ir.CaselessSet = .empty;
    if (env) |e| {
        var it = e.models.keyIterator();
        while (it.next()) |k| try models.put(arena, ir.binBase(k.*) orelse k.*, {});
        var si = e.subckts.keyIterator();
        while (si.next()) |k| try subckts.put(arena, k.*, {});
        var di = e.declared.keyIterator();
        while (di.next()) |k| try taken.put(arena, k.*, {});
    }
    var out: CaselessMap = .empty;
    var it = models.keyIterator();
    while (it.next()) |k| {
        try taken.put(arena, k.*, {});
        if (!subckts.contains(k.*)) continue;
        var name = try std.fmt.allocPrint(arena, "{s}__m", .{k.*});
        var n: usize = 2;
        while (taken.contains(name) or subckts.contains(name) or models.contains(name)) : (n += 1) {
            name = try std.fmt.allocPrint(arena, "{s}__m{d}", .{ k.*, n });
        }
        try out.put(arena, k.*, name);
    }
    return out;
}

/// `reserved`: each parameter `defined` (here or in another file of the
/// project) under a name the dialect keeps for itself, to the name it is
/// written under: `vt__p`, or `vt__p2` and so on when that is taken. Every
/// file of a project gets the same map. A name that is a variable in every
/// dialect (`time`) is left: in an expression the word is the variable.
pub fn reservedRenames(
    arena: Allocator,
    g: *const Grammar,
    defined: *const ir.CaselessSet,
    env: ?*const ir.Env,
) Allocator.Error!CaselessMap {
    var out: CaselessMap = .empty;
    for (g.reserved) |r| for (r.names) |n| {
        // `time` is the variable in every expression; a variable this
        // dialect takes before a parameter of its name (`shadowed`) is not.
        if (schema.isVariable(n) and !r.shadowed) continue;
        if (!defined.contains(n) and !(if (env) |e| e.params.contains(n) else false)) continue;
        var name = try std.fmt.allocPrint(arena, "{s}__p", .{n});
        var i: usize = 2;
        while (defined.contains(name) or (if (env) |e| e.params.contains(name) else false)) : (i += 1) {
            name = try std.fmt.allocPrint(arena, "{s}__p{d}", .{ n, i });
        }
        try out.put(arena, n, name);
    };
    return out;
}

/// `seen`: the names the scope defined before `stmts`; with `keep`, each
/// new one is kept, as `stmts` go away before the scope ends.
pub fn uniqueParamsIn(
    stmts: []const ir.Stmt,
    seen: *ir.CaselessSet,
    keep: ?ir.Keep,
    report: *ir.Report,
    g: *const Grammar,
) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.body.len > 0) try uniqueParams(s.body, report, g);
        if (s.kind != .param or s.get("params") != .params) continue;
        for (s.get("params").params) |p| {
            // The variation of the parameter before it, not a parameter.
            if (stats.devLotKey(p.key) != null) continue;
            const gop = try seen.getOrPut(ir.big, p.key);
            if (gop.found_existing)
                report.add(
                    .@"error",
                    .invalid,
                    s.line,
                    "parameter '{s}' is defined twice in one scope; {s}",
                    .{ p.key, g.unique_param },
                )
            else if (keep) |k| {
                gop.key_ptr.* = try k.text(p.key);
            }
        }
    }
}

/// `unique analysis`: more analyses than the simulator loads in one netlist
/// are an error on each; two it loads, running one, a caveat on the other.
/// The lines are the entries': a message is the same for a netlist built
/// in Python, whose statements have other lines.
pub fn uniqueAnalyses(
    a: Allocator,
    g: *const Grammar,
    found: []const Analysis,
    report: *ir.Report,
) Allocator.Error!void {
    const u = g.unique_analysis orelse return;
    if (found.len < 2) return;
    var besides: usize = 0;
    for (found) |f| besides += @intFromBool(f.kind == u.beside);
    if (found.len == 2 and besides > 0) {
        // Two of the kind are the same analysis twice: nothing is left out.
        if (besides == 2) return;
        const op: usize = @intFromBool(found[1].kind == u.beside);
        report.add(
            .warning,
            .caveat,
            found[op].line,
            "{s} beside {s}; {s}",
            .{ @tagName(found[op].kind), @tagName(found[op ^ 1].kind), u.reason },
        );
        return;
    }
    var names: std.ArrayList(u8) = .empty;
    for (found, 0..) |f, i|
        try names.print(a, "{s}{s}", .{ if (i == 0) "" else ", ", @tagName(f.kind) });
    for (found) |f|
        report.add(
            .@"error",
            .invalid,
            f.line,
            "{s}: one of {d} analyses in this netlist ({s}); {s}",
            .{ @tagName(f.kind), found.len, names.items, u.reason },
        );
}

/// `unique analysis`: the statements of `stmts` that count as an analysis
/// in `g`, outside subcircuits, in the order written.
pub fn collectAnalyses(
    a: Allocator,
    g: *const Grammar,
    stmts: []const ir.Stmt,
    found: *std.ArrayList(Analysis),
) Allocator.Error!void {
    const u = g.unique_analysis orelse return;
    for (stmts) |*s| {
        if (s.kind == .subckt) continue;
        if (std.mem.indexOfScalar(ir.Kind, u.kinds, s.kind) != null)
            try found.append(a, .{ .kind = s.kind, .line = s.line });
        try collectAnalyses(a, g, s.body, found);
    }
}

/// `unique master`: names both a model (or its bins, `nch.1`) and a
/// subcircuit define, here or in another file of the project, each to the
/// name its model is written under: `nch__m`, or `nch__m2` and so on when
/// that is taken. Every file of a project gets the same map.
pub fn masterRenames(
    arena: Allocator,
    stmts: []const ir.Stmt,
    env: ?*const ir.Env,
) Allocator.Error!CaselessMap {
    var models: ir.CaselessSet = .empty;
    var subckts: ir.CaselessSet = .empty;
    try collectMasters(arena, stmts, &models, &subckts, null);
    return renamesOf(arena, &models, &subckts, env);
}

/// `unique param`: a parameter defined twice in one scope. Each body
/// (subcircuit, library section, branch) is a scope of its own.
pub fn uniqueParams(
    stmts: []const ir.Stmt,
    report: *ir.Report,
    g: *const Grammar,
) Allocator.Error!void {
    var seen: ir.CaselessSet = .empty;
    defer seen.deinit(ir.big);
    try uniqueParamsIn(stmts, &seen, null, report, g);
}

/// `v` for `renameParams`, or null when nothing in it is renamed. `keys`:
/// the keys of a parameter list are parameters; `words`: so are bare words.
pub fn renamedValue(
    arena: Allocator,
    v: Value,
    renames: *const CaselessMap,
    keys: bool,
    words: bool,
    hit: *std.ArrayList([]const u8),
) Allocator.Error!?Value {
    switch (v) {
        .expr => |e| {
            const t = try expr.rename(arena, e, renames, hit);
            return if (t.ptr == e.ptr) null else .{ .expr = t };
        },
        .atom => |a| {
            const to = renames.get(a) orelse return null;
            if (!words) return null;
            try hit.append(arena, a);
            return .{ .atom = to };
        },
        .list => |l| {
            var out: ?[]Value = null;
            for (l, 0..) |x, i| if (try renamedValue(arena, x, renames, keys, words, hit)) |n| {
                if (out == null) out = try arena.dupe(Value, l);
                out.?[i] = n;
            };
            return if (out) |o| .{ .list = o } else null;
        },
        .params => |ps| {
            var out: ?[]ir.Param = null;
            for (ps, 0..) |p, i| {
                var n = p;
                if (keys) if (renames.get(p.key)) |to| {
                    try hit.append(arena, p.key);
                    n.key = to;
                };
                if (try renamedValue(arena, p.val, renames, false, false, hit)) |val| n.val = val;
                if (n.key.ptr == p.key.ptr and n.val.eql(p.val)) continue;
                if (out == null) out = try arena.dupe(ir.Param, ps);
                out.?[i] = n;
            }
            return if (out) |o| .{ .params = o } else null;
        },
        else => return null,
    }
}

pub const Analysis = struct { kind: ir.Kind, line: u32 };

pub fn clashes(
    arena: Allocator,
    stmts: []const ir.Stmt,
    models: *ir.CaselessSet,
    subckts: *ir.CaselessSet,
    told: *ir.CaselessSet,
    report: *ir.Report,
    g: *const Grammar,
) Allocator.Error!void {
    for (stmts) |*s| {
        try clashes(arena, s.body, models, subckts, told, report, g);
        if (schema.info(s.kind).class != .device or s.kind == .instance) continue;
        const m = s.get("master");
        if (m != .atom or !models.contains(m.atom) or !subckts.contains(m.atom)) continue;
        const gop = try told.getOrPut(arena, m.atom);
        if (gop.found_existing) continue;
        gop.key_ptr.* = try arena.dupe(u8, m.atom);
        report.add(
            .@"error",
            .invalid,
            s.line,
            "'{s}' names both a model and a subcircuit, and {s} uses it on {s}; {s}",
            .{ m.atom, @tagName(s.kind), s.get("name").atom, g.unique_master },
        );
    }
}

pub fn collectDeclared(
    arena: Allocator,
    stmts: []const ir.Stmt,
    out: *std.StringHashMapUnmanaged(void),
) Allocator.Error!void {
    for (stmts) |*s| {
        if ((s.kind == .model or s.kind == .subckt) and s.get("name") == .atom)
            try out.put(arena, try std.ascii.allocLowerString(arena, s.get("name").atom), {});
        try collectDeclared(arena, s.body, out);
    }
}

/// Names that differ only by case collide in a dialect that ignores case.
/// Nodes, instances, definitions and parameters are separate name spaces
/// (`schema.Space`): a source `Vdd` on a node `vdd` is no collision. A
/// subcircuit's ports, nodes and instances are its own scope; definitions
/// and parameters are shared by all scopes.
/// With `keep`, names are kept: the statements go away first.
pub fn checkCase(
    stmts: []const ir.Stmt,
    seen: *CaseMaps,
    report: *ir.Report,
    target: []const u8,
    keep: ?ir.Keep,
) Allocator.Error!void {
    for (stmts) |*s| {
        const scoped = s.kind == .subckt;
        var inner: CaseMaps = .{ .definitions = seen.definitions, .params = seen.params };
        const maps = if (scoped) &inner else seen;
        defer if (scoped) {
            seen.definitions = inner.definitions;
            seen.params = inner.params;
            inner.nodes.deinit(ir.big);
            inner.instances.deinit(ir.big);
        };
        for (schema.info(s.kind).slots, 0..) |sl, i| {
            const map = switch (sl.ty) {
                .node, .name, .ident => switch (sl.space orelse continue) {
                    .node => &maps.nodes,
                    .instance => &maps.instances,
                    .definition => &maps.definitions,
                    .param => &maps.params,
                },
                else => continue,
            };
            const one = [1]Value{s.at(i)};
            const items: []const Value = switch (one[0]) {
                .atom => &one,
                .list => |l| l,
                else => &.{},
            };
            for (items) |v| {
                if (v != .atom) continue;
                const gop = try map.getOrPut(ir.big, v.atom);
                if (gop.found_existing and !std.mem.eql(u8, gop.key_ptr.*, v.atom)) {
                    report.add(.@"error", .invalid, s.line, "'{s}' and '{s}' are different " ++
                        "names in the source but the same name in {s}, which ignores case", .{
                        gop.key_ptr.*, v.atom, target,
                    });
                    gop.key_ptr.* = if (keep) |k| try k.text(v.atom) else v.atom;
                } else if (!gop.found_existing) if (keep) |k| {
                    gop.key_ptr.* = try k.text(v.atom);
                };
            }
        }
        try checkCase(s.body, maps, report, target, keep);
    }
}

/// Two names that differ only by case are one name in a case-folding dialect.
/// Each key is the spelling last seen. The tables hold every node and
/// instance name, so they live outside the arena and are freed when done.
pub const CaseMaps = struct {
    nodes: ir.CaselessSet = .empty,
    instances: ir.CaselessSet = .empty,
    definitions: ir.CaselessSet = .empty,
    params: ir.CaselessSet = .empty,

    pub fn deinit(m: *CaseMaps) void {
        m.nodes.deinit(ir.big);
        m.instances.deinit(ir.big);
        m.definitions.deinit(ir.big);
        m.params.deinit(ir.big);
    }
};

pub fn collectFuncs(arena: Allocator, stmts: []const ir.Stmt, out: *expr.Funcs) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .func and s.get("name") == .atom)
            try out.put(arena, try std.ascii.allocLowerString(arena, s.get("name").atom), {});
        try collectFuncs(arena, s.body, out);
    }
}

pub fn collectInstances(stmts: []const ir.Stmt, out: *ir.CaselessSet) Allocator.Error!void {
    for (stmts) |*s| {
        if (schema.info(s.kind).class == .device and s.get("name") == .atom)
            try out.put(ir.big, s.get("name").atom, {});
        try collectInstances(s.body, out);
    }
}
