//! Source: a netlist being read, a group of statements at a time, and
//! `read`, which reads one whole (a run of lines at a time where the file
//! changes language).
//!
//! Contents:
//! - `pub const Source = struct`, with `pub fn open`, `pub fn deinit`, `pub fn rewind`,
//!   `pub fn useArena`, `pub fn next`, `pub fn between`, `pub fn canonical`,
//!   `pub fn watchSpelling`, `pub fn pruneSpelling`, `pub fn paramCount`, `pub fn finishGroup`
//! - `pub const Tables = struct`, with `pub fn init`, `pub fn add`
//! - `pub fn normalize(arena: Allocator, case_sensitive: bool,
//!   s: []const u8) Allocator.Error![]const u8`
//! - `pub fn read(g: *const Grammar, arena: Allocator, src: []const u8, report: *ir.Report,
//!   opts: ir.ReadOptions) Allocator.Error!ir.Netlist`
//! - `pub fn resolveGroup(g: *const Grammar, arena: Allocator, list: []ir.Stmt, t: *const Tables,
//!   report: *ir.Report) Allocator.Error!void`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const expr = @import("expr");
const dialects = @import("dialects");
const matcher = @import("matcher.zig");
const step = @import("step.zig");
const spelling = @import("spelling.zig");
const passes = @import("passes.zig");
const Declared = matcher.Declared;
const Reader = step.Reader;
const Needed = spelling.Needed;
const normalizeLists = passes.normalizeLists;
const flattenBins = passes.flattenBins;
const forms = @import("forms.zig");
const foldSegments = forms.foldSegments;
const foldForms = forms.foldForms;
const foldModules = forms.foldModules;
const measureWith = passes.measureWith;
const rebindParams = passes.rebindParams;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Kind = schema.Kind;
const Space = schema.Space;

