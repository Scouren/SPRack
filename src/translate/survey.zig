//! Stream: the survey, what the passes need of the whole netlist before its
//! first statement is written, and whether it can stream.
//!
//! Contents:
//! - `pub const Survey = struct`, with `pub fn init`, `pub fn reason`, `pub fn add`,
//!   `pub fn noteOptions`, `pub fn mergeOptions`, `pub fn takeOptions`, `pub fn retain`,
//!   `pub fn whole`

const std = @import("std");
const ir = @import("ir");
const schema = @import("schema");
const grammar = @import("grammar");
const reader = @import("reader");
const writer = @import("writer");
const stats = @import("stats");
const topology = @import("topology");
const stream = @import("stream.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Stmt = ir.Stmt;
const Kind = schema.Kind;
const Options = stream.Options;
const Hook = stream.Hook;

/// What the passes need of the whole netlist, and whether it can stream.
// tidy: allow(bool-heavy-struct) one Survey a translation, never an array of them: flags in
// an integer would save nothing.
pub const Survey = struct {
    gf: *const Grammar,
    gt: *const Grammar,
    env: ?*const ir.Env,
    w: writer.Survey,
    tables: reader.Tables,
    /// The last analysis at the top level, for a `.measure` naming none.
    last: ?[]const u8 = null,
    /// Why the netlist is read whole; the first reason met.
    why: ?[]const u8 = null,
    keep: ir.Keep,
    /// The top-level option statements as read, before the hook; then one
    /// for each heading (`mergeOptions`).
    options: std.ArrayList(Stmt) = .empty,
    /// Two of them were under one heading; and which of `options` the
    /// writing has come to.
    merged: bool = false,
    taken: []bool = &.{},
    /// For each of `gt`'s moves: a statement has the value to move, and
    /// one could take it.
    move_from: []bool,
    move_to: []bool,
    /// A statement of the kind a move's value goes to.
    move_seen: []bool,
    sweep: bool = false,
    stats: bool = false,
    /// Names of models whose type no table lists, and the models lettered
    /// devices name: a model in both is marked `unlisted_builtin`.
    unlisted: std.StringHashMapUnmanaged(void) = .empty,
    lettered: std.StringHashMapUnmanaged(std.EnumSet(Kind)) = .empty,
    /// Masters of generic instances: retagged where they name a model.
    instances: std.StringHashMapUnmanaged(void) = .empty,
    /// Every name the case check would compare has its class's spelling.
    canonical: bool = true,
    /// The topology is checked, if the netlist has an analysis.
    topo: bool,
    /// Subcircuits defined so far, and the names instances used before
    /// any definition of them.
    defined: ir.CaselessSet = .empty,
    early: ir.CaselessSet = .empty,
    group_defs: ir.CaselessSet = .empty,
    /// What the first definition of each subcircuit instantiates.
    uses_of: Uses = .empty,
    /// The subcircuits the topology check needs before their definitions
    /// come (`need`), each until `retain` has kept it.
    wanted: Marks = .empty,

    const Uses = std.HashMapUnmanaged(
        []const u8,
        ir.CaselessSet,
        ir.Caseless,
        std.hash_map.default_max_load_percentage,
    );
    const Marks = std.HashMapUnmanaged(
        []const u8,
        u8,
        ir.Caseless,
        std.hash_map.default_max_load_percentage,
    );

    pub fn init(
        keep: ir.Keep,
        gf: *const Grammar,
        gt: *const Grammar,
        opts: Options,
    ) Allocator.Error!Survey {
        // Only a netlist that streams is surveyed.
        assert(!opts.whole);
        const arena = keep.perm;
        const from = try arena.alloc(bool, gt.moves.len);
        const to = try arena.alloc(bool, gt.moves.len);
        const seen = try arena.alloc(bool, gt.moves.len);
        @memset(seen, false);
        @memset(from, false);
        @memset(to, false);
        return .{
            .gf = gf,
            .gt = gt,
            .env = opts.env,
            .w = .{ .dialect = gf.name, .library = opts.library },
            .tables = try .init(arena, opts.env),
            .keep = keep,
            .topo = gt.requires.len > 0 and !std.mem.eql(u8, gf.name, gt.name),
            .move_from = from,
            .move_to = to,
            .move_seen = seen,
        };
    }

    pub fn reason(sv: *Survey, why: []const u8) void {
        if (sv.why == null) sv.why = why;
    }

    pub fn add(
        sv: *Survey,
        s: *const reader.Source,
        k: ir.Keep,
        stmts: []const Stmt,
    ) Allocator.Error!void {
        // Names are kept where the survey keeps them.
        assert(k.perm.ptr == sv.keep.perm.ptr);
        const gf = sv.gf;
        const gt = sv.gt;
        try sv.w.addStreamed(gt, gf, k, stmts);
        try sv.tables.add(k, stmts);
        sv.last = reader.lastAnalysis(stmts, sv.last);
        for (stmts) |*st| {
            if (writer.needsAll(gt, st)) |why| sv.reason(why);
            for (gf.moves) |mv| {
                if (!mv.oneway and st.kind == mv.to and isBound(st.at(mv.to_slot)))
                    sv.reason("a value read on one statement that belongs on another");
            }
            for (gf.merges) |mg| if (st.kind == mg.into) sv.reason("a statement read as two");
            sv.noteMoves(st);
        }
        // `cond.split`: an instance may come before the subcircuit it names.
        if (!gt.canWrite(.cond_if) and conditional(stmts))
            sv.reason("a conditional block in a subcircuit");
        if (ir.hasSweep(stmts)) sv.sweep = true;
        if (stats.changes(gt, stmts)) sv.stats = true;
        try sv.masters(k, stmts);
        if (!gf.lex.case_sensitive and sv.canonical) sv.canonical = names(s, stmts);
        if (!sv.topo) return;
        sv.group_defs.clearRetainingCapacity();
        try sv.defs(k, stmts);
        try sv.uses(k, stmts, null);
        var it = sv.group_defs.keyIterator();
        while (it.next()) |n| try sv.defined.put(k.perm, n.*, {});
    }

    /// The top-level option statements of `stmts`, as read.
    pub fn noteOptions(sv: *Survey, stmts: []const Stmt) Allocator.Error!void {
        for (stmts) |*st|
            if (st.kind == .options)
                try sv.options.append(sv.keep.perm, try ir.cloneStmt(sv.keep, st));
    }

    /// Several option statements under one heading are one
    /// (`reader.mergeOptions`), where the first stands (`takeOptions`).
    pub fn mergeOptions(sv: *Survey, hook: ?Hook, muted: *ir.Report) Allocator.Error!void {
        const a = sv.keep.perm;
        const n = sv.options.items.len;
        try reader.mergeOptions(a, &sv.options);
        sv.merged = sv.options.items.len < n;
        sv.taken = try a.alloc(bool, sv.options.items.len);
        @memset(sv.taken, false);
        // What the writer asks of them, it asks after the hook.
        const hooked = try a.alloc(Stmt, sv.options.items.len);
        for (sv.options.items, hooked) |*st, *h| h.* = try ir.cloneStmt(sv.keep, st);
        if (hook) |h| try h.run(h.ctx, a, hooked, muted);
        sv.w.options = hooked;
    }

    /// The option statements of `list`, read again, as `mergeOptions`
    /// left them: the first under a heading is all of them, the others go.
    pub fn takeOptions(sv: *Survey, list: *std.ArrayList(Stmt)) void {
        if (!sv.merged) return;
        // `mergeOptions` has run: a mark for each statement it left.
        assert(sv.taken.len == sv.options.items.len);
        const package = schema.slot(.options, "package");
        var i: usize = 0;
        while (i < list.items.len) {
            const st = &list.items[i];
            const k = for (sv.options.items, 0..) |*m, k| {
                if (st.kind == .options and m.at(package).eql(st.at(package))) break k;
            } else {
                i += 1;
                continue;
            };
            if (sv.taken[k]) {
                _ = list.orderedRemove(i);
                continue;
            }
            sv.taken[k] = true;
            st.* = sv.options.items[k];
            i += 1;
        }
    }

    fn noteMoves(sv: *Survey, st: *const Stmt) void {
        for (sv.gt.moves, 0..) |mv, i| {
            if (st.kind == mv.from and st.at(mv.from_slot) != .none) sv.move_from[i] = true;
            // An options statement is made where there is none (`moveToOptions`).
            if (mv.to == .options or (st.kind == mv.to and st.at(mv.to_slot) == .none))
                sv.move_to[i] = true;
            if (st.kind == mv.to) sv.move_seen[i] = true;
        }
    }

    // tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
    fn masters(sv: *Survey, k: ir.Keep, stmts: []const Stmt) Allocator.Error!void {
        // Names are kept where the survey keeps them.
        assert(k.perm.ptr == sv.keep.perm.ptr);
        for (stmts) |*s| {
            try sv.masters(k, s.body);
            if (s.kind == .model and s.get("family") == .none and s.get("type") == .atom and
                s.get("name") == .atom)
                try ir.putName(&sv.unlisted, k.perm, k.src, s.get("name").atom);
            if (schema.info(s.kind).class != .device) continue;
            const m = s.get("master");
            if (m != .atom) continue;
            if (s.kind == .instance) {
                try ir.putName(&sv.instances, k.perm, k.src, m.atom);
            } else {
                const gop = try sv.lettered.getOrPut(k.perm, m.atom);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try k.text(m.atom);
                    gop.value_ptr.* = .empty;
                }
                gop.value_ptr.insert(s.kind);
            }
        }
    }

    // tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
    fn defs(sv: *Survey, k: ir.Keep, stmts: []const Stmt) Allocator.Error!void {
        for (stmts) |*s| {
            if (s.kind == .subckt)
                if (topology.nodeName(s.get("name"))) |n|
                    try ir.putName(&sv.group_defs, k.perm, k.src, n);
            try sv.defs(k, s.body);
        }
    }

    /// `owner`: what the subcircuit `stmts` are the body of instantiates,
    /// if it is the first of its name.
    // tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
    fn uses(
        sv: *Survey,
        k: ir.Keep,
        stmts: []const Stmt,
        owner: ?*ir.CaselessSet,
    ) Allocator.Error!void {
        // Names are kept where the survey keeps them.
        assert(k.perm.ptr == sv.keep.perm.ptr);
        for (stmts) |*s| {
            if (s.kind == .subckt) {
                const name = topology.nodeName(s.get("name"));
                const first = if (name) |n| !sv.uses_of.contains(n) else false;
                var mine: ir.CaselessSet = .empty;
                try sv.uses(k, s.body, if (first) &mine else null);
                if (first) {
                    const gop = try sv.uses_of.getOrPut(k.perm, name.?);
                    if (gop.found_existing) continue;
                    gop.key_ptr.* = try k.text(name.?);
                    gop.value_ptr.* = mine;
                }
                continue;
            }
            if (s.kind == .instance) if (topology.nodeName(s.get("master"))) |m| {
                if (!sv.defined.contains(m) and !sv.group_defs.contains(m))
                    try ir.putName(&sv.early, k.perm, k.src, m);
                if (owner) |o| try ir.putName(o, k.perm, k.src, m);
            };
            try sv.uses(k, s.body, owner);
        }
    }

    /// `name`, if the netlist defines it, is wanted before its definition
    /// comes, and so is what it instantiates.
    // tidy: allow(recursion) bounded by the subcircuits defined: each is wanted once, before
    // the calls for what it instantiates.
    fn need(sv: *Survey, name: []const u8) Allocator.Error!void {
        const named = sv.uses_of.getPtr(name) orelse return;
        const gop = try sv.wanted.getOrPut(sv.keep.perm, name);
        if (gop.found_existing) return;
        gop.value_ptr.* = 0;
        var it = named.keyIterator();
        while (it.next()) |m| try sv.need(m.*);
    }

    /// Does `name`, a wanted subcircuit, instantiate itself, through others
    /// or not? Its mark: 1 on the way down from it, 2 once it does not.
    // tidy: allow(recursion) bounded by the subcircuits wanted: each is marked on the way
    // down, and a marked one returns at once.
    fn cyclic(sv: *Survey, name: []const u8) bool {
        const mark = sv.wanted.getPtr(name) orelse return false;
        if (mark.* != 0) return mark.* == 1;
        mark.* = 1;
        var it = sv.uses_of.getPtr(name).?.keyIterator();
        while (it.next()) |m| if (sv.cyclic(m.*)) return true;
        mark.* = 2;
        return false;
    }

    /// Keeps the first definition of each wanted subcircuit among `stmts`,
    /// for the topology check.
    // tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
    pub fn retain(sv: *Survey, stmts: []const Stmt) Allocator.Error!void {
        for (stmts) |*s| {
            if (s.kind == .subckt) if (topology.nodeName(s.get("name"))) |n| {
                if (sv.wanted.remove(n))
                    try sv.w.early.append(sv.keep.perm, try ir.cloneStmt(sv.keep, s));
            };
            try sv.retain(s.body);
        }
    }

    /// Does the netlist need reading whole? Says why to `sv.why`.
    pub fn whole(sv: *Survey, arena: Allocator) Allocator.Error!bool {
        const gt = sv.gt;
        if (sv.sweep) sv.reason("a sweep");
        if (sv.stats) sv.reason("a statistics block");
        // `ir.markUnlistedBuiltins`.
        var li = sv.lettered.keyIterator();
        while (li.next()) |m|
            if (sv.unlisted.contains(m.*)) sv.reason("a model of an unlisted type");
        // `ir.resolveInstances` may retag statements: their kinds and the
        // names they carry are not the survey's.
        var retags = false;
        const t = &sv.tables;
        if (t.models.count() > 0) {
            var ii = sv.instances.keyIterator();
            while (ii.next()) |m| {
                if (!t.subckts.contains(m.*) and t.models.get(m.*) != null) retags = true;
            }
            var it = sv.lettered.iterator();
            while (it.next()) |kv| {
                const want = t.models.get(kv.key_ptr.*) orelse continue;
                var ki = kv.value_ptr.iterator();
                while (ki.next()) |kind| {
                    if (want != kind and want != .device and ir.sameSlots(kind, want))
                        retags = true;
                }
            }
        }
        if (retags and gt.needs.len > 0)
            sv.reason(
                "instances retagged by their model, where the target's boilerplate depends on " ++
                    "kinds",
            );
        sv.w.check_case = !sv.canonical or retags or sv.gf.lex.case_sensitive;
        // The case check is left out only where every name is canonical.
        if (!sv.w.check_case) assert(sv.canonical);
        // The topology check summarizes a subcircuit when it comes: one
        // needed sooner is kept beforehand (`retain`). Which of two that
        // hold each other is summarized first is the order they come in.
        if (sv.topo and sv.w.facts.any) {
            var ei = sv.early.keyIterator();
            while (ei.next()) |n| try sv.need(n.*);
            var wi = sv.wanted.keyIterator();
            while (wi.next()) |n|
                if (sv.cyclic(n.*))
                    sv.reason("a subcircuit that holds itself, used before it is defined");
        }
        // `Writer.applyMoves`, with the options the target adds.
        var opts: ir.Netlist = .{
            .dialect = sv.gf.name,
            .library = sv.w.library,
            .stmts = sv.w.options,
        };
        if (try writer.defaultOptions(arena, gt, &opts)) |d| sv.noteMoves(&d);
        // A value for an analysis the netlist has not is said not written
        // (`Writer.applyMoves`), from the whole netlist too.
        for (sv.move_from, sv.move_to, sv.move_seen, sv.gt.moves) |f, to, seen, mv| {
            const unseen_analysis = !seen and mv.from == .options and
                schema.info(mv.to).class == .analysis;
            if (f and (to or unseen_analysis)) sv.reason("a value written on another statement");
        }
        return sv.why != null;
    }
};

