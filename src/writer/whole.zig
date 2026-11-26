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
    // A case-sensitive target told to fold case (`header folded`) merges
    // names the way a case-insensitive one does.
    const fold_header = g.header_folded.len > 0 and (nl.folds_case or
        if (dialects.find(nl.dialect)) |sg| !sg.lex.case_sensitive else false);
    if (!g.lex.case_sensitive or fold_header) {
        var seen: CaseMaps = .{};
        defer seen.deinit();
        try checkCase(nl.stmts, &seen, report, g.name, null);
    }
    // An included file is not a netlist: it has no title of its own, must
    // not end the simulation, and leaves the boilerplate to the top file.
    if (g.lex.title and !nl.library) {
        try out.print("{s}{s}\n", .{ g.lex.title_prefix, if (nl.title.len > 0)
            nl.title
        else
            "untitled" });
    }
    for (if (fold_header) g.header_folded else g.header) |l| try w.line(l);
    if (!nl.library) {
        var used: [schema.kind_count]bool = if (env) |e| e.used else @splat(false);
        markUsed(nl.stmts, &used);
        rewrite.markUsed(g, nl.dialect, nl.stmts, &used);
        const said = if (g.preamble_unless) |k| used[@backingInt(k)] else false;
        if (!said) for (g.preamble) |l| try w.line(l);
        var fams: [schema.families.len]bool = if (env) |e| e.families else @splat(false);
        ir.markFamilies(nl.stmts, &fams);
        for (g.needs) |n| {
            if (n.family.len > 0) {
                const fi = for (schema.families, 0..) |f, i| {
                    if (std.mem.eql(u8, f.name, n.family)) break i;
                } else unreachable;
                if (!fams[fi]) continue;
            } else if (!used[@backingInt(n.kind)]) continue;
            // A needs line stays whole: ngspice lowercases a continuation
            // line inside .control, and so a path given with --provide (4.43).
            w.nowrap = true;
            for (n.lines) |l| try w.line(try needLine(arena, l, n.family, env));
            w.nowrap = false;
        }
    }
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
    try reportDefaults(arena, g, nl, report);
    // Before the alters are laid out, so a run that changes no temperature
    // is at the source's.
    if (try defaultOptions(arena, g, nl)) |d| {
        var names: std.ArrayList(u8) = .empty;
        for (schema.info(.options).slots, 0..) |sl, i| if (d.at(i) != .none) {
            try names.print(arena, "{s}{s}", .{ if (names.items.len > 0) ", " else "", sl.name });
        };
        report.add(
            .warning,
            .caveat,
            0,
            "options: {s} assumes other defaults for {s} than {s} does; they are written out",
            .{ nl.dialect, names.items, g.name },
        );
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
    var n_analyses: usize = 0;
    for (stmts) |*s| if (schema.info(s.kind).class == .analysis and s.kind != .alter) {
        n_analyses += 1;
        w.sole = s;
    };
    if (n_analyses != 1) w.sole = null;
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
        if (g.wrapOf(s.kind) == null) try w.stmt(s);
    }
    for (g.wraps) |*wr| {
        // A control block runs in order (VACASK), so settings come before
        // every analysis: SPICE applies them wherever they stand.
        var any = false;
        for ([_]bool{ false, true }) |analyses| for (stmts) |*s| {
            if (g.wrapOf(s.kind) != wr or (schema.info(s.kind).class == .analysis) != analyses)
                continue;
            if (!any) try w.line(wr.open);
            any = true;
            try w.stmt(s);
        };
        if (any) try w.line(wr.close);
    }
    if (g.lex.end_marker.len > 0 and !nl.library) try w.line(g.lex.end_marker);
    w.refusals();
    w.keptNote();
    w.foreignNote();
    const cp = w.copied;
    if (cp.n == 1) {
        report.add(.warning, .caveat, cp.line, "model '{s}' ({s}): {s} and {s} ship different " ++
            "implementations and versions of this model; parameters were copied as written, " ++
            "check them against {s}", .{
            cp.name, cp.family, cp.source, g.name, g.name,
        });
    } else if (cp.n > 1) {
        report.add(.warning, .caveat, cp.line, "model '{s}' ({s}) and {d} more model cards: " ++
            "{s} and {s} ship different implementations and versions of these models; " ++
            "parameters were copied as written, check them against {s}", .{
            cp.name, cp.family, cp.n - 1, cp.source, g.name, g.name,
        });
    }
    if (report.lost) return error.OutOfMemory;
}

// ------------------------------------------------------------- streaming
