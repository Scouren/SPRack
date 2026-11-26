//! The driver of the writer: the passes over the statements of a netlist,
//! in the order they run, and the writing of what they leave.
//!
//! A netlist is written a group of top-level statements at a time
//! (`Driver.begin`, `group` for each, `end`), after a `Survey` of all of it
//! has said what a pass needs of the statements it is not looking at. Some
//! passes need every statement at once (`Driver.netlistPasses`): a netlist
//! with work for one of them is written whole, which is one group holding
//! all of it (`write`). The order of the passes is `Driver.group` and
//! `Driver.tail`, and nowhere else.
//!
//! Report entries come out in pass order: as made, for a netlist written
//! whole; once sorted by `Report.phase`, for one written in groups.
//!
//! Contents:
//! - `pub const Survey = struct`, with `add(sv, g, k, stmts)` and
//!   `addStreamed(sv, g, gf, k, stmts)`
//! - `pub const Target = struct`
//! - `pub const Mode = union(enum)`
//! - `pub const Driver = struct`, with `begin(s, to, k, sv, mode)`,
//!   `group(s, arena, stmts)`, `end(s, rescan)` and `deinit(s)`
//! - `pub fn needsAll(g: *const Grammar, st: *const ir.Stmt) ?[]const u8`
//! - `pub fn write(to: Target, arena: Allocator, nl: *const ir.Netlist) Writer.Error!void`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const expr = @import("expr");
const stats = @import("stats");
const alter = @import("alter");
const topology = @import("topology");
const spread = @import("spread.zig");
const blocks = @import("blocks.zig");
const variants = @import("variants.zig");
const defaults = @import("defaults.zig");
const bins = @import("bins.zig");
const card_facts = @import("facts.zig");
const emit = @import("emit.zig");
const statement = @import("statement.zig");
const analysis_passes = @import("analyses.zig");
const name_passes = @import("names.zig");
const rewrite = @import("rewrite.zig");
const frame = @import("frame.zig");
const Refs = @import("refs.zig").Refs;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Kind = schema.Kind;
const Caps = emit.Caps;
const Writer = statement.Writer;
const Analysis = name_passes.Analysis;
const CaselessMap = name_passes.CaselessMap;