/// A netlist being read: its lines, what the first pass learnt, and the
/// reader for the passes after it. Made in place, as the reader points
/// into it.
pub const Source = struct {
    cfg: grammar.LexCfg,
    lines: lexer.Lines,
    win: lexer.Window,
    declared: Declared = .empty,
    r: Reader,
    title: []const u8 = "",

    /// Pass one: what the netlist declares and how it spells its names.
    /// Tables go to `perm`; nothing the pass reads is kept unless copied.
    pub fn open(
        g: *const Grammar,
        perm: Allocator,
        src: []const u8,
        report: *ir.Report,
        opts: ir.ReadOptions,
    ) Allocator.Error!*Source {
        const s = try perm.create(Source);
        s.cfg = g.lex;
        if (opts.library) s.cfg.title = false;
        s.lines = .init(&s.cfg, src, null);
        s.win = .init(&s.cfg, &s.lines);
        // The lines and tokens are outside the arena: freed on the way out
        // with an error too.
        errdefer {
            s.win.deinit();
            s.lines.deinit();
        }
        s.declared = .empty;
        if (opts.env) |e| {
            var it = e.declared.keyIterator();
            while (it.next()) |k| try s.declared.put(perm, k.*, {});
        }
        var boiler: std.ArrayList([]const u8) = .empty;
        for (g.preamble) |l| try boiler.append(perm, try normalize(perm, g.lex.case_sensitive, l));
        for (g.header) |l| try boiler.append(perm, try normalize(perm, g.lex.case_sensitive, l));
        for (g.needs) |n| {
            // A block that loads the file given (`{file}`) is not boilerplate:
            // ngspice's `.control` and `.endc` lines there are any block's.
            const given = for (n.lines) |l| {
                if (std.mem.indexOf(u8, l, "{file}") != null) break true;
            } else false;
            if (given) continue;
            for (n.lines) |l| try boiler.append(perm, try normalize(perm, g.lex.case_sensitive, l));
        }
        assert(boiler.items.len >= g.preamble.len + g.header.len);
        var folded: std.ArrayList([]const u8) = .empty;
        for (g.header_folded) |l|
            try folded.append(perm, try normalize(perm, g.lex.case_sensitive, l));
        s.r = .{
            .g = g,
            .arena = perm,
            .spell = .{
                .perm = perm,
                .src = src,
                .mixed = .initFill(.{ .src = src, .perm = perm }),
            },
            .lines = &s.lines,
            .report = report,
            .boiler = boiler.items,
            .folded_boiler = folded.items,
            .m = .{
                .g = g,
                .arena = perm,
                .win = &s.win,
                .lines = &s.lines,
                .declared = &s.declared,
                .keep = .{ .perm = perm, .src = src },
            },
        };
        errdefer s.r.spell.deinit();
        // The spelling table is filled in the first pass: nothing that pass
        // decides depends on it.
        try s.r.collectDeclared(&s.declared);
        s.title = s.lines.title;
        return s;
    }

    pub fn deinit(s: *Source) void {
        s.r.spell.deinit();
        s.win.deinit();
        s.lines.deinit();
    }

    /// Back to the first line for another pass, making statements in
    /// `arena`. `keep`: as for `lexer.Lines`.
    pub fn rewind(s: *Source, arena: Allocator, keep: ?Allocator) void {
        s.win.rewind(keep);
        s.r.ti = 0;
        s.r.folded = false;
        s.r.m.said.clearRetainingCapacity();
        s.useArena(arena);
    }

    pub fn useArena(s: *Source, arena: Allocator) void {
        s.r.arena = arena;
        s.r.m.arena = arena;
        s.r.m.log = .empty;
    }

    /// The next top-level statements: one, with the comment lines before
    /// it, or the several statements of one line. False at the end.
    pub fn next(s: *Source, out: *std.ArrayList(ir.Stmt)) Allocator.Error!bool {
        // Bounded by the lines: each step reads at least one, until the end.
        while (true) {
            const n = out.items.len;
            switch (try s.r.step(null, null, out)) {
                .eof => return false,
                .closed => unreachable,
                .more => if (out.items.len > n) return true,
            }
        }
    }

    /// Done with every statement read so far: the lines they came from go.
    pub fn between(s: *Source) void {
        s.win.drop(s.r.ti);
        s.r.ti = 0;
        s.lines.recycle();
    }

    /// The spelling a case-folding reader gives every name of `space`: two
    /// names of it that both have it are the same text.
    pub fn canonical(s: *const Source, space: Space, name: []const u8) bool {
        const sp = &s.r.spell;
        var buf: [256]u8 = undefined;
        if (space == .param and name.len <= buf.len) {
            if (sp.params.get(std.ascii.lowerString(&buf, name))) |p|
                return std.mem.eql(u8, p, name);
        }
        if (sp.mixed.getPtrConst(space).getKey(name)) |k| return std.mem.eql(u8, k, name);
        for (name) |c| if (std.ascii.isUpper(c)) return false;
        return true;
    }

    /// Record, until `prune`, which names of the spelling table answer a
    /// lookup with a spelling of their own.
    pub fn watchSpelling(s: *Source, needed: *Needed) void {
        s.r.spell.needed = needed;
    }

    /// Keep only the names `watchSpelling` recorded; the others answered
    /// every lookup with what it falls back to. Kept whole if the record
    /// could not be made.
    pub fn pruneSpelling(s: *Source) void {
        s.r.spell.prune();
    }

    /// Parameters first defined in a pass after the first (a line split in
    /// two, `splitAt`), which respell names in statements before them.
    pub fn paramCount(s: *const Source) usize {
        return s.r.spell.params.count();
    }

    /// The passes `read` runs over the whole netlist that need nothing but
    /// the statements `next` gave, run on them. `last`: the netlist's last
    /// analysis (`lastAnalysis`), which a `.measure` naming none measures.
    pub fn finishGroup(
        s: *Source,
        list: *std.ArrayList(ir.Stmt),
        report: *ir.Report,
        last: ?[]const u8,
    ) Allocator.Error!void {
        const r = &s.r;
        const g = r.g;
        const arena = r.arena;
        // Between top-level statements: inside no block.
        assert(r.depth == 0);
        report.phase = ir.Phase.finish;
        try r.finish(list.items);
        report.phase = ir.Phase.bodies;
        for (list.items) |*st| {
            if (st.body.len > 0) st.body = try normalizeLists(g, arena, st.body, report);
        }
        report.phase = ir.Phase.bins;
        try flattenBins(g, arena, list, report);
        report.phase = ir.Phase.segments;
        try foldSegments(arena, list.items, report);
        try foldForms(arena, list.items, report);
        try foldModules(arena, list.items, list.items);
        try measureWith(arena, list.items, last);
        try expr.convert(arena, g, list.items, false);
    }
};

