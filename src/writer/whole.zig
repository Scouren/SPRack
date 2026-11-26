//! Whole-netlist driver: every statement of a netlist read into memory → the
//! target's text, the passes run over all of it in order before the first
//! statement is written.

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
const pzPorts = analysis_passes.pzPorts;
const foldMaxord = analysis_passes.foldMaxord;
const idleCeilings = analysis_passes.idleCeilings;
pub const defaultOptions = analysis_passes.defaultOptions;
const reportDefaults = analysis_passes.reportDefaults;
const sameDialect = analysis_passes.sameDialect;
const anyConverted = analysis_passes.anyConverted;
const uniqueParams = name_passes.uniqueParams;
const Analysis = name_passes.Analysis;
const collectAnalyses = name_passes.collectAnalyses;
const uniqueAnalyses = name_passes.uniqueAnalyses;
pub const collectReserved = name_passes.collectReserved;
const reservedRenames = name_passes.reservedRenames;
const renameParams = name_passes.renameParams;
pub const masterRenames = name_passes.masterRenames;
const renameMasters = name_passes.renameMasters;
const uniqueMasters = name_passes.uniqueMasters;
const collectDeclared = name_passes.collectDeclared;
const CaseMaps = name_passes.CaseMaps;
const checkCase = name_passes.checkCase;
const collectInstances = name_passes.collectInstances;
const collectFuncs = name_passes.collectFuncs;

const emit = @import("emit.zig");
const statement = @import("statement.zig");
const Writer = statement.Writer;
const analysis_passes = @import("analyses.zig");
const name_passes = @import("names.zig");
const rewrite = @import("rewrite.zig");
const frame = @import("frame.zig");
pub const Caps = emit.Caps;

const groupBins = statement.groupBins;
const markUsed = statement.markUsed;
const collectTerminals = statement.collectTerminals;
const needLine = statement.needLine;
const collectModules = statement.collectModules;

