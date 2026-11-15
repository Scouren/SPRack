//! Translation as a stream: the netlist is read and written one top-level
//! statement at a time, so that what it takes is bounded by its largest
//! statement and by tables of names, not by its size.
//!
//! Three passes over the text, which stays in memory as the only copy of
//! the netlist:
//!
//! 1. the reader's own first pass (`reader.Source.open`): which names are
//!    models and subcircuits, and how each name is spelled;
//! 2. a survey: every statement is read and thrown away, keeping only what
//!    a pass of `read` or `write` needs of the whole netlist before it can
//!    handle the first statement (model kinds and families, subcircuit
//!    names, options, the analyses, the names references point at...);
//! 3. each statement read again, resolved and written before the next.
//!
//! A few constructs make a pass of `read` or `write` move or merge
//! statements across the netlist (alters, sweeps, Monte Carlo, two option
//! lines, a move between statements, binned models into Spectre,
//! statistics, pole-zero ports, a subcircuit used before it is defined
//! when the topology is checked). Where the survey meets one, the netlist
//! is read and written whole instead, as `read` and `write` do; so is a
//! file that switches language.

const std = @import("std");
const ir = @import("ir.zig");
const schema = @import("schema.zig");
const grammar = @import("grammar.zig");
const reader = @import("reader.zig");
const writer = @import("writer.zig");
const stats = @import("stats.zig");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Stmt = ir.Stmt;
const Kind = schema.Kind;

pub const Options = struct {
    env: ?*const ir.Env = null,
    library: bool = false,
    /// Run on each statement after it is read, before it is resolved and
    /// written (`sprack project` rewrites include paths so).
    hook: ?Hook = null,
    /// Read and write the netlist whole, as `reader.read` and `writer.write`.
    whole: bool = false,
};

pub const Hook = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, arena: Allocator, stmts: []Stmt, report: *ir.Report) Allocator.Error!void,
};

pub const Error = Allocator.Error || std.Io.Writer.Error;

/// Read `src` as `gf` and write it as `gt`, as `reader.read` then
/// `writer.write` would. Null when it was streamed, else why it was not.
pub fn translate(arena: Allocator, gf: *const Grammar, gt: *const Grammar, src: []const u8, out: *std.Io.Writer, report: *ir.Report, caps: ?*const writer.Caps, opts: Options) Error!?[]const u8 {
    if (opts.whole or (gf.switches.len > 0 and std.mem.indexOf(u8, src, "lang") != null)) {
        try whole(arena, gf, gt, src, out, report, caps, opts);
        return if (opts.whole) "asked to" else "a change of language";
    }
    const keep: ir.Keep = .{ .perm = arena, .src = src };
    const start = report.items.items.len;
    var muted: ir.Report = .{ .arena = arena, .mute = true };
    const s = try reader.Source.open(gf, arena, src, report, .{ .env = opts.env, .library = opts.library });
    defer s.deinit();
    var scratch: std.heap.ArenaAllocator = .init(ir.big);
    defer scratch.deinit();

    var sv: Survey = try .init(arena, gf, gt, opts);
    const params = s.paramCount();
    var needed: reader.Needed = .{};
    defer needed.set.deinit(ir.big);
    s.watchSpelling(&needed);
    s.r.report = &muted;
    s.rewind(scratch.allocator(), null);
    while (true) {
        s.between();
        _ = scratch.reset(.retain_capacity);
        s.useArena(scratch.allocator());
        var list: std.ArrayList(Stmt) = .empty;
        if (!try s.next(&list)) break;
        try s.finishGroup(&list, &muted, null);
        if (opts.hook) |h| try h.run(h.ctx, scratch.allocator(), list.items, &muted);
        try sv.add(s, keep, list.items);
    }
    sv.w.folds_case = s.r.folded;
    sv.w.title = s.title;
    if (s.paramCount() != params) sv.reason("a parameter defined in a line read as two");
    if (try sv.whole(arena)) {
        try whole(arena, gf, gt, src, out, report, caps, opts);
        return sv.why.?;
    }

    s.pruneSpelling();
    s.r.report = report;
    s.rewind(scratch.allocator(), null);
    var ws: writer.Stream = undefined;
    try ws.begin(gt, keep, out, &sv.w, report, caps, opts.env);
    while (true) {
        s.between();
        _ = scratch.reset(.retain_capacity);
        s.useArena(scratch.allocator());
        report.phase = ir.Phase.read;
        var list: std.ArrayList(Stmt) = .empty;
        if (!try s.next(&list)) break;
        try s.finishGroup(&list, report, sv.last);
        if (opts.hook) |h| {
            report.phase = ir.Phase.project;
            try h.run(h.ctx, scratch.allocator(), list.items, report);
        }
        try reader.resolveGroup(gf, scratch.allocator(), list.items, &sv.tables, report);
        try ws.group(scratch.allocator(), list.items);
    }
    const rescan: Rescan = .{ .s = s, .scratch = &scratch, .sv = &sv, .muted = &muted, .hook = opts.hook };
    try ws.end(rescan);
    report.sortPhases(start);
    return null;
}

