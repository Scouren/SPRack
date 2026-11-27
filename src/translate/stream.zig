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
//! statements, a move between them, binned models into Spectre,
//! statistics, pole-zero ports, a subcircuit written once for each branch
//! of a conditional block). Where the survey meets one, the netlist
//! is read and written whole instead, as `read` and `write` do; so is a
//! file that switches language.
//!
//! The subcircuits the topology check needs before their definitions come
//! are kept from one more pass, between the survey and the writing.
//!
//! The survey itself is `survey.zig`.
//!
//! Contents:
//! - `pub const Options = struct`
//! - `pub const Hook = struct`
//! - `pub const Error`
//! - `pub fn translate(arena: Allocator, gf: *const Grammar, gt: *const Grammar, src: []const u8,
//!   out: *std.Io.Writer, report: *ir.Report, caps: ?*const writer.Caps,
//!   opts: Options) Error!?[]const u8`
//! - the statements read again for the topology check (`Rescan`, private), with `pub fn run`
//!   for `writer.Driver.end`

const std = @import("std");
const ir = @import("ir");
const grammar = @import("grammar");
const reader = @import("reader");
const writer = @import("writer");
const survey = @import("survey.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Stmt = ir.Stmt;
const Survey = survey.Survey;

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
    run: *const fn (
        ctx: *anyopaque,
        arena: Allocator,
        stmts: []Stmt,
        report: *ir.Report,
    ) Allocator.Error!void,
};

pub const Error = Allocator.Error || std.Io.Writer.Error;

/// The statements again, as the writer is given them: for the topology
/// check, before the writing (`Survey.retain`) and after it, for the
/// islands at the top level.
const Rescan = struct {
    s: *reader.Source,
    scratch: *std.heap.ArenaAllocator,
    sv: *const Survey,
    muted: *ir.Report,
    hook: ?Hook,

    /// `f(ctx, stmts)` for the statements of each group.
    pub fn run(r: Rescan, comptime f: anytype, ctx: anytype) Error!void {
        const s = r.s;
        s.r.report = r.muted;
        s.rewind(r.scratch.allocator(), null);
        // Bound: the statements of the netlist; until `next` finds none.
        while (true) {
            s.between();
            _ = r.scratch.reset(.retain_capacity);
            s.useArena(r.scratch.allocator());
            var list: std.ArrayList(Stmt) = .empty;
            if (!try s.next(&list)) break;
            // `next` gives a statement at least, or says there is none.
            assert(list.items.len > 0);
            try s.finishGroup(&list, r.muted, r.sv.last);
            if (r.hook) |h| try h.run(h.ctx, r.scratch.allocator(), list.items, r.muted);
            try reader.resolveGroup(
                s.r.g,
                r.scratch.allocator(),
                list.items,
                &r.sv.tables,
                r.muted,
            );
            try f(ctx, list.items);
        }
    }
};