pub fn write(
    g: *const Grammar,
    arena: Allocator,
    out: *std.Io.Writer,
    nl_in: *const ir.Netlist,
    report: *ir.Report,
    caps: ?*const Caps,
    project_env: ?*const ir.Env,
) (Allocator.Error || std.Io.Writer.Error)!void {
    const env = project_env orelse nl_in.env;
    var w: Writer = .{
        .g = g,
        .arena = arena,
        .perm = arena,
        .out = out,
        .report = report,
        .caps = caps,
        .source = nl_in.dialect,
        .scratch = .init(ir.big),
    };
    defer w.scratch.deinit();
    var nl_own = nl_in.*;
    const nl = &nl_own;

    try collectDeclared(arena, nl.stmts, &w.declared);
    try ir.collectFamilies(arena, nl.stmts, &w.families, null);
    try collectModules(arena, nl.stmts, &w.modules);
    w.env = env;
    try collectFuncs(arena, nl.stmts, &w.funcs);
    defer w.instances.deinit(ir.big);
    try collectInstances(nl.stmts, &w.instances);
    try rewrite.collectClashKeys(arena, g, nl.stmts, &w.clash_keys, null);
    try collectTerminals(arena, nl.stmts, &w.terminals, null);
    if (env) |e| {
        var it = e.declared.keyIterator();
        while (it.next()) |k|
            try w.declared.put(arena, try std.ascii.allocLowerString(arena, k.*), {});
        var fi = e.funcs.keyIterator();
        while (fi.next()) |k| try w.funcs.put(arena, k.*, {});
    }
    if (!g.lex.case_sensitive or frame.foldsHeader(g, nl.dialect, nl.folds_case)) {
        var seen: CaseMaps = .{};
        defer seen.deinit();
        try checkCase(nl.stmts, &seen, report, g.name, null);
    }
    var facts: frame.Facts = .{
        .title = nl.title,
        .dialect = nl.dialect,
        .library = nl.library,
        .folds_case = nl.folds_case,
        .used = if (env) |e| e.used else @splat(false),
        .families = if (env) |e| e.families else @splat(false),
    };
    if (!nl.library) {
        markUsed(nl.stmts, &facts.used);
        rewrite.markUsed(g, nl.dialect, nl.stmts, &facts.used);
        ir.markFamilies(nl.stmts, &facts.families);
    }
    try frame.open(&w, &facts);
    if (!std.mem.eql(u8, nl.dialect, g.name)) {
        var found: std.ArrayList(Analysis) = .empty;
        try collectAnalyses(arena, g, nl.stmts, &found);
        try uniqueAnalyses(arena, g, found.items, report);
        if (g.unique_param.len > 0) try uniqueParams(nl.stmts, report, g);
        if (g.unique_master.len > 0) {
            var renames = try masterRenames(arena, nl.stmts, env);
            // A renamed model is declared under the name it is written as.
            var ri = renames.valueIterator();
            while (ri.next()) |v|
                try w.declared.put(arena, try std.ascii.allocLowerString(arena, v.*), {});
            if (renames.count() > 0) {
                var told: ir.CaselessSet = .empty;
                nl_own.stmts = try renameMasters(w.pass(), nl.stmts, &renames, &told);
            }
            try uniqueMasters(arena, nl.stmts, env, report, g);
        }
        if (g.reserved.len > 0) {
            var defined: ir.CaselessSet = .empty;
            try collectReserved(arena, g, nl.stmts, &defined, null);
            const renames = try reservedRenames(arena, g, &defined, env);
            if (renames.count() > 0) {
                var told: ir.CaselessSet = .empty;
                nl_own.stmts = try renameParams(w.pass(), nl.stmts, &renames, &told);
            }
        }
    }
    if (!sameDialect(nl, g)) try topology.check(ir.big, arena, nl, g, report);
    const filled = try w.fill(nl.stmts, nl.stmts);
    if (!std.mem.eql(u8, nl.dialect, g.name)) {
        var source: ?*const Grammar = null;
        if (caps) |c| for (c.grammars) |*sg| {
            if (std.mem.eql(u8, sg.name, nl.dialect)) source = sg;
        };
        try w.check(g, filled, source);
        if (source) |sg| try w.check(sg, filled, null);
    }
    var gathered = try ir.gatherSteps(arena, filled);
    if (g.canWrite(.step)) w.checkSteps(gathered);
    // Before the alters are laid out, so a run that changes no temperature
    // is at the source's.
    if (try frame.assumedOptions(&w, nl)) |d| {
        const list = try arena.alloc(ir.Stmt, gathered.len + 1);
        list[0] = d;
        @memcpy(list[1..], gathered);
        gathered = list;
    }
    var stmts = try w.applyMoves(
        try foldMaxord(arena, g, try alter.prepare(arena, g, gathered, report), report),
    );
    if (g.converts.len > 0 and anyConverted(g, stmts)) {
        const list = try arena.dupe(ir.Stmt, stmts);
        try expr.convert(arena, g, list, true);
        stmts = list;
    }
    if (g.blockOf(.model) != null) stmts = try groupBins(arena, stmts);
    stmts = try stats.prepare(arena, g, nl.dialect, stmts, report);
    stmts = try pzPorts(arena, g, w.origin(), stmts, report);
    stmts = try idleCeilings(arena, stmts, report);
    var analyses: usize = 0;
    for (stmts) |*s| analyses += @intFromBool(schema.runs(s.kind));
    if (!g.canWrite(.cond_if) and env == null and !std.mem.eql(u8, nl.dialect, g.name)) {
        if (try w.foreignInstance(stmts)) |x|
            w.foreign_inst = .{
                .line = x.line,
                .name = x.get("name").atom,
                .master = x.get("master").atom,
            };
    }
    if (!g.canWrite(.cond_if)) {
        // ponytail: each file of a project works the environment's out again; once a project if a PDK has thousands.
        try w.noteAllSplits(stmts, env);
    }
    for (stmts) |*s| {
        if (g.wrapOf(s.kind) != null) continue;
        frame.markSole(&w, s, analyses);
        try w.stmt(s);
    }
    try frame.wrapped(&w, stmts, analyses);
    try frame.close(&w, nl.library);
    if (report.lost) return error.OutOfMemory;
}
