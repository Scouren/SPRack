//! Streaming driver: a netlist a group of statements at a time → the target's
//! text, after a survey of the whole of it. `Survey` gathers, on a first
//! pass, what the passes need of the statements they are not looking at;
//! `Stream` then runs the passes over each group and writes it.

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const dialects = @import("dialects");
const expr = @import("expr");
const stats = @import("stats");
const alter = @import("alter");
const topology = @import("topology");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Kind = schema.Kind;
const idleCeilings = analysis_passes.idleCeilings;
pub const defaultOptions = analysis_passes.defaultOptions;
const reportDefaults = analysis_passes.reportDefaults;
const anyConverted = analysis_passes.anyConverted;
const uniqueParamsIn = name_passes.uniqueParamsIn;
const Analysis = name_passes.Analysis;
const collectAnalyses = name_passes.collectAnalyses;
const uniqueAnalyses = name_passes.uniqueAnalyses;
pub const collectReserved = name_passes.collectReserved;
const reservedRenames = name_passes.reservedRenames;
const renameParams = name_passes.renameParams;
const CaselessMap = name_passes.CaselessMap;
pub const masterRenames = name_passes.masterRenames;
const renamesOf = name_passes.renamesOf;
const collectMasters = name_passes.collectMasters;
const renameMasters = name_passes.renameMasters;
const clashes = name_passes.clashes;
const collectDeclared = name_passes.collectDeclared;
const CaseMaps = name_passes.CaseMaps;
const checkCase = name_passes.checkCase;
const collectFuncs = name_passes.collectFuncs;

const emit = @import("emit.zig");
const statement = @import("statement.zig");
const Refs = @import("refs.zig").Refs;
const TerminalMap = statement.TerminalMap;
const Writer = statement.Writer;
const analysis_passes = @import("analyses.zig");
const name_passes = @import("names.zig");
const rewrite = @import("rewrite.zig");
const frame = @import("frame.zig");
pub const Caps = emit.Caps;

const firstValue = statement.firstValue;
const binBase = statement.binBase;
const groupBins = statement.groupBins;
const markUsed = statement.markUsed;
const collectTerminals = statement.collectTerminals;
const needLine = statement.needLine;
const collectModules = statement.collectModules;

/// What writing needs to know of the whole netlist before its first
/// statement, when the statements come one at a time (`stream.zig`
/// gathers it in a pass of its own). Names are in `perm` or the source.
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
    /// `collectAnalyses`.
    counted: std.ArrayList(Analysis) = .empty,
    /// Two names differing only by case may be in it: the check runs.
    check_case: bool = true,
    facts: topology.Facts = .{},
    globals: std.ArrayList([]const u8) = .empty,
    refs: Refs = .{},
    /// `collectReserved`.
    reserved: ir.CaselessSet = .empty,
    /// `collectClashKeys`.
    clash_keys: ir.CaselessSet = .empty,
    /// `collectTerminals`.
    terminals: TerminalMap = .empty,

    /// Learn what `stmts`, the next top-level statements, hold.
    /// Keeps the value of `slot` on the netlist's first statement of `kind`
    /// that has one, for `fill`.
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
        const v = firstValue(stmts, kind, slot) orelse return;
        var st = try ir.newStmt(k.perm, kind, 0);
        try st.set(k.perm, slot, try ir.cloneValue(k, v));
        try sv.fill_from.append(k.perm, st);
    }

    /// `gf`: the grammar the netlist is read with.
    pub fn add(
        sv: *Survey,
        g: *const Grammar,
        gf: *const Grammar,
        k: ir.Keep,
        stmts: []const ir.Stmt,
    ) Allocator.Error!void {
        const a = k.perm;
        try collectDeclared(a, stmts, &sv.declared);
        try ir.collectFamilies(a, stmts, &sv.families, k.src);
        try collectModules(a, stmts, &sv.modules);
        try collectFuncs(a, stmts, &sv.funcs);
        markUsed(stmts, &sv.used);
        rewrite.markUsed(g, sv.dialect, stmts, &sv.used);
        try rewrite.collectClashKeys(a, g, stmts, &sv.clash_keys, k.src);
        ir.markFamilies(stmts, &sv.fams);
        try collectMasters(a, stmts, &sv.models, &sv.subckts, k.src);
        try collectTerminals(a, stmts, &sv.terminals, k.src);
        try collectReserved(a, g, stmts, &sv.reserved, k.src);
        for (g.fills) |f| try sv.takeFirst(k, stmts, f.from, f.from_slot);
        for (gf.omitted) |o| for (o.terms) |t| {
            if (t == .first) try sv.takeFirst(k, stmts, t.first.kind, t.first.slot);
        };
        for (stmts) |*s| {
            sv.analyses += @intFromBool(schema.runs(s.kind));
        }
        try collectAnalyses(a, g, stmts, &sv.counted);
        sv.facts.add(stmts);
        try sv.addGlobals(k, stmts);
        try sv.refs.want(k, stmts);
    }

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