// ---- private ----

/// A subcircuit of `stmts` holds a conditional block.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
fn conditional(stmts: []const Stmt) bool {
    for (stmts) |*s|
        if ((s.kind == .subckt and ir.holdsCond(s)) or conditional(s.body)) return true;
    return false;
}

fn isBound(v: ir.Value) bool {
    return switch (v) {
        .none => false,
        .list => |l| l.len > 0,
        .params => |p| p.len > 0,
        else => true,
    };
}

/// Are the names `writer.checkCase` compares in `stmts` all canonical
/// (`reader.Source.canonical`)? Then two that differ only by case cannot
/// both be there, and the check finds nothing.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
fn names(s: *const reader.Source, stmts: []const Stmt) bool {
    // Only a reader that folds case spells every name canonically.
    assert(!s.r.g.lex.case_sensitive);
    for (stmts) |*st| {
        for (schema.info(st.kind).slots, 0..) |sl, i| {
            switch (sl.ty) {
                .node, .name, .ident => {},
                else => continue,
            }
            const space = sl.space orelse continue;
            const v = st.at(i);
            const one = [1]ir.Value{v};
            const items: []const ir.Value = switch (v) {
                .atom => &one,
                .list => |l| l,
                else => &.{},
            };
            for (items) |x| if (x == .atom and !s.canonical(space, x.atom)) return false;
        }
        if (!names(s, st.body)) return false;
    }
    return true;
}