fn whole(arena: Allocator, gf: *const Grammar, gt: *const Grammar, src: []const u8, out: *std.Io.Writer, report: *ir.Report, caps: ?*const writer.Caps, opts: Options) Error!void {
    report.phase = 0;
    const nl = try reader.read(gf, arena, src, report, .{ .env = opts.env, .library = opts.library });
    if (opts.hook) |h| try h.run(h.ctx, arena, nl.stmts, report);
    try writer.write(gt, arena, out, &nl, report, caps, opts.env);
}

/// The statements again, for the topology check's islands at the top level.
const Rescan = struct {
    s: *reader.Source,
    scratch: *std.heap.ArenaAllocator,
    sv: *const Survey,
    muted: *ir.Report,
    hook: ?Hook,

    pub fn run(r: Rescan, t: anytype) Error!void {
        const s = r.s;
        s.r.report = r.muted;
        s.rewind(r.scratch.allocator(), null);
        while (true) {
            s.between();
            _ = r.scratch.reset(.retain_capacity);
            s.useArena(r.scratch.allocator());
            var list: std.ArrayList(Stmt) = .empty;
            if (!try s.next(&list)) break;
            try s.finishGroup(&list, r.muted, r.sv.last);
            if (r.hook) |h| try h.run(h.ctx, r.scratch.allocator(), list.items, r.muted);
            try reader.resolveGroup(s.r.g, r.scratch.allocator(), list.items, &r.sv.tables, r.muted);
            try t.cross(list.items);
        }
    }
};