/// A netlist written as it is read: `group` is given the top-level
/// statements a few at a time, as the reader makes them, and each pass of
/// `write` runs on them before the next come. What the passes need of the
/// whole netlist is in the `Survey`; constructs whose passes need the
/// statements themselves are written whole instead (`stream.zig` says
/// which). Report entries come in pass order once `stream.zig` sorts them.
pub const Stream = struct {
    w: Writer,
    nl: ir.Netlist,
    keep: ir.Keep,
    foreign: bool,
    case: bool = false,
    seen: CaseMaps = .{},
    params: ir.CaselessSet = .empty,
    renames: CaselessMap = .empty,
    told: ir.CaselessSet = .empty,
    /// `reservedRenames`, and those of them reported.
    param_renames: CaselessMap = .empty,
    param_told: ir.CaselessSet = .empty,
    models: ir.CaselessSet = .empty,
    subckts: ir.CaselessSet = .empty,
    clashed: ir.CaselessSet = .empty,
    topo: ?topology.Stream = null,
    fill_from: []const ir.Stmt = &.{},
    source: ?*const Grammar = null,
    analyses: usize = 0,
    wrapped: std.ArrayList(ir.Stmt) = .empty,
    refs: Refs = .{},
    lower: ?stats.Stream = null,
    /// How many `dev/gauss=` are random functions now (`stats.asFunctions`).
    functions: usize = 0,

    /// Everything before the first statement: title, header, boilerplate
    /// and the options the source's dialect assumes. In place: the writer
    /// points into it.
    pub fn begin(
        s: *Stream,
        g: *const Grammar,
        k: ir.Keep,
        out: *std.Io.Writer,
        sv: *Survey,
        report: *ir.Report,
        caps: ?*const Caps,
        env: ?*const ir.Env,
    ) Writer.Error!void {
        const perm = k.perm;
        s.* = .{
            .w = .{
                .g = g,
                .arena = perm,
                .perm = perm,
                .out = out,
                .report = report,
                .caps = caps,
                .source = sv.dialect,
                .scratch = .init(ir.big),
            },
            .nl = .{
                .title = sv.title,
                .dialect = sv.dialect,
                .library = sv.library,
                .folds_case = sv.folds_case,
            },
            .keep = k,
            .foreign = !std.mem.eql(u8, sv.dialect, g.name),
            .fill_from = sv.fill_from.items,
            .analyses = sv.analyses,
            .refs = sv.refs,
            .lower = stats.Stream.init(k, g, report),
        };
        errdefer s.deinit();
        const w = &s.w;
        w.refs = &s.refs;
        const nl = &s.nl;
        w.declared = sv.declared;
        w.families = sv.families;
        w.modules = sv.modules;
        w.env = env;
        w.funcs = sv.funcs;
        w.clash_keys = sv.clash_keys;
        w.terminals = sv.terminals;
        if (env) |e| {
            var it = e.declared.keyIterator();
            while (it.next()) |n|
                try w.declared.put(perm, try std.ascii.allocLowerString(perm, n.*), {});
            var fi = e.funcs.keyIterator();
            while (fi.next()) |n| try w.funcs.put(perm, n.*, {});
        }
        // The netlist's own make it be written whole (`stream.zig`).
        if (env) |e| if (!g.canWrite(.cond_if)) try w.noteAllSplits(e.conditional.items, null);
        const fold_header = frame.foldsHeader(g, nl.dialect, nl.folds_case);
        s.case = (!g.lex.case_sensitive or fold_header) and sv.check_case;
        var facts: frame.Facts = .{
            .title = nl.title,
            .dialect = nl.dialect,
            .library = nl.library,
            .folds_case = nl.folds_case,
            .used = if (env) |e| e.used else @splat(false),
            .families = if (env) |e| e.families else @splat(false),
        };
        for (&facts.used, sv.used) |*u, x| u.* = u.* or x;
        for (&facts.families, sv.fams) |*f, x| f.* = f.* or x;
        try frame.open(w, &facts);
        if (s.foreign and g.unique_master.len > 0) {
            s.renames = try renamesOf(perm, &sv.models, &sv.subckts, env);
            // A renamed model is declared under the name it is written as.
            var ri = s.renames.valueIterator();
            while (ri.next()) |v|
                try w.declared.put(perm, try std.ascii.allocLowerString(perm, v.*), {});
            // What `uniqueMasters` finds after the renames.
            var it = sv.models.keyIterator();
            while (it.next()) |m| try s.models.put(perm, s.renames.get(m.*) orelse m.*, {});
            try s.subckts.ensureUnusedCapacity(perm, sv.subckts.count());
            var si = sv.subckts.keyIterator();
            while (si.next()) |n| try s.subckts.put(perm, n.*, {});
            if (env) |e| {
                var mi = e.models.keyIterator();
                while (mi.next()) |m| try s.models.put(perm, ir.binBase(m.*) orelse m.*, {});
                var ei = e.subckts.keyIterator();
                while (ei.next()) |n| try s.subckts.put(perm, n.*, {});
            }
        }
        if (s.foreign) {
            report.phase = ir.Phase.params;
            try uniqueAnalyses(perm, g, sv.counted.items, report);
            s.param_renames = try reservedRenames(perm, g, &sv.reserved, env);
        }
        if (!std.mem.eql(u8, nl.dialect, g.name))
            s.topo = try topology.Stream.init(
                ir.big,
                perm,
                g,
                report,
                k.src,
                nl.library,
                sv.facts,
                sv.globals.items,
                sv.early.items,
            );
        if (caps) |c| for (c.grammars) |*sg| {
            if (std.mem.eql(u8, sg.name, nl.dialect)) s.source = sg;
        };
        var opts = nl.*;
        opts.stmts = sv.options;
        report.phase = ir.Phase.options;
        if (try frame.assumedOptions(w, &opts)) |d| try s.tail(try perm.dupe(ir.Stmt, &.{d}));
    }

    /// The next top-level statements, read and resolved; made in `arena`,
    /// which may be freed once this returns.
    pub fn group(s: *Stream, arena: Allocator, stmts_in: []ir.Stmt) Writer.Error!void {
        const w = &s.w;
        const g = w.g;
        const report = w.report;
        w.arena = arena;
        defer w.arena = s.keep.perm;
        var stmts = stmts_in;
        if (s.foreign and w.foreign_inst == null and !g.canWrite(.cond_if) and w.env == null) {
            if (try w.foreignInstance(stmts)) |x|
                w.foreign_inst = .{
                    .line = x.line,
                    .name = try s.keep.text(x.get("name").atom),
                    .master = try s.keep.text(x.get("master").atom),
                };
        }
        try s.refs.add(s.keep, stmts);
        report.phase = ir.Phase.case;
        if (s.case) try checkCase(stmts, &s.seen, report, g.name, s.keep);
        if (s.foreign) {
            report.phase = ir.Phase.params;
            if (g.unique_param.len > 0) try uniqueParamsIn(stmts, &s.params, s.keep, report, g);
            if (g.unique_master.len > 0) {
                report.phase = ir.Phase.renames;
                if (s.renames.count() > 0) stmts = try renameMasters(w.pass(), stmts, &s.renames, &s.told);
                report.phase = ir.Phase.masters;
                try clashes(s.keep.perm, stmts, &s.models, &s.subckts, &s.clashed, report, g);
            }
            if (s.param_renames.count() > 0)
                stmts = try renameParams(w.pass(), stmts, &s.param_renames, &s.param_told);
        }
        report.phase = ir.Phase.topology;
        if (s.topo) |*t| try t.group(stmts);
        report.phase = ir.Phase.fill;
        const filled = try w.fill(stmts, s.fill_from);
        if (s.foreign) {
            report.phase = ir.Phase.checks;
            try w.check(g, filled, s.source);
            report.phase = ir.Phase.checks_source;
            if (s.source) |sg| try w.check(sg, filled, null);
        }
        try s.tail(filled);
    }

    /// The passes after the options are laid out, and the writing itself.
    fn tail(s: *Stream, in: []const ir.Stmt) Writer.Error!void {
        const w = &s.w;
        const g = w.g;
        const a = w.arena;
        var stmts = in;
        if (g.converts.len > 0 and anyConverted(g, stmts)) {
            const list = try a.dupe(ir.Stmt, stmts);
            try expr.convert(a, g, list, true);
            stmts = list;
        }
        if (g.blockOf(.model) != null) stmts = try groupBins(a, stmts);
        // `stats.prepare`, but for the statistics blocks it folds, and
        // `pzPorts`: what those would change makes the netlist be written
        // whole (`stream.zig`).
        w.report.phase = ir.Phase.devlot;
        if (stats.devLots(g, s.nl.dialect) and stats.usesDevLot(stmts))
            stmts = try stats.devLot(a, stmts, w.report, &s.functions);
        w.report.phase = ir.Phase.stats;
        stats.checkReserved(g, stmts, w.report);
        if (s.lower) |*l| stmts = try l.group(a, stmts);
        try s.last(stmts);
    }

    /// The last pass and the writing itself.
    fn last(s: *Stream, in: []const ir.Stmt) Writer.Error!void {
        const w = &s.w;
        const g = w.g;
        w.report.phase = ir.Phase.ceilings;
        const stmts = try idleCeilings(w.arena, in, w.report);
        w.report.phase = ir.Phase.write;
        for (stmts) |*st| {
            if (g.wrapOf(st.kind) != null) {
                try s.wrapped.append(s.keep.perm, try ir.cloneStmt(s.keep, st));
                continue;
            }
            frame.markSole(w, st, s.analyses);
            try w.stmt(st);
        }
    }

    /// Everything after the last statement. `rescan` gives the topology
    /// check every group again when the top level has islands:
    /// `rescan.run(topology.Stream.cross, *topology.Stream)`.
    pub fn end(s: *Stream, rescan: anytype) Writer.Error!void {
        const w = &s.w;
        const g = w.g;
        const report = w.report;
        report.phase = ir.Phase.stats;
        stats.asFunctions(g, s.functions, report);
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
    pub fn deinit(s: *Stream) void {
        if (s.topo) |*t| t.deinit();
        s.params.deinit(ir.big);
        s.seen.deinit();
        s.w.scratch.deinit();
    }
};