/// What writing needs to know of the whole netlist before its first
/// statement. Names are in `perm` or the source.
// tidy: allow(bool-heavy-struct) one a netlist, not a row of a table
pub const Survey = struct {
    title: []const u8 = "",
    dialect: []const u8,
    library: bool = false,
    folds_case: bool = false,
    declared: std.StringHashMapUnmanaged(void) = .empty,
    families: std.StringHashMapUnmanaged([]const u8) = .empty,
    modules: std.StringHashMapUnmanaged([]const u8) = .empty,
    funcs: expr.Funcs = .empty,
    used: [schema.kind_count]bool = @splat(false),
    fams: [schema.families.len]bool = @splat(false),
    models: ir.CaselessSet = .empty,
    subckts: ir.CaselessSet = .empty,
    /// One statement per `default` source the target's grammar names,
    /// holding the first value of it in the netlist.
    fill_from: std.ArrayList(ir.Stmt) = .empty,
    /// The top-level option statements, as a netlist read whole has them.
    options: []ir.Stmt = &.{},
    /// The subcircuits an instance names before their definitions come.
    early: std.ArrayList(ir.Stmt) = .empty,
    /// Top-level analyses.
    analyses: usize = 0,
    /// `names.collectAnalyses`.
    counted: std.ArrayList(Analysis) = .empty,
    /// Two names differing only by case may be in it: the check runs.
    check_case: bool = true,
    facts: topology.Facts = .{},
    globals: std.ArrayList([]const u8) = .empty,
    refs: Refs = .{},
    /// `names.collectReserved`.
    reserved: ir.CaselessSet = .empty,
    /// `rewrite.collectClashKeys`.
    clash_keys: ir.CaselessSet = .empty,
    /// `card_facts.collectTerminals`.
    terminals: card_facts.TerminalMap = .empty,

    /// Learn what `stmts`, the next top-level statements, hold: what the
    /// writing of any netlist asks.
    pub fn add(
        sv: *Survey,
        g: *const Grammar,
        k: ir.Keep,
        stmts: []const ir.Stmt,
    ) Allocator.Error!void {
        const a = k.perm;
        try name_passes.collectDeclared(a, stmts, &sv.declared);
        try ir.collectFamilies(a, stmts, &sv.families, k.src);
        try card_facts.collectModules(a, stmts, &sv.modules);
        try name_passes.collectFuncs(a, stmts, &sv.funcs);
        statement.markUsed(stmts, &sv.used);
        rewrite.markUsed(g, sv.dialect, stmts, &sv.used);
        try rewrite.collectClashKeys(a, g, stmts, &sv.clash_keys, k.src);
        ir.markFamilies(stmts, &sv.fams);
        try name_passes.collectMasters(a, stmts, &sv.models, &sv.subckts, k.src);
        try card_facts.collectTerminals(a, stmts, &sv.terminals, k.src);
        try name_passes.collectReserved(a, g, stmts, &sv.reserved, k.src);
        try name_passes.collectAnalyses(a, g, stmts, &sv.counted);
    }

    /// As `add`, with what only a netlist written a group at a time asks,
    /// since the statements that hold it are gone when it is wanted: the
    /// values a later statement is filled from, the count of analyses, the
    /// facts of the topology check and the names references point at.
    /// `gf`: the grammar the netlist is read with.
    pub fn addStreamed(
        sv: *Survey,
        g: *const Grammar,
        gf: *const Grammar,
        k: ir.Keep,
        stmts: []const ir.Stmt,
    ) Allocator.Error!void {
        try sv.add(g, k, stmts);
        for (g.fills) |f| try sv.takeFirst(k, stmts, f.from, f.from_slot);
        for (gf.omitted) |o| for (o.terms) |t| {
            if (t == .first) try sv.takeFirst(k, stmts, t.first.kind, t.first.slot);
        };
        sv.analyses += countRuns(stmts);
        sv.facts.add(stmts);
        try sv.addGlobals(k, stmts);
        try sv.refs.want(k, stmts);
    }

    /// Keeps the value of `slot` on the netlist's first statement of `kind`
    /// that has one, for `defaults.fill`.
    fn takeFirst(
        sv: *Survey,
        k: ir.Keep,
        stmts: []const ir.Stmt,
        kind: Kind,
        slot: u8,
    ) Allocator.Error!void {
        for (sv.fill_from.items) |*s| {
            if (s.kind == kind and s.at(slot) != .none) return;
        }
        const v = defaults.firstValue(stmts, kind, slot) orelse return;
        var st = try ir.newStmt(k.perm, kind, 0);
        try st.set(k.perm, slot, try ir.cloneValue(k, v));
        try sv.fill_from.append(k.perm, st);
    }

    // tidy: allow(recursion) bounded by the depth of blocks, ir.max_depth
    fn addGlobals(sv: *Survey, k: ir.Keep, stmts: []const ir.Stmt) Allocator.Error!void {
        for (stmts) |*s| {
            if (s.kind == .global and s.get("nodes") == .list) {
                for (s.get("nodes").list) |v|
                    if (v == .atom) try sv.globals.append(k.perm, try k.text(v.atom));
            }
            try sv.addGlobals(k, s.body);
        }
    }
};

/// Where a netlist is written to, and with what.
pub const Target = struct {
    g: *const Grammar,
    out: *std.Io.Writer,
    report: *ir.Report,
    caps: ?*const Caps,
    env: ?*const ir.Env,
};

/// How the statements come: a few at a time, or all of them in one group,
/// from the netlist that holds them.
pub const Mode = union(enum) { groups, whole: *const ir.Netlist };