/// What resolving instances and checking model kinds need of the whole
/// netlist (`ir.resolveInstances`, `ir.checkModelKinds`).
pub const Tables = struct {
    models: std.StringHashMapUnmanaged(Kind) = .empty,
    subckts: ir.CaselessSet = .empty,
    families: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(arena: Allocator, env: ?*const ir.Env) Allocator.Error!Tables {
        var t: Tables = .{};
        if (env) |e| {
            var it = e.models.iterator();
            while (it.next()) |kv| try t.models.put(arena, kv.key_ptr.*, kv.value_ptr.*);
            var si = e.subckts.keyIterator();
            while (si.next()) |k| try t.subckts.put(arena, k.*, {});
        }
        return t;
    }

    pub fn add(t: *Tables, k: ir.Keep, stmts: []const ir.Stmt) Allocator.Error!void {
        try ir.collectModels(k.perm, stmts, &t.models, &t.subckts, k.src);
        try ir.collectFamilies(k.perm, stmts, &t.families, k.src);
    }
};

pub fn normalize(arena: Allocator, case_sensitive: bool, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |w| {
        if (out.items.len > 0) try out.append(arena, ' ');
        for (w) |c| try out.append(arena, if (case_sensitive) c else std.ascii.toLower(c));
    }
    return out.toOwnedSlice(arena);
}

pub fn read(
    g: *const Grammar,
    arena: Allocator,
    src: []const u8,
    report: *ir.Report,
    opts: ir.ReadOptions,
) Allocator.Error!ir.Netlist {
    const switched = if (g.switches.len > 0 and std.mem.indexOf(u8, src, "lang") != null)
        try readSwitched(g, arena, src, report, opts)
    else
        null;
    const nl = switched orelse try readPlain(g, arena, src, report, opts);
    if (report.lost) return error.OutOfMemory;
    return nl;
}

/// The passes `read` ends with, on the statements `Source.next` gave.
pub fn resolveGroup(
    g: *const Grammar,
    arena: Allocator,
    list: []ir.Stmt,
    t: *const Tables,
    report: *ir.Report,
) Allocator.Error!void {
    if (t.models.count() > 0) try ir.retag(arena, list, &t.models, &t.subckts);
    try rebindParams(g, arena, list);
    report.phase = ir.Phase.kinds;
    if (t.models.count() > 0) try ir.checkKinds(list, &t.models, &t.families, report);
}

// ---- private ----

/// Does `line` start with the words of a `switch`? Blanks and case aside.
fn startsSwitch(line: []const u8, words: []const u8) bool {
    var a = std.mem.tokenizeAny(u8, line, " \t\r");
    var b = std.mem.tokenizeAny(u8, words, " \t");
    while (b.next()) |w| {
        const x = a.next() orelse return false;
        if (!std.ascii.eqlIgnoreCase(x, w)) return false;
    }
    return true;
}

fn switchOf(g: *const Grammar, line: []const u8) ?*const grammar.Switch {
    for (g.switches) |*s| if (startsSwitch(line, s.words)) return s;
    return null;
}