/// What the passes need of the whole netlist, and whether it can stream.
const Survey = struct {
    gf: *const Grammar,
    gt: *const Grammar,
    env: ?*const ir.Env,
    w: writer.Survey,
    tables: reader.Tables,
    /// The last analysis at the top level, for a `.measure` naming none.
    last: ?[]const u8 = null,
    /// Why the netlist is read whole; the first reason met.
    why: ?[]const u8 = null,
    /// The top-level option statements, by heading.
    option_lines: usize = 0,
    /// For each of `gt`'s moves: a statement has the value to move, and
    /// one could take it.
    move_from: []bool,
    move_to: []bool,
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
    /// Subcircuits defined so far, and the names instances used before
    /// any definition of them.
    defined: ir.CaselessSet = .empty,
    early: ir.CaselessSet = .empty,
    group_defs: ir.CaselessSet = .empty,

    fn init(arena: Allocator, gf: *const Grammar, gt: *const Grammar, opts: Options) Allocator.Error!Survey {
        const from = try arena.alloc(bool, gt.moves.len);
        const to = try arena.alloc(bool, gt.moves.len);
        @memset(from, false);
        @memset(to, false);
        return .{
            .gf = gf,
            .gt = gt,
            .env = opts.env,
            .w = .{ .dialect = gf.name, .library = opts.library },
            .tables = try .init(arena, opts.env),
            .move_from = from,
            .move_to = to,
        };
    }

    fn reason(sv: *Survey, why: []const u8) void {
        if (sv.why == null) sv.why = why;
    }

    fn add(sv: *Survey, s: *const reader.Source, k: ir.Keep, stmts: []const Stmt) Allocator.Error!void {
        const gf = sv.gf;
        const gt = sv.gt;
        try sv.w.add(gt, k, stmts);
        try sv.tables.add(k, stmts);
        sv.last = reader.lastAnalysis(stmts, sv.last);
        for (stmts) |*st| {
            switch (st.kind) {
                .alter => sv.reason("an alter"),
                .montecarlo => if (st.body.len == 0) sv.reason("a Monte Carlo analysis of the whole netlist"),
                .options => {
                    sv.option_lines += 1;
                    if (sv.option_lines > 1) sv.reason("two option lines");
                },
                .pz => sv.reason("a pole-zero analysis"),
                .model => if (gt.blockOf(.model) != null and st.get("name") == .atom and ir.binBase(st.get("name").atom) != null)
                    sv.reason("a binned model"),
                else => {},
            }
            for (gf.moves) |mv| {
                if (!mv.oneway and st.kind == mv.to and isBound(st.at(mv.to_slot))) sv.reason("a value read on one statement that belongs on another");
            }
            for (gf.merges) |mg| if (st.kind == mg.into) sv.reason("a statement read as two");
            sv.noteMoves(st);
        }
        if (ir.hasSweep(stmts)) sv.sweep = true;
        if (stats.changes(gt, gf.name, stmts)) sv.stats = true;
        try sv.masters(k, stmts);
        if (!gf.lex.case_sensitive and sv.canonical) sv.canonical = names(s, stmts);
        // A subcircuit is summarized for the topology check when it comes:
        // an instance of one must come after it.
        sv.group_defs.clearRetainingCapacity();
        try sv.defs(k, stmts);
        try sv.uses(k, stmts);
        var it = sv.group_defs.keyIterator();
        while (it.next()) |n| try sv.defined.put(k.perm, n.*, {});
    }

    fn noteMoves(sv: *Survey, st: *const Stmt) void {
        for (sv.gt.moves, 0..) |mv, i| {
            if (st.kind == mv.from and st.at(mv.from_slot) != .none) sv.move_from[i] = true;
            if (st.kind == mv.to and st.at(mv.to_slot) == .none) sv.move_to[i] = true;
        }
    }

    fn masters(sv: *Survey, k: ir.Keep, stmts: []const Stmt) Allocator.Error!void {
        for (stmts) |*s| {
            try sv.masters(k, s.body);
            if (s.kind == .model and s.get("family") == .none and s.get("type") == .atom and s.get("name") == .atom)
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

    fn defs(sv: *Survey, k: ir.Keep, stmts: []const Stmt) Allocator.Error!void {
        for (stmts) |*s| {
            if (s.kind == .subckt and s.get("name") == .atom) try ir.putName(&sv.group_defs, k.perm, k.src, s.get("name").atom);
            try sv.defs(k, s.body);
        }
    }

    fn uses(sv: *Survey, k: ir.Keep, stmts: []const Stmt) Allocator.Error!void {
        for (stmts) |*s| {
            if (s.kind == .instance and s.get("master") == .atom) {
                const m = s.get("master").atom;
                if (!sv.defined.contains(m) and !sv.group_defs.contains(m)) try ir.putName(&sv.early, k.perm, k.src, m);
            }
            try sv.uses(k, s.body);
        }
    }

    /// Does the netlist need reading whole? Says why to `sv.why`.
    fn whole(sv: *Survey, arena: Allocator) Allocator.Error!bool {
        const gt = sv.gt;
        if (sv.sweep) sv.reason("a sweep");
        if (sv.stats) sv.reason("random parameters or statistics");
        // `ir.markUnlistedBuiltins`.
        var li = sv.lettered.keyIterator();
        while (li.next()) |m| if (sv.unlisted.contains(m.*)) sv.reason("a model of an unlisted type");
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
                    if (want != kind and want != .device and ir.sameSlots(kind, want)) retags = true;
                }
            }
        }
        if (retags and gt.needs.len > 0) sv.reason("instances retagged by their model, where the target's boilerplate depends on kinds");
        sv.w.check_case = !sv.canonical or retags or sv.gf.lex.case_sensitive;
        // The topology check summarizes a subcircuit when it comes.
        if (gt.requires.len > 0 and sv.w.facts.any and !std.mem.eql(u8, sv.gf.name, gt.name)) {
            var ei = sv.early.keyIterator();
            while (ei.next()) |n| if (sv.defined.contains(n.*)) sv.reason("a subcircuit used before it is defined");
        }
        // `Writer.applyMoves`, with the options the target adds.
        var opts: ir.Netlist = .{ .dialect = sv.gf.name, .library = sv.w.library, .stmts = sv.w.options.items };
        if (try writer.defaultOptions(arena, gt, &opts)) |d| sv.noteMoves(&d);
        for (sv.move_from, sv.move_to) |f, to| if (f and to) sv.reason("a value written on another statement");
        return sv.why != null;
    }
};

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
fn names(s: *const reader.Source, stmts: []const Stmt) bool {
    for (stmts) |*st| {
        for (schema.info(st.kind).slots, 0..) |sl, i| {
            switch (sl.ty) {
                .node, .name, .ident => {},
                else => continue,
            }
            if (st.kind == .model and std.mem.eql(u8, sl.name, "type")) continue;
            const v = st.at(i);
            const one = [1]ir.Value{v};
            const items: []const ir.Value = switch (v) {
                .atom => &one,
                .list => |l| l,
                else => &.{},
            };
            for (items) |x| if (x == .atom and !s.canonical(x.atom)) return false;
        }
        if (!names(s, st.body)) return false;
    }
    return true;
}