/// One netlist being written: `group` is given its top-level statements,
/// and each pass runs on them before the next come.
// tidy: allow(bool-heavy-struct) one a netlist, not a row of a table
pub const Driver = struct {
    w: Writer,
    /// The netlist's own facts; its statements are those of the group.
    nl: ir.Netlist,
    keep: ir.Keep,
    /// Every statement comes in one group: the passes that need them all
    /// have them.
    whole: bool,
    foreign: bool,
    case: bool = false,
    seen: name_passes.CaseMaps = .{},
    params: ir.CaselessSet = .empty,
    renames: CaselessMap = .empty,
    told: ir.CaselessSet = .empty,
    /// `names.reservedRenames`, and those of them reported.
    param_renames: CaselessMap = .empty,
    param_told: ir.CaselessSet = .empty,
    models: ir.CaselessSet = .empty,
    subckts: ir.CaselessSet = .empty,
    clashed: ir.CaselessSet = .empty,
    /// The analyses the survey counted, until `names` has checked them.
    counted: ?[]const Analysis = null,
    topo: ?topology.Stream = null,
    fill_from: []const ir.Stmt = &.{},
    source: ?*const Grammar = null,
    analyses: usize = 0,
    /// The statements a control block of the target holds: written last.
    wrapped: std.ArrayList(ir.Stmt) = .empty,
    refs: Refs = .{},
    lower: ?stats.Stream = null,
    /// How many `dev/gauss=` are random functions now (`stats.asFunctions`).
    functions: usize = 0,

    /// Everything before the first statement: the title, the header, the
    /// boilerplate, and for a netlist written in groups the options the
    /// source's dialect assumes. In place: the writer points into it.
    pub fn begin(s: *Driver, to: Target, k: ir.Keep, sv: *Survey, mode: Mode) Writer.Error!void {
        // In groups, what is kept outlives the statements only in the source.
        assert(mode == .whole or k.src != null);
        const g = to.g;
        const perm = k.perm;
        s.* = .{
            .w = .{
                .g = g,
                .arena = perm,
                .perm = perm,
                .out = to.out,
                .report = to.report,
                .caps = to.caps,
                .source = sv.dialect,
                .scratch = .init(ir.big),
                .env = to.env,
                .declared = sv.declared,
                .families = sv.families,
                .modules = sv.modules,
                .funcs = sv.funcs,
                .clash_keys = sv.clash_keys,
                .terminals = sv.terminals,
            },
            .nl = switch (mode) {
                .whole => |nl| nl.*,
                .groups => .{
                    .title = sv.title,
                    .dialect = sv.dialect,
                    .library = sv.library,
                    .folds_case = sv.folds_case,
                },
            },
            .keep = k,
            .whole = mode == .whole,
            .foreign = !std.mem.eql(u8, sv.dialect, g.name),
            .counted = sv.counted.items,
        };
        errdefer s.deinit();
        const w = &s.w;
        if (to.env) |e| {
            var it = e.declared.keyIterator();
            while (it.next()) |n|
                try w.declared.put(perm, try std.ascii.allocLowerString(perm, n.*), {});
            var fi = e.funcs.keyIterator();
            while (fi.next()) |n| try w.funcs.put(perm, n.*, {});
        }
        if (to.caps) |c| for (c.grammars) |*sg| {
            if (std.mem.eql(u8, sg.name, sv.dialect)) s.source = sg;
        };
        const folded = frame.foldsHeader(g, sv.dialect, sv.folds_case);
        s.case = (!g.lex.case_sensitive or folded) and sv.check_case;
        if (!s.whole) try s.beginGroups(sv);
        try frame.open(w, &frameFacts(sv, to.env));
        if (s.foreign) to.report.phase = ir.Phase.params;
        if (s.foreign) try s.beginRenames(sv);
        if (s.foreign and !s.whole) s.topo = try topology.Stream.init(ir.big, perm, g, to.report, .{
            .src = k.src.?,
            .library = sv.library,
            .facts = sv.facts,
            .globals = sv.globals.items,
            .early = sv.early.items,
        });
        if (!s.whole) try s.assumedFirst(sv);
    }

    /// The next top-level statements, read and resolved; made in `arena`,
    /// which may be freed once this returns. The passes, in order.
    pub fn group(s: *Driver, arena: Allocator, stmts_in: []ir.Stmt) Writer.Error!void {
        const w = &s.w;
        const g = w.g;
        const report = w.report;
        // Between two groups the writer allocates where what it keeps lives.
        assert(w.arena.ptr == s.keep.perm.ptr);
        w.arena = arena;
        defer w.arena = s.keep.perm;
        if (!s.whole) {
            try s.noteForeign(stmts_in);
            try s.refs.add(s.keep, stmts_in);
        }
        const named = try s.names(stmts_in);
        report.phase = ir.Phase.topology;
        try s.checkTopology(named);
        report.phase = ir.Phase.fill;
        const filled = try defaults.fill(w, named, if (s.whole) named else s.fill_from);
        if (s.foreign) {
            report.phase = ir.Phase.checks;
            try defaults.check(w, g, filled, s.source);
            report.phase = ir.Phase.checks_source;
            if (s.source) |sg| try defaults.check(w, sg, filled, null);
        }
        try s.tail(if (s.whole) try s.netlistPasses(named, filled) else filled);
    }

    /// Everything after the last statement. `rescan` gives the topology
    /// check every group again when the top level has islands:
    /// `rescan.run(topology.Stream.cross, *topology.Stream)`.
    pub fn end(s: *Driver, rescan: anytype) Writer.Error!void {
        const w = &s.w;
        const report = w.report;
        report.phase = ir.Phase.stats;
        stats.asFunctions(w.g, s.functions, report);
        if (s.lower) |*l| try s.last(try l.end(w.arena));
        report.phase = ir.Phase.write;
        try frame.wrapped(w, s.wrapped.items, s.analyses);
        report.phase = ir.Phase.caveat;
        try frame.close(w, s.nl.library);
        if (s.topo) |*t| {
            report.phase = ir.Phase.topology;
            if (try t.islands()) try rescan.run(topology.Stream.cross, t);
            try t.end();
        }
        s.refs.settle(report);
    }

    /// The tables outside the arena: after `end`, or an error after `begin`
    /// (which frees them itself when it fails).
    pub fn deinit(s: *Driver) void {
        if (s.topo) |*t| t.deinit();
        s.params.deinit(ir.big);
        s.seen.deinit();
        s.w.instances.deinit(ir.big);
        s.w.scratch.deinit();
    }

    // ---- private ----

    /// What a netlist written in groups needs before its first: the
    /// references a device may still answer, the values statements are
    /// filled from, the statistics lowered a group at a time, and the
    /// subcircuits of the environment written once for each branch (the
    /// netlist's own make it be written whole).
    fn beginGroups(s: *Driver, sv: *Survey) Allocator.Error!void {
        assert(!s.whole);
        const w = &s.w;
        const g = w.g;
        s.refs = sv.refs;
        w.refs = &s.refs;
        s.fill_from = sv.fill_from.items;
        s.analyses = sv.analyses;
        s.lower = stats.Stream.init(s.keep, g, w.report);
        if (w.env) |e|
            if (!g.canWrite(.cond_if)) try variants.noteAllSplits(w, e.conditional.items, null);
    }

    /// The names a foreign netlist is written under: a model named as a
    /// subcircuit is, and a parameter named as something the target
    /// reserves, get another (`names.renamesOf`, `names.reservedRenames`).
    fn beginRenames(s: *Driver, sv: *Survey) Allocator.Error!void {
        assert(s.foreign);
        const w = &s.w;
        const g = w.g;
        const perm = s.keep.perm;
        s.param_renames = try name_passes.reservedRenames(perm, g, &sv.reserved, w.env);
        if (g.unique_master.len == 0) return;
        s.renames = try name_passes.renamesOf(perm, &sv.models, &sv.subckts, w.env);
        // A renamed model is declared under the name it is written as.
        var ri = s.renames.valueIterator();
        while (ri.next()) |v|
            try w.declared.put(perm, try std.ascii.allocLowerString(perm, v.*), {});
        // The models and subcircuits there are after the renames.
        var it = sv.models.keyIterator();
        while (it.next()) |m| try s.models.put(perm, s.renames.get(m.*) orelse m.*, {});
        try s.subckts.ensureUnusedCapacity(perm, sv.subckts.count());
        var si = sv.subckts.keyIterator();
        while (si.next()) |n| try s.subckts.put(perm, n.*, {});
        const e = w.env orelse return;
        var mi = e.models.keyIterator();
        while (mi.next()) |m| try s.models.put(perm, ir.binBase(m.*) orelse m.*, {});
        var ei = e.subckts.keyIterator();
        while (ei.next()) |n| try s.subckts.put(perm, n.*, {});
    }

    /// The options the source assumes, written before the first group. A
    /// netlist written whole lays them out with its alters
    /// (`netlistPasses`).
    fn assumedFirst(s: *Driver, sv: *Survey) Writer.Error!void {
        assert(!s.whole);
        var opts = s.nl;
        opts.stmts = sv.options;
        s.w.report.phase = ir.Phase.options;
        const d = try frame.assumedOptions(&s.w, &opts) orelse return;
        try s.tail(try s.keep.perm.dupe(ir.Stmt, &.{d}));
    }

    /// The first instance that gives parameters to a subcircuit of another
    /// file, for `notes.foreignNote`.
    fn noteForeign(s: *Driver, stmts: []const ir.Stmt) Allocator.Error!void {
        const w = &s.w;
        if (!s.foreign or w.foreign_inst != null or w.g.canWrite(.cond_if) or w.env != null)
            return;
        const x = try variants.foreignInstance(w, stmts) orelse return;
        w.foreign_inst = .{
            .line = x.line,
            .name = try s.keep.text(x.get("name").atom),
            .master = try s.keep.text(x.get("master").atom),
        };
    }

    /// The names the target would refuse or read as others: two that differ
    /// only by case, more analyses than it runs, a parameter defined twice,
    /// a model and a subcircuit of one name, a parameter named as something
    /// it reserves. The statements with the renames made.
    fn names(s: *Driver, stmts_in: []ir.Stmt) Writer.Error![]ir.Stmt {
        const w = &s.w;
        const g = w.g;
        const report = w.report;
        // Only a netlist of another dialect is renamed.
        assert(s.foreign or s.renames.count() + s.param_renames.count() == 0);
        var stmts = stmts_in;
        report.phase = ir.Phase.case;
        if (s.case) try name_passes.checkCase(stmts, &s.seen, report, g.name, s.keep);
        if (!s.foreign) return stmts;
        report.phase = ir.Phase.params;
        if (s.counted) |found| {
            try name_passes.uniqueAnalyses(s.keep.perm, g, found, report);
            s.counted = null;
        }
        if (g.unique_param.len > 0)
            try name_passes.uniqueParamsIn(stmts, &s.params, s.keep, report, g);
        if (g.unique_master.len > 0) {
            report.phase = ir.Phase.renames;
            if (s.renames.count() > 0)
                stmts = try name_passes.renameMasters(w.pass(), stmts, &s.renames, &s.told);
            report.phase = ir.Phase.masters;
            const perm = s.keep.perm;
            const p: name_passes.Pass = .{ .arena = perm, .perm = perm, .g = g, .report = report };
            try name_passes.clashes(p, stmts, &s.models, &s.subckts, &s.clashed);
        }
        if (s.param_renames.count() > 0)
            stmts = try name_passes.renameParams(w.pass(), stmts, &s.param_renames, &s.param_told);
        return stmts;
    }

    /// What the target requires of the circuit itself (`requires`): all at
    /// once, or with the summaries the survey kept.
    fn checkTopology(s: *Driver, stmts: []ir.Stmt) Allocator.Error!void {
        const w = &s.w;
        if (!s.whole) {
            if (s.topo) |*t| try t.group(stmts);
            return;
        }
        var nl = s.nl;
        nl.stmts = stmts;
        if (analysis_passes.sameDialect(&nl, w.g)) return;
        try topology.check(ir.big, w.arena, &nl, w.g, w.report);
    }

    /// The passes that need every statement at once, in the order they
    /// run: sweeps gathered around their analyses, the options the source
    /// assumes, alters laid out as runs, a maximum order the target has no
    /// place for, values the target says on another statement. What is
    /// work for one of them is said by `needsAll`, or by the survey of
    /// `stream.zig` where it takes more than one statement to tell.
    /// `named`: the statements before `fill`, where the options given are
    /// read.
    fn netlistPasses(
        s: *Driver,
        named: []ir.Stmt,
        filled: []ir.Stmt,
    ) Writer.Error![]const ir.Stmt {
        assert(s.whole);
        const w = &s.w;
        const g = w.g;
        const a = w.arena;
        var stmts: []const ir.Stmt = try ir.gatherSteps(a, filled);
        if (g.canWrite(.step)) spread.checkSteps(w, stmts);
        // Before the alters are laid out, so a run that changes no
        // temperature is at the source's.
        var nl = s.nl;
        nl.stmts = named;
        if (try frame.assumedOptions(w, &nl)) |d| {
            const list = try a.alloc(ir.Stmt, stmts.len + 1);
            list[0] = d;
            @memcpy(list[1..], stmts);
            stmts = list;
        }
        stmts = try alter.prepare(a, g, stmts, w.report);
        stmts = try analysis_passes.foldMaxord(a, g, stmts, w.report);
        return defaults.applyMoves(w, stmts);
    }

    /// The passes after the options are laid out, and the writing itself.
    fn tail(s: *Driver, in: []const ir.Stmt) Writer.Error!void {
        const w = &s.w;
        const g = w.g;
        const a = w.arena;
        var stmts = in;
        if (g.converts.len > 0 and analysis_passes.anyConverted(g, stmts)) {
            const list = try a.dupe(ir.Stmt, stmts);
            try expr.convert(a, g, list, true);
            stmts = list;
        }
        if (g.blockOf(.model) != null) stmts = try bins.groupBins(a, stmts);
        stmts = try s.statistics(stmts);
        if (s.whole) stmts = try analysis_passes.pzPorts(a, g, w.origin(), stmts, w.report);
        try s.last(stmts);
    }

    /// Statistics as the target says them. All at once, a statistics block
    /// may be folded into the parameters it varies (`stats.prepare`); a
    /// netlist with one is written whole.
    fn statistics(s: *Driver, in: []const ir.Stmt) Allocator.Error![]const ir.Stmt {
        const w = &s.w;
        const g = w.g;
        const a = w.arena;
        if (s.whole) return stats.prepare(a, g, s.nl.dialect, in, w.report);
        var stmts = in;
        w.report.phase = ir.Phase.devlot;
        if (stats.devLots(g, s.nl.dialect) and stats.usesDevLot(stmts))
            stmts = try stats.devLot(a, stmts, w.report, &s.functions);
        w.report.phase = ir.Phase.stats;
        stats.checkReserved(g, stmts, w.report);
        if (s.lower) |*l| stmts = try l.group(a, stmts);
        return stmts;
    }

    /// The last pass and the writing itself.
    fn last(s: *Driver, in: []const ir.Stmt) Writer.Error!void {
        const w = &s.w;
        const g = w.g;
        // All at once, statistics are lowered at once (`statistics`).
        assert(!s.whole or s.lower == null);
        w.report.phase = ir.Phase.ceilings;
        const stmts = try analysis_passes.idleCeilings(w.arena, in, w.report);
        if (s.whole) {
            // What a netlist in groups takes from its survey and its
            // first statements, this one has here, as it is written.
            s.analyses = countRuns(stmts);
            try s.noteForeign(stmts);
            if (!g.canWrite(.cond_if)) try variants.noteAllSplits(w, stmts, w.env);
        }
        w.report.phase = ir.Phase.write;
        for (stmts) |*st| {
            if (g.wrapOf(st.kind) != null) {
                try s.wrapped.append(s.keep.perm, try ir.cloneStmt(s.keep, st));
                continue;
            }
            frame.markSole(w, st, s.analyses);
            try blocks.stmt(w, st);
        }
    }
};