/// A file that changes language (`simulator lang=spice`) is read one run
/// of lines at a time, each with its own grammar. Lines outside the run
/// are blanked rather than cut, so that line numbers stay those of the file.
fn readSwitched(
    g: *const Grammar,
    arena: Allocator,
    src: []const u8,
    report: *ir.Report,
    opts: ir.ReadOptions,
) Allocator.Error!?ir.Netlist {
    var starts: std.ArrayList(usize) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    var lines: std.ArrayList([]const u8) = .empty;
    while (it.next()) |l| try lines.append(arena, l);
    var other = false;
    for (lines.items, 0..) |l, i| if (switchOf(g, l)) |sw| {
        try starts.append(arena, i);
        other = other or !std.ascii.eqlIgnoreCase(sw.dialect, g.name);
    };
    // Only the header naming the file's own language: nothing to switch.
    if (!other) return null;
    assert(starts.items.len > 0);
    var out: std.ArrayList(ir.Stmt) = .empty;
    var title: []const u8 = "";
    var from: usize = 0;
    var cur = g;
    var k: usize = 0;
    var folds = false;
    while (from < lines.items.len) {
        const to = if (k < starts.items.len) starts.items[k] else lines.items.len;
        if (to > from) {
            var text: std.ArrayList(u8) = .empty;
            for (lines.items, 0..) |l, i| {
                if (i >= from and i < to) try text.appendSlice(arena, l);
                if (i + 1 < lines.items.len) try text.append(arena, '\n');
            }
            var seg_opts = opts;
            seg_opts.library = opts.library or from > 0;
            const nl = try readPlain(cur, arena, text.items, report, seg_opts);
            if (from == 0) title = nl.title;
            folds = folds or nl.folds_case or !cur.lex.case_sensitive;
            const tag: u8 = if (cur == g) 0 else (try dialects.intern(cur.name)) orelse 0;
            for (nl.stmts) |st| {
                // The blanked lines read as blank lines; they are not the file's.
                if (st.kind == .comment and std.mem.eql(
                    u8,
                    st.raw,
                    ir.blank_line,
                ) and (st.line < from + 1 or st.line > to)) continue;
                var s = st;
                if (s.dialect == 0) s.dialect = tag;
                try out.append(arena, s);
            }
        }
        if (k >= starts.items.len) break;
        const sw = switchOf(g, lines.items[starts.items[k]]).?;
        // Back to the file's own language is back to `g`, which may be a
        // grammar loaded from a file, not the built-in of the same name.
        cur = if (std.ascii.eqlIgnoreCase(sw.dialect, g.name))
            g
        else
            dialects.find(sw.dialect) orelse g;
        const n = try normalize(arena, cur.lex.case_sensitive, lines.items[starts.items[k]]);
        for (cur.header_folded) |l|
            folds = folds or std.mem.eql(u8, n, try normalize(arena, cur.lex.case_sensitive, l));
        from = starts.items[k] + 1;
        k += 1;
    }
    var nl: ir.Netlist = .{
        .title = title,
        .dialect = g.name,
        .library = opts.library,
        .folds_case = folds,
        .stmts = out.items,
    };
    try ir.resolveInstances(arena, &nl, opts.env);
    return nl;
}

fn readPlain(
    g: *const Grammar,
    arena: Allocator,
    src: []const u8,
    report: *ir.Report,
    opts: ir.ReadOptions,
) Allocator.Error!ir.Netlist {
    const env = opts.env;
    const s = try Source.open(g, arena, src, report, opts);
    defer s.deinit();
    s.rewind(arena, arena);
    const r = &s.r;
    var nl: ir.Netlist = .{
        .title = s.title,
        .dialect = g.name,
        .library = opts.library,
        .stmts = try r.top(),
    };
    // Every block read restores the depth it opened at.
    assert(r.depth == 0);
    nl.folds_case = r.folded;
    try r.finish(nl.stmts);
    nl.stmts = try normalizeLists(g, arena, nl.stmts, report);
    try ir.markUnlistedBuiltins(arena, &nl);
    try ir.resolveInstances(arena, &nl, env);
    try ir.resolveSweeps(arena, &nl);
    try rebindParams(g, arena, nl.stmts);
    try ir.checkModelKinds(arena, &nl, report, env);
    return nl;
}