/// Read `src` as `gf` and write it as `gt`, as `reader.read` then
/// `writer.write` would. Null when it was streamed, else why it was not.
// tidy: allow(too-many-parameters) the signature `sprack.translate`, the command line and the
// tests call; grouping its arguments is a change to each of them.
pub fn translate(
    arena: Allocator,
    gf: *const Grammar,
    gt: *const Grammar,
    src: []const u8,
    out: *std.Io.Writer,
    report: *ir.Report,
    caps: ?*const writer.Caps,
    opts: Options,
) Error!?[]const u8 {
    const to: writer.Target = .{
        .g = gt,
        .out = out,
        .report = report,
        .caps = caps,
        .env = opts.env,
    };
    if (opts.whole or (gf.switches.len > 0 and std.mem.indexOf(u8, src, "lang") != null)) {
        try whole(arena, gf, src, to, opts);
        return if (opts.whole) "asked to" else "a change of language";
    }
    const keep: ir.Keep = .{ .perm = arena, .src = src };
    const start = report.items.items.len;
    var muted: ir.Report = .{ .arena = arena, .mute = true };
    const read_opts: ir.ReadOptions = .{ .env = opts.env, .library = opts.library };
    const s = try reader.Source.open(gf, arena, src, report, read_opts);
    defer s.deinit();
    var scratch: std.heap.ArenaAllocator = .init(ir.big);
    defer scratch.deinit();

    var sv: Survey = try .init(keep, gf, gt, opts);
    const params = s.paramCount();
    var needed: reader.Needed = .{};
    defer needed.deinit();
    s.watchSpelling(&needed);
    try surveyAll(s, &scratch, &sv, &muted, opts.hook);
    sv.w.folds_case = s.r.folded;
    sv.w.title = s.title;
    if (s.paramCount() != params) sv.reason("a parameter defined in a line read as two");
    try sv.mergeOptions(opts.hook, &muted);
    if (try sv.whole(arena)) {
        try whole(arena, gf, src, to, opts);
        return sv.why.?;
    }
    // The netlist streams: nothing the survey met asks it to be read whole.
    assert(sv.why == null);

    s.pruneSpelling();
    const rescan: Rescan = .{
        .s = s,
        .scratch = &scratch,
        .sv = &sv,
        .muted = &muted,
        .hook = opts.hook,
    };
    if (sv.wanted.count() > 0) try rescan.run(Survey.retain, &sv);
    s.r.report = report;
    s.rewind(scratch.allocator(), null);
    var ws: writer.Driver = undefined;
    try ws.begin(to, keep, &sv.w, .groups);
    defer ws.deinit();
    // Bound: the statements of the netlist; until `next` finds none.
    while (true) {
        s.between();
        _ = scratch.reset(.retain_capacity);
        s.useArena(scratch.allocator());
        report.phase = ir.Phase.read;
        var list: std.ArrayList(Stmt) = .empty;
        if (!try s.next(&list)) break;
        try s.finishGroup(&list, report, sv.last);
        sv.takeOptions(&list);
        if (opts.hook) |h| {
            report.phase = ir.Phase.project;
            try h.run(h.ctx, scratch.allocator(), list.items, report);
        }
        try reader.resolveGroup(gf, scratch.allocator(), list.items, &sv.tables, report);
        try ws.group(scratch.allocator(), list.items);
    }
    try ws.end(rescan);
    report.sortPhases(start);
    if (report.lost) return error.OutOfMemory;
    return null;
}

// ---- private ----

/// The survey: every statement read, noted in `sv` and thrown away.
fn surveyAll(
    s: *reader.Source,
    scratch: *std.heap.ArenaAllocator,
    sv: *Survey,
    muted: *ir.Report,
    hook: ?Hook,
) Error!void {
    s.r.report = muted;
    s.rewind(scratch.allocator(), null);
    // Bound: the statements of the netlist; until `next` finds none.
    while (true) {
        s.between();
        _ = scratch.reset(.retain_capacity);
        s.useArena(scratch.allocator());
        var list: std.ArrayList(Stmt) = .empty;
        if (!try s.next(&list)) break;
        // `next` gives a statement at least, or says there is none.
        assert(list.items.len > 0);
        try s.finishGroup(&list, muted, null);
        try sv.noteOptions(list.items);
        if (hook) |h| try h.run(h.ctx, scratch.allocator(), list.items, muted);
        try sv.add(s, sv.keep, list.items);
    }
}

fn whole(
    arena: Allocator,
    gf: *const Grammar,
    src: []const u8,
    to: writer.Target,
    opts: Options,
) Error!void {
    const report = to.report;
    report.phase = 0;
    const nl = try reader.read(
        gf,
        arena,
        src,
        report,
        .{ .env = opts.env, .library = opts.library },
    );
    if (opts.hook) |h| try h.run(h.ctx, arena, nl.stmts, report);
    try writer.write(to, arena, &nl);
}