/// A netlist written whole has its topology checked at once: no group of
/// it is read again.
const NoRescan = struct {
    fn run(_: NoRescan, comptime _: anytype, _: anytype) Writer.Error!void {
        unreachable;
    }
};

const no_rescan: NoRescan = .{};

/// What `st`, a top-level statement, holds that a pass needing every
/// statement at once works on (`Driver.netlistPasses`, `Driver.tail`): a
/// netlist with one is written whole. Null where it holds none. A pass
/// added there says here what its work is.
pub fn needsAll(g: *const Grammar, st: *const ir.Stmt) ?[]const u8 {
    return switch (st.kind) {
        // `alter.prepare`.
        .alter => "an alter",
        // `ir.gatherSteps`: it is around every analysis.
        .montecarlo => if (st.body.len == 0)
            "a Monte Carlo analysis of the whole netlist"
        else
            null,
        // `analyses.pzPorts`.
        .pz => "a pole-zero analysis",
        // `analyses.foldMaxord`.
        .options => if (st.get("maxord") != .none) "a maximum order of integration" else null,
        // `bins.groupBins`: the bins of one model come a group each.
        .model => if (g.blockOf(.model) != null and st.get("name") == .atom and
            ir.binBase(st.get("name").atom) != null) "a binned model" else null,
        else => null,
    };
}

/// Write `nl`, a netlist held in memory, to `to`: every statement in one
/// group, so the passes that need them all run. `to.env`: the environment
/// of the project the netlist is a file of, else the netlist's own.
pub fn write(to_in: Target, arena: Allocator, nl: *const ir.Netlist) Writer.Error!void {
    var to = to_in;
    to.env = to_in.env orelse nl.env;
    // The statements outlive the writing: no name of theirs is copied.
    const keep: ir.Keep = .{ .perm = arena, .src = null };
    var sv: Survey = .{
        .title = nl.title,
        .dialect = nl.dialect,
        .library = nl.library,
        .folds_case = nl.folds_case,
    };
    try sv.add(to.g, keep, nl.stmts);
    var d: Driver = undefined;
    try d.begin(to, keep, &sv, .{ .whole = nl });
    defer d.deinit();
    // Its topology is checked at once: `no_rescan` is never run.
    assert(d.topo == null);
    try name_passes.collectInstances(nl.stmts, &d.w.instances);
    try d.group(arena, nl.stmts);
    try d.end(no_rescan);
    if (to.report.lost) return error.OutOfMemory;
}

// ---- private ----

/// The kinds and the model families in use: the netlist's and its
/// environment's.
fn frameFacts(sv: *const Survey, env: ?*const ir.Env) frame.Facts {
    var facts: frame.Facts = .{
        .title = sv.title,
        .dialect = sv.dialect,
        .library = sv.library,
        .folds_case = sv.folds_case,
        .used = if (env) |e| e.used else @splat(false),
        .families = if (env) |e| e.families else @splat(false),
    };
    for (&facts.used, sv.used) |*u, x| u.* = u.* or x;
    for (&facts.families, sv.fams) |*f, x| f.* = f.* or x;
    return facts;
}

/// How many of `stmts` are analyses the simulator runs.
fn countRuns(stmts: []const ir.Stmt) usize {
    var n: usize = 0;
    for (stmts) |*st| n += @intFromBool(schema.runs(st.kind));
    return n;
}
