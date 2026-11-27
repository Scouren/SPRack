//! End-to-end tests for the shipped grammars.

const std = @import("std");
const sprack = @import("root.zig");
const testing = std.testing;
const ir = sprack.ir;
const schema = sprack.schema;

const dialects = [_][]const u8{ "ngspice", "hspice", "spectre", "vacask", "xyce", "ltspice", "cdl" };
/// Dialects that are another for a different reader (`variant`): built in,
/// compiled like the rest, and tested by what they are for.
const variants = [_][]const u8{"cktimg"};

// One circuit, written by hand in each dialect the way a person would write
// it there: passives, sources, a parameterised subcircuit and an instance of
// it, an expression, and the analyses each dialect can express.

const core_ngspice =
    \\Core test circuit
    \\* comment line
    \\.param rload=2k cval=10p
    \\.subckt rcdiv in out vss r1=1k r2=1k
    \\R1 in out {r1}
    \\R2 out vss {r2}
    \\C1 out vss 1.5p
    \\.ends rcdiv
    \\V1 in 0 DC 1 AC 1 PULSE(0 1.8 1n 100p 100p 5n 10n)
    \\I1 0 out DC 1M $ one milliamp, not one megaamp
    \\X1 in out 0 rcdiv
    \\+ r1=1MEG r2={rload*2}
    \\Cl out 0 {cval}
    \\Ll out 0 10n
    \\.op
    \\.dc V1 0 1.8 0.1
    \\.ac dec 10 1 1G
    \\.tran 10p 20n
    \\.noise v(out) V1 dec 10 1k 1MEG
    \\.end
;

const core_hspice =
    \\Core test circuit
    \\.param rload=2k cval=10p
    \\.subckt rcdiv in out vss r1=1k r2=1k
    \\R1 in out 'r1'
    \\R2 out vss r2           $ a bare identifier is a value in HSPICE
    \\C1 out vss 1.5p
    \\.ends rcdiv
    \\V1 in 0 DC 1 AC 1 PULSE(0 1.8 1n 100p 100p 5n 10n)
    \\I1 0 out DC 1M
    \\X1 in out 0 rcdiv r1=1X r2='rload*2'
    \\Cl out 0 cval
    \\Ll out 0 10n
    \\.op
    \\.dc V1 0 1.8 0.1
    \\.ac dec 10 1 1G
    \\.tran 10p 20n
    \\.end
;

const core_xyce =
    \\Core test circuit
    \\.param rload=2k cval=10p
    \\.subckt rcdiv in out vss PARAMS: r1=1k r2=1k
    \\R1 in out {r1}
    \\R2 out vss {r2}
    \\C1 out vss 1.5p
    \\.ends rcdiv
    \\V1 in 0 DC 1 AC 1 PULSE(0 1.8 1n 100p 100p 5n 10n)
    \\I1 0 out DC 1M ; one milliamp
    \\X1 in out 0 rcdiv PARAMS: r1=1MEG r2={rload*2}
    \\Cl out 0 {cval}
    \\Ll out 0 10n
    \\.op
    \\.dc V1 0 1.8 0.1
    \\.ac dec 10 1 1G
    \\.tran 10p 20n
    \\.noise v(out) V1 dec 10 1k 1MEG
    \\.end
;

const core_spectre =
    \\// Core test circuit
    \\simulator lang=spectre
    \\global 0
    \\parameters rload=2k cval=10p
    \\subckt rcdiv (in out vss)
    \\parameters r1=1k r2=1k
    \\    r1 (in out) resistor r=r1
    \\    r2 (out vss) resistor r=r2
    \\    c1 (out vss) capacitor c=1.5p
    \\ends rcdiv
    \\v1 (in 0) vsource dc=1 mag=1 type=pulse val0=0 val1=1.8 delay=1n \
    \\    rise=100p fall=100p width=5n period=10n
    \\i1 (0 out) isource dc=1m  // one milliamp
    \\x1 (in out 0) rcdiv r1=1M r2=rload*2
    \\cl (out 0) capacitor c=cval
    \\ll (out 0) inductor l=10n
    \\op1 dc
    \\dc1 dc dev=v1 param=dc start=0 stop=1.8 step=0.1
    \\ac1 ac start=1 stop=1G dec=10
    \\tran1 tran step=10p stop=20n
    \\noise1 (out 0) noise iprobe=v1 start=1k stop=1M dec=10
;

const core_vacask =
    \\Core test circuit
    \\ground 0
    \\load "spice/resistor.osdi"
    \\load "spice/capacitor.osdi"
    \\load "spice/inductor.osdi"
    \\model resistor sp_resistor
    \\model capacitor sp_capacitor
    \\model inductor sp_inductor
    \\model vsource vsource
    \\model isource isource
    \\parameters rload=2k cval=10p
    \\subckt rcdiv(in out vss)
    \\  parameters r1=1k r2=1k
    \\  r1 (in out) resistor r=r1
    \\  r2 (out vss) resistor r=r2
    \\  c1 (out vss) capacitor c=1.5p
    \\ends
    \\v1 (in 0) vsource dc=1 mag=1 type="pulse" val0=0 val1=1.8 delay=1n \
    \\   rise=100p fall=100p width=5n period=10n
    \\i1 (0 out) isource dc=1m
    \\x1 (in out 0) rcdiv r1=1M r2=rload*2
    \\cl (out 0) capacitor c=cval
    \\ll (out 0) inductor l=10n
    \\control
    \\  analysis op1 op
    \\  sweep s1 instance="v1" parameter="dc" from=0 to=1.8 step=0.1
    \\  analysis dc1 op
    \\  analysis ac1 ac from=1 to=1G mode="dec" points=10
    \\  analysis tran1 tran step=10p stop=20n
    \\  analysis noise1 noise out="out" in="v1" from=1k to=1M mode="dec" points=10
    \\endc
;

const core_ltspice =
    \\Core test circuit
    \\* comment line
    \\.param rload=2k cval=10p
    \\.subckt rcdiv in out vss r1=1k r2=1k
    \\R1 in out {r1}
    \\R2 out vss {r2}
    \\C1 out vss 1.5p
    \\.ends rcdiv
    \\V1 in 0 DC 1 PULSE(0 1.8 1n 100p 100p 5n 10n) AC 1
    \\I1 0 out DC 1M ; one milliamp
    \\X1 in out 0 rcdiv params:
    \\+ r1=1MEG r2={rload*2}
    \\Cl out 0 {cval}
    \\Ll out 0 10n
    \\.op
    \\.dc V1 0 1.8 0.1
    \\.ac dec 10 1 1G
    \\.tran 10p 20n
    \\.noise V(out) V1 dec 10 1k 1MEG
    \\.end
;

// CDL is connectivity only: the circuit without its sources and analyses.
const core_cdl =
    \\* Core test circuit
    \\.PARAM rload=2k cval=10p
    \\.SUBCKT rcdiv in out vss r1=1k r2=1k
    \\R1 in out r1
    \\R2 out vss r2 $ a bare identifier is a value
    \\C1 out vss 1.5p
    \\.ENDS rcdiv
    \\V1 in 0 DC 1 $ a bench's sources, their DC value only
    \\I1 0 out DC 1m
    \\X1 in out 0 / rcdiv r1=1MEG r2='rload*2'
    \\Cl out 0 cval
    \\Ll out 0 10n
    \\.END
;

fn sample(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "ngspice")) return core_ngspice;
    if (std.mem.eql(u8, name, "ltspice")) return core_ltspice;
    if (std.mem.eql(u8, name, "cdl")) return core_cdl;
    if (std.mem.eql(u8, name, "hspice")) return core_hspice;
    if (std.mem.eql(u8, name, "xyce")) return core_xyce;
    if (std.mem.eql(u8, name, "spectre")) return core_spectre;
    return core_vacask;
}

/// Differences that are spelling, not meaning: analysis labels (SPICE has
/// none), and a noise reference node of ground (implicit where omitted).
/// `drop_noise` removes noise analyses, which the HSPICE grammar cannot say.
fn normalize(arena: std.mem.Allocator, nl: ir.Netlist, drop_noise: bool) !ir.Netlist {
    var out: std.ArrayList(ir.Stmt) = .empty;
    for (nl.stmts) |s| {
        if (drop_noise and s.kind == .noise) continue;
        var c = s;
        try c.own(arena);
        if (schema.info(s.kind).class == .analysis) try c.set(arena, schema.slotOf(s.kind, "name").?, .none);
        if (s.kind == .noise) {
            const ri = schema.slot(.noise, "ref");
            if (c.at(ri) == .atom and std.mem.eql(u8, c.at(ri).atom, "0")) try c.set(arena, ri, .none);
        }
        try out.append(arena, c);
    }
    return .{ .title = nl.title, .dialect = nl.dialect, .stmts = out.items };
}

fn readAs(arena: std.mem.Allocator, dialect: []const u8, text: []const u8, report: *ir.Report) !ir.Netlist {
    return sprack.read(arena, sprack.find(dialect).?, text, report);
}

fn writeAs(arena: std.mem.Allocator, dialect: []const u8, nl: *const ir.Netlist, report: *ir.Report) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try sprack.write(arena, sprack.find(dialect).?, &aw.writer, nl, report);
    return aw.written();
}

fn has(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("\n--- expected to find:\n{s}\n--- in:\n{s}\n", .{ needle, text });
        return error.TestExpectedText;
    }
}

fn reported(report: *const ir.Report, sev: ir.Severity, needle: []const u8) !void {
    if (!report.contains(sev, needle)) {
        std.debug.print("\n--- expected a report entry ({s}) containing:\n{s}\n--- report:\n", .{ @tagName(sev), needle });
        dumpReport(report);
        return error.TestExpectedReport;
    }
}

fn clean(report: *const ir.Report) !void {
    if (report.count(.@"error") != 0) {
        dumpReport(report);
        return error.TestUnexpectedErrors;
    }
}

/// Translate, and check what must hold for every translation (`invariants`).
/// Nearly every test below goes through here, so each example in this file
/// is also a test of those.
fn tr(a: std.mem.Allocator, from: []const u8, to: []const u8, src: []const u8, report: *ir.Report) ![]const u8 {
    return trx(a, from, to, src, report, .{});
}

fn trx(a: std.mem.Allocator, from: []const u8, to: []const u8, src: []const u8, report: *ir.Report, skip: Skip) ![]const u8 {
    const out = try sprack.translateAlloc(a, from, to, src, report);
    try invariants(a, from, to, src, out, skip);
    return out;
}

const Skip = struct {
    /// The target reads the output as other statements than the source's
    /// and no report entry says so. Each use says why that is known.
    silent: bool = false,
};

/// Report entries that explain a translation not reading back the same, as
/// `tools/corpus_summary.py` counts them.
fn excuses(r: *const ir.Report) usize {
    var n: usize = 0;
    inline for (.{ .untranslated, .unsupported, .loss, .synthesized, .invalid, .ambiguous, .oneway, .rename }) |c| n += r.countCode(c);
    return n;
}

fn jsonOf(a: std.mem.Allocator, nl: *const ir.Netlist) ![]const u8 {
    var j: std.Io.Writer.Allocating = .init(a);
    try sprack.json.writeNetlist(&j.writer, nl);
    return j.written();
}

var loaded_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var loaded_grammars: [dialects.len + variants.len]?*const sprack.Grammar = @splat(null);

/// The dialect's grammar file compiled now, at run time, once per process.
fn loadedGrammar(name: []const u8) !*const sprack.Grammar {
    const i = for (dialects ++ variants, 0..) |d, k| {
        if (std.mem.eql(u8, d, name)) break k;
    } else unreachable;
    if (loaded_grammars[i]) |g| return g;
    const la = loaded_arena.allocator();
    var diag: sprack.grammar.Diag = .{};
    const g = sprack.resolve(la, testing.io, try std.fmt.allocPrint(la, "grammars/{s}.spgrammar", .{name}), &diag) catch |e| {
        std.debug.print("{s}\n", .{diag.msg});
        return e;
    };
    loaded_grammars[i] = g;
    return g;
}

/// A small grammar for one test, compiled now; it lives until the process ends.
fn tinyGrammar(comptime src: []const u8) sprack.Grammar {
    var diag: sprack.grammar.Diag = .{};
    return sprack.grammar.compile(loaded_arena.allocator(), src, "", &diag) catch |e| {
        std.debug.panic("{s}: {s}", .{ @errorName(e), diag.msg });
    };
}

/// What holds for any input at all, damaged ones included: `out` is `src`
/// read as `from` and written as `to`.
///  - Twice gives the same bytes.
///  - The JSON form is the netlist: read back it is the same JSON, and
///    writes the same output.
///  - The grammar file compiled at run time reads and writes as the one
///    compiled into the binary.
fn anyInput(a: std.mem.Allocator, from: []const u8, to: []const u8, src: []const u8, out: []const u8) !ir.Netlist {
    var r1: ir.Report = .init(a);
    return anyInputReport(a, from, to, src, out, &r1);
}

/// `r1` gets the report of reading and writing.
fn anyInputReport(a: std.mem.Allocator, from: []const u8, to: []const u8, src: []const u8, out: []const u8, r1: *ir.Report) !ir.Netlist {
    const nl = try readAs(a, from, src, r1);
    try testing.expectEqualStrings(out, try writeAs(a, to, &nl, r1));

    const json = try jsonOf(a, &nl);
    var r2: ir.Report = .init(a);
    const from_json = try sprack.json.parseNetlist(a, json, &r2);
    try testing.expectEqual(0, r2.items.items.len);
    if (std.unicode.utf8ValidateSlice(src)) {
        try testing.expectEqualStrings(json, try jsonOf(a, &from_json));
        try testing.expectEqualStrings(out, try writeAs(a, to, &from_json, &r2));
    } else {
        // A byte that is not UTF-8 comes back from the JSON as the Latin-1
        // character of its value: from there on the form is stable.
        const again = try jsonOf(a, &from_json);
        try testing.expectEqualStrings(again, try jsonOf(a, &try sprack.json.parseNetlist(a, again, &r2)));
        try testing.expectEqual(0, r2.items.items.len);
    }

    var r3: ir.Report = .init(a);
    try testing.expectEqualStrings(json, try jsonOf(a, &try sprack.read(a, try loadedGrammar(from), src, &r3)));
    var w: std.Io.Writer.Allocating = .init(a);
    try sprack.write(a, try loadedGrammar(to), &w.writer, &nl, &r3);
    try testing.expectEqualStrings(out, w.written());
    return nl;
}

/// `anyInput`, and what holds for a netlist that is valid in its dialect:
///  - Nothing is lost in silence: the target reads the output as the same
///    circuit, or the report has an entry that says why not (`sprack audit`).
///  - What the target read, it writes again without an error and reads
///    the same from that.
fn invariants(a: std.mem.Allocator, from: []const u8, to: []const u8, src: []const u8, out: []const u8, skip: Skip) !void {
    errdefer std.debug.print("\n--- {s} -> {s}:\n{s}\n--- written:\n{s}\n", .{ from, to, src, out });
    var r1: ir.Report = .init(a);
    const nl = try anyInputReport(a, from, to, src, out, &r1);
    const gt = sprack.find(to).?;
    var rb: ir.Report = .init(a);
    const back = try readAs(a, to, out, &rb);
    if (!skip.silent and excuses(&r1) == 0 and !try sprack.sameTranslation(a, gt, &nl, &back)) {
        std.debug.print("\n--- source statements:\n{s}--- read back from {s}:\n{s}", .{ try jsonOf(a, &nl), to, try jsonOf(a, &back) });
        return error.TestSilentDifference;
    }
    if (r1.hasErrors()) return;
    var r2: ir.Report = .init(a);
    const again = try writeAs(a, to, &back, &r2);
    errdefer {
        std.debug.print("\n--- written again by {s}:\n{s}\n", .{ to, again });
        dumpReport(&r2);
    }
    try testing.expectEqual(0, r2.count(.@"error"));
    if (excuses(&r2) > 0) return;
    const back2 = try readAs(a, to, again, &r2);
    try testing.expect(ir.sameCircuit(&back, &back2));
}

fn dumpReport(report: *const ir.Report) void {
    for (report.items.items) |d| std.debug.print("  {s}: line {d}: {s}\n", .{ @tagName(d.sev), d.line, d.msg });
}

fn countKind(nl: ir.Netlist, kind: schema.Kind) usize {
    var n: usize = 0;
    for (nl.stmts) |s| n += @intFromBool(s.kind == kind);
    return n;
}

const Arena = std.heap.ArenaAllocator;

test "all grammars compiled" {
    try testing.expectEqual(dialects.len + variants.len, sprack.dialect_count);
    for (dialects ++ variants) |n| try testing.expect(sprack.find(n) != null);
    for (variants) |n| try testing.expect(sprack.find(n).?.variant_of.len > 0);
}

test "each grammar file compiled at run time is the grammar built into the binary" {
    // One compiler, run when the binary is built and again now: every table
    // of every dialect, field for field.
    for (dialects ++ variants) |d| {
        errdefer std.debug.print("dialect {s}\n", .{d});
        try testing.expectEqualDeep(sprack.find(d).?.*, (try loadedGrammar(d)).*);
    }
}

test "caps: every kind has a rule, a place or a reason in every dialect" {
    // `sprack caps` shows no `-`.
    for (sprack.grammars) |*g| for (schema.table) |info| {
        if (info.kind == .@"opaque" or info.kind == .comment or info.kind == .annotation) continue;
        const scoped = for (g.rules) |r| {
            if (r.kind == info.kind and r.dir != .read and r.within != null) break true;
        } else false;
        const said = g.canWrite(info.kind) or scoped or g.movedTo(info.kind) != null or g.absentReason(info.kind) != null or
            g.statementInert(info.kind) != null or
            (info.class == .device and g.canWrite(.instance) and schema.slotOf(info.kind, "master") != null);
        if (!said) {
            std.debug.print("{s} has no rule for '{s}' and no `no {s} : reason` line\n", .{ g.name, @tagName(info.kind), @tagName(info.kind) });
            return error.TestCapsGap;
        }
    };
}

/// A value of the kind a slot holds, for statements made up by the tests.
fn sampleValue(a: std.mem.Allocator, sl: schema.Slot, n: usize) !ir.Value {
    if (sl.list) {
        var one = sl;
        one.list = false;
        return .{ .list = try a.dupe(ir.Value, &.{ try sampleValue(a, one, n), try sampleValue(a, one, n + 1) }) };
    }
    return switch (sl.ty) {
        .name => .{ .atom = "X1" },
        .node => .{ .atom = try std.fmt.allocPrint(a, "n{d}", .{n}) },
        .ident => .{ .atom = "m1" },
        .ref => .{ .atom = "V1" },
        .value => .{ .num = .init("1.5", -9) },
        .atom => .{ .atom = "a1" },
        .path => .{ .str = "lib/f.inc" },
        .text => .{ .atom = "some text" },
        .signal => .{ .atom = "v(n1)" },
        .params => .{ .params = try a.dupe(ir.Param, &.{ .{ .key = "k1", .val = .{ .num = .init("1", 3) } }, .{ .key = "k2", .val = .{ .expr = "2*k1" } }, .{ .key = "flag", .val = .none } }) },
    };
}

/// A statement of `kind` with every slot given (`only` null), or with its
/// name and one slot.
fn sampleStmt(a: std.mem.Allocator, kind: schema.Kind, only: ?usize) !ir.Stmt {
    var st = try ir.newStmt(a, kind, 1);
    for (schema.info(kind).slots, 0..) |sl, i| {
        if (only == null or only.? == i or sl.ty == .name) try st.set(a, i, try sampleValue(a, sl, i));
    }
    return st;
}

test "every kind, every slot, every dialect: written without a crash, and the JSON is the statement" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var count: usize = 0;
    var silent: usize = 0;
    for (schema.table) |info| {
        // Written as text by every dialect, as a comment is (an annotation
        // has a test of its own).
        if (info.kind == .@"opaque" or info.kind == .comment or info.kind == .annotation) continue;
        var only: ?usize = null;
        while (true) {
            _ = arena_state.reset(.retain_capacity);
            var stmts = [_]ir.Stmt{try sampleStmt(a, info.kind, only)};
            const nl: ir.Netlist = .{ .title = "t", .dialect = "sprack", .stmts = &stmts };
            errdefer std.debug.print("kind {s}, slot {?d}\n", .{ @tagName(info.kind), only });
            // The JSON form holds any statement of the vocabulary exactly.
            const json = try jsonOf(a, &nl);
            var rj: ir.Report = .init(a);
            const back = try sprack.json.parseNetlist(a, json, &rj);
            try testing.expectEqual(0, rj.items.items.len);
            try testing.expect(nl.eql(&back));
            try testing.expectEqualStrings(json, try jsonOf(a, &back));
            for (dialects) |to| {
                errdefer std.debug.print("to {s}\n", .{to});
                var r1: ir.Report = .init(a);
                const out = try writeAs(a, to, &nl, &r1);
                // Twice the same, from the JSON the same, and by the grammar
                // compiled at run time the same.
                var r2: ir.Report = .init(a);
                try testing.expectEqualStrings(out, try writeAs(a, to, &back, &r2));
                try testing.expectEqual(r1.items.items.len, r2.items.items.len);
                var r3: ir.Report = .init(a);
                var w: std.Io.Writer.Allocating = .init(a);
                try sprack.write(a, try loadedGrammar(to), &w.writer, &nl, &r3);
                try testing.expectEqualStrings(out, w.written());
                // A kind the dialect has no form for is an error that names
                // the kind; where the grammar says why, the reason is given.
                const g = sprack.find(to).?;
                // (A device with a model may be written as an instance of it: `inst` in `sprack caps`.)
                const as_instance = info.class == .device and g.canWrite(.instance) and schema.slotOf(info.kind, "master") != null;
                // Nothing to write is not a loss: an options statement that is
                // only a heading.
                const empty = info.kind == .options and only != null and std.mem.eql(u8, info.slots[only.?].name, "package");
                if (!g.canWrite(info.kind) and g.movedTo(info.kind) == null and !as_instance and !empty and r1.count(.@"error") == 0) {
                    std.debug.print("SILENT {s} slot {?d} to {s}\n", .{ @tagName(info.kind), only, to });
                    silent += 1;
                }
                // What it wrote, its own reader takes without a crash.
                var r4: ir.Report = .init(a);
                _ = try readAs(a, to, out, &r4);
                count += 1;
            }
            const next = if (only) |o| o + 1 else 0;
            if (next == info.slots.len) break;
            only = next;
        }
    }
    try testing.expectEqual(0, silent);
    try testing.expect(count > 4000);
}

test "every `no` line: the kind is an error in that dialect, and the reason is the grammar's" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var count: usize = 0;
    var bad: usize = 0;
    for (sprack.grammars) |*g| for (g.absent) |no| {
        // Two kinds a dialect without the statement may still say another
        // way, so their reason is only given when that way fails: variations
        // as agauss() in the parameter (`stats.zig`), alters of parameters as
        // a table of runs (`alter.zig`).
        if (no.kind == .statistics or no.kind == .alter) continue;
        // One value of a kind the dialect has: "xyce: a tolerance is three options".
        if (no.slot != sprack.grammar.no_slot) continue;
        var stmts = [_]ir.Stmt{try sampleStmt(a, no.kind, null)};
        const nl: ir.Netlist = .{ .title = "t", .dialect = "sprack", .stmts = &stmts };
        var r: ir.Report = .init(a);
        var w: std.Io.Writer.Allocating = .init(a);
        try sprack.write(a, g, &w.writer, &nl, &r);
        if (!r.contains(.@"error", no.reason) or r.countCode(.unsupported) == 0) {
            std.debug.print("MISSING {s}: no {s} : {s}\n", .{ g.name, @tagName(no.kind), no.reason });
            dumpReport(&r);
            bad += 1;
        }
        count += 1;
    };
    try testing.expectEqual(0, bad);
    try testing.expect(count > 100);
}

test "xyce: a tolerance is three options, and vntol, trtol and chgtol are none" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The time step's, an operating point's Newton and a transient's (4.19).
    var r1: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", "t\n.options gmin=1e-10 reltol=1e-5\n.op\n.end\n", &r1);
    try has(xy, ".options timeint reltol=1e-5\n.options nonlin reltol=1e-5\n.options nonlin-tran reltol=1e-5\n.options device gmin=0.1n\n");
    try clean(&r1);
    try testing.expect(!r1.contains(.warning, "ABSTOL"));
    // Read back, the three lines are the one reltol, and Xyce keeps its lines.
    var r2: ir.Report = .init(a);
    try testing.expectEqualStrings(xy, try tr(a, "xyce", "xyce", xy, &r2));
    try has(try tr(a, "xyce", "ngspice", xy, &r2), ".options reltol=1e-5\n");
    try testing.expectEqual(0, r2.count(.@"error"));
    // Under nonlin alone it is not the reltol of the others, as before.
    var r3: ir.Report = .init(a);
    const own = "t\n.options nonlin reltol=1u\n.options timeint reltol=1e-4\n.op\n.end\n";
    try testing.expectEqualStrings(own, try tr(a, "xyce", "xyce", own, &r3));
    try testing.expectEqual(0, r3.items.items.len);
    try has(try tr(a, "xyce", "ngspice", own, &r3), ".options reltol=1e-4\n");
    try reported(&r3, .@"error", "options: 'reltol=1u' has no spelling in ngspice");

    // One ABSTOL for voltages and currents; no factor on the truncation
    // error; no charge tolerance in the step control.
    var r4: ir.Report = .init(a);
    const tol = try tr(a, "ngspice", "xyce", "t\n.options abstol=1p vntol=10n trtol=1 chgtol=1e-20\n.tran 1n 1u\n.end\n", &r4);
    try has(tol, ".options timeint abstol=1p\n.options nonlin abstol=1p\n.options nonlin-tran abstol=1p\n.tran");
    try reported(&r4, .warning, "options.abstol: Xyce's ABSTOL bounds node voltages as well as branch currents");
    try reported(&r4, .@"error", "options.vntol = 10n has no spelling in xyce: Xyce has no voltage tolerance: the ABSTOL of each package bounds node voltages and branch currents alike");
    try reported(&r4, .@"error", "options.trtol = 1 has no spelling in xyce: Xyce has no factor on the truncation error");
    try reported(&r4, .@"error", "options.chgtol = 1e-20 has no spelling in xyce: Xyce's step control bounds the error of each unknown, not of a charge");
    try testing.expectEqual(3, r4.count(.@"error"));
    // Every such line of a grammar ends the error of its slot.
    for (sprack.grammars) |*g| for (g.absent) |no| {
        if (no.slot == sprack.grammar.no_slot) continue;
        if (std.mem.eql(u8, g.name, "xyce") and no.kind == .options) {
            try testing.expect(r4.contains(.@"error", no.reason));
        } else {
            // Elsewhere (VACASK's ports, #49; Xyce's noise node pair, #68):
            // a statement giving the slot.
            var st = try sampleStmt(a, no.kind, null);
            try st.set(a, no.slot, .{ .num = .init("1", 0) });
            // A sweep's kind as a dialect spells it, not the sample's atom.
            if (schema.slotOf(no.kind, "sweep")) |i| try st.set(a, i, .{ .atom = "dec" });
            var stmts = [_]ir.Stmt{st};
            const nl: ir.Netlist = .{ .title = "t", .dialect = "sprack", .stmts = &stmts };
            var rr: ir.Report = .init(a);
            var w: std.Io.Writer.Allocating = .init(a);
            try sprack.write(a, g, &w.writer, &nl, &rr);
            try testing.expect(rr.contains(.@"error", no.reason));
        }
    };

    // HSPICE says one reltol twice on one line; in its own dialect a line is kept as read.
    var r5: ir.Report = .init(a);
    try has(try tr(a, "hspice", "hspice", "t\n.option reltol=1e-4\n.op\n.end\n", &r5), ".option reltol=1e-4\n");
    try has(try tr(a, "hspice", "xyce", "t\n.option absv=1u absi=1p\n.op\n.end\n", &r5), ".options nonlin abstol=1p\n");
    try reported(&r5, .@"error", "options.vntol = 1u has no spelling in xyce: Xyce has no voltage tolerance");
}

/// How many report entries the translation of `src` gave.
fn translateOnce(gpa: std.mem.Allocator, from: []const u8, to: []const u8, src: []const u8) !usize {
    var arena_state: Arena = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    _ = try sprack.translateAlloc(a, from, to, src, &report);
    return report.items.items.len;
}

test "out of memory at any allocation comes back as that: no crash, no leak" {
    // The large temporary tables too (`ir.big`), which are freed by hand.
    const big = ir.big;
    defer ir.big = big;
    // The samples are read whole (each has a sweep); `stream_deck` is
    // written as a stream, with the tables that keeps outside the arena.
    for ([_][3][]const u8{
        .{ "ngspice", "spectre", "" },          .{ "spectre", "vacask", "" },           .{ "vacask", "hspice", "" },           .{ "hspice", "xyce", "" },
        .{ "ngspice", "ltspice", stream_deck }, .{ "ngspice", "spectre", stream_deck }, .{ "ngspice", "vacask", stream_deck },
    }) |pair| {
        errdefer std.debug.print("{s} -> {s}\n", .{ pair[0], pair[1] });
        const src = if (pair[2].len > 0) pair[2] else sample(pair[0]);
        var failing: testing.FailingAllocator = .init(testing.allocator, .{});
        ir.big = failing.allocator();
        const entries = try translateOnce(failing.allocator(), pair[0], pair[1], src);
        const n = failing.alloc_index;
        try testing.expect(n > 10);
        for (0..n) |i| {
            failing = .init(testing.allocator, .{ .fail_index = i });
            ir.big = failing.allocator();
            // (What is not freed, `testing.allocator` reports when the test ends.)
            // (The output buffer running out is the writer's own error.)
            const got = translateOnce(failing.allocator(), pair[0], pair[1], src) catch |e| {
                try testing.expect(e == error.OutOfMemory or e == error.WriteFailed);
                continue;
            };
            // A run that comes back at all lost no report entry on the way.
            try testing.expectEqual(entries, got);
        }
    }
}

test "a report entry that finds no memory fails the reading or the writing, whatever else succeeded" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Each of these has something to report; the report alone is out of memory.
    var fba: std.heap.FixedBufferAllocator = .init(&.{});
    var r1: ir.Report = .init(fba.allocator());
    try testing.expectError(error.OutOfMemory, readAs(a, "spectre", "// t\nsubckt s (a b)\nr1 (a b) resistor r=1k\n", &r1));
    try testing.expect(r1.lost and r1.items.items.len == 0);

    var r2: ir.Report = .init(a);
    const nl = try readAs(a, "ngspice", "t\n.bogus 1\n.end\n", &r2);
    try testing.expectEqual(0, r2.items.items.len);
    var r3: ir.Report = .init(fba.allocator());
    try testing.expectError(error.OutOfMemory, writeAs(a, "xyce", &nl, &r3));

    var r4: ir.Report = .init(fba.allocator());
    try testing.expectError(error.OutOfMemory, sprack.json.parseNetlist(a, "{\"stmts\":[{\"kind\":\"zener\"}]}", &r4));

    // A netlist translated as a stream (null: it was).
    const ng = sprack.find("ngspice").?;
    const xy = sprack.find("xyce").?;
    var aw: std.Io.Writer.Allocating = .init(a);
    var r5: ir.Report = .init(a);
    try testing.expectEqual(null, try sprack.stream.translate(a, ng, xy, "t\n.bogus 1\n.end\n", &aw.writer, &r5, &sprack.caps, .{}));
    try testing.expect(r5.items.items.len > 0);
    var r6: ir.Report = .init(fba.allocator());
    try testing.expectError(error.OutOfMemory, sprack.stream.translate(a, ng, xy, "t\n.bogus 1\n.end\n", &aw.writer, &r6, &sprack.caps, .{}));
}

test "hand-written samples parse completely" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (dialects) |d| {
        var report: ir.Report = .init(a);
        const nl = try readAs(a, d, sample(d), &report);
        errdefer std.debug.print("dialect {s}\n", .{d});
        try testing.expectEqualStrings("Core test circuit", nl.title);
        try testing.expectEqual(0, countKind(nl, .@"opaque"));
        try testing.expectEqual(0, report.items.items.len);
        try testing.expectEqual(1, countKind(nl, .subckt));
        if (std.mem.eql(u8, d, "cdl")) continue;
        try testing.expectEqual(1, countKind(nl, .tran));
        try testing.expectEqual(1, countKind(nl, .dc));
    }
}

/// The samples spell names the way each dialect's users do (`R1` in SPICE,
/// `r1` in Spectre). Spelling is preserved, so compare without it.
fn lowerNames(arena: std.mem.Allocator, stmts: []ir.Stmt) !void {
    for (stmts) |*st| {
        for (st.values()) |*v| v.* = try lowerValue(arena, v.*);
        try lowerNames(arena, st.body);
    }
}

fn lowerValue(arena: std.mem.Allocator, v: ir.Value) !ir.Value {
    return switch (v) {
        .atom => |x| .{ .atom = try std.ascii.allocLowerString(arena, x) },
        .expr => |x| .{ .expr = try std.ascii.allocLowerString(arena, x) },
        .list => |items| blk: {
            const out = try arena.alloc(ir.Value, items.len);
            for (items, 0..) |it, i| out[i] = try lowerValue(arena, it);
            break :blk .{ .list = out };
        },
        .params => |ps| blk: {
            const out = try arena.dupe(ir.Param, ps);
            for (out) |*q| q.val = try lowerValue(arena, q.val);
            break :blk .{ .params = out };
        },
        else => v,
    };
}

fn withoutNoise(arena: std.mem.Allocator, nl: ir.Netlist) !ir.Netlist {
    var out: std.ArrayList(ir.Stmt) = .empty;
    for (nl.stmts) |s| if (s.kind != .noise and s.kind != .comment) try out.append(arena, s);
    return .{ .title = nl.title, .dialect = nl.dialect, .stmts = out.items };
}

/// The statements `g` has a form for: what a netlist-only dialect (CDL)
/// keeps of a simulation deck.
fn writableIn(arena: std.mem.Allocator, nl: ir.Netlist, g: *const sprack.Grammar) !ir.Netlist {
    var out: std.ArrayList(ir.Stmt) = .empty;
    for (nl.stmts) |s| if (s.kind == .comment or g.canWrite(s.kind)) try out.append(arena, s);
    const kept: ir.Netlist = .{ .title = nl.title, .dialect = nl.dialect, .stmts = out.items };
    return sprack.withoutInert(arena, g, &kept);
}

fn droppedIn(nl: ir.Netlist, g: *const sprack.Grammar) usize {
    var n: usize = 0;
    for (nl.stmts) |s| n += @intFromBool(s.kind != .comment and !g.canWrite(s.kind));
    return n;
}

test "the five readers agree on what the circuit is" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (dialects) |d1| {
        for (dialects) |d2| {
            var report: ir.Report = .init(a);
            const cdl = sprack.find("cdl").?;
            var n1 = try writableIn(a, try withoutNoise(a, try readAs(a, d1, sample(d1), &report)), cdl);
            var n2 = try writableIn(a, try withoutNoise(a, try readAs(a, d2, sample(d2), &report)), cdl);
            if (!std.mem.eql(u8, d1, "cdl") and !std.mem.eql(u8, d2, "cdl")) {
                n1 = try withoutNoise(a, try readAs(a, d1, sample(d1), &report));
                n2 = try withoutNoise(a, try readAs(a, d2, sample(d2), &report));
            }
            try lowerNames(a, n1.stmts);
            try lowerNames(a, n2.stmts);
            errdefer std.debug.print("{s} vs {s}\n", .{ d1, d2 });
            try testing.expect(ir.sameCircuit(&n1, &n2));
        }
    }
}

test "every pair of dialects: write, read back, same circuit, no errors" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (dialects) |from| {
        for (dialects) |to| {
            var report: ir.Report = .init(a);
            const read_nl = try readAs(a, from, sample(from), &report);
            const text = try writeAs(a, to, &read_nl, &report);
            errdefer {
                std.debug.print("{s} -> {s}\n{s}\n", .{ from, to, text });
                dumpReport(&report);
            }
            try invariants(a, from, to, sample(from), text, .{});
            // A netlist-only target has no form for the sources and
            // analyses: one `unsupported` error each, and the rest intact.
            const gt = sprack.find(to).?;
            const dropped = droppedIn(read_nl, gt);
            // The samples with analyses have four or five, and LTspice loads
            // one a deck: an `invalid` error on each, with all of them written.
            var many: usize = 0;
            if (gt.unique_analysis) |u| if (!std.mem.eql(u8, from, to)) {
                for (u.kinds) |k| many += countKind(read_nl, k);
            };
            try testing.expectEqual(dropped + many, report.count(.@"error"));
            try testing.expectEqual(dropped, report.countCode(.unsupported));
            try testing.expectEqual(many, report.countCode(.invalid));
            const src_nl = try writableIn(a, read_nl, gt);

            var report2: ir.Report = .init(a);
            const back = try readAs(a, to, text, &report2);
            try testing.expectEqual(0, countKind(back, .@"opaque"));
            // VACASK is given SPICE's step cap explicitly (a `synthesized` warning).
            const mi = schema.slot(.tran, "maxstep");
            const src_tran = for (src_nl.stmts) |s| {
                if (s.kind == .tran) break s;
            } else null;
            if (report.countCode(.synthesized) > 0) for (back.stmts) |*b| {
                if (b.kind == .tran and src_tran != null and src_tran.?.at(mi) == .none) {
                    try b.own(a);
                    try b.set(a, mi, .none);
                }
            };
            try testing.expect(try sprack.sameTranslation(a, gt, &src_nl, &back));
        }
    }
}

test "M is milli in SPICE and mega in Spectre" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);

    const sp = try tr(a, "ngspice", "spectre",
        \\t
        \\R1 a 0 1M
        \\R2 a 0 1MEG
        \\R3 a 0 2.2K
        \\C1 a 0 10pF
        \\C2 a 0 1e-18
        \\.end
    , &report);
    try has(sp, "R1 (a 0) resistor r=1m\n");
    try has(sp, "R2 (a 0) resistor r=1M\n");
    try has(sp, "R3 (a 0) resistor r=2.2k\n");
    try has(sp, "C1 (a 0) capacitor c=10p\n");
    try has(sp, "C2 (a 0) capacitor c=1a\n");

    const ng = try tr(a, "spectre", "ngspice",
        \\// t
        \\r1 (a 0) resistor r=1M
        \\r2 (a 0) resistor r=1m
        \\r3 (a 0) resistor r=3*1M
    , &report);
    try has(ng, "r1 a 0 1meg\n");
    try has(ng, "r2 a 0 1m\n");
    // Inside an expression too.
    try has(ng, "r3 a 0 {3*1meg}\n");

    // Xyce has no atto and no X: fall back to an exponent rather than a wrong suffix.
    const xy = try tr(a, "hspice", "xyce",
        \\t
        \\C1 a 0 1a
        \\R1 a 0 3x
        \\.end
    , &report);
    try has(xy, "C1 a 0 1e-18\n");
    try has(xy, "R1 a 0 3meg\n");
    try clean(&report);
}

test "an analysis the target cannot express is an error naming who can, and why" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const out = try tr(a, "ngspice", "xyce",
        \\t
        \\R1 in out 1k
        \\.pz in 0 out 0 vol pz
        \\.end
    , &report);
    try testing.expect(report.hasErrors());
    try reported(&report, .@"error", "analysis 'pz' cannot be written for xyce: Xyce has no pole-zero analysis. Dialects that define it: hspice, ngspice, spectre");
    // The rest of the netlist is still produced.
    try has(out, "R1 in out 1k\n");
    try has(out, "* [sprack] not written: analysis 'pz'");

    // Where the grammar simply has no rule, it says that instead.
    // No shipped grammar has such a gap any more; a tiny one does.
    const tiny = tinyGrammar(
        \\dialect tiny
        \\lexer
        \\  title yes
        \\end
        \\rule op = ".op"
    );
    var r2: ir.Report = .init(a);
    const nl = try readAs(a, "ngspice", "t\n.op\n.tran 1n 1u\n.end\n", &r2);
    var aw: std.Io.Writer.Allocating = .init(a);
    try sprack.write(a, &tiny, &aw.writer, &nl, &r2);
    try reported(&r2, .@"error", "analysis 'tran' cannot be written for tiny: tiny.spgrammar defines no rule for it.");
}

test "nothing is dropped: a value with no place in the target is an error" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var r1: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", "t\n.tran 1n 100n 5n 0.5n uic\n.end\n", &r1);
    try has(va, "analysis tran1 tran step=1n stop=100n start=5n maxstep=0.5n icmode=\"uic\"\n");
    // VACASK records from start= on (docs/cmd-analysis-tran.md:34).
    try has(va, "start=5n");
    try testing.expect(!r1.contains(.@"error", "tran.start"));

    // HSPICE's step cap is .OPTION DELMAX; a fourth .TRAN number is nothing
    // to it (y1, docs/verification.md 4.18).
    var r2: ir.Report = .init(a);
    const hs = try tr(a, "ngspice", "hspice", "t\n.tran 1n 100n 5n 0.5n uic\n.end\n", &r2);
    try has(hs, ".option tnom=27 delmax=0.5n\n.tran 1n 100n start=5n uic\n");
    try reported(&r2, .info, "tran.maxstep is written as options.delmax, which reads back there");
    try testing.expectEqual(0, r2.count(.@"error"));

    // Spectre can say all of it, with a caveat about what UIC means.
    var r3: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre", "t\n.tran 1n 100n 5n 0.5n uic\n.end\n", &r3);
    try has(sp, "tran1 tran step=1n stop=100n start=5n maxstep=0.5n skipdc=yes\n");
    try reported(&r3, .warning, "tran.skip_dc: skipdc=yes skips the DC solve");
    try clean(&r3);
}

test "a value the target requires but the source lacks is synthesised and reported" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const ng = try tr(a, "spectre", "ngspice",
        \\// t
        \\fast tran stop=2u errpreset=conservative
    , &report);
    try has(ng, ".tran {2u/1000} 2u\n");
    try reported(&report, .warning, "ngspice needs 'step' but the source gave none");
    // A Spectre-only setting is not copied into another dialect, and not dropped quietly either.
    try reported(&report, .@"error", "tran: 'errpreset=conservative' has no spelling in ngspice");

    // Same dialect: it is kept.
    var r2: ir.Report = .init(a);
    const sp = try tr(a, "spectre", "spectre", "// t\nfast tran stop=2u errpreset=conservative\n", &r2);
    try has(sp, "fast tran stop=2u errpreset=conservative\n");
    try testing.expectEqual(0, r2.items.items.len);
}

test "lines no rule understands are errors across dialects and untouched within one" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\t
        \\R1 a 0 1k
        \\.alter second run
        \\.control
        \\run
        \\plot v(a) $ nutmeg
        \\.endc
        \\.end
    ;
    var report: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre", src, &report);
    try has(sp, "// [sprack] untranslated ngspice: .alter second run\n");
    // The control script is read (#50); Spectre has none to write it as.
    try has(sp, "// [sprack] not written: run\n// [sprack] not written: plot v(a)\n");
    try testing.expectEqual(1, report.countCode(.untranslated));
    try testing.expectEqual(1, report.countCode(.unsupported));
    try testing.expectEqual(2, report.count(.@"error"));

    // Same dialect: untouched, case and all.
    var r2: ir.Report = .init(a);
    const ng = try tr(a, "ngspice", "ngspice", src, &r2);
    try has(ng, ".alter second run\n.control\nrun\nplot v(a) $ nutmeg\n.endc\n");
    // One note says so: ngspice itself may refuse such a line.
    try testing.expectEqual(1, r2.items.items.len);
    try reported(&r2, .info, "1 statement no ngspice rule understood is written back as it was");
    try testing.expectEqual(0, r2.count(.@"error"));
}

test "the report says what crosses: a dropped block's statements, text in another syntax, a block's lines" {
    // Issue 36.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A block the target has not: its statements are counted and kept as comments.
    var r1: ir.Report = .init(a);
    const ng = try tr(a, "hspice", "ngspice", "* t\n.variation\n.element_variation\nr r=10%\nc c=5%\n.end_element_variation\n.end_variation\nR1 a 0 1k\n.end\n", &r1);
    try has(ng, "* [sprack] not written: statgroup\n* [sprack] not written: vary\n* [sprack] not written: vary\n");
    try reported(&r1, .@"error", "statement 'statistics' cannot be written for ngspice: ngspice has no statistics block");
    try reported(&r1, .@"error", ". The 3 statements it holds are not written either, and are in the output as comments");
    // A measure carried as text is the source's syntax: an error between dialects.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ngspice", "t\nV1 out 0 sin(0 1 1k)\nR1 out 0 1k\n.tran 1u 2m\n.meas tran pn1 find phnoise at=1m\n.end\n", &r2);
    try reported(&r2, .@"error", "measure.spec: carried as text: the probes, expressions and numbers in it were not translated; it is hspice text, written as it was");
    // A raw block of three lines: the message says the rest.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "hspice", "t\nR1 a 0 1k\n.control\nsave all\nop\n.endc\n.end\n", &r3);
    // A control script (#50): its analyses are the deck's in a dialect without one.
    try reported(&r3, .info, "script: hspice has no control script; the ngspice script's analyses and outputs are written as the netlist's own");
    // A word ending in a colon is no port: HSPICE reads ngspice's params: as no rule's.
    var r4: ir.Report = .init(a);
    const xy = try tr(a, "hspice", "xyce", "t\n.subckt div a b params: rt=1k\nR1 a b rt\n.ends\nx1 in mid div params: rt=2k\n.end\n", &r4);
    try testing.expect(std.mem.indexOf(u8, xy, "params: params:") == null);
    try reported(&r4, .@"error", "no hspice rule understood this line; it is in the output only as a comment: .subckt div a b params: rt=1k");
    // An instance given parameters, its subcircuit in another file: said once.
    var r5: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\nX1 a 0 msel rfmode=1\nX2 b 0 msel rfmode=0\n.end\n", &r5);
    try reported(&r5, .warning, "instance 'X1' gives parameters to subcircuit 'msel', which is not in this file; xyce has no conditional blocks");
    try testing.expectEqual(1, r5.countCode(.ambiguous));
    var r6: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\n.subckt msel a b rfmode=0\nR1 a b 1k\n.ends\nX1 a 0 msel rfmode=1\n.end\n", &r6);
    try testing.expectEqual(0, r6.countCode(.ambiguous));
}

test "ngspice forms ngspice 45 takes: .opt, .opts, .width, .parameters, % and \\ after a blank, dc before a waveform" {
    // Issue 43, docs/verification.md 4.29.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r0: ir.Report = .init(a);
    const nl = try readAs(a, "ngspice", "t\n.opt temp=127\n.opts tnom=77\n.width in=72\n.parameters a=2 b=3\n.param p1=10 %3\n.param p2=10 \\ 3\nVin1 I1 0 dc pulse(0 1 1n 1n 1n 5n 10n)\nI2 I1 0 dc pwl(0 0 1n 1m)\n.end\n", &r0);
    for (nl.stmts) |st| try testing.expect(st.kind != .@"opaque");
    var r1: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", "t\n.opt temp=127\n.opts tnom=77\n.width in=72\n.parameters c=4\nV1 a 0 dc pulse(0 1 1n 1n 1n 5n 10n)\nR1 a 0 {1k*c}\n.tran 1n 20n\n.end\n", &r1);
    try has(xy, ".options device temp=127 tnom=77\n");
    try has(xy, ".param c=4\n");
    try has(xy, "V1 a 0 pulse(0 1 1n 1n 1n 5n 10n)\n");
    try reported(&r1, .info, "options: 'in=72' is not written: ngspice's .width in= only sets the columns of printed input");
    try clean(&r1);
    // ngspice's modulo and integer division: none of the others has the second.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\n.param p1=10 %3\n.param p2=10 \\ 3\n.end\n", &r2);
    try reported(&r2, .@"error", "operator 'mod' has no spelling in xyce");
    try reported(&r2, .@"error", "operator 'idiv' has no spelling in xyce. Dialects that have it: ngspice");
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "ngspice", "t\n.param p2=10 \\ 3\n.end\n", &r3), ".param p2={10 \\ 3}\n");
}

test "a current as the output of .tf: ngspice i(), VACASK's branch unknown, an error where it is not measured" {
    // Issue 43, docs/verification.md 4.29.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nVin in 0 1\nR1 in out 1k\nVmeasure out 0 0\n.tf i(Vmeasure) Vin\n.end\n";
    var r1: ir.Report = .init(a);
    const nl = try readAs(a, "ngspice", src, &r1);
    try testing.expectEqual(1, countKind(nl, .tf));
    try has(try tr(a, "ngspice", "ngspice", src, &r1), ".tf i(Vmeasure) Vin\n");
    try clean(&r1);
    var r2: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", src, &r2);
    try has(va, "analysis tf1 dcxf out=\"Vmeasure:flow(br)\"\n");
    try testing.expectEqual(0, r2.count(.@"error"));
    // Read back, the suffix marks the current; a plain node is still `out`.
    var r3: ir.Report = .init(a);
    const back = try readAs(a, "vacask", va, &r3);
    try testing.expectEqual(1, countKind(back, .tf));
    for (back.stmts) |st| if (st.kind == .tf) try testing.expectEqualStrings("Vmeasure", st.get("iout").atom);
    var r4: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "vacask", "t\nV1 a 0 1\nR1 a 0 1k\n.tf v(a) V1\n.end\n", &r4), "analysis tf1 dcxf out=\"a\"\n");
    var r5: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "hspice", src, &r5);
    try reported(&r5, .@"error", "tf.iout: this grammar has no HSPICE form for a current as the output of .TF");
}

test "the URC line: ngspice's U is a lossyline of family urc; Xyce's U is digital" {
    // Issue 43, docs/verification.md 4.29.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nV1 in 0 1\nU1 in out 0 umod L=100u N=10\nRL out 0 10k\n.model umod URC(K=1.5 FMAX=1G RPERL=1000 CPERL=1p)\n.op\n.end\n";
    var r1: ir.Report = .init(a);
    const nl = try readAs(a, "ngspice", src, &r1);
    try testing.expectEqual(1, countKind(nl, .lossyline));
    const same = try tr(a, "ngspice", "ngspice", src, &r1);
    try has(same, "U1 in out 0 umod l=100u n=10\n");
    try has(same, ".model umod urc k=1.5 fmax=1g rperl=1000 cperl=1p\n");
    try clean(&r1);
    var r2: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", src, &r2);
    try reported(&r2, .@"error", "Xyce's U is a digital device");
}

test "small forms a target has: print all and .plot into Xyce, HB harmonics, maxord into Spectre" {
    // Issue 44.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nV1 in 0 1\nR1 in out 1k\nR2 out 0 1k\n.tran 1u 2u\n.print tran all\n.plot tran v(out)\n.options method=gear maxord=1\n.end\n";
    var r1: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", src, &r1);
    try has(xy, ".print tran v(*)\n.print tran v(out)\n");
    try reported(&r1, .warning, "print.style: Xyce has no .plot; the signals are printed instead");
    try clean(&r1);
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "spectre", src, &r2), "tran1 tran step=1u stop=2u method=euler\n");
    try reported(&r2, .info, "options.maxord = 1 is backward Euler: spectre has no maximum order, so it is written as the method euler");
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "spectre", "t\nV1 a 0 1\nR1 a 0 1k\n.options method=gear maxord=4\n.tran 1u 2u\n.end\n", &r3);
    try reported(&r3, .info, "options.maxord = 4 is not written: spectre has no maximum order");
    try testing.expectEqual(0, r3.count(.@"error"));
    var r4: ir.Report = .init(a);
    try has(try tr(a, "hspice", "xyce", "t\nV1 a 0 1\nR1 a 0 1k\n.hb tones=1k nharms=2\n.end\n", &r4), ".hb 1k\n.options hbint numfreq=2\n");
    try clean(&r4);
}

test "comments, blank lines and trailing comments are carried over" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre",
        \\Bias network
        \\* --- supplies ---
        \\V1 vdd 0 1.8 $ core supply
        \\
        \\
        \\* divider
        \\R1 vdd mid 10k ; top
        \\R2 mid 0
        \\* (ten kilohm, see spec)
        \\+ 10k
        \\.end
    , &report);
    try has(sp,
        \\// Bias network
        \\simulator lang=spectre insensitive=yes
        \\global 0
        \\// --- supplies ---
        \\V1 (vdd 0) vsource dc=1.8 // core supply
        \\
        \\// divider
        \\R1 (vdd mid) resistor r=10k // top
        \\R2 (mid 0) resistor r=10k
        \\// (ten kilohm, see spec)
        \\
    );
    try testing.expectEqual(0, report.items.items.len);

    // VACASK block comments come out as comment lines.
    var r2: ir.Report = .init(a);
    const ng = try tr(a, "vacask", "ngspice", "t\nmodel r sp_resistor\n/* two\n   lines */\nr1 (a 0) r r=1k // load\n", &r2);
    try has(ng, "* two\n* lines\nr1 a 0 1k r $ load\n");
}

test "source spelling is preserved" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    // ngspice ignores case, so VDD, Vdd and vdd are one node. The first
    // spelling wins everywhere, which is what a case-sensitive target needs.
    const sp = try tr(a, "ngspice", "spectre",
        \\t
        \\.param Wn=2u
        \\.subckt Inv In Out VDD
        \\MN1 Out In 0 0 NCH W={WN} L=180n
        \\.ends
        \\.model NCH nmos level=54
        \\XU1 a b Vdd INV
        \\Vsup vdd 0 1.8
        \\.dc VSUP 0 1.8 0.1
        \\.end
    , &report);
    try has(sp, "parameters Wn=2u\n");
    try has(sp, "subckt Inv (In Out VDD)\n");
    try has(sp, "MN1 (Out In 0 0) NCH w=Wn l=180n\n");
    try has(sp, "model NCH bsim4 type=n\n");
    try has(sp, "XU1 (a b VDD) Inv\n");
    try has(sp, "Vsup (VDD 0) vsource dc=1.8\n");
    try has(sp, "dc1 dc dev=Vsup start=0 stop=1.8 step=0.1\n");
    try clean(&report);
}

test "model cards: level numbers and master names are mapped, with a warning" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\t
        \\.model nch nmos level=54 version=4.5 vth0=0.4
        \\.model pch pmos (level=54 version=4.5 vth0=-0.4)
        \\.model dx d is=1e-14
        \\M1 out in 0 0 nch w=1u l=0.18u
        \\M2 out in vdd vdd pch w=2u l=0.18u
        \\.end
    ;
    var report: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", src, &report);
    try has(xy, ".model nch nmos level=14 version=4.5 vth0=0.4\n");
    // Three cards, one caveat: it names the first and counts the rest.
    try reported(&report, .warning, "model 'nch' (bsim4) and 2 more model cards: ngspice and xyce ship different implementations and versions");
    try testing.expectEqual(1, report.countCode(.caveat));

    var r2: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre", src, &r2);
    try has(sp, "model nch bsim4 type=n version=4.5 vth0=0.4\n");
    try has(sp, "model pch bsim4 type=p version=4.5 vth0=-0.4\n");
    try has(sp, "model dx diode is=1e-14\n");
    try has(sp, "M1 (out in 0 0) nch w=1u l=0.18u\n");

    // And back: Spectre does not say what kind of device M1 is. The model does.
    var r3: ir.Report = .init(a);
    const hs = try tr(a, "spectre", "hspice", sp, &r3);
    try has(hs, ".model nch nmos level=54 version=4.5 vth0=0.4\n");
    try has(hs, "M1 out in 0 0 nch w=1u l=0.18u\n");
    try clean(&r3);

    // VACASK: the model names the OSDI module, which has to be loaded.
    var r4: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", src, &r4);
    try has(va, "load \"spice/bsim4v8.osdi\"\n");
    try has(va, "model nch sp_bsim4v8 (type=1 vth0=0.4)\n");
    try reported(&r4, .warning, "model 'nch' and 1 more card in this file: version not written");
    try has(va, "M1 (out in 0 0) nch w=1u l=0.18u\n");
    // It ships no HiSIM2: say so, and say who has.
    _ = try tr(a, "ngspice", "vacask", "t\n.model nh nmos level=68\n.end\n", &r4);
    try reported(&r4, .@"error", "vacask.spgrammar has no spelling for model family 'hisim2 n'. Defined by: hspice, ngspice, spectre");

    // FinFET models: HSPICE level 72 is the Xyce level of its version; ngspice has it only as a module given.
    var r5: ir.Report = .init(a);
    const fin = "t\n.model nfet nmos level=72 version=107\nM1 d g 0 0 nfet nfin=2\n.end\n";
    try has(try tr(a, "hspice", "xyce", fin, &r5), ".model nfet nmos level=107\n");
    try reported(&r5, .info, "model 'nfet': version=107 is said by the xyce nmos level=107 spelling and is not written");
    try has(try tr(a, "hspice", "spectre", fin, &r5), "model nfet bsimcmg type=n version=107\n");
    try clean(&r5);
    _ = try tr(a, "hspice", "ngspice", fin, &r5);
    try reported(&r5, .@"error", "ngspice has no built-in bsimcmg; it runs one as a compiled module given to the translation: --provide bsimcmg=FILE");
}

test "a model card's level by its version or by its instances' terminals (when)" {
    // docs/verification.md 4.21: Xyce's VBIC is level 11 with three terminals
    // and 12 with four; its BSIM-CMG one level per version.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const v = try tr(a, "ngspice", "xyce", "t\n.model q1 npn level=4 is=1e-16\nQ1 c b e s t q1\n.model q2 npn level=4 is=1e-16\nQ2 c b e q2\nV1 c 0 1\nV2 b 0 0.8\nV3 e 0 0\nV4 s 0 0\nR1 t 0 1k\n.op\n.end\n", &r1);
    try has(v, ".model q1 npn level=12 is=0.1f\n");
    try has(v, ".model q2 npn level=11 is=0.1f\n");
    // Instances of both counts: the one model, and a warning.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", "t\n.model q3 npn level=4\nQ3 c b e q3\nQ4 c b e s q3\n.end\n", &r2), ".model q3 npn level=11\n");
    try reported(&r2, .warning, "model 'q3' (vbic): instances with 3 and with 4 terminals name it");
    // No instance to tell by (a library): the plain spelling, said.
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", "t\n.model q4 npn level=4\n.end\n", &r3), ".model q4 npn level=11\n");
    try reported(&r3, .warning, "model 'q4' (vbic): xyce writes another model by its conditions, and no instance in this file names it");
    // A version none of the levels is: the newest, said.
    var r4: ir.Report = .init(a);
    try has(try tr(a, "hspice", "xyce", "t\n.model nf nmos level=72 version=109\n.end\n", &r4), ".model nf nmos level=111 version=109\n");
    try reported(&r4, .warning, "version=109 is none of the values the spellings name");
    var r5: ir.Report = .init(a);
    try has(try tr(a, "hspice", "xyce", "t\n.model nf pmos level=72\n.end\n", &r5), ".model nf pmos level=111\n");
    try reported(&r5, .warning, "it gives no version");
    // Read back, any of the levels is the family.
    var r6: ir.Report = .init(a);
    try has(try tr(a, "xyce", "hspice", "t\n.model nf nmos level=107\n.model q npn level=12\n.end\n", &r6), ".model nf nmos level=72\n");
}

test "resistor and capacitor cards: ngspice's other names, and Xyce's cards take only theirs" {
    // docs/verification.md 4.22.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\n.model rnd r rsh=120 tc1r=1.422e-3 tc2r=6.569e-7 tnom=30 w=1u\nr1 a 0 rnd w=0.42 l=4.2\n.model cm c cox=1m capsw=1n w=1u\nc1 a 0 cm l=1u\nV1 a 0 1\n.op\n.end\n";
    var r1: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", src, &r1);
    try has(xy, ".model rnd r rsh=120 tc1=1.422m tc2=0.6569u tnom=30 defw=1u\n");
    try has(xy, ".model cm c cj=1m cjsw=1n defw=1u\n");
    try reported(&r1, .info, "model 'rnd': the parameter 'tc1r' is spelled 'tc1' in xyce");
    try reported(&r1, .info, "model 'cm': the parameter 'cox' is spelled 'cj' in xyce");
    try clean(&r1);
    // A name Xyce's card does not take: a loss, not a copy Xyce ignores.
    var r2: ir.Report = .init(a);
    const lost = try tr(a, "ngspice", "xyce", "t\n.model rk r rsh=1k kf=1e-25 af=1\n.model cc c cap=1p\n.model rr r res=5\n.end\n", &r2);
    try has(lost, ".model rk r rsh=1k\n");
    try has(lost, ".model cc c\n");
    try reported(&r2, .@"error", "model 'rk': kf=1e-25 not written: the resistor card of xyce takes no such parameter; it takes narrow, defw, r, rsh, tc1, tc2, tce, tnom");
    try reported(&r2, .@"error", "model 'rk': af=1 not written");
    try reported(&r2, .@"error", "model 'cc': cap=1p not written: the capacitor card of xyce takes no such parameter");
    try reported(&r2, .@"error", "model 'rr': r not written: Xyce lists R among its resistor card's parameters");
    try testing.expectEqual(4, r2.count(.@"error"));
    // From a dialect with no table for the family: each name as written.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "hspice", "xyce", "t\n.model cm c cj=1m cox=2m\n.end\n", &r3);
    try reported(&r3, .@"error", "model 'cm': cox=2m not written: the capacitor card of xyce takes no such parameter");
    // A target without `only` keeps the name as written.
    var r4: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "hspice", src, &r4), ".model rnd r rsh=120 tc1r=1.422m tc2r=0.6569u tnom=30 w=1u\n");
}

test "card parameters into Xyce: every name its device declares, ngspice's other names, the rest a loss" {
    // docs/verification.md 4.23: the tables are tools/param_lists.py's.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", "t\n.model d1 d is=1e-14 mj=0.3 ik=1m tref=25 tlev=1 cta=1m\n.model q1 npn tref=25 trc=1m\n.model n1 nmos level=54 version=4.5 vth0=0.4\n.end\n", &r1);
    try has(xy, ".model d1 d is=1e-14 m=0.3 ikf=1m tnom=25\n");
    try has(xy, ".model q1 npn tnom=25\n");
    try has(xy, ".model n1 nmos level=14 version=4.5 vth0=0.4\n");
    try reported(&r1, .info, "model 'd1': the parameter 'mj' is spelled 'm' in xyce");
    try reported(&r1, .@"error", "model 'd1': tlev=1 not written: the diode card of xyce takes no such parameter");
    try reported(&r1, .@"error", "model 'd1': cta=1m not written");
    try reported(&r1, .@"error", "model 'q1': trc=1m not written: the bjt card of xyce takes no such parameter");
    try testing.expectEqual(3, r1.count(.@"error"));
    // A card Xyce refuses by its level is another model: no name of it is checked.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\n.model d3 d level=3 is=1e-14 tlev=1 xw=1u\n.end\n", &r2);
    try testing.expectEqual(1, r2.count(.@"error"));
    // Safe-operating-area parameters change no current: one warning a file.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\n.model q2 npn level=4 vbe_max=1.6 is=1e-16\nQ1 c b e s t q2\n.end\n", &r3);
    try reported(&r3, .warning, "vbe_max not written: Xyce's VBIC has no safe-operating-area check");
    try clean(&r3);
}

test "card parameters into VACASK: every name its module's OSDI descriptor lists, the rest a loss" {
    // docs/verification.md 4.23: the tables are tools/param_lists.py vacask's.
    // VACASK refuses a card with a name its module lacks ("Parameter ... not found").
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", "t\n.model d1 d is=1e-14 mj=0.3 ik=1m tref=25 tlev=1 foo=1\n.model q1 npn tref=25 trc=1m tnf1=1e-4\n.end\n", &r1);
    try has(va, "model d1 sp_diode (is=1e-14 m=0.3 ikf=1m tnom=25 tlev=1)\n");
    try has(va, "model q1 sp_bjt (type=1 tnom=25 trc1=1m tnf1=1e-4)\n");
    try reported(&r1, .info, "model 'd1': the parameter 'ik' is spelled 'ikf' in vacask");
    try reported(&r1, .@"error", "model 'd1': foo=1 not written: the diode card of vacask takes no such parameter");
    try testing.expectEqual(1, r1.count(.@"error"));
    // BSIM4's rgeomod is an instance parameter of sp_bsim4v8: at 0, its default, a warning.
    var r2: ir.Report = .init(a);
    const b4 = try tr(a, "ngspice", "vacask", "t\n.model n1 nmos level=54 rgeomod=0 vth0=0.4\n.model n2 nmos level=54 rgeomod=1\n.end\n", &r2);
    try has(b4, "model n1 sp_bsim4v8 (type=1 vth0=0.4)\nmodel n2 sp_bsim4v8 (type=1)\n");
    try reported(&r2, .warning, "model 'n1': rgeomod not written: sp_bsim4v8 takes rgeomod on the instance only");
    try reported(&r2, .@"error", "model 'n2': rgeomod not written");
    try testing.expectEqual(1, r2.count(.@"error"));
    // PSP 103.6 names psp103v4 lacks: a warning at the neutral value, else an
    // error; the safe-operating-area check is absent: a warning.
    var r3: ir.Report = .init(a);
    const psp = try tr(a, "ngspice", "vacask", "t\n.model p1 psp103va type=1 thecso=2 swsoa=1 toxo=1.5n\n.model p2 psp103va type=1 thecso=1\n.model v1 npn level=4 vbe_max=1.6 is=1e-16\nQ1 c b e s v1\n.end\n", &r3);
    try has(psp, "model p1 psp103va (type=1 toxo=1.5n)\nmodel p2 psp103va (type=1)\n");
    try reported(&r3, .warning, "model 'p1': thecso not written: VACASK's PSP103 (psp103v4, PSP 103.4) has no such parameter; at 2 it changes nothing");
    try reported(&r3, .warning, "model 'p1': swsoa not written: VACASK's PSP103 (psp103v4) has no safe-operating-area check");
    try reported(&r3, .warning, "model 'v1': vbe_max not written: VACASK's VBIC (vbic_1p3.va) has no safe-operating-area check");
    try reported(&r3, .@"error", "model 'p2': thecso not written");
    try testing.expectEqual(1, r3.count(.@"error"));
}

test "Xyce's reserved names: renamed in sweeps, data columns and alters; temper and hertz are shadowed" {
    // docs/verification.md 4.15.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", "t\n.param vt=3.5m\nV1 a 0 1\nR1 a 0 {1k*(1+vt)}\n.dc vt 1m 5m 1m\n.end\n", &r1), ".dc vt__p 1m 5m 1m\n");
    var r2: ir.Report = .init(a);
    const xy = try tr(a, "hspice", "xyce", "t\n.param vt=3.5m\nV1 a 0 1\nR1 a 0 '1k*(1+vt)'\n.tran 1n 10n sweep vt 1m 5m 1m\n.data d1 vt\n+ 1m\n+ 2m\n.enddata\n.end\n", &r2);
    try has(xy, ".step vt__p 1m 5m 1m\n");
    try has(xy, ".data d1 vt__p 1m 2m\n");
    // Spectre's temper and hertz are parameters, not its variables (temp).
    const sp = "simulator lang=spectre\nparameters temper=4 hertz=3\nV1 (a 0) vsource dc=1\nR1 (a 0) resistor r=1k*temper+hertz+temp\nop1 dc\n";
    var r3: ir.Report = .init(a);
    const sx = try tr(a, "spectre", "xyce", sp, &r3);
    try has(sx, ".param temper__p=4 hertz__p=3\n");
    try has(sx, "R1 a 0 {1k*temper__p+hertz__p+temp}\n");
    try reported(&r3, .info, "parameter 'temper' is written as 'temper__p'");
    var r4: ir.Report = .init(a);
    try has(try tr(a, "spectre", "spectre", sp, &r4), "R1 (a 0) resistor r=1k*temper+hertz+temp\n");
    // ngspice takes both words for its variables: an error each.
    var r5: ir.Report = .init(a);
    try has(try tr(a, "spectre", "ngspice", sp, &r5), "R1 a 0 {1k*temper+hertz+temper}\n");
    try reported(&r5, .@"error", "the parameter 'temper' is a variable of ngspice under that name");
    try reported(&r5, .@"error", "the parameter 'hertz' is a variable of ngspice under that name");
}

test "an unknown level is an error across dialects, not a guess" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const out = try tr(a, "ngspice", "xyce", "t\n.model nx nmos level=11 foo=1\n.end\n", &report);
    try reported(&report, .warning, "model type 'nmos' with these parameters is not in the ngspice models table");
    try reported(&report, .@"error", "type 'nmos' with these parameters is not in the ngspice models table");
    try has(out, ".model nx nmos level=11 foo=1\n");
    // 99 and up: ngspice runs level 1, and says so (#48).
    var r1: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", "t\n.model nx nmos level=1040\n.end\n", &r1), ".model nx nmos level=1\n");
    try reported(&r1, .warning, "with level=1040: ngspice takes it as the mos1 model");
}

test "names: prefix letters and case" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Spectre names carry no type letter; SPICE needs one.
    var r1: ir.Report = .init(a);
    const ng = try tr(a, "spectre", "ngspice",
        \\// t
        \\load (out 0) resistor r=50
        \\bias (vdd 0) vsource dc=1.8
        \\amp (in out) opamp gain=10
        \\I0 (in out) opamp gain=10
    , &r1);
    try has(ng, "rload out 0 50\n");
    try has(ng, "vbias vdd 0 dc 1.8\n");
    try has(ng, "xamp in out opamp gain=10\n");
    try has(ng, "XI0 in out opamp gain=10\n");
    try reported(&r1, .info, "renamed 'load' to 'rload'");
    try clean(&r1);

    // Two names that differ only by case cannot both exist in SPICE.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "spectre", "ngspice",
        \\// t
        \\r1 (Vdd 0) resistor r=1k
        \\r2 (vdd 0) resistor r=1k
    , &r2);
    try reported(&r2, .@"error", "'Vdd' and 'vdd' are different names in the source but the same name in ngspice");

    // Spectre to VACASK keeps both: both are case sensitive.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "spectre", "vacask", "// t\nr1 (Vdd 0) resistor r=1k\nr2 (vdd 0) resistor r=1k\n", &r3);
    try clean(&r3);
}

test "SPICE lines that only parse by trying alternatives" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const nl = try readAs(a, "ngspice",
        \\t
        \\.model qmod npn bf=100
        \\.model rmod r rsh=100
        \\Q1 c b e qmod
        \\Q2 c b e sub qmod
        \\Q3 c b e qmod 2
        \\Q4 c b e sub qmod 2
        \\R1 a b 1k
        \\R2 a b rmod l=10u w=1u
        \\R3 a b 1k rmod
        \\X1 a b c amp
        \\X2 a amp gain=2
        \\.end
    , &report);
    try testing.expectEqual(0, countKind(nl, .@"opaque"));
    const q = nl.stmts[2..6];
    for (q) |s| try testing.expectEqualStrings("qmod", s.get("master").atom);
    try testing.expect(q[0].get("s") == .none and q[0].get("area") == .none);
    try testing.expectEqualStrings("sub", q[1].get("s").atom);
    try testing.expect(q[2].get("s") == .none and q[2].get("area") == .num);
    try testing.expectEqualStrings("sub", q[3].get("s").atom);
    try testing.expect(q[3].get("area") == .num);
    try testing.expect(nl.stmts[6].get("r") == .num and nl.stmts[6].get("master") == .none);
    try testing.expect(nl.stmts[7].get("r") == .none);
    try testing.expectEqualStrings("rmod", nl.stmts[7].get("master").atom);
    try testing.expect(nl.stmts[8].get("r") == .num);
    try testing.expectEqualStrings("rmod", nl.stmts[8].get("master").atom);
    try testing.expectEqual(3, nl.stmts[9].get("nodes").list.len);
    try testing.expectEqualStrings("amp", nl.stmts[10].get("master").atom);

    // HSPICE: a bare name is a parameter unless a model of that name exists.
    var r2: ir.Report = .init(a);
    const hs = try readAs(a, "hspice",
        \\t
        \\.model rmod r rsh=100
        \\R1 a b rval
        \\R2 a b rmod l=10u
        \\.end
    , &r2);
    try testing.expectEqualStrings("rval", hs.stmts[1].get("r").expr);
    try testing.expect(hs.stmts[2].get("r") == .none);
    try testing.expectEqualStrings("rmod", hs.stmts[2].get("master").atom);
}

test "sources: every waveform, and what each target can say" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre",
        \\t
        \\V1 a 0 SIN(0.9 0.1 1MEG)
        \\V2 b 0 PWL(0 0 1n 1.8 2n 0)
        \\V3 c 0 EXP(0 5 1u 2u 6u 3u)
        \\V4 d 0 sin(0 1 1k) ac 1
        \\.end
    , &report);
    try has(sp, "V1 (a 0) vsource type=sine sinedc=0.9 ampl=0.1 freq=1M\n");
    try has(sp, "V2 (b 0) vsource type=pwl wave=[0 0 1n 1.8 2n 0]\n");
    try has(sp, "V3 (c 0) vsource type=exp val0=0 val1=5 td1=1u tau1=2u td2=6u tau2=3u\n");
    try has(sp, "V4 (d 0) vsource mag=1 type=sine sinedc=0 ampl=1 freq=1k\n");
    const xy = try tr(a, "spectre", "xyce", sp, &report);
    try has(xy, "V1 a 0 sin(0.9 0.1 1meg)\n");
    try has(xy, "V2 b 0 pwl(0 0 1n 1.8 2n 0)\n");
    try testing.expectEqual(0, report.items.items.len);

    // Frequency modulation exists in the SPICE family only.
    var r2: ir.Report = .init(a);
    // ngspice puts the modulating frequency third and the carrier fifth.
    try has(try tr(a, "ngspice", "hspice", "t\nV1 a 0 SFFM(0 1 20k 5 1k)\n.end\n", &r2), "V1 a 0 sffm(0 1 1k 5 20k)\n");
    try clean(&r2);
    _ = try tr(a, "ngspice", "spectre", "t\nV1 a 0 SFFM(0 1 20k 5 1k)\n.end\n", &r2);
    try reported(&r2, .@"error", "vsource.wave = sffm has no spelling in spectre");

    // VACASK: a PWL is a vector of time, value pairs.
    var r3: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", "t\nV1 a 0 SIN(0.9 0.1 1MEG)\nV2 b 0 PWL(0 0 1n 1)\n.end\n", &r3);
    try has(va, "V1 (a 0) vsource type=\"sine\" sinedc=0.9 ampl=0.1 freq=1M\n");
    try has(va, "V2 (b 0) vsource type=\"pwl\" wave=[0, 0, 1n, 1]\n");
    try clean(&r3);
}

test "libraries and includes" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const sp = try tr(a, "hspice", "spectre",
        \\t
        \\.lib '/pdk/Models/corners.lib' TT
        \\.include "Cells/inv.sp"
        \\.lib ff
        \\.param vth=0.3
        \\.endl ff
        \\.end
    , &report);
    try has(sp, "include \"/pdk/Models/corners.lib\" section=TT\n");
    try has(sp, "include \"Cells/inv.sp\"\n");
    try has(sp, "section ff\nparameters vth=0.3\nendsection ff\n");
    const ng = try tr(a, "spectre", "ngspice", sp, &report);
    try has(ng, ".lib \"/pdk/Models/corners.lib\" TT\n");
    try clean(&report);
}

test "a dialect chosen at compile time" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Ng = sprack.Dialect("ngspice");
    const Sp = sprack.Dialect("spectre");
    var report: ir.Report = .init(a);
    const nl = try Ng.read(a, "t\nR1 a 0 1k\n.end\n", &report);
    var aw: std.Io.Writer.Allocating = .init(a);
    try Sp.write(a, &aw.writer, &nl, &report);
    try has(aw.written(), "R1 (a 0) resistor r=1k\n");
}

test "a grammar loaded at run time writes and reads byte for byte as the built-in" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: sprack.grammar.Diag = .{};
    const loaded = try sprack.resolve(a, testing.io, "grammars/ngspice.spgrammar", &diag);
    const builtin = sprack.find("ngspice").?;
    try testing.expect(loaded != builtin);
    for (dialects) |d| {
        var r1: ir.Report = .init(a);
        var r2: ir.Report = .init(a);
        const nl = try readAs(a, d, sample(d), &r1);
        _ = try readAs(a, d, sample(d), &r2);
        var w1: std.Io.Writer.Allocating = .init(a);
        var w2: std.Io.Writer.Allocating = .init(a);
        try sprack.write(a, builtin, &w1.writer, &nl, &r1);
        try sprack.write(a, loaded, &w2.writer, &nl, &r2);
        try testing.expectEqualStrings(w1.written(), w2.written());
        try testing.expectEqual(r1.items.items.len, r2.items.items.len);

        // Read back with each: the same statements, as JSON.
        var j1: std.Io.Writer.Allocating = .init(a);
        var j2: std.Io.Writer.Allocating = .init(a);
        try sprack.json.writeNetlist(&j1.writer, &try sprack.read(a, builtin, w1.written(), &r1));
        try sprack.json.writeNetlist(&j2.writer, &try sprack.read(a, loaded, w1.written(), &r2));
        try testing.expectEqualStrings(j1.written(), j2.written());
    }
}

test "a dialect's own options round-trip, also as statements added from another dialect" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\n.options plotwinsize=0 numdgt=15\n.op\n.end\n";
    var r1: ir.Report = .init(a);
    try testing.expectEqualStrings(src, try tr(a, "ltspice", "ltspice", src, &r1));
    try testing.expectEqual(0, r1.items.items.len);

    // The same statement in a netlist from elsewhere, marked as LTspice's.
    const json =
        \\{"title":"t","dialect":"sprack","stmts":[{"kind":"options","params":{"plotwinsize":"0","numdgt":"15"},"dialect":"ltspice"},{"kind":"op"}]}
    ;
    var r2: ir.Report = .init(a);
    const nl = try sprack.json.parseNetlist(a, json, &r2);
    try testing.expectEqualStrings(src, try writeAs(a, "ltspice", &nl, &r2));
    try clean(&r2);
    var r3: ir.Report = .init(a);
    _ = try writeAs(a, "ngspice", &nl, &r3);
    try reported(&r3, .@"error", "options: 'plotwinsize=0' has no spelling in ngspice");
}

/// `src` read as `from`, through the JSON the Python package uses, then
/// written as `to`.
fn viaJson(a: std.mem.Allocator, from: []const u8, to: []const u8, src: []const u8, report: *ir.Report) ![]const u8 {
    const nl = try readAs(a, from, src, report);
    var j: std.Io.Writer.Allocating = .init(a);
    try sprack.json.writeNetlist(&j.writer, &nl);
    const back = try sprack.json.parseNetlist(a, j.written(), report);
    return writeAs(a, to, &back, report);
}

test "Schemify decks: paths, scopes, control blocks and XSPICE survive the JSON trip" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Paths survive the JSON trip; pre_osdi, a .control command, stays bare.
    const ng =
        \\t
        \\.lib "models.lib" tt
        \\.include "extra.inc"
        \\AU1 [ clk rst cmp ] [ d_7 eoc ] sar_m
        \\AU2 [ A ] [ y ] dinv
        \\.model dinv d_cosim simulation="dinv.vvp"
        \\.control
        \\pre_osdi amp.osdi
        \\.endc
        \\.control
        \\run
        \\.endc
        \\.end
        \\
    ;
    var r1: ir.Report = .init(a);
    try testing.expectEqualStrings(ng, try viaJson(a, "ngspice", "ngspice", ng, &r1));
    try clean(&r1);
    // A bare relative file name is a path too.
    var r0: ir.Report = .init(a);
    try has(try viaJson(a, "ngspice", "xyce", "t\n.lib models.lib tt\n.include extra.inc\n.end\n", &r0), ".lib \"models.lib\" tt\n.include \"extra.inc\"\n");
    try clean(&r0);
    // XSPICE is ngspice's alone, and the reason says so.
    var r2: ir.Report = .init(a);
    _ = try viaJson(a, "ngspice", "xyce", ng, &r2);
    try reported(&r2, .@"error", "XSPICE code models are ngspice's");

    // Nets are local to a subcircuit: `IN` inside and `in` outside are
    // different nets, not a case collision. In one scope they still are.
    const sc =
        \\t
        \\.subckt inv IN OUT
        \\R1 IN OUT 1k
        \\.ends inv
        \\.subckt buf a y
        \\R1 a y 1k
        \\.ends buf
        \\X1 in out inv
        \\.end
        \\
    ;
    var r5: ir.Report = .init(a);
    const nl = try sprack.json.parseNetlist(a,
        \\{"title":"t","dialect":"sprack","stmts":[
        \\ {"kind":"subckt","name":"inv","ports":["IN","OUT"],"body":[{"kind":"resistor","name":"R1","pos":"IN","neg":"OUT","r":"1k"}]},
        \\ {"kind":"subckt","name":"buf","ports":["a","y"],"body":[{"kind":"resistor","name":"R1","pos":"a","neg":"y","r":"1k"}]},
        \\ {"kind":"instance","name":"X1","nodes":["in","out"],"master":"inv"}]}
    , &r5);
    try testing.expectEqualStrings(sc, try writeAs(a, "ngspice", &nl, &r5));
    try clean(&r5);
    var r6: ir.Report = .init(a);
    _ = try tr(a, "spectre", "ngspice", "// t\nr1 (in Out) resistor r=1k\nr2 (IN out) resistor r=1k\n", &r6);
    try reported(&r6, .@"error", "'in' and 'IN' are different names in the source but the same name in ngspice");
}

test "JSON is the netlist: what a plain string would not read back as is tagged" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // `sprack read | sprack write` is `sprack translate`. Each of these once
    // came out different: the version as {3.3.0}, the print not written,
    // the model card not at all (a JSON object cannot hold toxref twice).
    const src =
        \\t
        \\.model n3 nmos level=49 version=3.3.0
        \\.model p1 pmos level=54 toxref=1.26n vsat=69000 toxref=1.3n
        \\.print dc -i(vc) vids#branch
        \\R1 a 0 {13}
        \\.end
        \\
    ;
    var r: ir.Report = .init(a);
    const nl = try readAs(a, "ngspice", src, &r);
    const json = try jsonOf(a, &nl);
    // A version and a signal are plain strings; only what would read
    // otherwise is tagged.
    try has(json, "\"params\":{\"version\":\"3.3.0\"}");
    try has(json, "\"params\":[[\"toxref\",\"1.26e-9\"],[\"vsat\",\"69000\"],[\"toxref\",\"1.3e-9\"]]");
    try has(json, "\"signals\":[\"-i(vc)\",\"i(vids)\"]");
    try has(json, "\"r\":{\"expr\":\"13\"}");
    var r2: ir.Report = .init(a);
    const back = try sprack.json.parseNetlist(a, json, &r2);
    try testing.expectEqual(0, r2.items.items.len);
    try testing.expect(nl.eql(&back));
    try testing.expectEqualStrings(try writeAs(a, "ngspice", &nl, &r), try writeAs(a, "ngspice", &back, &r2));
    try has(try writeAs(a, "ngspice", &back, &r2), "t\n.model n3 nmos level=8 version=3.3.0\n.model p1 pmos level=14 toxref=1.26n vsat=69000 toxref=1.3n\n.print dc -i(vc) i(vids)\nR1 a 0 {13}\n");

    // By hand, as the Python package writes it: the same forms, and the
    // tags where a plain string means something else.
    var r3: ir.Report = .init(a);
    const hand = try sprack.json.parseNetlist(a,
        \\{"title":"a \"quoted\" title\twith a tab","stmts":[
        \\ {"kind":"model","name":"m","family":"bsim3","polarity":"n","params":{"version":"3.2.4","word":{"raw":"a.b"},"file":{"str":"m.dat"},"k":{"expr":"13"},"on":true,"n":3,"x":2.5}},
        \\ {"kind":"print","style":"print","analysis":"dc","signals":["v(a)","-i(vc)",{"expr":"v(a)*2"},"all"]},
        \\ {"kind":"param","params":[["a",1],["dev/gauss","0.1"],["b","2"],["dev/gauss","0.2"]]},
        \\ {"kind":"comment","raw":"","blank":true},
        \\ {"kind":"resistor","name":"R1","pos":"a","neg":0,"r":"1k","tail":"back\\slash \u0007"}]}
    , &r3);
    try testing.expectEqual(0, r3.items.items.len);
    const ps = hand.stmts[0].get("params").params;
    try testing.expectEqualStrings("3.2.4", ps[0].val.atom);
    try testing.expectEqualStrings("a.b", ps[1].val.atom);
    try testing.expectEqualStrings("m.dat", ps[2].val.str);
    try testing.expectEqualStrings("13", ps[3].val.expr);
    try testing.expectEqualStrings("yes", ps[4].val.atom);
    try testing.expectEqualStrings("3", ps[5].val.num.digits());
    try testing.expectEqualStrings("2.5", ps[6].val.num.digits());
    const sig = hand.stmts[1].get("signals").list;
    try testing.expect(sig[0] == .atom and sig[1] == .expr and sig[2] == .expr and sig[3] == .atom);
    try testing.expectEqual(4, hand.stmts[2].get("params").params.len);
    // Quotes, backslashes and control characters survive the trip.
    const again = try jsonOf(a, &hand);
    try has(again, "{\"title\":\"a \\\"quoted\\\" title\\twith a tab\"");
    try has(again, "\"tail\":\"back\\\\slash \\u0007\"");
    var r4: ir.Report = .init(a);
    try testing.expectEqualStrings(again, try jsonOf(a, &try sprack.json.parseNetlist(a, again, &r4)));

    // What is wrong is reported with the statement's number, never fatal.
    const bad = [_][2][]const u8{
        .{ "[1,2]", "the top level must be an object with 'stmts'" },
        .{ "{\"stmts\":", "not valid JSON" },
        .{ "{\"stmts\":{}}", "'stmts' and 'body' must be arrays" },
        .{ "{\"stmts\":[7]}", "a statement must be an object" },
        .{ "{\"stmts\":[{\"kind\":\"resistor\",\"name\":[1]}]}", "'name' must be a name" },
        .{ "{\"stmts\":[{\"kind\":\"resistor\",\"params\":7}]}", "'params' must be an object of name: value pairs" },
        .{ "{\"stmts\":[{\"kind\":\"resistor\",\"params\":[[\"a\"]]}]}", "'params' as an array must hold [name, value] pairs" },
        .{ "{\"stmts\":[{\"kind\":\"capacitor\",\"c\":\"10PF\"}]}", "'10PF' is not a number" },
        .{ "{\"stmts\":[{\"kind\":\"subckt\",\"body\":3}]}", "'stmts' and 'body' must be arrays" },
    };
    for (bad) |cs| {
        var rb: ir.Report = .init(a);
        _ = try sprack.json.parseNetlist(a, cs[0], &rb);
        errdefer std.debug.print("{s}\n", .{cs[0]});
        try reported(&rb, .@"error", cs[1]);
    }
}

test "statement dialects are table indices; the JSON keeps the name" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Built-ins have fixed indices; a name is interned once, case ignored.
    try testing.expectEqualStrings(sprack.grammars[0].name, sprack.dialectName(1));
    try testing.expectEqual(@as(?u8, 1), try sprack.internDialect(sprack.grammars[0].name));
    const mine = (try sprack.internDialect("MyDialectForTest")).?;
    try testing.expectEqual(@as(?u8, mine), try sprack.internDialect("mydialectfortest"));
    try testing.expect(mine > sprack.dialect_count);
    // A grammar loaded at run time is registered; its statements keep their
    // name through JSON and are its own when written by it.
    var diag: sprack.grammar.Diag = .{};
    const g = try sprack.resolve(a, testing.io, "grammars/ngspice.spgrammar", &diag);
    const json = "{\"title\":\"t\",\"dialect\":\"sprack\",\"stmts\":[{\"kind\":\"options\",\"params\":{\"klu\":null},\"dialect\":\"MyDialectForTest\"}]}";
    var r: ir.Report = .init(a);
    const nl = try sprack.json.parseNetlist(a, json, &r);
    try testing.expectEqual(mine, nl.stmts[0].dialect);
    var j: std.Io.Writer.Allocating = .init(a);
    try sprack.json.writeNetlist(&j.writer, &nl);
    try has(j.written(), "\"dialect\":\"MyDialectForTest\"");
    var aw: std.Io.Writer.Allocating = .init(a);
    try sprack.write(a, g, &aw.writer, &nl, &r);
    try reported(&r, .@"error", "options: 'klu' has no spelling in ngspice");
    // The same statement marked as ngspice's is the loaded grammar's own.
    var r2: ir.Report = .init(a);
    const own = try sprack.json.parseNetlist(a, "{\"title\":\"t\",\"dialect\":\"sprack\",\"stmts\":[{\"kind\":\"options\",\"params\":{\"klu\":null},\"dialect\":\"ngspice\"}]}", &r2);
    var aw2: std.Io.Writer.Allocating = .init(a);
    try sprack.write(a, g, &aw2.writer, &own, &r2);
    try has(aw2.written(), ".options klu\n");
    try clean(&r2);
}

test "a name an expression refers to keeps its spelling when its definition is elsewhere" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // No .param here: VCM, Voff, Vamp, Rval and the subcircuit's Wn are
    // defined in another file, or another block of a Python deck. Spectre
    // is case-sensitive, so `vcm` would be an unknown parameter there.
    const src =
        \\t
        \\VP inp 0 dc {VCM} ac 1
        \\VDD vdd 0 {VDD}
        \\V3 b 0 pulse(0 {VCM} 1n 1n 1n 5n 10n)
        \\V4 c 0 sin({Voff} {Vamp} 1k)
        \\V5 d 0 pwl(0 0 1n {VCM})
        \\R1 a b {2*Rval}
        \\X1 a b sub Wn=1u
        \\X2 a b sub wn=2u
        \\M1 d g 0 0 nch W=1u L=1u
        \\.end
        \\
    ;
    var r: ir.Report = .init(a);
    // Not the same read back: M1's model is declared in no file here, so
    // Spectre's reader cannot tell it from a subcircuit instance
    // (`ir.resolveInstances`), and the report says so.
    const sp = try tr(a, "ngspice", "spectre", src, &r);
    try reported(&r, .warning, "mosfet 'M1': its model 'nch' is declared in no file read; spectre tells a mosfet from a subcircuit instance only by its model");
    for ([_][]const u8{
        "VP (inp 0) vsource dc=VCM mag=1\n",
        // The source VDD, its node vdd and the parameter VDD are three names.
        "VDD (vdd 0) vsource dc=VDD\n",
        "V3 (b 0) vsource type=pulse val0=0 val1=VCM ",
        "V4 (c 0) vsource type=sine sinedc=Voff ampl=Vamp freq=1k\n",
        "V5 (d 0) vsource type=pwl wave=[0 0 1n VCM]\n",
        "R1 (a b) resistor r=2*Rval\n",
        // One spelling for the subcircuit's parameter; a device's are lower case.
        "X1 (a b) sub Wn=1u\n",
        "X2 (a b) sub Wn=2u\n",
        "M1 (d g 0 0) nch w=1u l=1u\n",
    }) |line| try has(sp, line);
}

test "a broken grammar file is reported with its path and line" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.spgrammar", .data = "dialect bad\nlexer\nend\n\nrule tran = \".tran\" stop [ step\n" });
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/bad.spgrammar", .{tmp.sub_path});
    var diag: sprack.grammar.Diag = .{};
    try testing.expectError(error.BadGrammar, sprack.resolve(a, io, path, &diag));
    try has(diag.msg, try std.fmt.allocPrint(a, "{s}:5: missing ']' in pattern", .{path}));
    try testing.expectError(error.CannotRead, sprack.resolve(a, io, "no/such.spgrammar", &diag));
    try has(diag.msg, "cannot read no/such.spgrammar");
    try testing.expectError(error.UnknownDialect, sprack.resolve(a, io, "nosuch", &diag));
}

test "options: one vocabulary, five ways of filing it" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\n.options reltol=1e-4 abstol=1p vntol=1u gmin=1e-12 tnom=25 scale=1u method=gear\n.temp 85\n.tran 1n 1u\n.end\n";

    var r1: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre", src, &r1);
    try has(sp, "sprackOptions1 options reltol=1e-4 iabstol=1p vabstol=1u gmin=1p temp=85 tnom=25 scale=1u\n");
    // The integration method is a tran parameter in Spectre.
    try has(sp, "tran1 tran step=1n stop=1u method=gear2\n");
    try clean(&r1);
    // And comes back as an option.
    try has(try tr(a, "spectre", "ngspice", sp, &r1), ".options temp=85 reltol=1e-4 abstol=1p vntol=1u gmin=1p tnom=25 scale=1u method=gear\n");

    var r2: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", src, &r2);
    try has(xy, ".options timeint reltol=1e-4 abstol=1p method=gear\n.options nonlin reltol=1e-4 abstol=1p\n.options nonlin-tran reltol=1e-4 abstol=1p\n" ++
        ".options device gmin=1p temp=85 tnom=25\n.options parser scale=1u\n");
    // Xyce has one absolute tolerance, not a separate voltage tolerance.
    try reported(&r2, .@"error", "options.vntol = 1u has no spelling in xyce: Xyce has no voltage tolerance");
    try testing.expectEqual(1, r2.count(.@"error"));

    var r3: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", src, &r3);
    try has(va, "control\noptions reltol=1e-4 abstol=1p vntol=1u gmin=1p temp=85 tnom=25 scale=1u tran_method=\"gear2\"\n");
    try clean(&r3);

    var r4: ir.Report = .init(a);
    const hs = try tr(a, "ngspice", "hspice", src, &r4);
    // One reltol and one gmin are two keys each in HSPICE (c5).
    try has(hs, ".option reltol=1e-4 reli=1e-4 abstol=1p vntol=1u gmin=1p gmindc=1p tnom=25 scale=1u method=gear\n.temp 85\n");
    try clean(&r4);

    // An option only its own simulator knows is never copied across; one
    // that changes no result is not an error (docs/verification.md 4.27).
    var r5: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "spectre", "t\n.options klu noacct\n.end\n", &r5);
    try reported(&r5, .info, "options: 'klu' is not written: ngspice's KLU only picks the sparse solver");
    try reported(&r5, .info, "options: 'noacct' is not written: ngspice's NOACCT only leaves out the accounting printout");
    try testing.expectEqual(0, r5.count(.@"error"));
    // Nothing of it crosses: no bare `.options timeint`, which Xyce 7.10
    // warns "is missing one or more required parameters" about.
    var r9: ir.Report = .init(a);
    const xy9 = try tr(a, "ngspice", "xyce", "t\n.options klu noacct\nV1 a 0 1\nR1 a 0 1k\n.op\n.end\n", &r9);
    try testing.expect(std.mem.indexOf(u8, xy9, ".options") == null);
    try testing.expectEqual(0, r9.count(.@"error"));
    // A method with no transient for it to act on.
    var r8: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "spectre", "t\nV1 a 0 1\nR1 a 0 1k\n.options method=gear\n.op\n.end\n", &r8);
    try reported(&r8, .info, "options.method = gear is not written: spectre says it on tran.method, and this netlist has no tran for it to act on");
    try testing.expectEqual(0, r8.count(.@"error"));
    var r6: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "ngspice", "t\n.options klu noacct\n.end\n", &r6), ".options klu noacct\n");
    try testing.expectEqual(0, r6.items.items.len);
    // An integration method the target has no name for.
    var r7: ir.Report = .init(a);
    _ = try tr(a, "spectre", "ngspice", "// t\nt1 tran stop=1u method=euler\n", &r7);
    try reported(&r7, .@"error", "options.method = euler has no spelling in ngspice");
}

test "expressions: functions, operators and variables are mapped" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const src = "t\n.param a=2 b={a^2 + LOG(a)*Temper}\n.func dbl(x) {2*x}\nR1 n 0 {dbl(b) * 1k}\n.end\n";
    const sp = try tr(a, "ngspice", "spectre", src, &r1);
    // `^` is power in ngspice and exclusive-or in Spectre; log is natural in both.
    try has(sp, "parameters a=2 b=(pow(abs(a),2) + log(a)*temp)\n");
    const xy = try tr(a, "ngspice", "xyce", src, &r1);
    try has(xy, ".param a=2 b={pow(abs(a),2) + ln(a)*temp}\n.func dbl(x) {2*x}\nR1 n 0 {dbl(b) * 1k}\n");
    const hs = try tr(a, "ngspice", "hspice", src, &r1);
    try has(hs, ".param a=2 b='pow(abs(a),2) + log(a)*temper'\n.param dbl(x) = '2*x'\nR1 n 0 'dbl(b) * 1k'\n");

    // Spectre's `^` has no ngspice spelling; a statistical function is a
    // statistics variation in Spectre.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "spectre", "ngspice", "// t\nparameters m=(3 ^ 5)\n", &r2);
    try reported(&r2, .@"error", "operator 'xor' has no spelling in ngspice. Dialects that have it: ltspice, spectre");
    var r3: ir.Report = .init(a);
    const st = try tr(a, "ngspice", "spectre", "t\n.param vth={agauss(0.4, 0.01, 3)}\n.end\n", &r3);
    try clean(&r3);
    try has(st, "parameters vth=0.4\n");
    try has(st, "vary vth dist=gauss std=(0.01)/(3)\n");
    // A function nobody defines is not passed along on trust.
    var r4: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\n.param q={mystery(2)}\n.end\n", &r4);
    try reported(&r4, .@"error", "function 'mystery' has no spelling in xyce");
}

test "outputs, initial conditions and measurements" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\t
        \\V1 in 0 1
        \\R1 in out 1k
        \\.ic v(out)=0.5 V(in)=1
        \\.save v(out) i(V1)
        \\.print tran v(out) v(in,out)
        \\.meas tran trise trig v(out) val=0.2 rise=1 targ v(out) val=0.8 rise=1
        \\.four 1k v(out)
        \\.end
    ;
    var r1: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", src, &r1);
    try has(xy, ".ic v(out)=0.5 v(in)=1\n");
    try has(xy, ".print tran v(out) v(in,out)\n");
    try has(xy, ".measure tran trise trig v(out)=0.2 rise=1 targ v(out)=0.8 rise=1\n");
    try has(xy, ".four 1k v(out)\n");
    try reported(&r1, .@"error", "statement 'save' cannot be written for xyce: Xyce records only what .PRINT lists");
    try testing.expectEqual(1, r1.count(.@"error"));
    // With an analysis to print for, the save is a .print of each.
    var r1b: ir.Report = .init(a);
    const xy2 = try tr(a, "ngspice", "xyce", "t\nV1 in 0 1\nR1 in out 1k\n.save v(out) i(V1)\n" ++
        ".tran 1n 10n\n.dc V1 0 1 0.1\n.end\n", &r1b);
    try has(xy2, ".print dc v(out) i(V1)\n.print tran v(out) i(V1)\n");
    try reported(&r1b, .info, "save: written as a print for each analysis the netlist runs (dc, tran)");

    var r2: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre", src, &r2);
    try has(sp, "ic out=0.5 in=1\n");
    try has(sp, "save out V1:p\n");
    // A differential voltage is not something Spectre's save can name.
    try reported(&r2, .@"error", "print: no spectre form of this statement can say the signal v(in,out)");
    try reported(&r2, .@"error", "statement 'measure' cannot be written for spectre: Spectre's own language has no measure statement");
    // Without the differential probe, print becomes save, and says so.
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "spectre", "t\nR1 out 0 1\n.print tran v(out)\n.end\n", &r3), "save out\n");
    try reported(&r3, .warning, "print.signals: Spectre has no print statement; the signals are saved instead");
    try clean(&r3);
    // Spectre back to SPICE.
    var r4: ir.Report = .init(a);
    try has(try tr(a, "spectre", "hspice", "// t\nv1 (a 0) vsource dc=1\nsave a v1:p\nic a=1\n", &r4), ".probe v(a) i(v1)\n.ic v(a)=1\n");
    try clean(&r4);
}

test "more devices: behavioural and controlled sources, coupling, switches, lines" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\t
        \\V1 in 0 1
        \\L1 in a 1u
        \\L2 b 0 1u
        \\K1 L1 L2 0.9
        \\B1 out 0 V={v(in)*2}
        \\F1 x 0 V1 3
        \\H1 y 0 V1 50
        \\T1 a 0 b 0 z0=50 td=1n
        \\S1 p 0 in 0 swm on
        \\.model swm sw vt=0.5 vh=0.1 ron=1
        \\.end
    ;
    var r1: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre", src, &r1);
    try has(sp, "K1 mutual_inductor coupling=0.9 ind1=L1 ind2=L2\n");
    try has(sp, "B1 (out 0) bsource v=v(in)*2\n");
    try has(sp, "F1 (x 0) cccs probe=V1 gain=3\n");
    try has(sp, "H1 (y 0) ccvs probe=V1 rm=50\n");
    try has(sp, "T1 (a 0 b 0) tline z0=50 td=1n\n");
    // Spectre has the switch, as an instance of a vswitch model.
    try has(sp, "S1 (p 0 in 0) swm region=on\n");
    try has(sp, "model swm vswitch vt=0.5 vh=0.1 ron=1\n");

    var r2: ir.Report = .init(a);
    const hs = try tr(a, "ngspice", "hspice", src, &r2);
    // HSPICE has no B element: a voltage expression is an E source with VOL=.
    try has(hs, "EB1 out 0 vol='v(in)*2'\n");
    try reported(&r2, .info, "renamed 'B1' to 'EB1'");
    var r3: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", src, &r3);
    try has(xy, "S1 p 0 in 0 swm on\n.model swm vswitch von=600m voff=400m ron=1\n");
    try clean(&r3);
    // References are checked: a sweep over something that is neither a
    // device nor a parameter of the netlist.
    var r4: ir.Report = .init(a);
    _ = try tr(a, "hspice", "spectre", "t\n.param rv=1k\nR1 a 0 rv\n.dc rx 1k 10k 1k\n.end\n", &r4);
    try reported(&r4, .@"error", "dc.src = rx does not name a device in this netlist");
    // A temperature sweep is its own thing.
    var r5: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "spectre", "t\nR1 a 0 1k\n.dc temp -40 125 5\n.end\n", &r5), "dc1 dc param=temp start=-40 stop=125 step=5\n");
    try clean(&r5);
}

test "Verilog-A: loading a module and instantiating it" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const ng = try tr(a, "spectre", "ngspice",
        \\// t
        \\ahdl_include "mydiode.va"
        \\model dmod mydiode is=1e-14
        \\d1 (a 0) dmod area=2
    , &r1);
    // ngspice loads the module OpenVAF compiles the source to.
    try has(ng, ".control\npre_osdi mydiode.osdi\n.endc\n");
    try has(ng, ".model dmod mydiode is=1e-14\n");
    // An instance of a model that is not a built-in family is an N device.
    try has(ng, "nd1 a 0 dmod area=2\n");
    try reported(&r1, .warning, "hdl.path: 'mydiode.va' is written as 'mydiode.osdi': " ++
        "ngspice loads compiled OSDI files with pre_osdi; compile the Verilog-A source with OpenVAF");
    try reported(&r1, .warning, "model 'dmod' is of the Verilog-A module 'mydiode': ngspice must load the same module");

    var r2: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", ng, &r2);
    // Read back, the compiled module stays the one named.
    try has(va, "load \"mydiode.osdi\"\n");
    var r4: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "ngspice", ng, &r4), "pre_osdi mydiode.osdi\n");
    try testing.expectEqual(0, r4.countCode(.caveat));
    try testing.expect(!r1.contains(.warning, "is still spectre syntax"));
    try has(va, "nd1 (a 0) dmod area=2\n");
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", ng, &r3);
    try reported(&r3, .@"error", "statement 'hdl' cannot be written for xyce: Xyce loads Verilog-A models as compiled plugins");
    try reported(&r3, .@"error", "device: xyce instantiates the Verilog-A module 'mydiode' only through a plugin of it");
}

test "an ADE-style Spectre netlist" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const ng = try tr(a, "spectre", "ngspice",
        \\// Generated for: spectre
        \\simulator lang=spectre
        \\global 0 vdd!
        \\include "models/tt.scs" section=tt
        \\model nch bsim4 type=n version=4.8
        \\subckt cs_amp (in out)
        \\parameters w=2u l=180n
        \\    M0 (out in 0 0) nch w=w l=l m=2
        \\ends cs_amp
        \\I0 (in out) cs_amp w=4u
        \\V0 (vdd! 0) vsource dc=1.8 type=dc
        \\V1 (in 0) vsource dc=0.6 mag=1 type=sine ampl=1m freq=1M
        \\simulatorOptions options reltol=1e-3 temp=27 tnom=27
        \\dcOp dc
        \\ac ac start=1k stop=1G dec=20
        \\tran tran stop=5u
        \\save out in
    , &report);
    const want = [_][]const u8{
        ".global vdd!\n",
        ".lib \"models/tt.scs\" tt\n",
        ".model nch nmos level=14 version=4.8\n",
        // The transistor is recognised through its model and gets no X.
        "M0 out in 0 0 nch w={w} l={l} m=2\n",
        // A subcircuit call named I0 would be a current source in SPICE.
        "XI0 in out cs_amp w=4u\n",
        "V0 vdd! 0 dc 1.8\n",
        "V1 in 0 dc 0.6 ac 1 sin(0.6 1m 1meg)\n",
        ".options temp=27 reltol=1m tnom=27\n",
        // Analyses named after their own type, as ADE writes them.
        ".op\n",
        ".ac dec 20 1k 1g\n",
        ".tran {5u/1000} 5u\n",
        ".save v(out) v(in)\n",
    };
    for (want) |w| try has(ng, w);
    try clean(&report);
    try reported(&report, .warning, "\"models/tt.scs\" is still spectre syntax");
    try reported(&report, .info, "renamed 'I0' to 'XI0'");
    try reported(&report, .warning, "ngspice needs 'sinedc' but the source gave none; wrote 0.6");
}

test "VACASK control block and sweep" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const xy = try tr(a, "vacask", "xyce",
        \\RC excited by a pulse
        \\model res sp_resistor
        \\model cap sp_capacitor
        \\model v vsource
        \\ground 0
        \\r1 (1 2) res r=1k
        \\c1 (2 0) cap c=1u
        \\v1 (1 0) v type="pulse" val0=0 val1=5 rise=1u delay=1m
        \\control
        \\  sweep vsw instance="v1" parameter="dc" from=0.5 to=0.9 step=0.05
        \\  analysis op2 op
        \\  analysis tran1 tran stop=10m step=1u
        \\  postprocess(PYTHON, "runme.py")
        \\endc
    , &report);
    // User-named models of built-in modules resolve to the right device letters.
    try has(xy, ".model res r\n");
    try has(xy, "r1 1 2 1k res\n");
    try has(xy, "c1 2 0 1u cap\n");
    try has(xy, "v1 1 0 pulse(0 5 1m 1u)\n");
    try has(xy, ".dc v1 0.5 0.9 0.05\n");
    try has(xy, ".tran 1u 10m\n");
    try has(xy, "* [sprack] not written: postprocess (PYTHON, \"runme.py\")\n");
    // A VACASK pulse without fall or width is not the SPICE pulse of the same words.
    // The swept op and the tran are two analyses: Xyce runs only the last.
    try testing.expectEqual(5, report.count(.@"error"));
    try reported(&report, .@"error", "dc: one of 2 analyses in this netlist (dc, tran); Xyce 7.10 runs one analysis a netlist");
    try reported(&report, .@"error", "vsource.fall is not given: a VACASK pulse without a fall time never falls");
    try reported(&report, .@"error", "vsource.width is not given: a VACASK pulse without a width has no flat top");
    try reported(&report, .info, "model 'v' only names a built-in vsource");
}

test "readers survive truncated and foreign input" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (dialects) |reader_name| {
        for (dialects) |sample_name| {
            const text = sample(sample_name);
            var n: usize = 0;
            while (n <= text.len) : (n += 3) {
                _ = arena_state.reset(.retain_capacity);
                var report: ir.Report = .init(a);
                const nl = try readAs(a, reader_name, text[0..n], &report);
                // Whatever was read can also be written, in every dialect.
                for (dialects) |to| _ = try writeAs(a, to, &nl, &report);
            }
        }
    }
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Up to 64 KiB, so repetition and nesting are reachable (issue 64).
    const buf = try a.alloc(u8, 64 << 10);
    const n = smith.slice(buf);
    for (dialects) |from| {
        var report: ir.Report = .init(a);
        const nl = try readAs(a, from, buf[0..n], &report);
        for (dialects) |to| _ = try writeAs(a, to, &nl, &report);
    }
    // No crash is the least of it: one pair, chosen by the input, must
    // also keep what holds for any input.
    if (n < 2) return;
    const from = dialects[buf[0] % dialects.len];
    const to = dialects[buf[1] % dialects.len];
    var report: ir.Report = .init(a);
    _ = try anyInput(a, from, to, buf[0..n], try tr0(a, from, to, buf[0..n], &report));
}

/// Translate, with no checks: for input that is not a valid netlist.
fn tr0(a: std.mem.Allocator, from: []const u8, to: []const u8, src: []const u8, report: *ir.Report) ![]const u8 {
    return sprack.translateAlloc(a, from, to, src, report);
}

test "fuzz: any bytes in, no crash" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = &.{ core_ngspice, core_spectre, core_vacask, "\x00+\\\n+ ( = = )\n{'\"[", ".ic v(a)=1 v(\n.print tran v(a,b) i(\n.func f(x,\n.options a b=\n" } });
}

test "a byte that is not UTF-8 is written to JSON as its Latin-1 character" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    // A Latin-1 micro sign, a lone continuation byte, an overlong '/', a
    // UTF-16 surrogate and a sequence cut short; then UTF-8 kept as it is.
    const nl = try readAs(a, "ngspice", "t \xb5 \x80 \xc0\xaf \xed\xa0\x80 \xe2\x82 \xc2\xb5\nR1 a 0 1k\n.end\n", &report);
    const json = try jsonOf(a, &nl);
    try has(json, "\"title\":\"t \\u00b5 \\u0080 \\u00c0\\u00af \\u00ed\\u00a0\\u0080 \\u00e2\\u0082 \xc2\xb5\"");
    var r2: ir.Report = .init(a);
    const back = try sprack.json.parseNetlist(a, json, &r2);
    try testing.expectEqual(0, r2.items.items.len);
    try testing.expectEqualStrings("t \xc2\xb5 \xc2\x80 \xc3\x80\xc2\xaf \xc3\xad\xc2\xa0\xc2\x80 \xc3\xa2\xc2\x82 \xc2\xb5", back.title);
    try testing.expectEqual(nl.stmts.len, back.stmts.len);
}

/// Any bytes as the JSON form: read, then written in every dialect.
fn fuzzJson(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const buf = try a.alloc(u8, 64 << 10);
    const n = smith.slice(buf);
    var report: ir.Report = .init(a);
    const nl = (try sprack.json.parseDocument(a, buf[0..n], &report)) orelse return;
    for (dialects) |to| _ = try writeAs(a, to, &nl, &report);
}

test "fuzz: any bytes as JSON, no crash" {
    try testing.fuzz({}, fuzzJson, .{ .corpus = &.{
        "{\"title\":\"t\",\"dialect\":\"ngspice\",\"stmts\":[{\"kind\":\"resistor\",\"name\":\"R1\",\"pos\":\"a\",\"neg\":\"0\",\"r\":\"1e3\"},{\"kind\":\"tran\",\"step\":\"1e-9\",\"stop\":\"1e-6\"}]}",
        "{\"title\":\"t\",\"stmts\":[{\"kind\":\"subckt\",\"name\":\"s\",\"ports\":[\"a\"],\"body\":[{\"kind\":\"subckt\",\"name\":\"t\",\"body\":[]}]}]}",
        "{\"stmts\":[{\"kind\":\"param\",\"params\":{\"a\":\"1+\",\"b\":{\"str\":\"x\"}}}]}",
        "[]",
        "{\"stmts\":",
    } });
}

/// Any bytes as a grammar file: compiled, and where it compiles, a sample
/// read and written with it.
fn fuzzGrammar(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const buf = try a.alloc(u8, 16 << 10);
    const n = smith.slice(buf);
    var diag: sprack.grammar.Diag = .{};
    const g = sprack.grammar.compile(a, buf[0..n], "fuzz.spgrammar", &diag) catch return;
    var report: ir.Report = .init(a);
    const nl = try sprack.read(a, &g, core_ngspice, &report);
    var aw: std.Io.Writer.Allocating = .init(a);
    try sprack.write(a, &g, &aw.writer, &nl, &report);
    const back = try readAs(a, "ngspice", core_ngspice, &report);
    var aw2: std.Io.Writer.Allocating = .init(a);
    try sprack.write(a, &g, &aw2.writer, &back, &report);
}

test "fuzz: any bytes as a grammar, no crash" {
    try testing.fuzz({}, fuzzGrammar, .{ .corpus = &.{
        "dialect f\nlexer\n  case insensitive\n  title yes\n  comment line \"*\"\nend\nrule resistor = name~\"R\" pos neg r\nrule op = \".op\"\n",
        "dialect f\nlexer\nend\nblock subckt\n  open \".subckt\" name ports*\n  close \".ends\"\nend\ndefine x = ( a | b )\n",
        "dialect f\nlexer\nend\nmodels\n  mos1 n = nmos level=1 | nmos !level\nend\n",
    } });
}

/// A small tree of files whose include lines the input chooses (cycles,
/// a missing file, sections), run as a project with and without a target.
fn fuzzProject(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var pick: [16]u8 = undefined;
    const n = smith.slice(&pick);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const names = [_][]const u8{ "top.sp", "a.sp", "sub/b.sp", "missing.sp", "lib.lib" };
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    for (names[0..3], 0..) |name, k| {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(a, if (k == 0) "top\n" else "* part\n");
        var j: usize = k;
        while (j < n) : (j += 3) {
            const to = names[pick[j] % names.len];
            if (pick[j] & 0x80 != 0) {
                try text.print(a, ".lib \"{s}/{s}\" {s}\n", .{ base, to, if (pick[j] & 0x40 != 0) "tt" else "ff" });
            } else try text.print(a, ".include \"{s}\"\n", .{to});
        }
        try text.print(a, "R{d} n{d} 0 1k\n", .{ k, k });
        if (k == 0) try text.appendSlice(a, ".op\n.end\n");
        try tmp.dir.createDirPath(testing.io, "sub");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = text.items });
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib.lib", .data = ".lib tt\n.include \"a.sp\"\n.endl tt\n.lib ff\n.include \"lib.lib\"\n.endl ff\n" });
    var log: std.Io.Writer.Allocating = .init(a);
    const top = try std.fmt.allocPrint(a, "{s}/top.sp", .{base});
    for ([_]?*const sprack.Grammar{ null, sprack.find("xyce").? }) |to| {
        _ = try sprack.project.run(testing.io, testing.allocator, .{
            .from = sprack.find("ngspice").?,
            .to = to,
            .tops = &.{top},
            .out_dir = try std.fmt.allocPrint(a, "{s}/out", .{base}),
            .log = &log.writer,
            .catalog = if (to == null) &log.writer else null,
        });
    }
}

test "fuzz: any tree of includes, no crash" {
    try testing.fuzz({}, fuzzProject, .{ .corpus = &.{ "", "\x00\x01\x02", "\x81\xc2\x83\x04\x05\x06", "\x01\x01\x01\x01\x01\x01" } });
}

test "20,000 randomly damaged netlists, no crash" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A fixed seed in `zig build test`; the nightly job gives its own
    // (SPRACK_FUZZ_SEED), printed when the test fails.
    const seed: u64 = blk: {
        const v = testing.environ.getAlloc(a, "SPRACK_FUZZ_SEED") catch break :blk 0x5eed;
        break :blk std.fmt.parseInt(u64, v, 0) catch 0x5eed;
    };
    errdefer std.debug.print("20,000 damaged netlists: seed 0x{x}\n", .{seed});
    var prng: std.Random.DefaultPrng = .init(seed);
    const rnd = prng.random();
    const junk = "\n\n+\\ ()=={}'\"[],.$;*/ \t0123456789eEkKmMuU_abcXVR^?:";
    const extra = "\n.options reltol=1e-3 method=gear klu\n.ic v(out)=1\n.save v(out) i(V1)\n.print tran v(in,out)\n.func f(x) {x*2}\nB1 out 0 V={f(v(in))^2}\n.meas tran m1 max v(out)\n";
    var buf: [4096]u8 = undefined;
    for (0..20_000) |i| {
        _ = arena_state.reset(.retain_capacity);
        const from = dialects[i % dialects.len];
        const base = sample(dialects[rnd.uintLessThan(usize, dialects.len)]);
        @memcpy(buf[0..base.len], base);
        @memcpy(buf[base.len..][0..extra.len], extra);
        const len = base.len + extra.len;
        for (0..rnd.intRangeAtMost(usize, 1, 12)) |_| {
            buf[rnd.uintLessThan(usize, len)] = junk[rnd.uintLessThan(usize, junk.len)];
        }
        var report: ir.Report = .init(a);
        const nl = try readAs(a, from, buf[0..len], &report);
        const to = dialects[rnd.uintLessThan(usize, dialects.len)];
        const out = try writeAs(a, to, &nl, &report);
        // One in eight also keeps what holds for any input.
        errdefer std.debug.print("\niteration {d}, {s} -> {s}:\n{s}\n", .{ i, from, to, buf[0..len] });
        if (i % 8 == 0) _ = try anyInput(a, from, to, buf[0..len], out);
    }
}

// Grammar files the fuzzer broke, minimised. Each must be refused with a
// diagnostic, not crash the compiler or hang the reader it would build.
const fuzzed_grammars = [_]struct { src: []const u8, msg: []const u8 }{
    // An empty model spelling word indexed past its end.
    .{ .src = "dialect x\nlexer\nend\nmodels\n  bjt npn = npn ''\nend\n", .msg = "f.spgrammar:5: empty string" },
    // An empty operator spelling matched without moving: the reader looped
    // on `B1 o 0 V={v(a)+1}` until it ran out of memory.
    .{ .src = "dialect x\nlexer\n  expr after-equals\nend\nrule bsource = name~\"B\" pos neg { v=v ...params }\noperators\n  pow \"\"\nend\n", .msg = "f.spgrammar:7: empty string" },
    // The wildcard `_` where only a named slot can stand indexed the
    // kind's slots with it.
    .{ .src = "dialect x\nlexer\nend\nrule resistor = name pos neg r _...\n", .msg = "f.spgrammar:4: unknown slot '_' for kind 'resistor'" },
    .{ .src = "dialect x\nlexer\nend\nrule resistor = name pos neg r _:\"a\"\n", .msg = "f.spgrammar:4: unknown slot '_'" },
    .{ .src = "dialect x\nlexer\nend\nrule resistor = name pos neg r { ..._ }\n", .msg = "f.spgrammar:4: unknown slot '_'" },
    .{ .src = "dialect x\nlexer\nend\nrule resistor = name pos neg r -_\n", .msg = "f.spgrammar:4: unknown slot '_'" },
};

test "fuzz: mutated grammars are refused with a diagnostic" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    for (fuzzed_grammars) |cs| {
        var diag: sprack.grammar.Diag = .{};
        try testing.expectError(error.BadGrammar, sprack.grammar.compile(arena_state.allocator(), cs.src, "f.spgrammar", &diag));
        try has(diag.msg, cs.msg);
    }
}

test "fuzz: deeply nested grammar groups are refused, not a stack overflow" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // 5000 `[` overflowed the stack; a chain of defines recurses the same way.
    for (0..2) |case| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "dialect x\nlexer\nend\n");
        if (case == 0) {
            try src.appendSlice(a, "rule resistor = name pos neg r");
            for (0..5000) |_| try src.appendSlice(a, " [");
            try src.append(a, '\n');
        } else {
            try src.appendSlice(a, "define d0 = r\n");
            for (1..5000) |i| try src.print(a, "define d{d} = <d{d}>\n", .{ i, i - 1 });
            try src.appendSlice(a, "rule resistor = name pos neg <d4999>\n");
        }
        var diag: sprack.grammar.Diag = .{};
        try testing.expectError(error.BadGrammar, sprack.grammar.compile(a, src.items, "f.spgrammar", &diag));
        try has(diag.msg, "groups nested more than 100 deep");
    }
}

test "limits: blocks and JSON nested deeper than 100 are refused, not a stack overflow" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // 30,000 nested .subckt overflowed the stack and 3,000 took 316 MiB;
    // 150 are enough to pass the limit. The same in Spectre and for .if.
    for ([_][3][]const u8{
        .{ "ngspice", ".subckt s{d} a\n", ".ends\n" },
        .{ "ngspice", ".if (1)\n", ".endif\n" },
        .{ "spectre", "subckt s{d} (a)\n", "ends\n" },
    }) |c| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, if (std.mem.eql(u8, c[0], "spectre")) "simulator lang=spectre\n" else "t\n");
        for (0..150) |i| {
            if (std.mem.indexOf(u8, c[1], "{d}")) |at| try src.print(a, "{s}{d}{s}", .{ c[1][0..at], i, c[1][at + 3 ..] }) else try src.appendSlice(a, c[1]);
        }
        for (0..150) |_| try src.appendSlice(a, c[2]);
        var r: ir.Report = .init(a);
        _ = try readAs(a, c[0], src.items, &r);
        try reported(&r, .@"error", "blocks nested more than 100 deep");
        var r2: ir.Report = .init(a);
        _ = try sprack.translateAlloc(a, c[0], "xyce", src.items, &r2);
        try testing.expect(r2.hasErrors());
    }
    // A JSON body and a JSON list, 150 deep.
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(a, "{\"title\":\"t\",\"dialect\":\"ngspice\",\"stmts\":[");
    for (0..150) |i| try body.print(a, "{{\"kind\":\"subckt\",\"name\":\"s{d}\",\"ports\":[\"a\"],\"body\":[", .{i});
    for (0..150) |_| try body.appendSlice(a, "]}");
    try body.appendSlice(a, "]}");
    var r3: ir.Report = .init(a);
    _ = try sprack.json.parseNetlist(a, body.items, &r3);
    try reported(&r3, .@"error", "nested more than 100 deep: what is deeper is not read");
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(a, "{\"title\":\"t\",\"stmts\":[{\"kind\":\"param\",\"params\":{\"p\":");
    for (0..150) |_| try list.append(a, '[');
    try list.append(a, '1');
    for (0..150) |_| try list.append(a, ']');
    try list.appendSlice(a, "}}]}");
    var r4: ir.Report = .init(a);
    _ = try sprack.json.parseNetlist(a, list.items, &r4);
    try reported(&r4, .@"error", "nested more than 100 deep");
}

test "a define that doubles at each level is refused, not expanded" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // 1 KB of grammar that asked for 2^40 nodes.
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "dialect x\nlexer\nend\ndefine d0 = r\n");
    for (1..41) |i| try src.print(a, "define d{d} = <d{d}> <d{d}>\n", .{ i, i - 1, i - 1 });
    try src.appendSlice(a, "rule resistor = name pos neg <d40>\n");
    var diag: sprack.grammar.Diag = .{};
    try testing.expectError(error.BadGrammar, sprack.grammar.compile(a, src.items, "f.spgrammar", &diag));
    try has(diag.msg, "f.spgrammar:45: more than 10000 nodes, defines expanded");
}

test "fuzz: a model or device without a name is reported, not written" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A mutated grammar whose model rule lost its name, and the same
    // statement from JSON, crashed every writer.
    var diag: sprack.grammar.Diag = .{};
    const g = try sprack.grammar.compile(a, "dialect x\nlexer\nend\nrule model = \".model\" type {...params?}\n", "f.spgrammar", &diag);
    var report: ir.Report = .init(a);
    const nl = try sprack.read(a, &g, "t\n.model nmos level=1\n", &report);
    const from_json = try sprack.json.parseNetlist(a, "{\"title\":\"t\",\"dialect\":\"ngspice\",\"stmts\":[{\"kind\":\"model\",\"type\":\"nmos\"},{\"kind\":\"mosfet\",\"master\":\"m\"}]}", &report);
    for (dialects) |to| {
        _ = try writeAs(a, to, &nl, &report);
        _ = try writeAs(a, to, &from_json, &report);
    }
    try reported(&report, .@"error", "model: a statement without a name cannot be written");
    try reported(&report, .@"error", "mosfet: a statement without a name cannot be written");
}

test "fuzz: a statement of thousands of repeated words does not overflow the stack" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // `( freqs )+` recursed once per word: 3000 of them overflowed an 8 MB stack.
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "t\n.hb tones=");
    for (0..20_000) |_| try src.appendSlice(a, "1 ");
    try src.appendSlice(a, "\n.hb tones=1k 2k nharms=3 3\n.end\n");
    for (dialects) |from| {
        var report: ir.Report = .init(a);
        const nl = try readAs(a, from, src.items, &report);
        for (dialects) |to| _ = try writeAs(a, to, &nl, &report);
    }
    // The statement too long to match is kept as text; the next one still reads.
    var report: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", src.items, &report);
    try testing.expectEqual(.@"opaque", nl.stmts[0].kind);
    try testing.expectEqual(.hb, nl.stmts[1].kind);
}

test "fuzz: long grammar lists compile in linear memory" {
    // A pattern of 3000 words, and 2000 function names on 100 lines, once
    // took O(n^2) memory: about 600 MB and 60 MB here.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    const buf = try testing.allocator.alloc(u8, 4 << 20);
    defer testing.allocator.free(buf);
    for (0..2) |case| {
        src.clearRetainingCapacity();
        try src.appendSlice(testing.allocator, "dialect x\nlexer\nend\n");
        if (case == 0) {
            try src.appendSlice(testing.allocator, "rule resistor = name~\"R\" pos neg r");
            for (0..3000) |_| try src.appendSlice(testing.allocator, " \"x\"");
        } else {
            try src.appendSlice(testing.allocator, "functions\n");
            for (0..100) |_| try src.appendSlice(testing.allocator, "  same abs min max sqrt exp pow pwr floor ceil int sgn sin cos tan asin acos atan sinh cosh tanh\n");
            try src.appendSlice(testing.allocator, "end\n");
        }
        var fba: std.heap.FixedBufferAllocator = .init(buf);
        var diag: sprack.grammar.Diag = .{};
        _ = try sprack.grammar.compile(fba.allocator(), src.items, "f.spgrammar", &diag);
    }
}

// The tests below reproduce, in small, what running the VAMS Conformance
// Suite decks through the translator turned up.

test "corpus: ngspice line syntax corners" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce",
        \\* title
        \\//  only a comment
        \\+ a continuation of nothing
        \\.subckt div a b params: rt=1k
        \\r1 a b {rt} ; semicolon
        \\.ends div
        \\x1 in mid div params: rt=2k
        \\r3 in 0 \\
        \\1e6mil
        \\.temp 27
        \\.end
    , &report);
    // params: is a keyword, not the subcircuit name.
    try has(xy, "x1 in mid div params: rt=2k\n");
    // Two backslashes continue the line; 1e6 mil is 25.4.
    try has(xy, "r3 in 0 25.4\n");
    try has(xy, ".options device temp=27\n");
    // The stray lines are comments in ngspice and stay comments.
    try has(xy, "*  only a comment\n* + a continuation of nothing\n");
    try has(xy, "r1 a b {rt} ; semicolon\n");
    try testing.expectEqual(0, report.items.items.len);
}

test "corpus: more source and analysis forms" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre",
        \\t
        \\.model jm njf vto=-2
        \\J1 d g 0 jm
        \\VDS d 0 1
        \\VGS g 0 1
        \\.dc VDS 0 5 0.1 VGS 1 3 0.5
        \\.end
    , &report);
    try has(sp, "model jm jfet type=n vto=-2\n");
    try has(sp, "J1 (d g 0) jm\n");
    // Spectre nests sweeps with a sweep statement around the inner dc.
    try has(sp, "sweep1 sweep dev=VGS start=1 stop=3 step=0.5 {\ndc1 dc dev=VDS start=0 stop=5 step=0.1\n}\n");

    var r2: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", "t\nV1 d 0 1\nV2 g 0 1\n.dc V1 0 5 0.1 V2 1 3 0.5\n.end\n", &r2);
    try has(va,
        \\sweep outer1 instance="V2" from=1 to=3 step=0.5
        \\sweep sweep1 instance="V1" from=0 to=5 step=0.1
        \\analysis dc1 op
    );
    try has(try tr(a, "vacask", "hspice", va, &r2), ".dc V1 0 5 0.1 V2 1 3 0.5\n");
    try clean(&r2);
}

test "corpus: things that would otherwise change meaning without a word" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A bare name after the nodes is a model in ngspice and a parameter in HSPICE.
    var r1: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "hspice", "t\nR1 a 0 rv\n.end\n", &r1);
    try reported(&r1, .warning, "'rv' on R1 is a model name in ngspice, but no model of that name is declared here; hspice will read it as a parameter");

    // A diode line on a transistor model.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "spectre", "t\nD1 a 0 qm\n.model qm npn\n.end\n", &r3);
    try reported(&r3, .warning, "'D1' is a diode but its model 'qm' is declared as a bjt model");

    // Parentheses added to protect blanks are not part of the expression.
    var r4: ir.Report = .init(a);
    const nl = try readAs(a, "ngspice", "t\nR1 a 0 '10 - 3'\n.end\n", &r4);
    const sp = try writeAs(a, "spectre", &nl, &r4);
    try has(sp, "R1 (a 0) resistor r=(10 - 3)\n");
    const back = try readAs(a, "spectre", sp, &r4);
    try testing.expect(ir.sameCircuit(&nl, &back));

    // Braces are not expressions in HSPICE: flagged, never reinterpreted.
    var r5: ir.Report = .init(a);
    _ = try readAs(a, "hspice", "t\nX1 a b sub w={wn}\n.end\n", &r5);
    try reported(&r5, .warning, "not a number, a name or a delimited expression in hspice");
}

test "corpus: a VACASK deck the way upstream writes them" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const ng = try tr(a, "vacask", "ngspice",
        \\Full-wave rectifier
        \\load "spice/resistor.osdi"
        \\model r sp_resistor
        \\model vsource vsource
        \\model dx sp_diode ( is=76.9p rs=42.0m /* tt=4.32u */ n=1.45 )
        \\vs (inp inn) vsource dc=0 type="sine" sinedc=0.0 ampl=20 freq=50.0
        \\d1 (inp outp) dx
        \\rl (outp 0) r r=1k
        \\control
        \\  options tran_method="gear2"
        \\  analysis tran1 tran step=1u stop=1 maxstep=1u
        \\endc
    , &report);
    try has(ng, ".model dx d is=76.9p rs=42.0m n=1.45\n");
    try has(ng, "* tt=4.32u\n");
    try has(ng, "vs inp inn dc 0 sin(0.0 20 50.0)\n");
    try has(ng, "d1 inp outp dx\n");
    try has(ng, "rl outp 0 1k r\n");
    try has(ng, ".options method=gear\n");
    try has(ng, ".tran 1u 1 0 1u\n");
    try clean(&report);
}

test "define: a named pattern compiles to the same nodes as writing it out" {
    const g = tinyGrammar(
        \\dialect tiny
        \\lexer
        \\end
        \\define pre = "dc" dc
        \\define both = <pre> [ "ac" acmag ]
        \\rule vsource = name~"V" pos neg <both>
        \\rule isource = name~"I" pos neg "dc" dc [ "ac" acmag ]
    );
    const a = g.rules[0].pat;
    const b = g.rules[1].pat;
    try testing.expectEqual(b.len, a.len);
    for (a[3..], b[3..]) |x, y| {
        try testing.expectEqual(y.tag, x.tag);
        try testing.expectEqualStrings(y.text, x.text);
        try testing.expectEqual(y.slot, x.slot);
    }
    // The shipped grammars use it for the source waveforms.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    var report: ir.Report = .init(arena_state.allocator());
    const out = try tr(arena_state.allocator(), "hspice", "xyce", "t\nV1 a 0 SIN(0 1 1k)\nI1 a 0 PWL(0 0 1n 1)\n.end\n", &report);
    try has(out, "V1 a 0 sin(0 1 1k)");
    try has(out, "I1 a 0 pwl(0 0 1n 1)");
}

test "HSPICE .ac plus .noise is one noise analysis" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    // Adjacent, with a comment between: one statement.
    const one = try readAs(a, "hspice", "t\n.ac dec 10 1k 1meg\n* noise\n.noise v(out) vin\n.end\n", &report);
    try testing.expectEqual(0, countKind(one, .ac));
    try testing.expectEqual(1, countKind(one, .noise));
    try testing.expectEqual(1, countKind(one, .comment));
    const ng = try tr(a, "hspice", "ngspice", "t\nVin in 0 ac 1\n.ac dec 10 1k 1meg\n.noise v(out,ref) vin\n.end\n", &report);
    try has(ng, ".noise v(out,ref) Vin dec 10 1k 1meg\n");
    try testing.expect(std.mem.indexOf(u8, ng, ".ac") == null);
    // Apart: the .ac stays an analysis of its own and lends its sweep.
    const two = try tr(a, "hspice", "ngspice", "t\nVin in 0 ac 1\n.ac dec 10 1k 1meg\n.print ac v(out)\n.noise v(out) vin\n.end\n", &report);
    try has(two, ".ac dec 10 1k 1meg\n");
    try has(two, ".noise v(out) Vin dec 10 1k 1meg\n");
    try clean(&report);
}

test "repeated groups: list slots in lockstep, with a separator" {
    const g = tinyGrammar(
        \\dialect tiny
        \\lexer
        \\  title yes
        \\  scale k=3
        \\end
        \\rule hb = ".hb" ( "f" freqs "h" harms )+"and"
    );
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const nl = try sprack.read(a, &g, "t\n.hb f 1k h 3 and f 2k h 5\n.hb f 1k h 3 and\n", &report);
    try testing.expectEqual(2, nl.stmts.len);
    const hb = nl.stmts[0];
    try testing.expectEqual(schema.Kind.hb, hb.kind);
    try testing.expectEqual(2, hb.get("freqs").list.len);
    try testing.expectEqual(5, hb.get("harms").list[1].num.toFloat());
    // A separator with nothing after it is not a pass.
    try testing.expectEqual(schema.Kind.@"opaque", nl.stmts[1].kind);
    var aw: std.Io.Writer.Allocating = .init(a);
    try sprack.write(a, &g, &aw.writer, &nl, &report);
    try has(aw.written(), ".hb f 1k h 3 and f 2k h 5\n");

    // HSPICE `.hb tones=f1 f2 ... nharms=h1 h2 ...`, both ways.
    var r2: ir.Report = .init(a);
    const src = "t\n.hb tones=1k 1.3k nharms=7 7 intmodmax=7\n.end\n";
    const xy = try tr(a, "hspice", "xyce", src, &r2);
    try has(xy, ".hb 1k 1.3k\n");
    var r3: ir.Report = .init(a);
    try has(try tr(a, "hspice", "hspice", src, &r3), ".hb tones=1k 1.3k nharms=7 7 intmodmax=7\n");
    try clean(&r3);
    try has(try tr(a, "xyce", "hspice", "t\n.hb 1k 2k\n.end\n", &r3), ".hb tones=1k 2k\n");
}

/// Counts the bytes held through it and the most ever held at once.
const Counting = struct {
    child: std.mem.Allocator,
    now: usize = 0,
    peak: usize = 0,

    fn allocator(c: *Counting) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn grow(c: *Counting, old: usize, new: usize) void {
        c.now = c.now - old + new;
        c.peak = @max(c.peak, c.now);
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        const p = c.child.rawAlloc(len, a, ra) orelse return null;
        c.grow(0, len);
        return p;
    }

    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new: usize, ra: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        if (!c.child.rawResize(m, a, new, ra)) return false;
        c.grow(m.len, new);
        return true;
    }

    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new: usize, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        const p = c.child.rawRemap(m, a, new, ra) orelse return null;
        c.grow(m.len, new);
        return p;
    }

    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.child.rawFree(m, a, ra);
        c.grow(m.len, 0);
    }
};

// A large netlist is mostly short device lines. The tokens of the whole
// file (5x its size), dense slot arrays and lower-cased copies of every
// name once made a translation take 16 times the size of its input.
test "translation memory stays a small multiple of the input" {
    var src: std.Io.Writer.Allocating = .init(testing.allocator);
    defer src.deinit();
    const w = &src.writer;
    try w.writeAll("* RC mesh\n.param rval=1k\nV1 n0_0 0 PULSE(0 1.8 0 10p 10p 1n 2n)\n");
    const n = 120;
    for (0..n) |i| for (0..n) |j| {
        if (j + 1 < n) try w.print("R{d}_{d}h n{d}_{d} n{d}_{d} {{rval*1.01}}\n", .{ i, j, i, j, i, j + 1 });
        if (i + 1 < n) try w.print("R{d}_{d}v n{d}_{d} n{d}_{d} 1.5k\n", .{ i, j, i, j, i + 1, j });
        try w.print("C{d}_{d} n{d}_{d} 0 1f $ cap\n", .{ i, j, i, j });
    };
    try w.writeAll(".tran 1p 10n\n.end\n");
    const input = src.written();

    for ([_][]const u8{ "spectre", "xyce" }) |to| {
        var count: Counting = .{ .child = std.heap.page_allocator };
        const saved = ir.big;
        ir.big = count.allocator();
        defer ir.big = saved;
        var arena_state: std.heap.ArenaAllocator = .init(count.allocator());
        defer arena_state.deinit();
        var report: ir.Report = .init(arena_state.allocator());
        var sink: std.Io.Writer.Discarding = .init(&.{});
        try sprack.translate(arena_state.allocator(), "ngspice", to, input, &sink.writer, &report);
        // Measured: 0.71x to Spectre and to Xyce, beside the input, which
        // is not counted here; it was 11.55x and 11.74x when the netlist
        // was read whole. This counts whole arena chunks, untouched pages
        // too; the peak RSS of a 111 MiB mesh is 1.5x, input included.
        if (count.peak * 10 > 8 * input.len) {
            std.debug.print("to {s}: peak {d} bytes for {d} of input\n", .{ to, count.peak, input.len });
            return error.TooMuchMemory;
        }
    }
}

// What a stream has to know of the whole netlist before its first
// statement: two option lines that are one, a subcircuit the top level and
// another subcircuit use before it is defined, dev/gauss and agauss(); and
// what it reads again after the last: two islands at the top level, one fed
// by a current source (LTspice's `cutset`).
const stream_deck =
    \\* t
    \\.option temp=30
    \\X1 a 0 top
    \\V1 a 0 1
    \\C8 a f 1p
    \\C9 f 0 1p
    \\C10 a g 1p
    \\I1 g 0 1m
    \\.subckt top p n
    \\X1 p m leaf
    \\C1 m n 1p
    \\.ends
    \\.option tnom=25 temp=40
    \\.subckt leaf p n
    \\.param r0=1k dev/gauss=10
    \\R1 p q {r0}
    \\C1 q n 1p
    \\C2 q2 n 1p
    \\C3 q2 p 1p
    \\.ends
    \\.param w=agauss(1u, 0.1u, 3)
    \\.op
    \\.end
    \\
;

test "a stream writes what the whole netlist does" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{ "spectre", "xyce", "hspice", "vacask", "ltspice" }) |to| {
        var out: [2][]const u8 = undefined;
        var rep: [2][]const ir.Diag = undefined;
        for ([_]bool{ true, false }, 0..) |whole, i| {
            var report: ir.Report = .init(a);
            var aw: std.Io.Writer.Allocating = .init(a);
            const why = try sprack.stream.translate(a, sprack.find("ngspice").?, sprack.find(to).?, stream_deck, &aw.writer, &report, &sprack.caps, .{ .whole = whole });
            if (!whole) try testing.expectEqual(null, why);
            out[i] = aw.written();
            rep[i] = report.items.items;
        }
        try testing.expectEqualStrings(out[0], out[1]);
        try testing.expect(rep[0].len > 0);
        try testing.expectEqual(rep[0].len, rep[1].len);
        for (rep[0], rep[1]) |x, y| {
            try testing.expectEqualStrings(x.msg, y.msg);
            try testing.expectEqual(x.line, y.line);
            try testing.expectEqual(x.sev, y.sev);
        }
    }
}

// docs/verification.md section 6: the nine findings that were wrong.

test "verification: Xyce log is base 10 and ^ is exclusive-or" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", "t\n.param x=2 y={log(x) + x^3}\n.end\n", &r1);
    try has(xy, ".param x=2 y={ln(x) + pow(abs(x),3)}\n");
    try clean(&r1);
    // Xyce's own LOG is decimal, and its `^` has no ngspice spelling.
    var r2: ir.Report = .init(a);
    const ng = try tr(a, "xyce", "ngspice", "t\n.param x=2 y={log(x) + ln(x)}\n.end\n", &r2);
    try has(ng, ".param x=2 y={log10(x) + ln(x)}\n");
    try clean(&r2);
    var r3: ir.Report = .init(a);
    _ = try tr(a, "xyce", "ngspice", "t\n.param y={1 ^ 0}\n.end\n", &r3);
    try reported(&r3, .@"error", "operator 'xor' has no spelling in ngspice");
}

test "verification: Xyce VBIC levels and switch model types" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce",
        \\t
        \\.model qv npn level=4
        \\.model swm sw vt=0.5 vh=0.1
        \\.model cwm csw it=1m ih=0.1m
        \\.end
    , &r1);
    try has(xy, ".model qv npn level=11\n");
    try has(xy, ".model swm vswitch von=600m voff=400m\n");
    try has(xy, ".model cwm iswitch ion=1100u ioff=900u\n");
    // There is no level 10.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "xyce", "ngspice", "t\n.model qv npn level=10\n.end\n", &r2);
    try reported(&r2, .@"error", "type 'npn' with these parameters is not in the xyce models table");
}

test "verification: an ngspice nhfet card without a level is not an HFET" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const nl = try readAs(a, "ngspice", "t\n.model h1 nhfet level=5\n.model h2 nhfet\n.end\n", &report);
    try testing.expectEqualStrings("hfet", nl.stmts[0].get("family").atom);
    const f2 = nl.stmts[1].get("family");
    try testing.expect(f2 != .atom or !std.mem.eql(u8, f2.atom, "hfet"));
    // A Z device points at that card; it cannot be dropped as boilerplate.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\nZ1 d g 0 hm\n.model hm nhfet level=6\n.end\n", &r2);
    try reported(&r2, .@"error", "no spelling for model family 'hfet n'");
}

test "verification: Xyce S-parameters through .LIN and P ports" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const src = "t\nV1 in 0 dc 0 ac 1 portnum 1 z0 50\nR1 in 0 50\n.sp lin 3 1meg 3meg\n.end\n";
    const xy = try tr(a, "ngspice", "xyce", src, &report);
    try has(xy, "PV1 in 0 dc 0 port=1 z0=50 ac 1\n");
    try has(xy, ".ac lin 3 1meg 3meg\n.lin\n");
    try clean(&report);
    const back = try readAs(a, "xyce", xy, &report);
    try testing.expectEqual(1, countKind(back, .sp));
    try testing.expectEqual(0, countKind(back, .ac));
}

test "verification: VACASK behavioural sources, dcxf, subckt parentheses, val0/val1" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask",
        \\t
        \\.subckt div in out
        \\R1 in out 1k
        \\.ends div
        \\V1 in 0 1
        \\B1 b 0 V={v(in)*2}
        \\B2 0 c I={v(in)*1m}
        \\.tf v(b) V1
        \\.end
    , &r1);
    try has(va, "subckt div (in out)\n");
    try has(va, "ends div\n");
    try has(va, "B1 (b 0) v=v(in)*2\n");
    try has(va, "B2 (0 c) i=v(in)*1m\n");
    try has(va, "analysis tf1 dcxf out=\"b\"\n");
    // dcxf has no input source of its own: it reports every source.
    // dcxf reports every source: the one named is among them.
    try reported(&r1, .warning, "tf.src: dcxf reports tf() and zin() for every independent source");
    try reported(&r1, .warning, "tf.out: dcxf reports tf(), zin() and yin() for every independent source");
    // v0/v1 are not VACASK source parameters, so they are not pulse levels.
    var r2: ir.Report = .init(a);
    const nl = try readAs(a, "vacask", "t\nv1 (a 0) vsource type=\"pulse\" v0=0 v1=1 rise=1n fall=1n width=1n\n", &r2);
    try testing.expect(nl.stmts[0].get("val1") == .none);
}

test "verification: VACASK sources: sine phase, exp origin, pwl, fm, and SPICE defaults" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const src =
        \\t
        \\Va a 0 sin(0.5 1 1meg 100n 1e5 30)
        \\Vb b 0 exp(0 1 100n 200n 1u 300n)
        \\Vc c 0 pwl(0 0 1u 1)
        \\Vd d 0 sffm(0 1 2meg 3 200k)
        \\.end
    ;
    const va = try tr(a, "ngspice", "vacask", src, &r1);
    try has(va, "Va (a 0) vsource type=\"sine\" delay=100n sinedc=0.5 ampl=1 freq=1M theta=1e5 tdphase=30\n");
    // td2 counts from delay in VACASK.
    try has(va, "Vb (b 0) vsource type=\"exp\" val0=0 val1=1 delay=100n td2=900n tau1=200n tau2=300n\n");
    try has(va, "Vc (c 0) vsource type=\"pwl\" wave=[0, 0, 1u, 1]\n");
    try has(va, "Vd (d 0) vsource type=\"fm\" sinedc=0 ampl=1 freq=200k modindex=3 modfreq=2M\n");
    try clean(&r1);
    // And back, exactly.
    var r2: ir.Report = .init(a);
    const ng = try tr(a, "vacask", "ngspice", va, &r2);
    try has(ng, "Vb b 0 exp(0 1 100n 200n 1u 300n)\n");
    try has(ng, "Va a 0 sin(0.5 1 1meg 100n 1e5 30)\n");
    // What VACASK defaults differently is an error, never a quiet change.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "vacask", "t\nV1 a 0 pulse(0 1 0 0)\nV2 b 0 sin(0 1)\nV3 c 0 exp(0 1)\n.end\n", &r3);
    try reported(&r3, .@"error", "vsource.rise is 0: VACASK needs rise > 0");
    try reported(&r3, .@"error", "vsource.fall is not given: a VACASK pulse without a fall time never falls");
    try reported(&r3, .@"error", "vsource.width is not given");
    try reported(&r3, .@"error", "vsource.freq is not given: VACASK's default frequency is 1k");
    try reported(&r3, .@"error", "vsource.td2 is not given");
}

test "verification: VACASK functions, operators and variables" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", "t\n.param p={log(2) + asinh(1) + temper + agauss(1,0.1,3)}\n.end\n", &r1);
    try has(va, "parameters p=(ln(2) + asinh(1) + $temp + agauss(1,0.1,3))\n");
    try clean(&r1);
    // VACASK's log is natural, and its ^ is exclusive-or.
    var r2: ir.Report = .init(a);
    const sp = try tr(a, "vacask", "spectre", "t\nparameters q=log(2)+(3^5)+integer(2.5)\n", &r2);
    try has(sp, "parameters q=log(2)+(3^5)+int(2.5)\n");
    try clean(&r2);
    // VACASK's sgn(0) is 1: not the SPICE function, so not mapped.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "vacask", "t\n.param s={sgn(0)}\n.end\n", &r3);
    try reported(&r3, .@"error", "function 'sgn' has no spelling in vacask");
}

test "verification: VACASK coupling, controlled sources, lines, libraries, conditionals" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const src =
        \\t
        \\.lib 'models.lib' typ
        \\V1 in 0 1
        \\L1 in 0 1u
        \\L2 b 0 1u
        \\K1 L1 L2 0.9
        \\E1 e 0 in 0 2
        \\G1 0 g in 0 1m
        \\F1 0 f V1 3
        \\H1 h 0 V1 500
        \\T1 c 0 d 0 z0=50 td=1n
        \\.if (a == 1)
        \\R3 x 0 1k
        \\.elseif (a == 2)
        \\R3 x 0 2k
        \\.else
        \\R3 x 0 3k
        \\.endif
        \\.end
    ;
    const va = try tr(a, "ngspice", "vacask", src, &r1);
    const want = [_][]const u8{
        "model mutual mutual\n",                 "load \"tline_ideal.osdi\"\nmodel tline tline_ideal\n",
        "include \"models.lib\" section=typ\n",  "K1 () mutual k=0.9 ind1=\"L1\" ind2=\"L2\"\n",
        "E1 (e 0 in 0) vcvs gain=2\n",           "G1 (0 g in 0) vccs gain=1m\n",
        "F1 (0 f) cccs ctlinst=\"V1\" gain=3\n", "H1 (h 0) ccvs ctlinst=\"V1\" gain=500\n",
        "T1 (c 0 d 0) tline z0=50 td=1n\n",      "@if (a == 1)\n",
        "@elseif (a == 2)\n",                    "@else\n",
        "@end\n",
    };
    for (want) |w| try has(va, w);
    // Read back: the same circuit.
    var r2: ir.Report = .init(a);
    const orig = try readAs(a, "ngspice", src, &r2);
    const back = try readAs(a, "vacask", va, &r2);
    try testing.expectEqual(orig.stmts.len, back.stmts.len + 0);
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "vacask", "* lib\n.lib typ\n.param r=1k\n.endl typ\n", &r3), "section typ\nparameters r=1k\nendsection\n");
}

test "verification: VACASK analyses: acsp, acstb, pss period, ic and nodeset on the analysis" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const va = try tr(a, "spectre", "vacask",
        \\// t
        \\simulator lang=spectre
        \\V1 (in 0) vsource type=sine ampl=1 freq=1M
        \\pss1 pss fund=1M harms=10 tstab=1u
        \\stb1 stb start=1k stop=1G dec=10 probe=V1
    , &r1);
    try has(va, "analysis pss1 pss tper=1u tstab=1u maxharm=10\n");
    try has(va, "analysis stb1 acstb probe=\"V1\" from=1k to=1G mode=\"dec\" points=10\n");
    // The period goes back to a frequency.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "vacask", "spectre", va, &r2), "pss1 pss fund=1M harms=10 tstab=1u\n");

    var r3: ir.Report = .init(a);
    const src = "t\nR1 out 0 1k\nC1 out 0 1u\n.ic v(out)=0.2\n.nodeset v(out)=0.1\n.op\n.ac lin 5 1k 5k\n.sp dec 10 1k 1meg\n.tran 1u 1m uic\n.end\n";
    const out = try tr(a, "ngspice", "vacask", src, &r3);
    try has(out, "analysis op1 op nodeset={\"out\",0.1}\n");
    // A linear sweep counts intervals in VACASK.
    try has(out, "analysis ac1 ac from=1k to=5k mode=\"lin\" points=4 nodeset={\"out\",0.1}\n");
    try has(out, "analysis sp1 acsp from=1k to=1M mode=\"dec\" points=10 nodeset={\"out\",0.1}\n");
    try has(out, "analysis tran1 tran step=1u stop=1m maxstep=1u icmode=\"uic\" ic={\"out\",0.2} nodeset={\"out\",0.1}\n");
    // Reading lifts them back out into statements of their own.
    var r4: ir.Report = .init(a);
    const ng = try tr(a, "vacask", "ngspice", out, &r4);
    try has(ng, ".ic v(out)=0.2\n");
    try has(ng, ".nodeset v(out)=0.1\n");
    try has(ng, ".ac lin 5 1k 5k\n");
    // With nothing to carry them, an ic says why it cannot be written.
    var r5: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "vacask", "t\nR1 out 0 1k\n.ic v(out)=0.2\n.op\n.end\n", &r5);
    try reported(&r5, .@"error", "vacask says it as tran.ic, and this netlist has no tran");
    var r6: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "vacask", "t\n.sens v(out)\nS1 a 0 b 0 sw\n.model sw sw\n.end\n", &r6);
    try reported(&r6, .@"error", "VACASK has no sensitivity analysis");
    try reported(&r6, .@"error", "VACASK has no switch device");
}

test "verification: VACASK model families load their modules" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask",
        \\t
        \\Q1 c b 0 qn
        \\Q2 c b 0 qv
        \\J1 d g 0 jp
        \\M1 d g 0 0 m3
        \\M2 d g 0 vd
        \\.model qn npn bf=100
        \\.model qv pnp level=4
        \\.model jp pjf
        \\.model m3 nmos level=3
        \\.model vd vdmos
        \\.end
    , &r1);
    const want = [_][]const u8{
        "load \"spice/bjt.osdi\"\n",      "load \"vbic_1p3_4t.osdi\"\n",   "load \"spice/jfet1.osdi\"\n",
        "load \"spice/mos3.osdi\"\n",     "load \"spice/vdmos.osdi\"\n",   "model qn sp_bjt (type=1 bf=100)\n",
        "model qv vbic13_4t (type=-1)\n", "model jp sp_jfet1 (type=-1)\n", "model m3 sp_mos3 (type=1)\n",
        "model vd sp_vdmos\n",
    };
    for (want) |w| try has(va, w);
    try testing.expect(std.mem.indexOf(u8, va, "mos1.osdi") == null);
}

// docs/verification.md section 9: every line written here was run in
// ngspice 45, Xyce 7.10 or VACASK b2c1551 and the inductance read back.
test "verification: an inductor's model between ngspice, Xyce and VACASK; a loss where no form is measured" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ng =
        \\t
        \\I1 0 a dc 0 ac 1
        \\L1 a 0 lmod 1m tc1=0.03
        \\.model lmod l tc1=0.01
        \\.end
    ;
    var r1: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", ng, &r1), "L1 a 0 lmod 1m tc1=0.03\n.model lmod l tc1=0.01\n");
    try clean(&r1);
    var r2: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", ng, &r2);
    try has(va, "L1 (a 0) lmod l=1m tc1=0.03\nmodel lmod sp_inductor (tc1=0.01)\n");
    try clean(&r2);

    // Xyce takes the model on either side of the value, or the value by key,
    // and the model card as `l` or `ind`.
    inline for (.{ "L1 a 0 1m lmod", "L1 a 0 lmod 1m", "L1 a 0 lmod l=1m" }) |line| {
        var r: ir.Report = .init(a);
        const xy = "t\nI1 0 a dc 0 ac 1\n" ++ line ++ "\n.model lmod ind tc1=0.01\n.end\n";
        try has(try tr(a, "xyce", "ngspice", xy, &r), "L1 a 0 lmod 1m\n.model lmod l tc1=0.01\n");
        try clean(&r);
    }

    var r3: ir.Report = .init(a);
    var r4: ir.Report = .init(a);
    try has(try tr(a, "vacask", "ngspice", va, &r3), "L1 a 0 lmod 1m tc1=0.03\n");
    try has(try tr(a, "vacask", "xyce", va, &r4), "L1 a 0 lmod 1m tc1=0.03\n");
    try clean(&r3);
    try clean(&r4);

    // The model alone gives the value in ngspice (`ind`) and VACASK; a Xyce
    // instance must say it, so the model has nowhere to go there.
    const alone = "t\nI1 0 a dc 0 ac 1\nL1 a 0 lmod\n.model lmod l ind=1m\n.end\n";
    var r5: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "vacask", alone, &r5), "L1 (a 0) lmod\n");
    try clean(&r5);
    var r6: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", alone, &r6);
    try reported(&r6, .@"error", "inductor.master = lmod has no spelling in xyce");

    // LTspice 26.0.2 refuses the line and the card: neither is written.
    var r7: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "ltspice", ng, &r7), "L1 a 0 1m tc1=0.03\n");
    try reported(&r7, .@"error", "inductor.master = lmod has no spelling in ltspice");
    try reported(&r7, .@"error", "ltspice.spgrammar has no spelling for model family 'inductor'");

    // HSPICE Y-2026.03-SP2-1 refuses every form tried (docs/verification.md
    // 9.6): the model stays an error.
    var r8: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "hspice", ng, &r8), "L1 a 0 1m tc1=0.03\n");
    try reported(&r8, .@"error", "inductor.master = lmod has no spelling in hspice");
}

// Each written form below was loaded in Spectre 25.10 or HSPICE Y-2026.03.

test "verification: LTspice 26.0.2, what running it showed" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Into LTspice: its defaults are 27 degrees and are not written; a pulse
    // gets the four values it needs; round, a quoted library path, Zo, .print
    // and the measure forms are its own.
    var r1: ir.Report = .init(a);
    const lt = try tr(a, "ngspice", "ltspice",
        \\t
        \\V1 a 0 pulse(0 1 1m)
        \\R1 a 0 1k
        \\T1 a 0 b 0 z0=50 td=1n
        \\R2 b 0 50
        \\.param x=2 c=0
        \\.param q={nint(2.5) + -x**2 + pwr(x,2)} w={x > 1 && !c} v={5 % 3}
        \\.lib 'f.lib' tt
        \\.print tran v(a)
        \\.meas tran m1 find v(a) at=1m
        \\.meas tran m2 param='m1*2'
        \\.tran 10u 6m
        \\.end
        \\
    , &r1);
    try testing.expectEqualStrings(
        \\t
        \\V1 a 0 pulse(0 1 1m 10u 10u 6m)
        \\R1 a 0 1k
        \\T1 a 0 b 0 zo=50 td=1n
        \\R2 b 0 50
        \\.param x=2 c=0
        \\.param q={round(2.5) + -pow(abs(x),2) + pwr(x,2)} w={x > 1 && !c} v={5 % 3}
        \\.lib "f.lib" tt
        \\.print tran v(a)
        \\.meas tran m1 find v(a) at=1m
        \\.meas tran m2 param={m1*2}
        \\.tran 10u 6m
        \\.end
        \\
    , lt);
    try clean(&r1);
    try reported(&r1, .warning, "vsource.width is not given: ngspice means the tran.stop by that, and ltspice needs it said; wrote 6m");
    try reported(&r1, .warning, "nint in ltspice: halves round away from zero");
    try reported(&r1, .warning, "pwr in ltspice: the sign of a negative base is dropped");
    // ngspice's power is written as what it means (4.44): no minus binds
    // before it. HSPICE's is written as it is.
    try testing.expect(!r1.contains(.warning, "minuspow"));
    var r9: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ltspice", "t\n.param x=2 q='-x**2'\n.end\n", &r9);
    try reported(&r9, .warning, "minuspow in ltspice: a minus binds before the power: -2**2 is 4, not -4");
    try reported(&r1, .warning, "andor in ltspice: LTspice has no && and ||");
    try reported(&r1, .warning, "print.style: LTspice reads the line and prints nothing");
    // What it refuses or means otherwise is an error: a sine without a
    // frequency, the frequency variable, .probe.
    var r2: ir.Report = .init(a);
    const no = try tr(a, "ngspice", "ltspice", "t\nV1 a 0 sin(0 1)\nR1 a 0 1k\nB1 b 0 V=hertz*v(a)\nR2 b 0 1k\n.probe v(a)\n.tran 1u 1m\n.end\n", &r2);
    try has(no, "V1 a 0\n");
    try reported(&r2, .@"error", "vsource.wave = sine has no spelling in ltspice");
    try reported(&r2, .@"error", "variable 'hertz' has no spelling in ltspice");
    try reported(&r2, .@"error", "no ltspice form of this statement can say style = probe");
    // Out of LTspice: expressions after `=` with blanks in them, Z0, one
    // number after .tran. A zero rise time is a tenth of the width there.
    var r3: ir.Report = .init(a);
    const ng = try tr(a, "ltspice", "ngspice", "t\nV1 a 0 1\nR1 a 0 1k\nB1 c 0 V=v(a) * 2 + 1\nR2 c 0 1k\n.param s = 2 * 3 t = 5\nT1 a 0 b 0 Z0=75 Td=1n\nR3 b 0 75\nE1 d 0 value={2*v(a)}\nR4 d 0 1k\n.tran 1m\n.end\n", &r3);
    try has(ng, "B1 c 0 v={v(a) * 2 + 1}\n");
    try has(ng, ".param s={2 * 3} t=5\n");
    try has(ng, "T1 a 0 b 0 z0=75 td=1n\n");
    try has(ng, "E1 d 0 vol={2*v(a)}\n");
    try has(ng, ".tran {1m/1000} 1m\n");
    try clean(&r3);
    var r4: ir.Report = .init(a);
    _ = try tr(a, "ltspice", "ngspice", "t\nV1 a 0 pulse(0 1 0 0 0 1m 2m)\nR1 a 0 1k\n.tran 1u 4m\n.end\n", &r4);
    try reported(&r4, .@"error", "vsource.rise is 0: LTspice takes a tenth of the pulse width");
    // Topologies: parallel voltage sources stop it, a current source into
    // a floating node is its error, the rest it solves in its own way.
    var r5: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "ltspice", "t\nV1 a 0 1\nV2 a 0 1\nL1 a 0 1m\nC1 a b 1n\nC2 b 0 1n\nI1 0 c 1m\nC3 c 0 1n\nL2 a d 1m\nL3 a d 1m\nR1 d 0 1k\n.op\n.end\n", &r5);
    try reported(&r5, .@"error", "LTspice stops on voltage sources in parallel");
    try reported(&r5, .@"error", "node 'c' has no DC path to ground");
    try reported(&r5, .warning, "node 'b' has no DC path to ground");
    try reported(&r5, .warning, "V1, L1 form a loop of voltage sources and inductors");
    try reported(&r5, .warning, "L2, L3 form a loop of inductors");
}

test "Spectre: conditionals, functions, xf, pz, sens, fourier, hb, nested dc, switches" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const src =
        \\t
        \\V1 in 0 dc 1 ac 1
        \\V2 b 0 dc 0
        \\R1 in out 1k
        \\S1 out 0 in 0 smod on
        \\W1 out 0 V1 wmod
        \\.model smod sw vt=0.5
        \\.model wmod csw it=1m
        \\.func f1(x,y) {x*2+y}
        \\.param a=2
        \\.if (a > 1)
        \\R9 out 0 1k
        \\.elseif (a < 0)
        \\R9 out 0 2k
        \\.else
        \\R9 out 0 3k
        \\.endif
        \\.tf v(out) V1
        \\.sens v(out)
        \\.dc V1 0 1 0.1 V2 0 1 0.5
        \\.tran 1u 1m
        \\.four 1k v(out)
        \\.end
    ;
    const sp = try tr(a, "ngspice", "spectre", src, &report);
    try has(sp, "S1 (out 0 in 0) smod region=on\n");
    try has(sp, "W1 (out 0) wmod probe=V1\n");
    try has(sp, "model wmod iswitch it=1m\n");
    try has(sp, "real f1(real x,real y) {\nreturn (x*2+y)\n}\n");
    try has(sp, "if ((a > 1)) {\nR9 (out 0) resistor r=1k\n} else if ((a < 0)) {\n");
    try has(sp, "} else {\nR9 (out 0) resistor r=3k\n}\n");
    try has(sp, "xf1 (out 0) xf freq=0\n");
    try reported(&report, .warning, "tf.src: xf gives the transfer function from every source");
    try has(sp, "sens1 dc\nsens (out) for (sens1)\n");
    try has(sp, "four1 (out 0) fourier fund=1k\n");
    try testing.expect(!report.hasErrors());

    // Read back: the same circuit, the conditional and the function included.
    var r2: ir.Report = .init(a);
    const back = try tr(a, "spectre", "ngspice", sp, &r2);
    try has(back, ".if (a > 1)\n");
    try has(back, ".elseif (a < 0)\n");
    try has(back, ".sens v(out)\n");
    try has(back, ".dc V1 0 1 0.1 V2 0 1 0.5\n");
    try has(back, ".four 1k v(out)\n");

    // The Fourier analyser watches one signal; two cannot be one instance.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "spectre", "t\n.tran 1u 1m\n.four 1k v(a) v(b)\n.end\n", &r3);
    try testing.expect(r3.hasErrors());

    // hb: frequencies and harmonics as vectors.
    var r4: ir.Report = .init(a);
    try has(try tr(a, "hspice", "spectre", "t\n.hb tones=1k nharms=5\n.end\n", &r4), "hb1 hb fundfreqs=[1k] maxharms=[5]\n");

    // Functions Spectre has under the SPICE names.
    var r5: ir.Report = .init(a);
    const fx = try tr(a, "ngspice", "spectre", "t\n.param p={pwr(a,2)+sgn(b)+nint(c)}\n.end\n", &r5);
    try has(fx, "pwr(a,2)+sgn(b)+nint(c)");
    try testing.expect(!r5.hasErrors());
}

test "HSPICE: .pz, .noise interval, .lin, .sn, MESFETs, model before value, pow" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const src =
        \\t
        \\vin in 0 dc 1 ac 1
        \\r1 in out rm 1k
        \\.model rm r tc1=1m
        \\j1 out in 0 mm 2
        \\.model mm njf level=3
        \\.pz v(out) vin
        \\.ac dec 10 1 1meg
        \\.noise v(out) vin 10
        \\.ac dec 10 1meg 1g
        \\.lin
        \\.sn tone=1k nharms=5 trinit=1m
        \\.end
    ;
    const nl = try readAs(a, "hspice", src, &report);
    try testing.expectEqual(1, countKind(nl, .mesfet));
    try testing.expectEqual(1, countKind(nl, .pz));
    try testing.expectEqual(1, countKind(nl, .sp));
    try testing.expectEqual(1, countKind(nl, .pss));
    try testing.expectEqual(0, countKind(nl, .ac));
    const same = try tr(a, "hspice", "hspice", src, &report);
    try has(same, "r1 in out rm 1k\n");
    try has(same, ".pz v(out) vin\n");
    try has(same, ".noise v(out) vin 10\n");
    try has(same, ".ac dec 10 1meg 1g\n.lin\n");
    try has(same, ".sn tone=1k nharms=5 trinit=1m\n");

    // A SPICE resistor with a model is written model first.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "hspice", "t\nR1 a 0 1k rm\n.model rm r tc1=1m\n.end\n", &r2), "R1 a 0 rm 1k\n");
    // A MESFET is a J element with a level-3 model.
    var r3: ir.Report = .init(a);
    const ms = try tr(a, "ngspice", "hspice", "t\nZ1 d g 0 zm\n.model zm nmf\n.end\n", &r3);
    try has(ms, ".model zm njf level=3\n");
    // The pole-zero output and source go to Spectre; the interval does not.
    var r4: ir.Report = .init(a);
    const sx = try tr(a, "hspice", "spectre", src, &r4);
    try has(sx, "pz1 (out 0) pz iprobe=vin\n");
    try reported(&r4, .@"error", "noise.interval = 10 has no spelling in spectre");
    // ngspice's points-per-summary is the same number.
    var r8: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", src, &r8), ".noise v(out) vin dec 10 1 1meg 10\n");
    // HSPICE cuts a power's exponent to an integer: a caveat either way.
    var r5: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "hspice", "t\n.param p={2**x}\n.end\n", &r5);
    try reported(&r5, .warning, "the exponent is cut to an integer");
    var r6: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ngspice", "t\n.param p='pow(2,x)'\n.end\n", &r6);
    try reported(&r6, .warning, "the exponent is cut to an integer");
    // HSPICE's limit() is not the clamp of the other dialects.
    var r7: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "hspice", "t\n.param p={limit(x,0,1)}\n.end\n", &r7);
    try reported(&r7, .@"error", "function 'limit' has no spelling in hspice");
}

test "fixes from the load check: Spectre globals, dotted versions, Spectre pow" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The first node of a Spectre global statement is ground: `global vdd`
    // alone shorted vdd to ground.
    var r1: ir.Report = .init(a);
    const g = try tr(a, "ngspice", "spectre", "t\n.global vdd\nvdd vdd 0 1\n.end\n", &r1);
    try has(g, "global 0 vdd\n");
    try testing.expect(std.mem.indexOf(u8, g, "global vdd") == null);
    // ngspice reads version=3.3.0; HSPICE and Spectre refuse it.
    for ([_][]const u8{ "spectre", "hspice" }) |to| {
        var r2: ir.Report = .init(a);
        _ = try tr(a, "ngspice", to, "t\n.model n3 nmos(level=49 version=3.3.0)\n.end\n", &r2);
        try reported(&r2, .@"error", "version=3.3.0 is not a number");
    }
    // Spectre stops on pow(-1.75,2.5).
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "spectre", "t\nV1 a 0 {pow(-1.75,2.5)}\n.end\n", &r3);
    try reported(&r3, .warning, "a negative base with a fractional exponent stops the run");
}

test "parse check: forms ngspice and Xyce reject when they load the netlist" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\t
        \\.func g(x, y) {x+y}
        \\D1 a 0 dm 2 pj=1m
        \\.model n3 nmos level=49 version=3.3.0
        \\.end
    ;
    for ([_][]const u8{ "ngspice", "xyce" }) |to| {
        var r: ir.Report = .init(a);
        const out = try tr(a, "ngspice", to, src, &r);
        // `g(x y)`: ngspice and Xyce both refuse a .func without commas.
        try has(out, ".func g(x,y) {x+y}\n");
        // `D1 a 0 dm 2`: ngspice 45 takes the bare area for a thermal node's model.
        try has(out, "D1 a 0 dm area=2 pj=1m\n");
        // `{3.3.0}` is not an expression.
        try has(out, "version=3.3.0\n");
    }
    // Xyce's .noise parser handles only V(out); SIN needs its frequency.
    var r1: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\nV1 a 0 1 ac 1\n.noise v(a,b) V1 dec 3 10 10k\n.end\n", &r1);
    try testing.expect(r1.hasErrors());
    var r2: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\nV1 a 0 SIN(0 1)\n.tran 10n 1u\n.end\n", &r2);
    try testing.expect(r2.hasErrors());
}

test "parse check: ngspice MESA and HFET cards are not plain MESFETs" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // nmf level=2 is MESA, which Xyce does not have; it was written as Xyce's Z level 1 card.
    var r1: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\nZ1 d g 0 nm\n.model nm nmf level=2 vto=-1\n.end\n", &r1);
    try reported(&r1, .@"error", "model 'nm' (mesa n) cannot be written for xyce: Xyce's MESFET (Z) has one level");
    // An HFET card with nothing but its level still names a model Xyce lacks.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\nZ1 d g 0 hm\n.model hm nhfet level=6\n.end\n", &r2);
    try reported(&r2, .@"error", "xyce.spgrammar has no spelling for model family 'hfet n'");
    // A plain MESFET still translates.
    var r3: ir.Report = .init(a);
    const out = try tr(a, "ngspice", "xyce", "t\nZ1 d g 0 zm\n.model zm nmf vto=-1\n.end\n", &r3);
    try has(out, ".model zm nmf vto=-1\n");
}

test "parse check: a long .lib or .include line is never wrapped" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const long = "/a/very/long/path/to/a/process/design/kit/that/goes/on/and/on/and/on/models/sky130.lib.spice";
    var r: ir.Report = .init(a);
    // ngspice takes `.lib` with its path on a `+` line for an unknown subcircuit library.
    const out = try tr(a, "ngspice", "xyce", "t\n.lib \"" ++ long ++ "\" tt\n.include \"" ++ long ++ long ++ "\"\n.end\n", &r);
    try has(out, ".lib \"" ++ long ++ "\" tt\n");
    try has(out, ".include \"" ++ long ++ long ++ "\"\n");
}

test "parse check: a model parameter given twice keeps the last, as SPICE does" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // FreePDK45's PMOS_VTL gives toxref twice; Xyce rejects such a card.
    var r: ir.Report = .init(a);
    const out = try tr(a, "hspice", "xyce", "t\n.model p1 pmos level=54 toxref=1.26n vsat=69000 toxref=1.3n\n.end\n", &r);
    try has(out, ".model p1 pmos level=14 vsat=69000 toxref=1.3n\n");
    try reported(&r, .warning, "model 'p1': 'toxref' is given twice; the last value is kept");
}

test "sim check: Xyce gmin and nodeset differ from ngspice and say so" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\n.options gmin=1e-3\n.nodeset v(a)=1\nR1 a 0 1\n.op\n.end\n", &r);
    try reported(&r, .warning, "options.gmin: Xyce adds GMIN differently from ngspice");
    try reported(&r, .warning, "nodeset.values: Xyce and ngspice apply nodesets with different algorithms");
}

test "sim check: a switch's threshold and hysteresis become Xyce's on and off levels" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Xyce ignores VT/VH (with a warning) and switched at its default levels.
    var r: ir.Report = .init(a);
    const src = "t\nS1 a 0 c 0 sw1\n.model sw1 sw(vt=2.5 vh=0.5 ron=1 roff=1meg)\n.model cw csw(it=1m ih=0.2m)\n.end\n";
    const xy = try tr(a, "ngspice", "xyce", src, &r);
    try has(xy, ".model sw1 vswitch von=3 voff=2 ron=1 roff=1meg\n");
    try has(xy, ".model cw iswitch ion=1200u ioff=800u\n");
    try reported(&r, .warning, "model 'sw1': the threshold and hysteresis are written as on and off levels");
    try testing.expect(!r.hasErrors());
    // Read back, the levels are SPICE's midpoint and half-width again.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "xyce", "ngspice", xy, &r2), ".model sw1 sw vt=2.5 vh=0.5 ron=1 roff=1meg\n");
    // Without hysteresis the two levels would be equal, which Xyce cannot run.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\n.model s0 sw(vt=1)\n.end\n", &r3);
    try reported(&r3, .@"error", "model 's0': a switch with no hysteresis has no xyce form");
}

// ---------------------------------------------------------------------------
// Gaps found by translating a proprietary HSPICE model library. Every deck
// here is synthetic: it reproduces the shape of what the library does, with
// made-up names and values. Each test states the behaviour wanted; all of
// them are fixed and run.

fn anyMsgHasAll(report: *const ir.Report, needles: []const []const u8) bool {
    for (report.items.items) |d| {
        for (needles) |n| {
            if (std.mem.indexOf(u8, d.msg, n) == null) break;
        } else return true;
    }
    return false;
}

test "gap: an unquoted function call is a value in an HSPICE .param" {
    // gap: hspice reader. `( , )` are blanks in the HSPICE lexer, so a bare
    // call such as agauss(0,1,3) splits and the whole .param is untranslated.
    // Model libraries write Monte Carlo parameters this way.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const xy = try tr(a, "hspice", "xyce",
        \\t
        \\.param dvt=agauss(0,1,3) du=aunif(0,1) wr = wmin*max(nf,2)/2
        \\.param xr = aunif('xc/2','xc/2')
        \\.end
    , &report);
    try testing.expectEqual(0, report.countCode(.untranslated));
    try has(xy, "agauss(0,1,3)");
    try has(xy, "wmin*max(nf,2)/2");
}

test "gap: HSPICE coupling written with k=" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const kw = try tr(a, "hspice", "spectre", "t\nL1 a 0 1n\nL2 b 0 1n\nK1 L1 L2 k=0.5\n.end\n", &r1);
    var r2: ir.Report = .init(a);
    const pos = try tr(a, "hspice", "spectre", "t\nL1 a 0 1n\nL2 b 0 1n\nK1 L1 L2 0.5\n.end\n", &r2);
    try testing.expectEqual(0, r1.countCode(.untranslated));
    try testing.expectEqualStrings(pos, kw);
}

test "gap: function definitions and values in one HSPICE .param" {
    // gap: hspice reader. A .param holding one function definition is read;
    // several definitions, or a definition next to a plain value, are not.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const ng = try tr(a, "hspice", "ngspice",
        \\t
        \\.param
        \\+ sq(x,y)='(x+y)**2'
        \\+ k0 = 1
        \\+ cu(x)='x**3'
        \\.param z='sq(k0,2)+cu(2)'
        \\.end
    , &report);
    try testing.expectEqual(0, report.countCode(.untranslated));
    try has(ng, ".param k0=1");
    try clean(&report);
}

test "gap: a $ comment after a backslash-continued HSPICE expression" {
    // gap: hspice reader. The continued expression is read without the
    // comment; with a trailing `$` comment on its last line the statement
    // is untranslated.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const sp = try tr(a, "hspice", "spectre",
        \\t
        \\.param b=1 c=2
        \\.param a='(b == 1 ? c : \\
        \\        (b == 2 ? 3 : 4))' $ note (x), y
        \\.end
    , &report);
    try testing.expectEqual(0, report.countCode(.untranslated));
    try has(sp, "a=((b == 1 ? c : (b == 2 ? 3 : 4)))");
}

test "gap: ngspice .func with several arguments needs commas" {
    // gap: ngspice grammar (xyce's has the same rule, not checked): `args*`
    // writes `.func sq(a b) {...}`, which ngspice 45 rejects ("failed to
    // parse .func"); `.func sq(a, b)` loads.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const ng = try tr(a, "hspice", "ngspice", "t\n.param sq(a,b)='(a+b)**2'\n.end\n", &report);
    try has(ng, ".func sq(a,b) {(a+b)**2}");
}

test "gap: Spectre user functions" {
    // gap: spectre grammar has no rule for `func` (README, Known limits).
    // Spectre accepts `real f(real a) { return ... }` at top level and inside
    // a subcircuit, where the body may use the subcircuit's parameters
    // (checked with a synthetic deck). A library of model wrappers defines
    // its geometry helpers this way, so without it nothing loads.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const sp = try tr(a, "hspice", "spectre",
        \\t
        \\.subckt rr a b w=2
        \\.param f(x)='x*w'
        \\r1 a b 'f(3)'
        \\.ends rr
        \\.end
    , &report);
    // Loads in Spectre with the subcircuit's w (checked: f(3) is 6 ohm).
    try has(sp, "real f(real x) {\nreturn (x*w)\n}\n");
    try clean(&report);
}

test "gap: binned HSPICE models become one Spectre model group" {
    // gap: spectre writer. `.model nch.1 ...` / `.model nch.2 ...` are
    // written as `model nch.1 bsim4 ...`, and Spectre does not pick a bin
    // for an instance of `nch` from those: it reports `nch` undefined.
    // A model group `model nch bsim4 { 1: ... 2: ... }` loads and selects
    // by lmin/lmax (checked with a synthetic deck). No diagnostic today.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const sp = try tr(a, "hspice", "spectre",
        \\t
        \\M1 d g 0 0 nch l=100n w=1u
        \\.model nch.1 nmos level=54 lmin=50n lmax=200n vth0=0.4
        \\.model nch.2 nmos level=54 lmin=200n lmax=10u vth0=0.4
        \\.end
    , &report);
    try has(sp, "model nch bsim4 {\n");
    try has(sp, "1: type=n lmin=50n lmax=200n vth0=0.4\n");
}

test "a subcircuit named like the model its transistor uses" {
    // HSPICE resolves `m0 ... nch` to the model inside subckt nch; Spectre
    // resolves it to the subcircuit and stops on a recursive call. The
    // model is renamed, and the transistor with it.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const sp = try tr(a, "hspice", "spectre",
        \\t
        \\.subckt nch d g s b l=100n w=1u
        \\m0 d g s b nch l=l w=w
        \\.ends nch
        \\.model nch.1 nmos level=54 lmin=50n lmax=200n
        \\.model nch.2 nmos level=54 lmin=200n lmax=10u
        \\.end
    , &report);
    try has(sp, "subckt nch (d g s b)\n");
    try has(sp, "m0 (d g s b) nch__m l=l w=w\n");
    try has(sp, "model nch__m bsim4 {\n");
    try reported(&report, .info, "'nch' names both a model and a subcircuit: the model is written as 'nch__m'");
    try testing.expectEqual(0, report.count(.@"error"));

    // The new name is a declared model: a resistor that names it is not
    // told its model is nowhere.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "spectre", "t\n.model rm r rsh=10\n.subckt rm a b\nR1 a b rm w=1u\n.ends rm\nR9 a 0 rm w=1u\n.end\n", &r2), "R9 (a 0) rm__m w=1u\n");
    try testing.expect(!r2.contains(.warning, "is a model name in"));
}

test "gap: a parameter defined twice" {
    // gap: spectre writer. HSPICE takes a repeated .param silently; Spectre
    // stops with an error unless told otherwise. A library repeats some 100
    // parameters across its include files. Wanted: a report entry (or the
    // option that makes Spectre accept it, with a caveat).
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    _ = try tr(a, "hspice", "spectre", "t\n.param vt0=0.3\n.param vt0=0.35\n.end\n", &report);
    try testing.expect(anyMsgHasAll(&report, &.{"vt0"}));
}

test "gap: a project keeps Verilog-A sources and section spellings" {
    // gap: project. (1) A section referenced as `typ` from another file but
    // defined as `.lib Typ` is written `section=typ`; Spectre matches section
    // names exactly and does not find it. Within one file the spelling is
    // already unified. (2) `.hdl './cap.va'` stays a relative path in the
    // translated tree, but the .va file is not copied there (nor the path
    // pointed back at the source), so Spectre cannot open it. Also the
    // caveat about compiled OSDI files is attached to a .va source.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "in");
    try tmp.dir.writeFile(io, .{ .sub_path = "in/top.lib", .data =
        \\.lib tt
        \\.lib 'w.lib' typ
        \\.hdl './cap.va'
        \\.endl tt
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "in/w.lib", .data = ".lib Typ\n.param rw=1\n.endl Typ\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "in/cap.va", .data = "module cap(a, b); endmodule\n" });
    const hspice = sprack.find("hspice").?;
    const spectre = sprack.find("spectre").?;
    var log: std.Io.Writer.Allocating = .init(a);
    _ = try sprack.project.run(io, testing.allocator, .{
        .from = hspice,
        .to = spectre,
        .tops = &.{try std.fmt.allocPrint(a, "{s}/in/top.lib", .{base})},
        .out_dir = try std.fmt.allocPrint(a, "{s}/out", .{base}),
        .library = true,
        .log = &log.writer,
    });
    const top = try tmp.dir.readFileAlloc(io, "out/top.lib", a, .unlimited);
    try has(top, "include \"w.lib\" section=Typ\n");
    const va_copied = if (tmp.dir.access(io, "out/cap.va", .{})) |_| true else |_| false;
    try testing.expect(va_copied or std.mem.indexOf(u8, top, "ahdl_include \"./cap.va\"") == null);
    try testing.expect(std.mem.indexOf(u8, log.written(), "OSDI") == null);
}

// b2: statistics and structure

fn writeLib(a: std.mem.Allocator, from: []const u8, to: []const u8, src: []const u8, report: *ir.Report) ![]const u8 {
    const nl = try sprack.reader.read(sprack.find(from).?, a, src, report, .{ .library = true });
    var aw: std.Io.Writer.Allocating = .init(a);
    try sprack.write(a, sprack.find(to).?, &aw.writer, &nl, report);
    return aw.written();
}

test "statistics: Spectre blocks, SPICE random functions, HSPICE variation" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const scs =
        \\// t
        \\parameters x=1 y=2 z=3
        \\statistics {
        \\process {
        \\vary x dist=gauss std=0.1
        \\vary y dist=unif N=0.2
        \\}
        \\mismatch {
        \\vary z dist=gauss std=0.05
        \\}
        \\correlate param=[x y] cc=0.5
        \\}
        \\
    ;
    // Read and written back the same.
    var r1: ir.Report = .init(a);
    const same = try tr(a, "spectre", "spectre", scs, &r1);
    try clean(&r1);
    try has(same, "statistics {\nprocess {\nvary x dist=gauss std=0.1\nvary y dist=unif N=0.2\n}\nmismatch {\nvary z dist=gauss std=0.05\n}\ncorrelate param=[x y] cc=0.5\n}\n");
    // Process variations become random functions where the parameter is
    // defined; a mismatch variation and a correlation have no SPICE form.
    var r2: ir.Report = .init(a);
    const ng = try tr(a, "spectre", "ngspice", scs, &r2);
    try has(ng, ".param x={agauss(1, 0.1, 1)} y={aunif(2, 0.2)} z=3\n");
    try reported(&r2, .@"error", "statement 'statistics' cannot be written for ngspice");
    try reported(&r2, .warning, "vary x: written as a random function");
    var r3: ir.Report = .init(a);
    const hs = try tr(a, "spectre", "hspice", scs, &r3);
    try has(hs, ".param x='agauss(1, 0.1, 1)'");
    try reported(&r3, .@"error", "statement 'correlate' cannot be written for hspice");

    // Random functions into Spectre: a whole-parameter call keeps the
    // parameter and varies it per run; a call inside a subcircuit is a new
    // parameter varied per instance, with ngspice's zero-sigma case kept.
    const lib =
        \\.lib tt
        \\.param p1 = agauss(1k, 100, 1) n0 = 0
        \\.subckt rr a b
        \\r1 a b {agauss(1k, 100, n0)}
        \\r2 a b {gauss(1k, 0.1, 1)}
        \\.ends
        \\.endl tt
        \\
    ;
    var r4: ir.Report = .init(a);
    const sp = try writeLib(a, "ngspice", "spectre", lib, &r4);
    try clean(&r4);
    try has(sp, "parameters p1=1k n0=0\n");
    try has(sp, "r1 (a b) resistor r=((1k + ((n0) == 0 ? 0 : (100)/(n0))*sprack_rv_rr_r1))\n");
    try has(sp, "r2 (a b) resistor r=((1k)*(1 + 0.1*sprack_rv_rr_r2))\n");
    try has(sp, "parameters sprack_rv_rr_r1=0 sprack_rv_rr_r2=0\nstatistics {\nprocess {\nvary p1 dist=gauss std=100\n}\nmismatch {\nvary sprack_rv_rr_r1 dist=gauss std=1\nvary sprack_rv_rr_r2 dist=gauss std=1\n}\n}\nendsection tt\n");
    try reported(&r4, .warning, "written as spectre statistics variations");

    // HSPICE's .VARIATION varies model parameters, absolutely or in percent.
    const hsv =
        \\t
        \\.model rm r rsh=1
        \\.variation
        \\.global_variation
        \\r rm rsh=0.1
        \\.end_global_variation
        \\.local_variation
        \\r rm rsh=5 %
        \\.end_local_variation
        \\.end_variation
        \\.end
        \\
    ;
    var r5: ir.Report = .init(a);
    const back = try tr(a, "hspice", "hspice", hsv, &r5);
    try clean(&r5);
    try has(back, ".variation\n.global_variation\nr rm rsh=0.1\n.end_global_variation\n.local_variation\nr rm rsh=5 %\n.end_local_variation\n.end_variation\n");
    var r6: ir.Report = .init(a);
    _ = try tr(a, "hspice", "spectre", hsv, &r6);
    try reported(&r6, .@"error", "vary.model = rm has no spelling in spectre");
}

test "Spectre: insensitive=yes from a source that folds case, kept from Spectre" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const folded = "simulator lang=spectre insensitive=yes\nglobal 0\n";
    var r1: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "spectre", "t\nV1 IN 0 1\nr1 in 0 1k\n.end\n", &r1), "// t\n" ++ folded ++ "V1 (IN 0) vsource dc=1\nr1 (IN 0) resistor r=1k\n");
    try clean(&r1);
    // Spectre to Spectre: the header the source had, first line or a later switch.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "spectre", "spectre", "// t\nsimulator lang=spectre\nr1 (a 0) resistor r=1k\n", &r2), "// t\nsimulator lang=spectre\nglobal 0\nr1");
    var r3: ir.Report = .init(a);
    const ins = "// t\nsimulator lang=spectre insensitive=yes\nr1 (a 0) resistor r=1k\n";
    try has(try tr(a, "spectre", "spectre", ins, &r3), "// t\n" ++ folded ++ "r1 (a 0) resistor r=1k\n");
    try clean(&r3);
    var r4: ir.Report = .init(a);
    try has(try tr(a, "spectre", "spectre", "// t\nsimulator lang=spectre\nr1 (a 0) resistor r=1k\nsimulator lang=spectre insensitive=yes\nr2 (a 0) resistor r=1k\n", &r4), "// t\n" ++ folded ++ "r1 (a 0) resistor r=1k\nr2 (a 0) resistor r=1k\n");
    // Folding merges names the source kept apart.
    var r5: ir.Report = .init(a);
    _ = try tr(a, "spectre", "spectre", "// t\nsimulator lang=spectre\nr1 (a 0) resistor r=1k\nsimulator lang=spectre insensitive=yes\nR1 (b 0) resistor r=1k\n", &r5);
    try reported(&r5, .@"error", "'r1' and 'R1' are different names in the source but the same name in spectre");
    // Nothing of it reaches a SPICE dialect, which folds case anyway.
    var r6: ir.Report = .init(a);
    try has(try tr(a, "spectre", "ngspice", ins, &r6), "t\nr1 a 0 1k\n.end\n");
    try clean(&r6);
    // The reader records it; the JSON form carries it as `folds_case`.
    var r7: ir.Report = .init(a);
    const nl = try sprack.read(a, sprack.find("spectre").?, ins, &r7);
    try testing.expect(nl.folds_case);
}

test "Spectre: a simulator lang=spice section is read as HSPICE" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\// t
        \\simulator lang=spectre
        \\r0 (a 0) resistor r=1k
        \\simulator lang=spice
        \\.param rv=2k
        \\R1 a b 'rv*2'
        \\simulator lang=spectre
        \\r2 (b 0) resistor r=3k
        \\
    ;
    var r1: ir.Report = .init(a);
    const ng = try tr(a, "spectre", "ngspice", src, &r1);
    try clean(&r1);
    try has(ng, "r0 a 0 1k\n.param rv=2k\nR1 a b {rv*2}\nr2 b 0 3k\n");
    var r2: ir.Report = .init(a);
    const sp = try tr(a, "spectre", "spectre", src, &r2);
    try clean(&r2);
    try has(sp, "r0 (a 0) resistor r=1k\nparameters rv=2k\nR1 (a b) resistor r=rv*2\nr2 (b 0) resistor r=3k\n");
    // Spectre reads the spice section ignoring case; written in Spectre's
    // syntax, it keeps that only with insensitive=yes.
    try has(sp, "// t\nsimulator lang=spectre insensitive=yes\nglobal 0\n");
    // Line numbers are the file's.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "spectre", "ngspice", "// t\nsimulator lang=spice\n.bogus x\n", &r3);
    try reported(&r3, .@"error", "no hspice rule understood this line");
    try testing.expectEqual(@as(u32, 3), r3.items.items[0].line);
    // Read with the grammar loaded from its file, back in Spectre is back in
    // that grammar: once it was the built-in of the name, and r0 and r2
    // came out as statements of another dialect.
    var r4: ir.Report = .init(a);
    const nl = try sprack.read(a, try loadedGrammar("spectre"), src, &r4);
    try testing.expectEqual(@as(u8, 0), nl.stmts[0].dialect);
    try testing.expectEqual(@as(u8, 0), nl.stmts[nl.stmts.len - 1].dialect);
    try testing.expect(nl.stmts[1].dialect != 0);
}

test "HSPICE dev/gauss= and names Xyce keeps for itself" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\n.param vt=3.5m\n.param czero=1p dev/gauss=0.1p\nC1 a 0 {czero}\n.end\n";
    var r1: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", src, &r1);
    try has(xy, ".param vt__p=3.5m\n.param czero={agauss(1p, 0.1p, 1)}\n");
    try reported(&r1, .warning, "dev/gauss=");
    try reported(&r1, .info, "parameter 'vt' is written as 'vt__p'");
    // Into Spectre the variation becomes a statistics block.
    var r2: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre", src, &r2);
    try has(sp, "vary czero dist=gauss std=0.1p\n");
    // HSPICE reads the form itself.
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "hspice", src, &r3), "dev/gauss=0.1p");

    // Several on one card: each is the variation of the parameter before
    // it, in a subcircuit (per instance) and at the top level (per run).
    const two = "t\n.param a=1 dev/gauss=0.1 b=2 dev/gauss=0.2\n.subckt s p n\n.param\n+ x=1k dev/gauss=10\n+ y=2 dev/gauss=0.2\nR1 p n {x*y}\n.ends\nX1 p 0 s\nR2 p 0 {a*b}\n.end\n";
    var r5: ir.Report = .init(a);
    const sp2 = try tr(a, "ngspice", "spectre", two, &r5);
    try has(sp2, "vary a dist=gauss std=0.1\nvary b dist=gauss std=0.2\n");
    try has(sp2, "parameters x=((1k + 10*sprack_rv_s_x)) y=((2 + 0.2*sprack_rv_s_y))\n");
    try has(sp2, "mismatch {\nvary sprack_rv_s_x dist=gauss std=1\nvary sprack_rv_s_y dist=gauss std=1\n}\n");
    try testing.expectEqual(0, r5.count(.@"error"));
    var r6: ir.Report = .init(a);
    // For Xyce the subcircuit's own parameters go on its header (`hoist param`).
    try has(try tr(a, "ngspice", "xyce", two, &r6), ".subckt s p n params: x={agauss(1k, 10, 1)} y={agauss(2, 0.2, 1)}\n");
    try testing.expectEqual(0, r6.count(.@"error"));
    // A parameter given twice is still told, with variations between.
    var r7: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "spectre", "t\n.param a=1 dev/gauss=0.1 a=2 dev/gauss=0.2\nR1 p 0 {a}\n.end\n", &r7);
    try reported(&r7, .@"error", "parameter 'a' is defined twice");
}

test "statistics: a variation said the other way reads back that way, and one note for the file says so" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Random functions as a statistics block: the note is the only entry
    // that explains the block read back (`tr` fails on a difference with none).
    var r1: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "spectre", "t\n.param vth={agauss(0.4, 0.01, 3)} tox={aunif(2n, 0.1n)}\n.subckt s a b\nR1 a b {gauss(1k, 0.1, 1)}\n.ends\n.end\n", &r1);
    try reported(&r1, .info, "3 parameters varied in a statistics block in place of a random function; spectre reads back the block, not the function");
    try testing.expectEqual(1, r1.countCode(.oneway));
    // A statistics block as random functions.
    var r2: ir.Report = .init(a);
    const ng = try tr(a, "spectre", "ngspice", "// t\nparameters vth=0.4 tox=2n\nstatistics {\nprocess {\nvary vth dist=gauss std=0.01\nvary tox dist=unif N=0.1n\n}\n}\n", &r2);
    try has(ng, ".param vth={agauss(0.4, 0.01, 1)} tox={aunif(2n, 0.1n)}\n");
    try clean(&r2);
    try reported(&r2, .info, "2 parameters varied by a random function in the definition, in place of a variation given separately; ngspice reads back the function, not the variation");
    try testing.expectEqual(1, r2.countCode(.oneway));
    // HSPICE's dev/gauss= as a random function.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\n.param czero=1p dev/gauss=0.1p\nC1 a 0 {czero}\n.end\n", &r3);
    try reported(&r3, .info, "1 parameter varied by a random function in the definition, in place of a variation given separately; xyce reads back the function, not the variation");
    // Nothing varied, nothing said.
    var r4: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "spectre", "t\n.param vth=0.4\n.end\n", &r4);
    _ = try tr(a, "spectre", "ngspice", "// t\nparameters vth=0.4\n", &r4);
    try testing.expectEqual(0, r4.items.items.len);
}

test "statistics: the block's own parameters are a loss where its variations are random functions" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // No grammar reads or writes them: the block is `statistics {` in
    // Spectre and `.variation` in HSPICE, with no value of its own.
    var rj: ir.Report = .init(a);
    const with = try sprack.json.parseNetlist(a, "{\"title\":\"t\",\"stmts\":[{\"kind\":\"statistics\",\"params\":[[\"k1\",1],[\"flag\",null]]}]}", &rj);
    const bare = try sprack.json.parseNetlist(a, "{\"title\":\"t\",\"stmts\":[{\"kind\":\"statistics\"}]}", &rj);
    try testing.expectEqual(0, rj.items.items.len);
    // (Spectre is the one that keeps the block: its writer says the same.)
    for ([_][]const u8{ "ngspice", "xyce", "vacask", "hspice", "spectre" }) |to| {
        errdefer std.debug.print("to {s}\n", .{to});
        var r1: ir.Report = .init(a);
        _ = try writeAs(a, to, &with, &r1);
        try reported(&r1, .@"error", try std.fmt.allocPrint(a, "statistics: 'k1=1' has no spelling in {s}", .{to}));
        try reported(&r1, .@"error", try std.fmt.allocPrint(a, "statistics: 'flag' has no spelling in {s}", .{to}));
        try testing.expectEqual(2, r1.countCode(.loss));
        // A block that says nothing is nothing to write, and no loss.
        var r2: ir.Report = .init(a);
        _ = try writeAs(a, to, &bare, &r2);
        try testing.expectEqual(0, r2.items.items.len);
    }
}

test "JSON that is not a document reads as nothing; a problem inside one leaves the rest" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    try testing.expect(try sprack.json.parseDocument(a, "{\"stmts\":", &r) == null);
    try testing.expect(try sprack.json.parseDocument(a, "[]", &r) == null);
    try testing.expectEqual(2, r.count(.@"error"));
    const nl = (try sprack.json.parseDocument(a, "{\"stmts\":[{\"kind\":\"zener\"},{\"kind\":\"resistor\",\"name\":\"R1\",\"pos\":\"a\",\"neg\":\"0\",\"r\":\"1k\"}]}", &r)).?;
    try testing.expectEqual(3, r.count(.@"error"));
    try testing.expectEqual(1, countKind(nl, .resistor));
}

test "Monte Carlo: Spectre montecarlo, HSPICE monte=, Xyce .sampling" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const scs = "// t\nr1 (a 0) resistor r=1k\nmc1 montecarlo numruns=30 seed=1 {\ntr1 tran stop=1u\n}\n";
    var r1: ir.Report = .init(a);
    try has(try tr(a, "spectre", "spectre", scs, &r1), "mc1 montecarlo numruns=30 seed=1 {\ntr1 tran stop=1u\n}\n");
    try clean(&r1);
    var r2: ir.Report = .init(a);
    try has(try tr(a, "spectre", "hspice", scs, &r2), ".tran '1u/1000' 1u sweep monte=30\n");
    try reported(&r2, .warning, "HSPICE takes the Monte Carlo seed from .OPTION SEED");
    var r3: ir.Report = .init(a);
    const sp = try tr(a, "hspice", "spectre", "t\nr1 a 0 1k\n.tran 1n 1u sweep monte=30\n.end\n", &r3);
    try clean(&r3);
    try has(sp, "montecarlo numruns=30 variations=all {\ntran1 tran step=1n stop=1u\n}\n");
    var r4: ir.Report = .init(a);
    const xy = try tr(a, "spectre", "xyce", scs, &r4);
    try clean(&r4);
    try has(xy, ".sampling useexpr=true\n.options samples numsamples=30 seed=1\n.tran {1u/1000} 1u\n");
    var r5: ir.Report = .init(a);
    try has(try tr(a, "xyce", "spectre", xy, &r5), "montecarlo numruns=30 seed=1 variations=all {\n");
    var r6: ir.Report = .init(a);
    _ = try tr(a, "spectre", "ngspice", scs, &r6);
    try reported(&r6, .@"error", "ngspice has no Monte Carlo statement");
}

test "Spectre structure: binned models, inline subcircuits, libraries" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // SPICE bins are separate cards; Spectre groups them under one model.
    const ng = "t\n.model nch.1 nmos level=54 lmin=0.1u lmax=1u\n.model nch.2 nmos level=54 lmin=1u lmax=10u\nM1 d g 0 0 nch w=1u l=2u\n.end\n";
    var r1: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre", ng, &r1);
    try clean(&r1);
    try has(sp, "model nch bsim4 {\n1: type=n lmin=0.1u lmax=1u\n2: type=n lmin=1u lmax=10u\n}\n");
    var r2: ir.Report = .init(a);
    const back = try tr(a, "spectre", "ngspice", sp, &r2);
    try clean(&r2);
    try has(back, ".model nch.1 nmos level=14 lmin=0.1u lmax=1u\n.model nch.2 nmos level=14 lmin=1u lmax=10u\nM1 d g 0 0 nch w=1u l=2u\n");
    // An inline subcircuit is an ordinary one elsewhere, with a caveat.
    const inl = "// t\ninline subckt cell (a b)\ncell (a b) resistor r=1k\nends cell\nx1 (n 0) cell\n";
    var r3: ir.Report = .init(a);
    try has(try tr(a, "spectre", "spectre", inl, &r3), "inline subckt cell (a b)\n");
    var r4: ir.Report = .init(a);
    try has(try tr(a, "spectre", "ngspice", inl, &r4), ".subckt cell a b\n");
    try reported(&r4, .warning, "ngspice has no inline subcircuits");
    // A library wraps sections; elsewhere its name is a comment.
    var r5: ir.Report = .init(a);
    const libs = "simulator lang=spectre\nlibrary mylib\nsection tt\nparameters r0=1k\nendsection tt\nendlibrary mylib\n";
    try has(try writeLib(a, "spectre", "spectre", libs, &r5), "library mylib\nsection tt\nparameters r0=1k\nendsection tt\nendlibrary mylib\n");
    try has(try writeLib(a, "spectre", "ngspice", libs, &r5), "* library mylib\n.lib tt\n.param r0=1k\n.endl tt\n* endlibrary\n");
}

test "b3 analyses: periodic small-signal, mismatch, transient noise, loop stability" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // HSPICE SN and HB forms keep their engine through Spectre and back.
    const hs =
        \\t
        \\Vin in 0 ac 1 sin(0 1 1k)
        \\R1 in out 1k
        \\E1 b 0 0 fb 10
        \\Vprobe b fb 0
        \\.sn tone=1k nharms=8
        \\.snac lin 3 100 300
        \\.snnoise v(out) Vin dec 3 10 10k
        \\.snxf v(out,in) dec 3 10 10k
        \\.hb tones=1k nharms=5
        \\.hbac dec 4 10 10k
        \\.hbnoise v(out) Vin dec 3 10 10k
        \\.hbxf v(out) dec 3 10 10k
        \\.dcmatch v(out)
        \\.ac dec 10 1 1meg
        \\.lstb mode=single vsource=Vprobe
        \\.end
    ;
    var r1: ir.Report = .init(a);
    const sp = try tr(a, "hspice", "spectre", hs, &r1);
    try clean(&r1);
    try has(sp, "pac1 pac start=100 stop=300 lin=3\n");
    try has(sp, "pnoise1 (out 0) pnoise iprobe=Vin refsideband=0 start=10 stop=10k dec=3\n");
    try has(sp, "pxf1 (out in) pxf start=10 stop=10k dec=3\n");
    try has(sp, "pac2 hbac start=10 stop=10k dec=4\n");
    try has(sp, "pnoise2 (out 0) hbnoise iprobe=Vin refsideband=0 start=10 stop=10k dec=3\n");
    try has(sp, "pxf2 (out 0) hbxf start=10 stop=10k dec=3\n");
    try has(sp, "dcmatch1 (out 0) dcmatch\n");
    try has(sp, "stb1 stb start=1 stop=1M dec=10 probe=Vprobe\n");
    var r2: ir.Report = .init(a);
    const back = try tr(a, "spectre", "hspice", sp, &r2);
    try clean(&r2);
    try has(back, ".snac lin 3 100 300\n");
    try has(back, ".hbnoise v(out) Vin dec 3 10 10k\n");
    try has(back, ".snxf v(out,in) dec 3 10 10k\n");
    try has(back, ".ac dec 10 1 1meg\n.lstb mode=single vsource=Vprobe\n");

    // Spectre-only analyses read as statements, not as instances.
    var r3: ir.Report = .init(a);
    const only = try readAs(a, "spectre", "t\nxf1 (out 0) xf start=1 stop=1k dec=10\nenv1 envlp clockname=\"clk\" stop=5m\nqp1 qpss funds=[\"f1\" \"f2\"] maxharms=[2 2]\n", &r3);
    try testing.expectEqual(1, countKind(only, .xf));
    try testing.expectEqual(1, countKind(only, .envelope));
    try testing.expectEqual(1, countKind(only, .qpss));

    // VACASK: acxf, and pac on the period it is given.
    var r4: ir.Report = .init(a);
    const va = try tr(a, "spectre", "vacask", "t\nxf1 (out 0) xf start=1 stop=1k dec=10\n", &r4);
    try clean(&r4);
    try has(va, "analysis xf1 acxf out=\"out\" from=1 to=1k mode=\"dec\" points=10\n");
    var r5: ir.Report = .init(a);
    const vp = try tr(a, "vacask", "vacask", "t\ncontrol\nanalysis pac1 pac tper=1m from=10 to=10k mode=\"lin\" points=9\nendc\n", &r5);
    try clean(&r5);
    try has(vp, "analysis pac1 pac tper=1m from=10 to=10k mode=\"lin\" points=9\n");
    var r6: ir.Report = .init(a);
    _ = try tr(a, "spectre", "vacask", "t\npss1 pss fund=1k\npac1 pac start=10 stop=10k dec=4\n", &r6);
    try reported(&r6, .@"error", "pac: no vacask form of this statement can say a statement without 'fund'");

    // HSPICE transient noise: its own card there, an error naming why elsewhere.
    var r7: ir.Report = .init(a);
    const tn = try tr(a, "hspice", "hspice", "t\nR1 out 0 1k\n.tran 1u 1m\n.trannoise v(out) samples=2 seed=1\n", &r7);
    try has(tn, ".trannoise v(out) samples=2 seed=1\n");
    var r8: ir.Report = .init(a);
    _ = try tr(a, "hspice", "spectre", "t\nR1 out 0 1k\n.tran 1u 1m\n.trannoise v(out) samples=2\n", &r8);
    try reported(&r8, .@"error", "Spectre runs transient noise as parameters of the tran analysis");
}

test "a rule that depends on the model's family: Xyce HICUM's thermal node" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nq1 c b 0 0 hm\nq2 c b 0 gp\n.model hm npn level=8\n.model gp npn\n.end\n";
    var r1: ir.Report = .init(a);
    const x = try tr(a, "ngspice", "xyce", src, &r1);
    try has(x, "q1 c b 0 0 dtq1 hm\n");
    try has(x, "q2 c b 0 gp\n");
    try reported(&r1, .warning, "xyce needs 'tj' but the source gave none; wrote dtq1");
    // Without the card in the file the plain forms are used.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", "t\nq1 c b 0 0 hm\n.end\n", &r2), "q1 c b 0 0 hm\n");
}

test "b4: lossy and coupled lines take their letter from the model" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\t
        \\o1 a 0 b 0 lline
        \\.model lline ltra r=1 l=250n g=0 c=100p len=2
        \\y1 a 0 c 0 ymod
        \\.model ymod txl r=1u l=250n g=0 c=100p length=1
        \\P1 a1 a2 0 b1 b2 0 pline
        \\.model pline cpl r=0.2 0 0.2 l=9.13n 3.3n 9.13n length=10
        \\.end
    ;
    var r1: ir.Report = .init(a);
    const nl = try readAs(a, "ngspice", src, &r1);
    try testing.expectEqual(3, countKind(nl, .lossyline));
    try clean(&r1);
    // The same dialect: each letter back, the CPL matrix as numbers after its key.
    const same = try tr(a, "ngspice", "ngspice", src, &r1);
    try has(same, "o1 a 0 b 0 lline\n");
    try has(same, "y1 a 0 c 0 ymod\n");
    try has(same, "P1 a1 a2 0 b1 b2 0 pline\n");
    try has(same, ".model pline cpl r=0.2 0 0.2 l=9.13n 3.3n 9.13n length=10\n");
    try clean(&r1);
    // Xyce has the LTRA line only.
    var r2: ir.Report = .init(a);
    const x = try tr(a, "ngspice", "xyce", src, &r2);
    try has(x, "o1 a 0 b 0 lline\n");
    try reported(&r2, .@"error", "no xyce form of this statement can say a model of family 'txl'");
    try reported(&r2, .@"error", "no spelling for model family 'cpl'. Defined by: ngspice");
    // HSPICE's W element with an RLGC model, read and written.
    const w = "t\nW1 a1 a2 0 b1 b2 0 RLGCmodel=pline N=2 l=10\n.model pline W modeltype=RLGC N=2 Lo=9.13n 3.3n 9.13n\n.end\n";
    var r3: ir.Report = .init(a);
    const hs = try tr(a, "hspice", "hspice", w, &r3);
    try has(hs, "W1 a1 a2 0 b1 b2 0 rlgcmodel=pline n=2 l=10\n");
    try has(hs, ".model pline w modeltype=rlgc n=2 lo=9.13n 3.3n 9.13n\n");
    try clean(&r3);
    var r4: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ngspice", w, &r4);
    try reported(&r4, .@"error", "no ngspice form of this statement can say a model of family 'rlgc'");
}

test "b4: controlled sources in POLY, TABLE, LAPLACE, POLE, VCR and VCCAP form" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\t
        \\e1 o1 0 poly(2) a 0 b 0 0 1 1
        \\g2 0 o2 poly(1) a 0 0 1m
        \\f3 0 o3 poly(1) vs 0 2
        \\h4 o4 0 poly(1) vs 0 1k
        \\e5 o5 0 table {v(a)} = (0,0) (1,2) (2,2)
        \\vs s 0 0
        \\.end
    ;
    var r1: ir.Report = .init(a);
    const nl = try readAs(a, "ngspice", src, &r1);
    try testing.expectEqual(5, countKind(nl, .ctlsrc));
    for ([_][]const u8{ "xyce", "hspice" }) |to| {
        var r: ir.Report = .init(a);
        const out = try tr(a, "ngspice", to, src, &r);
        try has(out, "e1 o1 0 poly(2) a 0 b 0 0 1 1\n");
        try has(out, "f3 0 o3 poly(1) vs 0 2\n");
    }
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", src, &r2), "e5 o5 0 table {v(a)} =(0,0)(1,2)(2,2)\n");
    try clean(&r2);
    // A one-input polynomial is Spectre's pvccs; a two-input one is not.
    var r3: ir.Report = .init(a);
    const sx = try tr(a, "ngspice", "spectre", src, &r3);
    try has(sx, "g2 (0 o2 a 0) pvccs coeffs=[0 1m]\n");
    try reported(&r3, .@"error", "more than one 'cpos'");
    const h =
        \\t
        \\e1 b 0 laplace a 0 1 / 1 1e-3
        \\e2 b 0 pole a 0 1e4 1e3,0 / 1 1e2,0 1e4,0
        \\g8 o8 0 vcr c 0 2
        \\g9 o9 0 vccap c 0 1u
        \\.end
    ;
    var r4: ir.Report = .init(a);
    const hs = try tr(a, "hspice", "hspice", h, &r4);
    try has(hs, "e1 b 0 laplace a 0 1 / 1 1m\n");
    try has(hs, "e2 b 0 pole a 0 1e4 1k,0 / 1 100,0 1e4,0\n");
    try has(hs, "g8 o8 0 vcr c 0 2\n");
    try clean(&r4);
    var r5: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ngspice", h, &r5);
    try reported(&r5, .@"error", "no ngspice form of this statement can say form = laplace");
}

test "b4: source forms" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\t
        \\v1 a 0 pulse(0 1 0 1n 1n 5n 10n 2)
        \\v2 b 0 dc 0 trnoise(0.1 1n 0 0)
        \\v3 c 0 am(0 0.5 1 100k 1meg 1u 30 45)
        \\v4 d 0 am(0 0.5 1 100k 1meg)
        \\i1 e 0 ac
        \\v5 f 0 dc=0 sin 0 50 100k
        \\.end
    ;
    var r1: ir.Report = .init(a);
    const same = try tr(a, "ngspice", "ngspice", src, &r1);
    try clean(&r1);
    try has(same, "v1 a 0 pulse(0 1 0 1n 1n 5n 10n 2)\n");
    try has(same, "v2 b 0 dc 0 trnoise(0.1 1n 0 0)\n");
    try has(same, "v3 c 0 am(0 0.5 1 100k 1meg 1u 30 45)\n");
    try has(same, "i1 e 0 ac 1\n");
    try has(same, "v5 f 0 dc 0 sin(0 50 100k)\n");
    // HSPICE's AM has no offset and gives the modulation offset relative
    // to the amplitude; it has no pulse count and no trnoise.
    var r2: ir.Report = .init(a);
    const hs = try tr(a, "ngspice", "hspice", src, &r2);
    try has(hs, "v4 d 0 am(1 500m 100k 1meg)\n");
    try reported(&r2, .@"error", "vsource.count = 2 has no spelling in hspice");
    try reported(&r2, .@"error", "vsource.wave = trnoise has no spelling in hspice");
    try reported(&r2, .@"error", "vsource.sinedc = 0 has no spelling in hspice");
    var r3: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\nv4 d 0 am(2 0.5 100k 1meg)\nv5 e 0 pat (1 0 0 1n 1n 5n b1011)\n.end\n", &r3), "v4 d 0 am(0 1 2 100k 1meg)\n");
    try reported(&r3, .@"error", "vsource.wave = pat has no spelling in ngspice");
}

test "#56: a bare ac in an HSPICE source is a magnitude of 1, not the DC value" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // HSPICE reads a bare name as a value, so `ac` was the DC value
    // (`v1 a 0 dc {ac}`) and `dc 0 ac` no rule's. ngspice 45 gives 0.5 on
    // this divider for both forms (docs/verification.md 4.38).
    const src = "t\nv1 a 0 ac\nv2 b 0 dc 0 ac\ni1 c 0 ac sin(0 1 1k)\nv3 d 0 1 ac 2 90\nr1 a 0 1k\n.end\n";
    var r: ir.Report = .init(a);
    const ng = try tr(a, "hspice", "ngspice", src, &r);
    try clean(&r);
    try has(ng, "v1 a 0 ac 1\n");
    try has(ng, "v2 b 0 dc 0 ac 1\n");
    try has(ng, "i1 c 0 ac 1 sin(0 1 1k)\n");
    try has(ng, "v3 d 0 dc 1 ac 2 90\n");
}

test "b4: output forms and measurements" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\t
        \\.print ac db(i(vm)) ph(i(vm))
        \\.print dc -i(vc) vids#branch
        \\.meas tran tb trig v(b) val=0.2 rise=1 targ v(b) val=0.4 rise=1
        \\.meas tran fw find v(o4) when v(c)=0.5 rise=1
        \\.meas tran vb find v(b) at=30n
        \\.meas tran av avg v(o5) from=0 to=50n
        \\.meas tran ii integ v(o5) from=0 to=50n
        \\.meas tran q1 param='tb*2'
        \\.meas tran z1 max v(b) from=1n rise=last
        \\.end
    ;
    var r1: ir.Report = .init(a);
    const same = try tr(a, "ngspice", "ngspice", src, &r1);
    try clean(&r1);
    try has(same, ".print ac db(i(vm)) ph(i(vm))\n");
    try has(same, ".print dc -i(vc) i(vids)\n");
    try has(same, ".meas tran fw find v(o4) when v(c)=0.5 rise=1\n");
    var r2: ir.Report = .init(a);
    const x = try tr(a, "ngspice", "xyce", src, &r2);
    try has(x, ".print ac idb(vm) ip(vm)\n");
    try has(x, ".print dc {-i(vc)} i(vids)\n");
    try has(x, ".measure tran tb trig v(b)=0.2 rise=1 targ v(b)=0.4 rise=1\n");
    try has(x, ".measure tran q1 param={tb*2}\n");
    try reported(&r2, .@"error", "measure.spec: carried as text");
    var r3: ir.Report = .init(a);
    const hs = try tr(a, "ngspice", "hspice", src, &r3);
    try has(hs, ".print dc par('-i(vc)') i(vids)\n");
    try has(hs, ".meas tran q1 param='tb*2'\n");
    // A terminal current in Spectre is a device and a terminal.
    var r4: ir.Report = .init(a);
    try has(try tr(a, "xyce", "ngspice", "t\n.print dc id(m1)\n.end\n", &r4), ".print dc @m1[id]\n");
    var r5: ir.Report = .init(a);
    try has(try tr(a, "spectre", "ngspice", "// t\nsimulator lang=spectre\nsave m1:d\n", &r5), ".save @m1[id]\n");
}

test "b4: Spectre relay and port, VACASK control commands" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = "// t\nsimulator lang=spectre\nk1 (a b c 0) relay vt1=1 vt2=0.5\np1 (b 0) port r=50 num=1\n";
    var r1: ir.Report = .init(a);
    const nl = try readAs(a, "spectre", s, &r1);
    try testing.expectEqual(1, countKind(nl, .relay));
    try testing.expectEqual(1, countKind(nl, .vsource));
    var r2: ir.Report = .init(a);
    const x = try tr(a, "spectre", "xyce", s, &r2);
    try has(x, "p1 b 0 port=1 z0=50\n");
    try reported(&r2, .@"error", "Xyce has no relay element");
    const v = "t\ncontrol\n  print stats\n  postprocess(PYTHON, \"runme.py\")\nendc\nembed \"runme.py\" <<<FILE\nprint(1)\n>>>FILE\n";
    var r3: ir.Report = .init(a);
    const vn = try readAs(a, "vacask", v, &r3);
    try testing.expectEqual(2, countKind(vn, .simctl));
    var r4: ir.Report = .init(a);
    const same = try tr(a, "vacask", "vacask", v, &r4);
    try has(same, "control\nprint stats\npostprocess (PYTHON, \"runme.py\")\nendc\n");
    try clean(&r4);
    var r5: ir.Report = .init(a);
    _ = try tr(a, "vacask", "ngspice", v, &r5);
    try reported(&r5, .@"error", "simctl: 'print stats' is a command of vacask's control language");
    try reported(&r5, .@"error", "VACASK embeds a file");
}

// b1: sweeps

/// `from` to `to` and back: the netlist read back is the same circuit.
fn sameBack(a: std.mem.Allocator, from: []const u8, to: []const u8, src: []const u8, report: *ir.Report) ![]const u8 {
    const nl = try readAs(a, from, src, report);
    const out = try writeAs(a, to, &nl, report);
    const back = try readAs(a, to, out, report);
    if (!try sprack.sameTranslation(a, sprack.find(to).?, &nl, &back)) {
        std.debug.print("\n--- not the same circuit read back from {s}:\n{s}\n", .{ to, out });
        return error.TestNotSame;
    }
    return out;
}

test "sweeps: what a .dc sweeps decides how it is written" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    // A parameter of the netlist.
    const param = "t\n.param rv=1k\nV1 a 0 1\nR1 a 0 rv\n.dc rv 1k 10k 1k\n.end\n";
    try has(try sameBack(a, "hspice", "spectre", param, &r), "dc1 dc param=rv start=1k stop=10k step=1k\n");
    try has(try sameBack(a, "hspice", "vacask", param, &r), "sweep sweep1 instance=\"__topinst__\" parameter=\"rv\" from=1k to=10k step=1k\n");
    try has(try sameBack(a, "hspice", "xyce", param, &r), ".dc rv 1k 10k 1k\n");
    try clean(&r);
    var r1: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ngspice", param, &r1);
    try reported(&r1, .@"error", "no ngspice form of this statement");
    // A resistor: its resistance, which Spectre and VACASK sweep when no
    // instance parameter is named (param=dc is a source's).
    var r2: ir.Report = .init(a);
    const res = "t\nV1 a 0 1\nR1 a 0 1k\n.dc R1 1k 3k 1k\n.end\n";
    try has(try sameBack(a, "ngspice", "spectre", res, &r2), "dc1 dc dev=R1 start=1k stop=3k step=1k\n");
    try has(try sameBack(a, "ngspice", "vacask", res, &r2), "sweep sweep1 instance=\"R1\" from=1k to=3k step=1k\n");
    try clean(&r2);
    // An instance parameter that is not the instance's own value has no SPICE form.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "spectre", "ngspice", "// t\nV1 (a 0) vsource dc=1 mag=1\nR1 (a 0) resistor r=1k\nd1 dc dev=V1 param=mag start=0 stop=1 step=0.5\n", &r3);
    try reported(&r3, .@"error", "dc.devparam = mag");
    var r4: ir.Report = .init(a);
    _ = try sameBack(a, "spectre", "vacask", "// t\nV1 (a 0) vsource dc=1\nR1 (a 0) resistor r=1k\nd1 dc dev=R1 param=r start=1k stop=2k step=1k\n", &r4);
    try clean(&r4);
    // The temperature as the outer loop.
    var r5: ir.Report = .init(a);
    const temp = "t\nV1 a 0 1\nR1 a 0 1k\n.dc V1 0 1 0.5 temp 0 50 25\n.end\n";
    try has(try sameBack(a, "ngspice", "spectre", temp, &r5), "sweep1 sweep param=temp start=0 stop=50 step=25 {\ndc1 dc dev=V1 start=0 stop=1 step=0.5\n}\n");
    try has(try sameBack(a, "ngspice", "vacask", temp, &r5), "sweep outer1 option=\"temp\" from=0 to=50 step=25\n");
    try has(try sameBack(a, "ngspice", "xyce", temp, &r5), ".dc V1 0 1 0.5 temp 0 50 25\n");
    try clean(&r5);
}

test "sweeps: ranges by points, lists, keywords and tables" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    const dec = "t\nV1 a 0 1\nR1 a 0 1k\n.dc V1 dec 2 1 100\n.end\n";
    try has(try sameBack(a, "hspice", "xyce", dec, &r), ".dc dec V1 1 100 2\n");
    try has(try sameBack(a, "hspice", "spectre", dec, &r), "dc1 dc dev=V1 start=1 stop=100 dec=2\n");
    try has(try sameBack(a, "hspice", "vacask", dec, &r), "from=1 to=100 mode=\"dec\" points=2\n");
    // LIN counts points in HSPICE, intervals in Spectre and VACASK.
    const lin = "t\nV1 a 0 1\nR1 a 0 1k\n.dc V1 lin 5 0 1\n.end\n";
    try has(try sameBack(a, "hspice", "spectre", lin, &r), "dc1 dc dev=V1 start=0 stop=1 lin=4\n");
    try has(try sameBack(a, "hspice", "vacask", lin, &r), "from=0 to=1 mode=\"lin\" points=4\n");
    // POI: a count, then the points; a second sweep may follow.
    const poi = "t\nV1 a 0 1\nI1 0 a 0\nR1 a 0 1k\n.dc V1 poi 3 0.5 -1 2 I1 lin 2 0 1m\n.end\n";
    try has(try sameBack(a, "hspice", "hspice", poi, &r), ".dc V1 poi 3 0.5 -1 2 I1 lin 2 0 1m\n");
    try has(try sameBack(a, "hspice", "spectre", poi, &r), "sweep1 sweep dev=I1 start=0 stop=1m lin=1 {\ndc1 dc dev=V1 values=[0.5 -1 2]\n}\n");
    try has(try sameBack(a, "spectre", "xyce", "// t\nV1 (a 0) vsource dc=1\nR1 (a 0) resistor r=1k\nd1 dc dev=V1 values=[1 5 7]\n", &r), ".dc list V1 1 5 7\n");
    // START= STOP= STEP= is read, and written positionally.
    try has(try tr(a, "hspice", "hspice", "t\nV1 a 0 1\n.dc V1 start=0 stop=1 step=0.25\n.end\n", &r), ".dc V1 0 1 0.25\n");
    // A table, and a sweep over its rows.
    const data = "t\n.param rl=1k\nV1 a 0 1\nR1 a 0 rl\n.data rows rl V1\n+ 1k 1\n+ 3k 2\n.enddata\n.dc data=rows\n.end\n";
    try has(try sameBack(a, "hspice", "xyce", data, &r), ".data rows rl V1 1k 1 3k 2\n.enddata\n.dc data=rows\n");
    try clean(&r);
}

test "sweeps: a sweep whose stop is its start" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    // Spectre refuses stop = start; its one point goes in values=.
    const src = "t\nV1 a 0 1 ac 1\nR1 a b 1k\nC1 b 0 1n\n.dc V1 1 1 0.25\n.ac lin 1 1k 1k\n.noise v(b) V1 dec 4 100 100\n.end\n";
    const sp = try sameBack(a, "ngspice", "spectre", src, &r);
    try has(sp, "dc1 dc dev=V1 start=1 step=0.25 values=[1]\n");
    try has(sp, "ac1 ac start=1k lin=0 values=[1k]\n");
    try has(sp, "noise1 (b 0) noise iprobe=V1 start=100 dec=4 values=[100]\n");
    try clean(&r);
    // Xyce runs only the last of the three (docs: grammars/xyce.spgrammar, unique).
    var rx: ir.Report = .init(a);
    try has(try sameBack(a, "ngspice", "xyce", src, &rx), ".dc V1 1 1 0.25\n");
    try testing.expectEqual(3, rx.count(.@"error"));
    try reported(&rx, .@"error", "noise: one of 3 analyses in this netlist (dc, ac, noise)");
}

test "sweeps: a step repeats the analyses it holds" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    // A .step line sweeps every analysis; nested, the first is the outer loop.
    const src = "t\n.param rv=1k\nV1 a 0 1\nR1 a b 1k\nR2 b 0 {rv}\n.step param rv list 1k 3k\n.step temp list -40 85\n.op\n.tran 1n 10n\n.end\n";
    const sp = try sameBack(a, "ltspice", "spectre", src, &r);
    try has(sp, "swp1 sweep param=rv values=[1k 3k] {\nswp2 sweep param=temp values=[-40 85] {\nop1 dc\ntran1 tran step=1n stop=10n\n}\n}\n");
    try has(try sameBack(a, "ltspice", "xyce", src, &r), ".step rv list 1k 3k\n.step temp list -40 85\n.op\n.tran 1n 10n\n");
    try has(try sameBack(a, "ltspice", "ltspice", src, &r), ".step param rv list 1k 3k\n.step temp list -40 85\n");
    try clean(&r);
    // HSPICE's .TEMP with several values is a step over the temperature.
    var r2: ir.Report = .init(a);
    try has(try sameBack(a, "hspice", "xyce", "t\nR1 a 0 1k\nI1 0 a 1m\n.temp -55 25 125\n.op\n.end\n", &r2), ".step temp list -55 25 125\n.op\n");
    try clean(&r2);
    // A sweep around one analysis of several is not a .step.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "spectre", "xyce", "// t\nV1 (a 0) vsource dc=1 mag=1\nR1 (a 0) resistor r=1k\nswp1 sweep param=temp values=[0 50] {\nop1 dc\n}\nac1 ac start=1 stop=1k dec=10\n", &r3);
    try reported(&r3, .@"error", "a xyce sweep applies to every analysis of the netlist");
    // Where a sweep is one line per analysis, there is no step.
    var r4: ir.Report = .init(a);
    _ = try tr(a, "ltspice", "vacask", src, &r4);
    try reported(&r4, .@"error", "VACASK has no sweep of the whole netlist");
    // A .TEMP list in a deck with no analysis repeats nothing.
    var r5: ir.Report = .init(a);
    _ = try tr(a, "hspice", "xyce", "t\nR1 a 0 1k\n.temp -40 85\n.end\n", &r5);
    try reported(&r5, .@"error", "no analysis for the xyce sweep to repeat");
}

test "instance parameters: renamed for the target, a loss where its device lacks one" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\t
        \\R1 a b 1k ac=2k noisy=0 m=-2 tc=1m
        \\I1 a 0 1m m=2
        \\D1 a 0 dm w=1u l=1u off
        \\Q1 c b e s1 t qm dtemp=1
        \\.model dm d
        \\.model qm npn
        \\.end
    ;
    var r1: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", src, &r1);
    try has(xy, "R1 a b 1k m=-2 tc1=1m\n");
    try has(xy, "I1 a 0 dc 1m\n");
    try reported(&r1, .@"error", "resistor: 'ac=2k' has no spelling in xyce, whose resistor takes no such instance parameter");
    try reported(&r1, .@"error", "isource: 'm=2' has no spelling in xyce");
    try reported(&r1, .@"error", "diode: 'w=1u' has no spelling in xyce");
    try reported(&r1, .@"error", "resistor: m=-2: xyce refuses m of zero or less");

    var r2: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre", src, &r2);
    try has(sp, "R1 (a b) resistor r=1k ac=2k isnoisy=0 m=-2 tc1=1m\n");
    // OFF changes no result (`inert diode off`): a note, not an error.
    try reported(&r2, .info, "diode: 'off' is not written");
    // A model name after the nodes is no flag: Q1 has a thermal node.
    try has(sp, "Q1 (c b e s1 t) qm dtemp=1\n");

    // And back: Spectre's spelling reads as the canonical one.
    var r3: ir.Report = .init(a);
    const ng = try tr(a, "spectre", "ngspice", "// t\nR1 (a b) resistor r=1k isnoisy=0 trise=2\n", &r3);
    try has(ng, "R1 a b 1k noisy=0 dtemp=2\n");
    try clean(&r3);
}

test "a zero or missing pulse rise is SPICE's .tran step, written out where the target needs it" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nV1 a 0 pulse(0 1 0 0 0 10n 20n)\nV2 b 0 pulse(0 1 1n)\nR1 a b 1k\n.tran 2n 50n\n.end\n";
    var r1: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre", src, &r1);
    try has(sp, "V1 (a 0) vsource type=pulse val0=0 val1=1 delay=0 rise=2n fall=2n width=10n period=20n\n");
    try has(sp, "V2 (b 0) vsource type=pulse val0=0 val1=1 delay=1n rise=2n fall=2n\n");
    try reported(&r1, .warning, "vsource.rise is 0: ngspice means the tran.step by that, and spectre needs it said; wrote 2n");
    try clean(&r1);
    var r2: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", src, &r2);
    try has(va, "delay=1n rise=2n fall=2n width=50n\n");
    try clean(&r2);
    // No .tran to take the step from: the value cannot be known.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "spectre", "t\nV1 a 0 pulse(0 1 0 0 0 10n 20n)\n.op\n.end\n", &r3);
    try reported(&r3, .@"error", "vsource.rise is 0: Spectre refuses a zero rise time");
}

test "the spelling table holds names only: a keyword DC does not respell a node dc" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre", "t\nV1 a 0 DC 1\nR1 a dc 1k\nR2 dc Out 1k\nC1 out 0 1p W=1\n.save v(OUT)\n.end\n", &r);
    try has(sp, "R1 (a dc) resistor r=1k\n");
    // A name is still spelled the way it is first capitalised, everywhere.
    try has(sp, "C1 (Out 0) capacitor c=1p");
    try has(sp, "R2 (dc Out) resistor r=1k\n");
}

test "a name has one spelling among the names of its kind: a source Vdd leaves the node vdd" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The most common line in SPICE: the node is not the source.
    const deck = "t\nVdd vdd 0 1\nR1 vdd out 1k\nR2 out 0 1k\n.print dc v(vdd) i(vdd)\n.ic v(vdd)=1\n.op\n.end\n";
    for ([_][]const u8{ "ngspice", "xyce" }) |to| {
        var r: ir.Report = .init(a);
        const out = try tr(a, "ngspice", to, deck, &r);
        try has(out, "Vdd vdd 0 dc 1\nR1 vdd out 1k\n");
        // A voltage names nodes, a current a device.
        try has(out, ".print dc v(vdd) i(Vdd)\n.ic v(vdd)=1\n");
    }
    var r1: ir.Report = .init(a);
    const scs = try tr(a, "ngspice", "spectre", deck, &r1);
    try has(scs, "Vdd (vdd 0) vsource dc=1\nR1 (vdd out) resistor r=1k\n");
    try has(scs, "save vdd Vdd:p\nic vdd=1\n");
    // A node written with capitals once is still one node, spelled so everywhere.
    var r2: ir.Report = .init(a);
    const one = try tr(a, "ngspice", "ngspice", "t\nVdd vdd 0 1\nR1 VDD out 1k\nR2 out 0 1k\n.ic v(vdd)=1\n.end\n", &r2);
    try has(one, "Vdd VDD 0 dc 1\nR1 VDD out 1k\nR2 out 0 1k\n.ic v(VDD)=1\n");
    // A model, a parameter and a node of the same letters; a subcircuit's
    // port; the names in an expression, each in its own space.
    var r3: ir.Report = .init(a);
    const all = try tr(a, "ngspice", "ngspice",
        \\t
        \\.param Out=2 nch=1u
        \\.model Out nmos
        \\.model NCH nmos
        \\.subckt Inv in OUT vdd
        \\M1 OUT in 0 0 out w={NCH} l={out*1u}
        \\M2 nch in vdd vdd nch
        \\.ends
        \\Vdd VDD 0 {out}
        \\X1 a out vdd inv
        \\Rnch nch 0 1k
        \\B1 b 0 v={v(vdd)*out + i(vdd)*nch}
        \\.end
        \\
    , &r3);
    try has(all, ".param Out=2 nch=1u\n.model Out nmos level=1\n.model NCH nmos level=1\n");
    try has(all, ".subckt Inv in OUT VDD\nM1 OUT in 0 0 Out w={nch} l={Out*1u}\nM2 nch in VDD VDD NCH\n.ends Inv\n");
    try has(all, "Vdd VDD 0 dc {Out}\nX1 a OUT VDD Inv\nRnch nch 0 1k\n");
    try has(all, "B1 b 0 v={v(VDD)*Out + i(Vdd)*nch}\n");
    // A device named in a list, and a terminal, which is no name: the node d stays.
    var r4: ir.Report = .init(a);
    const refs = try tr(a, "xyce", "xyce", "t\nV1 a 0 1\nv2 d 0 1\nR1 a v1 1k\nF1 c 0 poly(2) v1 V2 0 1 1\nM1 d a 0 0 nch\n.model nch nmos\n.print dc ID(m1)\n.end\n", &r4);
    try has(refs, "V2 d 0 dc 1\nR1 a v1 1k\nF1 c 0 poly(2) V1 V2 0 1 1\nM1 d a 0 0 nch\n");
    // A swept parameter is spelled as its definition, in a target that tells case.
    var r5: ir.Report = .init(a);
    const va = try tr(a, "xyce", "vacask", "t\n.param vcm=1\nV1 a 0 {vcm}\nR1 a VCM 1k\nR2 vcm 0 1k\n.dc VCM 0 1 0.1\n.end\n", &r5);
    try has(va, "parameters vcm=1\n");
    try has(va, "R1 (a VCM) resistor r=1k\nR2 (VCM 0) resistor r=1k\n");
    try has(va, "parameter=\"vcm\" from=0 to=1 step=0.1\n");
}

test "expression semantics: a choice in the target's form, and what evaluates differently" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // ngspice ternary_fcn is if() here; HSPICE and Spectre have only ?:.
    var r1: ir.Report = .init(a);
    const hs = try tr(a, "ngspice", "hspice", "t\n.param x=2\n.param p={ternary_fcn(x > 1, 3, 4)}\n.end\n", &r1);
    try has(hs, ".param p='(x > 1 ? 3 : 4)'\n");
    try clean(&r1);
    // LTspice has if() and no ?:.
    var r2: ir.Report = .init(a);
    const lt = try tr(a, "ngspice", "ltspice", "t\n.param x=2\n.param q={x>1 ? 1 : 0}\n.end\n", &r2);
    try has(lt, ".param q={if(x>1, 1, 0)}\n");
    // CDL has neither.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "cdl", "t\n.param q={x>1 ? 1 : 0}\n.end\n", &r3);
    try reported(&r3, .@"error", "operator 'ternary' has no spelling in cdl");
    // Measured differences: ngspice's .param pwr, Xyce's nint, HSPICE's log.
    var r4: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\n.param p={pwr(x,2)+nint(y)+1+-2**2}\n.end\n", &r4);
    try reported(&r4, .warning, "pwr in ngspice: in .param the sign of a negative base is dropped");
    try reported(&r4, .warning, "nint in xyce: halves round away from zero");
    try reported(&r4, .warning, "negpow in ngspice");
    var r5: ir.Report = .init(a);
    _ = try tr(a, "spectre", "hspice", "// t\nparameters p=log(x)\n", &r5);
    try reported(&r5, .warning, "ln in hspice: a negative argument gives -ln|x|");
}

test "VACASK: options and saves come before the analyses in the control block" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    // VACASK runs a control block in order; options after an analysis do not reach it.
    const va = try tr(a, "ngspice", "vacask", "t\nV1 in 0 AC 1\nR1 in 0 1k\n.noise v(in) V1 dec 4 10 10k\n.options temp=0\n.save v(in)\n.end\n", &report);
    try has(va, "control\noptions temp=0\nsave v(in)\nanalysis noise1 noise");
    try reported(&report, .warning, "noise.out: VACASK writes the output noise as a power density with the power gain");
}

test "VACASK tran: SPICE's step cap is written as maxstep" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    // SPICE never steps past TSTEP; VACASK only limits the step to stop/50.
    const va = try tr(a, "ngspice", "vacask", "t\nV1 in 0 1\nR1 in 0 1k\n.tran 1u 1m\n.end\n", &report);
    try has(va, "analysis tran1 tran step=1u stop=1m maxstep=1u\n");
    try reported(&report, .warning, "tran: vacask needs 'maxstep' to behave as ngspice does without it; wrote 1u");
    // A given maxstep is kept, and a VACASK deck is left as it was.
    try has(try tr(a, "ngspice", "vacask", "t\nV1 in 0 1\nR1 in 0 1k\n.tran 1u 1m 0 5u\n.end\n", &report), "maxstep=5u\n");
    var r2: ir.Report = .init(a);
    const same = try tr(a, "vacask", "vacask", "t\nmodel v vsource\nv1 (a 0) v dc=1\ncontrol\nanalysis tran1 tran step=1u stop=1m\nendc\n", &r2);
    try has(same, "analysis tran1 tran step=1u stop=1m\n");
    try clean(&r2);
    // A step at or above the stop time is a ceiling that limits nothing:
    // one given is not written, so none is made up.
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "vacask", "t\nV1 in 0 1\nR1 in 0 1k\n.tran 101 20n\n.end\n", &r3), "analysis tran1 tran step=101 stop=20n\n");
    try has(try tr(a, "ngspice", "vacask", "t\nV1 in 0 1\nR1 in 0 1k\n.tran 20n 20n\n.end\n", &r3), "analysis tran1 tran step=20n stop=20n\n");
    try testing.expectEqual(0, r3.items.items.len);
    var r4: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "vacask", "t\nV1 in 0 1\nR1 in 0 1k\n.tran 101 20n 0 101\n.end\n", &r4), "analysis tran1 tran step=101 stop=20n start=0\n");
    try reported(&r4, .info, "tran.maxstep at or above the stop time limits nothing and is not written");
    try testing.expectEqual(0, r4.countCode(.synthesized));
}

test "VACASK nodeset: a caveat, since it holds for one Newton iteration only" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", "t\nV1 q 0 1\nR1 q 0 1k\n.nodeset v(q)=5\n.op\n.end\n", &report);
    try has(va, "analysis op1 op nodeset={\"q\",5}\n");
    try reported(&report, .warning, "op.nodeset: VACASK pulls toward a nodeset only during its first Newton iteration");
}

test "VACASK model cards: a refused version is a warning, a refused JFET level 2 an error" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", "t\n.model n3 nmos level=8 version=3.3 vth0=0.4\n.model nj njf level=2 vto=-1\n.model n1 njf level=1 vto=-2\n.end\n", &report);
    try has(va, "model n3 sp_bsim3v3 (type=1 vth0=0.4)\n");
    try has(va, "model nj sp_jfet1 (type=1 vto=-1)\n");
    try has(va, "model n1 sp_jfet1 (type=1 vto=-2)\n");
    try reported(&report, .warning, "model 'n3': version not written: sp_bsim3v3 implements BSIM3 3.3.0 only");
    try reported(&report, .@"error", "model 'nj': level not written: sp_jfet1 is the level 1 JFET");
    try reported(&report, .warning, "model 'n1': level not written: sp_jfet1 is the level 1 JFET");
    try testing.expectEqual(1, report.count(.@"error"));
    // sp_bjt refuses `level` too ("Parameter 'level' not found" in VACASK b2c1551).
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "vacask", "t\n.model qq npn level=1 bf=80\n.end\n", &r2), "model qq sp_bjt (type=1 bf=80)\n");
    try reported(&r2, .warning, "model 'qq': level not written: sp_bjt is the level 1 (Gummel-Poon) BJT");
    try testing.expectEqual(0, r2.count(.@"error"));
}

test "VACASK model cards: a refused version is one warning per file, a refused level an error per card" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const two = "t\n.model b.0 nmos level=54 version=4.5\n.model b.1 nmos level=54 version=4.5\n.end\n";
    var report: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "vacask", two, &report);
    // Read whole and as a stream: one entry for the two cards, and no error.
    for ([_]bool{ true, false }) |whole| {
        var r: ir.Report = .init(a);
        var aw: std.Io.Writer.Allocating = .init(a);
        const why = try sprack.stream.translate(a, sprack.find("ngspice").?, sprack.find("vacask").?, two, &aw.writer, &r, &sprack.caps, .{ .whole = whole });
        if (!whole) try testing.expectEqual(null, why);
        try reported(&r, .warning, "model 'b.0' and 1 more card in this file: version not written: VACASK ships BSIM4 4.8");
        var n: usize = 0;
        for (r.items.items) |d| n += @intFromBool(std.mem.indexOf(u8, d.msg, "version not written") != null);
        try testing.expectEqual(1, n);
        try testing.expectEqual(0, r.count(.@"error"));
    }
    var r2: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "vacask", "t\n.model j.0 njf level=2\n.model j.1 njf level=2\n.end\n", &r2);
    try reported(&r2, .@"error", "model 'j.0': level not written");
    try reported(&r2, .@"error", "model 'j.1': level not written");
    try testing.expectEqual(2, r2.count(.@"error"));
}

test "VACASK instance parameters: m is $mfactor, resistor ac has no place" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const src = "t\nR1 a 0 1k m=2 tc=1m\nC1 a 0 1n ic=0.5\nR2 a b 1k ac=2k\nM1 d g 0 0 nm w=1u l=1u m=3 sa=1u\nVg g 0 1\n.model nm nmos level=1\n.end\n";
    const va = try tr(a, "ngspice", "vacask", src, &report);
    try has(va, "R1 (a 0) resistor r=1k $mfactor=2 tc=1m\n");
    try has(va, "C1 (a C1__ic) capacitor c=1n\n");
    // An open table renames m and copies the rest.
    try has(va, "M1 (d g 0 0) nm w=1u l=1u $mfactor=3 sa=1u\n");
    try reported(&report, .@"error", "resistor: 'ac=2k' has no spelling in vacask");
    try testing.expectEqual(1, report.count(.@"error"));
    // And back: $mfactor is m again, where ngspice has a table and where it has none.
    var r2: ir.Report = .init(a);
    const ng = try tr(a, "vacask", "ngspice", va, &r2);
    try has(ng, "R1 a 0 1k m=2 tc=1m\n");
    try has(ng, "M1 d g 0 0 nm w=1u l=1u m=3 sa=1u\n");
}

test "VACASK capacitor: ic= is a DC source in series, q= a behavioural source of ddt(q)" {
    // docs/verification.md 4.16: both measured in ngspice 45 and VACASK b2c1551.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // In a subcircuit, and in a branch of a conditional block (IHP's twelve).
    const sub =
        \\t
        \\.subckt cic a b
        \\C1 a b 1n ic=0.5
        \\.ends
        \\.subckt cc a b s=0
        \\.if (s == 0)
        \\C2 a b 1p ic=0.1
        \\.else
        \\C2 a b 2p ic=0.2
        \\.endif
        \\.ends
        \\V1 in 0 1
        \\R1 in b 1k
        \\X1 b 0 cic
        \\X2 b 0 cc
        \\.tran 1n 50n uic
        \\.end
    ;
    var r1: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", sub, &r1);
    try has(va, "C1 (a C1__ic) capacitor c=1n\nVC1__ic (C1__ic b) vsource dc=0.5\n");
    try has(va, "C2 (a C2__ic) capacitor c=1p\nVC2__ic (C2__ic b) vsource dc=0.1\n");
    try has(va, "model vsource vsource\n");
    try reported(&r1, .info, "capacitor 'C1': vacask's capacitor takes no initial voltage (ic=0.5); it is written to node C1__ic");
    try clean(&r1);
    // Read whole and as a stream: the same.
    var outs: [2][]const u8 = undefined;
    for ([_]bool{ true, false }, 0..) |whole, i| {
        var r: ir.Report = .init(a);
        var aw: std.Io.Writer.Allocating = .init(a);
        _ = try sprack.stream.translate(a, sprack.find("ngspice").?, sprack.find("vacask").?, sub, &aw.writer, &r, &sprack.caps, .{ .whole = whole });
        outs[i] = aw.written();
    }
    try testing.expectEqualStrings(outs[0], outs[1]);
    // An .ic on one of its nodes: ngspice takes the capacitor's, the series
    // source would add the two.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "vacask", "t\nV1 in 0 1\nR1 in b 1k\nC1 b 0 1n ic=0.5\n.ic v(b)=0.2\n.tran 1n 50n uic\n.end\n", &r2);
    try reported(&r2, .@"error", "capacitor 'C1': ic=0.5, and an .ic sets node b too");
    // Inside a subcircuit only a hierarchical name ending in the node counts.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "vacask", "t\n.subckt cic a b\nC1 a b 1n ic=0.5\n.ends\nX1 b 0 cic\nV1 b 0 1\n.ic v(x1.a)=0.2 v(b)=1\n.tran 1n 50n uic\n.end\n", &r3);
    try reported(&r3, .@"error", "capacitor 'C1': ic=0.5, and an .ic sets node a too");
    try testing.expectEqual(1, r3.count(.@"error"));
    // A charge: the current is its time derivative, times m.
    var r4: ir.Report = .init(a);
    const q = try tr(a, "ngspice", "vacask", "t\nV1 a 0 1\nR1 a b 100k\nCg b 0 q='1p*v(b)+min(v(b),0)*1f' m=2\n.tran 1n 300n\n.end\n", &r4);
    try has(q, "Cg (b 0) i=2*ddt(1p*v(b)+min(v(b),0)*1f)\n");
    try reported(&r4, .info, "capacitor 'Cg': vacask's capacitor takes no charge (q=)");
    try clean(&r4);
    // ngspice has no such restriction: its own capacitor, and ddt read back.
    var r5: ir.Report = .init(a);
    try has(try tr(a, "vacask", "ngspice", q, &r5), "BCg b 0 i={2*ddt(1p*v(b)+min(v(b),0)*1f)}\n");
    // ddt is a function of ngspice and VACASK alone.
    var r6: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\nB1 a 0 i='ddt(1p*v(a))'\nR1 a 0 1k\n.end\n", &r6);
    try reported(&r6, .@"error", "function 'ddt' has no spelling in xyce");
}

test "Spectre capacitor: q= is an error, not written" {
    // docs/verification.md 4.39: the Components Reference (23.1) lists no
    // charge among the capacitor's instance parameters; not run in Spectre.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    const out = try tr(a, "ngspice", "spectre", "t\nV1 a 0 1\nR1 a b 100k\nCg b 0 q='1p*v(b)'\n.tran 1n 300n\n.end\n", &r);
    try testing.expect(std.mem.indexOf(u8, out, "q=") == null);
    try reported(&r, .@"error", "capacitor: 'q=1e-12*v(b)' has no spelling in spectre");
}

test "Spectre options: trtol and chgtol are errors that give the reason" {
    // docs/verification.md 4.39: the User Guide (13.1.1) has lteratio and
    // no charge tolerance.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "spectre", "t\nV1 a 0 1\nR1 a 0 1k\n.options trtol=1 chgtol=1e-14\n.op\n.end\n", &r);
    try reported(&r, .@"error", "options.trtol = 1 has no spelling in spectre: Spectre's truncation-error factor is lteratio");
    try reported(&r, .@"error", "options.chgtol = 1e-14 has no spelling in spectre: Spectre has no charge tolerance");
}

test "Xyce: a diode card of ngspice's level 3 is an error, a level 1 card is not" {
    // docs/verification.md 4.20: Xyce 7.10 has diode levels 1, 2, 200 and 2002.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", "t\n.model dd d level=3.0 is=1e-15 mj=0.3\nD1 a 0 dd area=1 pj=4\nV1 a 0 0.7\n.op\n.end\n", &r1);
    try has(xy, ".model dd d is=1f mj=0.3\n");
    try reported(&r1, .@"error", "model 'dd': level not written: Xyce 7.10's diode has levels 1, 2, 200 and 2002");
    try testing.expectEqual(1, r1.count(.@"error"));
    var r2: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\n.model dd d level=1 is=1e-15\nD1 a 0 dd\nV1 a 0 0.7\n.op\n.end\n", &r2);
    try clean(&r2);
}

test "VACASK: a node pair in noise and dcxf, gshunt, and a transient's start" {
    // docs/verification.md 4.25.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", "t\nV1 a 0 1 ac 1\nR1 a b 1k\nC1 b 0 1u\nR2 b 0 1k\n.noise v(a,b) V1 dec 10 1 1k\n.noise v(a) V1 dec 10 1 1k\n.tf v(a,b) V1\n.end\n", &r1);
    try has(va, "analysis noise1 noise out=[\"a\",\"b\"] in=\"V1\"");
    try has(va, "analysis noise2 noise out=\"a\" in=\"V1\"");
    try has(va, "analysis tf1 dcxf out=[\"a\",\"b\"]\n");
    try clean(&r1);
    var r2: ir.Report = .init(a);
    try has(try tr(a, "hspice", "vacask", "t\nI1 0 a 1m\nR1 a 0 1k\n.options gshunt=1m\n.op\n.end\n", &r2), "gshunt=1m");
    try testing.expect(!r2.contains(.@"error", "gshunt"));
}

test "a function the target lacks is written as what the source means by it (means)" {
    // docs/verification.md 4.26: VACASK has no pwr.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // ngspice's .param pwr drops the sign; its B sources keep it.
    var r1: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", "t\n.param p={pwr(-2,3)}\nR1 a 0 {p*1k}\nB1 b 0 V={pwr(v(a),3)}\nR2 b 0 1k\nV1 a 0 1\n.op\n.end\n", &r1);
    try has(va, "parameters p=pow(abs(-2),3)\n");
    try has(va, "B1 (b 0) v=sign(pow(abs(v(a)),3),v(a))\n");
    try reported(&r1, .info, "expression 'pwr(-2,3)': vacask has no pwr; written as what ngspice means by it, pow(abs(x),y)");
    try testing.expectEqual(0, r1.count(.@"error"));
    // HSPICE keeps the sign everywhere; Xyce's is pow.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "hspice", "vacask", "t\n.param p=pwr(x,2) x=-2\n.end\n", &r2), "p=sign(pow(abs(x),2),x)");
    var r3: ir.Report = .init(a);
    try has(try tr(a, "xyce", "vacask", "t\n.param x=-2\n.param p={pwr(x,2)}\n.end\n", &r3), "p=pow(x,2)");
    // A target that has pwr gets it as it was.
    var r4: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "hspice", "t\n.param p={pwr(-2,3)}\n.end\n", &r4), "pwr(-2,3)");
}

test "ngspice's power drops the sign of a negative base, and is written so into the others (#78)" {
    // docs/verification.md 4.44: ngspice 45 gives b**2.5 = 4.051 for b=-1.75,
    // (-8)**(1/3) = 2 and 2**3**2 = 64, in .param and B sources alike.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", "t\n.param b=-1.75 p={2**3**2} q={-b**2} r={1e-3**2} s={f(b)**-1}\nV1 a 0 {b^2.5}\nV4 e 0 {(-8)**(1/3)}\nB1 c 0 V={v(a)**2}\n.op\n.end\n", &r1);
    try has(va, "V1 (a 0) vsource dc=pow(abs(b),2.5)\n");
    try has(va, "V4 (e 0) vsource dc=pow(abs(-8),1/3)\n");
    try has(va, "B1 (c 0) v=pow(abs(v(a)),2)\n");
    // From the left, before a unary minus; a number's own exponent is its own.
    try has(va, "p=pow(abs(pow(abs(2),3)),2) q=-pow(abs(b),2) r=pow(abs(1m),2) s=pow(abs(f(b)),-1)");
    try reported(&r1, .info, "expression 'b**2.5': ngspice's x ** y is pow(abs(x),y), and vacask's power is not");
    // Written as what it means, the operator is no caveat.
    try testing.expect(!r1.contains(.warning, "pow in ngspice"));
    // A minus after another operator: how ngspice reads that is still one.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", "t\n.param p={1+-2**2}\n.end\n", &r2), "p={1+-pow(abs(2),2)}");
    try reported(&r2, .warning, "negpow in ngspice");
    // The target's own caveat stays: HSPICE's pow cuts the exponent.
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "hspice", "t\n.param p={b**2.5}\n.end\n", &r3), "p='pow(abs(b),2.5)'");
    try reported(&r3, .warning, "pow in hspice: the exponent is cut to an integer");
    // pow() itself is not the operator: its caveat is still said.
    var r4: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "vacask", "t\n.param p={pow(b,3)*b**2}\n.end\n", &r4);
    try reported(&r4, .warning, "pow in ngspice");
}

test "VACASK pulse: a width given as 0 is SPICE's TSTOP, as a missing one" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    // ngspice takes a zero PW as the final time; VACASK's width=0 has no flat top.
    const va = try tr(a, "ngspice", "vacask", "t\nV1 a 0 PULSE(0 1 0 1n 1n 0 0)\nR1 a 0 1k\n.tran 10n 1u\n.end\n", &report);
    try has(va, "width=1u period=0\n");
    try reported(&report, .warning, "vsource.width is 0: ngspice means the tran.stop by that");
}

test "c2 alter: reruns with cumulative edits, in each dialect's form" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    const src = "t\n.param ra=1k\nV1 a 0 1\nR1 a b 'ra'\nR2 b 0 1k\n.op\n.alter one\n.param ra=3k\n.alter two\n.temp 75\n.end\n";
    const nl = try readAs(a, "hspice", src, &r);
    try testing.expectEqual(2, countKind(nl, .alter));
    try has(try sameBack(a, "hspice", "hspice", src, &r), ".op\n.alter one\n.param ra=3k\n.alter two\n.temp 75\n.end\n");
    // Spectre runs analyses where they stand: each altergroup is followed by them.
    try has(try sameBack(a, "hspice", "spectre", src, &r), "op1 dc\none altergroup {\nparameters ra=3k\n}\nop2 dc\ntwo altergroup {\nsprackOptions2 options temp=75\n}\nop3 dc\n");
    try clean(&r);
    // Xyce: a .step over a table, a row for the netlist and one per alter.
    var r1: ir.Report = .init(a);
    try has(try tr(a, "hspice", "xyce", src, &r1), ".data alters ra temp 1k 25 3k 25 3k 75\n.enddata\n.step data=alters\n.op\n");
    // HSPICE runs at 25 when it says nothing (the default options, c4).
    try reported(&r1, .warning, "hspice assumes other defaults for temp, tnom than xyce does");
    try testing.expect(!r1.hasErrors());
    // VACASK's control block runs in order; ngspice reruns from .control.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "hspice", "vacask", src, &r2), "analysis op1 op\nalter instance(\"__topinst__\") ra=3k\nanalysis op2 op\noptions temp=75\nanalysis op3 op\nendc\n");
    try has(try tr(a, "hspice", "ngspice", src, &r2), ".op\n.control\nreset\nrun\n.endc\n.control\nalterparam ra=3k\nreset\nrun\n.endc\n.control\nreset\noption temp=75\nrun\n.endc\n");
    try testing.expect(!r2.hasErrors());
    // What those forms cannot change is an error with the reason.
    var r3: ir.Report = .init(a);
    const elem = "t\nV1 a 0 1\nR1 a b 1k\nR2 b 0 1k\n.op\n.alter\nR2 b 0 3k\n.alter\nR3 b 0 1k\n.end\n";
    _ = try tr(a, "hspice", "xyce", elem, &r3);
    try reported(&r3, .@"error", "changes only parameters and the temperature, not a resistor");
    var r4: ir.Report = .init(a);
    _ = try tr(a, "hspice", "spectre", elem, &r4);
    try reported(&r4, .@"error", "resistor 'R3' is not in the netlist");
    try testing.expectEqual(1, r4.count(.@"error"));
}

test "c2 alter: Spectre alter and altergroup read back as alters" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    // One-change alters with no analysis between them are one rerun.
    const scs = "// t\nparameters ra=1k\nv1 (a 0) vsource dc=1\nr1 (a b) resistor r=ra\nr2 (b 0) resistor r=1k\nd1 (b 0) dm\nmodel dm diode is=1e-14\n" ++
        "op0 dc\na1 alter dev=r2 param=r value=3k\na2 alter mod=dm param=is value=1e-12\nop1 dc\na3 alter param=temp value=75\nop2 dc\nag4 altergroup {\nparameters ra=2k\n}\nop3 dc\n";
    const nl = try readAs(a, "spectre", scs, &r);
    try testing.expectEqual(3, countKind(nl, .alter));
    try testing.expectEqual(1, countKind(nl, .op));
    try has(try tr(a, "spectre", "hspice", scs, &r), ".op\n.alter a1\nr2 b 0 3k\n.model dm d is=1p\n.alter a3\n.temp 75\n.alter ag4\n.param ra=2k\n.end\n");
    _ = try sameBack(a, "spectre", "spectre", scs, &r);
    try testing.expect(!r.hasErrors());
    // Analyses after an altergroup that are not the netlist's: no rerun.
    var r1: ir.Report = .init(a);
    _ = try readAs(a, "spectre", "// t\nr1 (a 0) resistor r=1k\nop0 dc\nag1 altergroup {\nr1 (a 0) resistor r=2k\n}\ntran1 tran stop=1n\n", &r1);
    try reported(&r1, .@"error", "the analyses after it are not those of the netlist");
}

test "c2 sweep: HSPICE SWEEP at the end of an analysis line is a step around it" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    const src = "t\n.param rl=1k\nV1 a 0 1 ac 1\nVdd d 0 1\nR1 a b rl\nC1 b 0 1n\n.data rows rl\n+ 1k\n+ 3k\n.enddata\n" ++
        ".tran 1n 1u SWEEP rl 1k 10k 1k\n.ac dec 10 1 1g SWEEP temp poi 3 0 27 85\n.op sweep data=rows\n.dc V1 0 1 0.1 SWEEP Vdd 1 2 0.5\n.end\n";
    const nl = try readAs(a, "hspice", src, &r);
    try testing.expectEqual(3, countKind(nl, .step));
    const back = try sameBack(a, "hspice", "hspice", src, &r);
    try has(back, ".tran 1n 1u sweep rl 1k 10k 1k\n.ac dec 10 1 1g sweep temp poi 3 0 27 85\n.op sweep data=rows\n");
    // One loop around a DC sweep is its outer loop.
    try has(back, ".dc V1 0 1 0.1 Vdd 1 2 0.5\n");
    try clean(&r);
    // Spectre has no .data tables, so the other three only.
    var r0: ir.Report = .init(a);
    const sp = try tr(a, "hspice", "spectre", src, &r0);
    try has(sp, "swp1 sweep param=rl start=1k stop=10k step=1k {\ntran1 tran step=1n stop=1u\n}\nswp2 sweep param=temp values=[0 27 85] {\nac1 ac start=1 stop=1G dec=10\n}\n");
    try has(sp, "sweep dev=Vdd start=1 stop=2 step=0.5 {\ndc1 dc dev=V1 start=0 stop=1 step=0.1\n}\n");
    // A .TEMP list around the only analysis stays a .TEMP line.
    var r1: ir.Report = .init(a);
    try has(try sameBack(a, "hspice", "hspice", "t\nR1 a 0 1k\nI1 0 a 1m\n.temp -55 25 125\n.op\n.end\n", &r1), ".temp -55 25 125\n.op\n");
    try clean(&r1);
}

// c3: circuits a target cannot solve (src/topology.zig)

/// The topology entries of translating `src` from ngspice to `to`.
fn topo(a: std.mem.Allocator, to: []const u8, src: []const u8) !ir.Report {
    var report: ir.Report = .init(a);
    _ = try tr(a, "ngspice", to, src, &report);
    var out: ir.Report = .init(a);
    for (report.items.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "DC path") != null or std.mem.indexOf(u8, d.msg, "form a loop") != null) try out.items.append(a, d);
    }
    return out;
}

test "topology: capacitor islands, series capacitors and current cutsets have no DC path" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A node reached only by a capacitor to ground.
    var r = try topo(a, "vacask", "t\nV1 in 0 1\nR1 in 0 1k\nCm metal 0 1p\n.tran 1p 2n\n.end\n");
    try reported(&r, .@"error", "node 'metal' has no DC path to ground: only Cm reaches it");
    try testing.expectEqual(1, r.items.items.len);
    // A capacitive divider, and an island behind a 0 V source in series.
    r = try topo(a, "vacask", "t\nV1 in 0 1\nC1 in x 1p\nC2 x 0 1p\nC3 in m 1n\nVam m i 0\nC4 i 0 1n\n.tran 1n 10n\n.end\n");
    try reported(&r, .@"error", "node 'x' has no DC path to ground: only C1, C2 reach it");
    try reported(&r, .@"error", "nodes 'm', 'i' have no DC path to ground: only C3, C4 reach them");
    try testing.expectEqual(2, r.items.items.len);
    // Current sources into a node only a capacitor otherwise touches.
    r = try topo(a, "vacask", "t\nI1 0 a 1m\nI2 a b 1m\nR1 b 0 1k\nC1 a 0 1p\n.tran 1n 10n\n.end\n");
    try reported(&r, .@"error", "node 'a' has no DC path to ground: only I1, I2, C1 reach it, which conduct no DC there, and the currents of the sources into it must balance");
    // A MOSFET gate and a controlled source's input conduct nothing.
    r = try topo(a, "vacask", "t\nV1 d 0 1\nM1 d g 0 0 nm\nE1 o 0 g 0 2\nR1 o 0 1k\n.model nm nmos level=1\n.op\n.end\n");
    try reported(&r, .@"error", "node 'g' has no DC path to ground: only M1, E1 reach it");
    // Spectre solves such a node: a warning there.
    r = try topo(a, "spectre", "t\nV1 in 0 1\nC1 in x 1p\nC2 x 0 1p\n.tran 1n 10n\n.end\n");
    try reported(&r, .warning, "node 'x' has no DC path to ground");
    // Where every analysis skips the DC solve, nothing needs a path.
    r = try topo(a, "vacask", "t\nV1 in 0 1\nC1 in x 1p\nC2 x 0 1p\n.tran 1n 10n uic\n.end\n");
    try testing.expectEqual(0, r.items.items.len);
}

test "topology: loops of voltage sources and inductors" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // An inductor across a source, coupled to another (kinduc_k_exact).
    var r = try topo(a, "vacask", "t\nV1 a 0 ac 1\nL1 a 0 1u\nL2 b 0 1u\nR2 b 0 1e12\nK1 L1 L2 0.3\n.ac lin 1 1meg 1meg\n.end\n");
    try reported(&r, .@"error", "V1, L1 form a loop of voltage sources and inductors through 'a' and '0'");
    try testing.expectEqual(1, r.items.items.len);
    // Sources in parallel, also through a controlled one; a loop of inductors.
    r = try topo(a, "vacask", "t\nV1 a 0 1\nV2 a b 0\nE1 b 0 c 0 1\nR1 c 0 1k\nVi in 0 1\nR3 in p 1k\nL1 p 0 1u\nL2 p q 1u\nL3 q 0 1u\n.op\n.end\n");
    try reported(&r, .@"error", "V1, V2, E1 form a loop of voltage sources through 'b' and '0'");
    try reported(&r, .@"error", "L1, L2, L3 form a loop of inductors through 'q' and '0'");
    try testing.expectEqual(2, r.items.items.len);
    // Each grammar states its own severity: an inductor-only loop is an
    // error in Spectre, a warning in Xyce and nothing in ngspice.
    const lloop = "t\nV1 in 0 1\nR1 in p 1k\nL1 p 0 1u\nL2 p 0 1u\n.op\n.end\n";
    try reported(&(try topo(a, "spectre", lloop)), .@"error", "L1, L2 form a loop of inductors");
    try reported(&(try topo(a, "xyce", lloop)), .warning, "L1, L2 form a loop of inductors");
    var hr: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ngspice", lloop, &hr);
    try testing.expect(!hr.contains(.warning, "form a loop") and !hr.contains(.@"error", "form a loop"));
    // Only one branch of a conditional is in the circuit.
    r = try topo(a, "vacask", "t\n.param big=1\nV1 in 0 1\nR1 in p 1k\n.if (big > 0)\nL1 p 0 1u\n.else\nL1 p 0 1n\n.endif\n.op\n.end\n");
    try testing.expectEqual(0, r.items.items.len);
    // With UIC the transient integrates through the inductors; a loop of
    // sources stays singular.
    r = try topo(a, "vacask", "t\nV1 a 0 1\nL1 a 0 1u\nV2 b 0 1\nV3 b 0 1\nR1 b 0 1\n.tran 1n 10n uic\n.end\n");
    try reported(&r, .@"error", "V2, V3 form a loop of voltage sources");
    try testing.expectEqual(1, r.items.items.len);
}

test "topology: subcircuits carry their DC paths to the instance, and are checked on their own" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // subckt_params: a and mid conduct, b is behind a capacitor. Between
    // the two instances mid1 has no path; through X3 (a resistor) out has.
    var r = try topo(a, "vacask",
        \\t
        \\.subckt rcf a b r=1k c=1n
        \\R1 a mid {r}
        \\C1 mid b {c}
        \\.ends
        \\.subckt rr a b
        \\R1 a b 1k
        \\.ends
        \\.subckt bad p
        \\R1 p 0 1k
        \\C1 p f 1p
        \\.ends
        \\X1 in mid1 rcf
        \\X2 mid1 out rcf
        \\X3 out 0 rr
        \\X4 in bad
        \\Xu in lost unknown_cell
        \\Vin in 0 1
        \\.tran 1u 0.2m
        \\.end
    );
    try reported(&r, .@"error", "node 'mid1' has no DC path to ground: only X1, X2 reach it");
    try reported(&r, .@"error", "subcircuit 'bad': node 'f' has no DC path to ground: only C1 reaches it");
    // An instance of a cell defined elsewhere joins its terminals.
    try testing.expectEqual(2, r.items.items.len);
    // A global node and ground inside a subcircuit are paths.
    r = try topo(a, "vacask", "t\n.global vdd\n.subckt inv i o\nM1 o i vdd vdd pm\nM2 o i 0 0 nm\n.ends\n.model nm nmos level=1\n.model pm pmos level=1\nX1 a b inv\nVa a 0 1\nVdd vdd 0 1\n.op\n.end\n");
    try testing.expectEqual(0, r.items.items.len);
}

test "topology: no alarm where the netlist does not say enough" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_][]const u8{
        // A Verilog-A module may drive its one terminal against ground.
        "t\n.model pm v_pulse rout=1k\nN1 y pm\nC1 y 0 1p\n.tran 1n 10n\n.end\n",
        // A line no rule understood may be the device that gives the path.
        "t\nP1 b 0 port=2 z0=1k\nC2 b 0 1n\n.tran 1n 10n\n.end\n",
        // An RF port has its z0 in series: no loop with the inductor.
        "t\nVp out 0 DC 0 AC 1 portnum 1 z0 50\nL1 out 0 1m\n.ac dec 3 1k 1meg\n.end\n",
        // An .alter's redefinition replaces the source; it is not a second one.
        "t\nV1 a 0 1\nR1 a 0 1k\n.op\n.alter\nV1 a 0 2\n.end\n",
        // A subcircuit's path through a behavioural source, a Verilog-A
        // module or an unknown cell is no source path; nor one in a body
        // no rule understood.
        "t\n.subckt bs p n\nB1 p n V={1}\n.ends\n.subckt un p n\nXu p n elsewhere\n.ends\n.subckt op p n\n.foo bar\nV1 p n 1\n.ends\nV1 a 0 1\nX1 a 0 bs\nX2 a 0 un\nX3 a 0 op\n.op\n.end\n",
        // A source in series between two ports of a subcircuit, and a
        // source to ground behind a resistor: no loop with the parent's.
        "t\n.subckt sr p n\nV1 p m 0\nR1 m n 1k\nV2 k 0 1\nR2 k p 1k\n.ends\nV1 a 0 1\nX1 a 0 sr\n.op\n.end\n",
    };
    for (cases) |src| {
        const r = try topo(a, "vacask", src);
        if (r.items.items.len != 0) {
            dumpReport(&r);
            return error.TestUnexpectedReport;
        }
    }
}

test "topology: a loop through subcircuit instances, one and two levels down" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lib =
        \\.subckt ref p n
        \\Vr p n 1
        \\.ends
        \\.subckt wrap a b
        \\X2 a b ref
        \\.ends
        \\.subckt ind a b
        \\L1 a m 1u
        \\Vm m b 0
        \\.ends
        \\.subckt choke a b
        \\L1 a b 1u
        \\.ends
        \\.subckt gref p
        \\Vg p 0 1
        \\.ends
        \\
    ;
    // A source in the parent, one in the subcircuit, one level down.
    var r = try topo(a, "vacask", "t\n" ++ lib ++ "V1 in 0 1\nX1 in 0 ref\n.op\n.end\n");
    try reported(&r, .@"error", "V1, X1(in,0) form a loop of voltage sources through 'in' and '0'");
    try testing.expectEqual(1, r.items.items.len);
    // Two levels down, between two parent sources.
    r = try topo(a, "vacask", "t\n" ++ lib ++ "V1 a 0 1\nXw a b wrap\nV2 b 0 1\n.op\n.end\n");
    try reported(&r, .@"error", "V1, Xw(a,b), V2 form a loop of voltage sources through 'b' and '0'");
    try testing.expectEqual(1, r.items.items.len);
    // A subcircuit's source to its ground.
    r = try topo(a, "vacask", "t\n" ++ lib ++ "V1 a 0 1\nXg a gref\n.op\n.end\n");
    try reported(&r, .@"error", "V1, Xg(a,0) form a loop of voltage sources");
    // A path of a source and an inductor; one of inductors only.
    r = try topo(a, "vacask", "t\n" ++ lib ++ "V1 a 0 1\nX1 a 0 ind\nV2 c 0 1\nR2 c p 1k\nL2 p 0 1u\nX2 p 0 choke\n.op\n.end\n");
    try reported(&r, .@"error", "V1, X1(a,0) form a loop of voltage sources and inductors through 'a' and '0'");
    try reported(&r, .@"error", "L2, X2(p,0) form a loop of inductors through 'p' and '0'");
    try testing.expectEqual(2, r.items.items.len);
    // ngspice has no inductor-loop rule; Xyce warns on it.
    const lsrc = "t\n" ++ lib ++ "V2 c 0 1\nR2 c p 1k\nL2 p 0 1u\nX2 p 0 choke\n.op\n.end\n";
    try testing.expectEqual(0, (try topo(a, "ngspice", lsrc)).items.items.len);
    try reported(&(try topo(a, "xyce", lsrc)), .warning, "form a loop of inductors");
    // A loop inside a subcircuit is reported there, not again at each instance.
    r = try topo(a, "vacask", "t\n.subckt dbl p n\nV1 p n 1\nV2 p n 1\n.ends\nX1 a 0 dbl\nR1 a 0 1k\nX2 b 0 dbl\nR2 b 0 1k\n.op\n.end\n");
    try reported(&r, .@"error", "subcircuit 'dbl': V1, V2 form a loop of voltage sources");
    try testing.expectEqual(1, r.items.items.len);
}

// c4: HSPICE-reader gaps

test "c4: a dialect's default TNOM and TEMP are written where the target's differ" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // HSPICE: TNOM 25, and the circuit at TNOM. ngspice: 27 and 27.
    var r1: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\nV1 a 0 1\nR1 a 0 1k tc1=0.01\n.temp 125\n.op\n.end\n", &r1), ".options tnom=25\n");
    var r2: ir.Report = .init(a);
    const ng = try tr(a, "hspice", "ngspice", "t\nI1 0 a 1m\nD1 a 0 dm\n.model dm d\n.op\n.end\n", &r2);
    try has(ng, ".options temp=25 tnom=25\n");
    try reported(&r2, .warning, "hspice assumes other defaults for temp, tnom than ngspice does");
    // TEMP follows a TNOM the deck sets.
    var r3: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\n.option tnom=50\nV1 a 0 1\n.op\n.end\n", &r3), ".temp 50\n");
    // The other way: TNOM 27 is said; TEMP then follows it in HSPICE.
    var r4: ir.Report = .init(a);
    const hs = try tr(a, "ngspice", "hspice", "t\nV1 a 0 1\n.op\n.end\n", &r4);
    try has(hs, ".option tnom=27\n");
    try testing.expect(std.mem.indexOf(u8, hs, ".temp") == null);
    // Same defaults, nothing written; a library file gets none.
    var r5: ir.Report = .init(a);
    try testing.expect(std.mem.indexOf(u8, try tr(a, "ngspice", "xyce", "t\nV1 a 0 1\n.op\n.end\n", &r5), ".options") == null);
    try clean(&r1);
    try clean(&r4);
    var r6: ir.Report = .init(a);
    _ = try sameBack(a, "hspice", "spectre", "t\nV1 a 0 1\nR1 a 0 1k\n.op\n.end\n", &r6);
}

test "a circuit on a PDK that sets no temperature is an error where the PDK's simulator assumes another" {
    // ASAP7 is an HSPICE PDK (25 degrees); a sprack.Circuit on it written for
    // Xyce ran at Xyce's 27 with nothing said: nmos_rvt 113.40477 uA against
    // 113.55035 uA at 25 in Xyce 7.10 (issue 31).
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const circuit = "{\"title\":\"t\",\"dialect\":\"sprack\",\"defaults\":\"hspice\",\"stmts\":[{\"kind\":\"resistor\",\"name\":\"R1\",\"pos\":\"a\",\"neg\":\"0\",\"r\":\"1k\"},{\"kind\":\"op\"}]}";
    var r1: ir.Report = .init(a);
    const nl = try sprack.json.parseNetlist(a, circuit, &r1);
    const xy = try writeAs(a, "xyce", &nl, &r1);
    try reported(&r1, .@"error", "options: the circuit sets no temp or tnom; its PDK's simulator (hspice) assumes temp=25, tnom=25 and xyce assumes temp=27, tnom=27");
    try testing.expect(std.mem.indexOf(u8, xy, "temp") == null);
    // The PDK's own simulator, or a circuit that says its temperatures: nothing to report.
    var r2: ir.Report = .init(a);
    _ = try writeAs(a, "hspice", &nl, &r2);
    try testing.expectEqual(0, r2.count(.@"error"));
    const set = "{\"title\":\"t\",\"dialect\":\"sprack\",\"defaults\":\"hspice\",\"stmts\":[{\"kind\":\"options\",\"temp\":25,\"tnom\":25},{\"kind\":\"resistor\",\"name\":\"R1\",\"pos\":\"a\",\"neg\":\"0\",\"r\":\"1k\"},{\"kind\":\"op\"}]}";
    var r3: ir.Report = .init(a);
    const nl3 = try sprack.json.parseNetlist(a, set, &r3);
    _ = try writeAs(a, "xyce", &nl3, &r3);
    try testing.expectEqual(0, r3.count(.@"error"));
    // A circuit with no PDK means no simulator's defaults: nothing to report.
    var r4: ir.Report = .init(a);
    const bare = try sprack.json.parseNetlist(a, "{\"title\":\"t\",\"stmts\":[{\"kind\":\"op\"}]}", &r4);
    _ = try writeAs(a, "xyce", &bare, &r4);
    try testing.expectEqual(0, r4.count(.@"error"));
}

test "c4: SFFM argument order, HSPICE and Xyce against ngspice" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // HSPICE SFFM(VO VA FC MDI FS); ngspice SFFM(VO VA FM MDI FC), MDI 90 when left out.
    {
        var r: ir.Report = .init(a);
        const out = try tr(a, "hspice", "ngspice", "t\nv1 a 0 sffm(0 1 10meg 0.5 1meg)\nv2 b 0 sffm(0 1 10meg)\n.tran 1n 2u\n.end\n", &r);
        try has(out, "v1 a 0 sffm(0 1 1meg 0.5 10meg)\n");
        try has(out, "v2 b 0 sffm(0 1 0 0 10meg)\n");
        try reported(&r, .warning, "limits the SFFM modulation index");
    }
    var r2: ir.Report = .init(a);
    try has(try tr(a, "hspice", "xyce", "t\nv1 a 0 sffm(0 1 10meg 0.5 1meg)\n.end\n", &r2), "v1 a 0 sffm(0 1 10meg 0.5 1meg)\n");
}

test "c4: gshunt, cshunt and delmax" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\n.option gshunt=1m cshunt=1n delmax=50n\ni1 0 a pwl(0 0 1p 1m)\nr1 a 0 1k\n.tran 1u 8u\n.end\n";
    // ngspice: gshunt loads nothing at an operating point; rshunt does.
    // No step-ceiling option: the .tran maximum step.
    var r1: ir.Report = .init(a);
    const ng = try tr(a, "hspice", "ngspice", src, &r1);
    try has(ng, "rshunt=1k cshunt=1n");
    try has(ng, ".tran 1u 8u 0 50n\n");
    try clean(&r1);
    try reported(&r1, .info, "options.delmax is written as tran.maxstep");
    var r2: ir.Report = .init(a);
    try has(try tr(a, "hspice", "hspice", src, &r2), "gshunt=1m cshunt=1n delmax=50n");
    try clean(&r2);
}

test "c4: .dcvolt in both spellings is the initial condition" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    const out = try tr(a, "hspice", "ngspice", "t\nc1 a 0 1n\nc2 b 0 1n\n.dcvolt v(a)=1\n.dcvolt b 2\n.tran 10n 5u uic\n.end\n", &r);
    try has(out, ".ic v(a)=1\n");
    try has(out, ".ic v(b)=2\n");
    try clean(&r);
}

test "c4: HSPICE .pz output and source as ngspice node pairs" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nvin in 0 dc 0 ac 1\nr1 in out 1k\nc1 out 0 1n\n.pz v(out) vin\n.end\n";
    {
        var r: ir.Report = .init(a);
        try has(try tr(a, "hspice", "ngspice", src, &r), ".pz in 0 out 0 vol pz\n");
        try clean(&r);
    }
    var r2: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\nib 0 in 1m\nr1 in 0 1k\n.pz v(in,0) ib\n.end\n", &r2), ".pz 0 in in 0 cur pz\n");
    // HSPICE to HSPICE and Spectre keep the source.
    var r3: ir.Report = .init(a);
    try has(try tr(a, "hspice", "spectre", src, &r3), "iprobe=vin");
    var r4: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ngspice", "t\nr1 in out 1k\n.pz v(out) vx\n.end\n", &r4);
    try reported(&r4, .@"error", "no voltage or current source 'vx'");
}

test "c4: a multi-segment .tran runs to its last stop at its smallest step" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    const out = try tr(a, "hspice", "ngspice", "t\nr1 a 0 1k\n.tran 0.1n 10n 1n 40n\n.end\n", &r);
    try has(out, ".tran 0.1n 40n\n");
    try reported(&r, .warning, "multi-segment .tran is one run to its last stop");
    try clean(&r);
    var r2: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ngspice", "t\n.tran 1n 10n 1n 5n 2n\n.end\n", &r2);
    try testing.expect(r2.count(.@"error") > 0);
    // Numbers that do not rise are SPICE's start time and step ceiling;
    // HSPICE takes the ceiling as nothing (y1), so it is not carried.
    var r3: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\n.tran 10n 1m 0 10n uic\n.end\n", &r3), ".tran 10n 1m 0 uic\n");
    try clean(&r3);
    try reported(&r3, .info, "tran: HSPICE takes a fourth .TRAN number that is no second segment as nothing (its step cap is .OPTION DELMAX), so it is left out");
    var r6: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\n.tran 1n 100n 90n\n.end\n", &r6), ".tran 1n 100n 90n\n");
    var r4: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\n.tran 1n 10n 2n 40n uic\n.end\n", &r4), ".tran 1n 40n uic\n");
    // A ceiling above the stop is no segment either way.
    var r7: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "hspice", "t\n.tran 0.1n 10n 1n 40n\n.end\n", &r7), ".tran 0.1n 10n start=1n\n");
    // A `%` glued to a number is its suffix, not a modulo.
    var r5: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "hspice", "t\nr1 a 0 r={2k%3}\n.end\n", &r5);
    try testing.expect(!r5.contains(.@"error", "operator 'mod'"));
}

test "c4: .option search finds includes in sprack project" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "in/dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "in/top.sp", .data = "t\n.option search='dir'\n.include 'div.inc'\n.lib 'c.lib' tt\nv1 a 0 1\n.op\n.end\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "in/dir/div.inc", .data = "r1 a b 1k\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "in/dir/c.lib", .data = ".lib tt\nr2 b 0 3k\n.endl tt\n" });
    var log: std.Io.Writer.Allocating = .init(a);
    const sum = try sprack.project.run(io, testing.allocator, .{
        .from = sprack.find("hspice").?,
        .to = sprack.find("ngspice").?,
        .tops = &.{try std.fmt.allocPrint(a, "{s}/in/top.sp", .{base})},
        .out_dir = try std.fmt.allocPrint(a, "{s}/out", .{base}),
        .log = &log.writer,
    });
    try testing.expectEqual(0, sum.errors);
    const top = try tmp.dir.readFileAlloc(io, "out/top.sp", a, .unlimited);
    try has(top, ".include \"dir/div.inc\"\n");
    try has(top, ".lib \"dir/c.lib\" tt\n");
    try testing.expect(std.mem.indexOf(u8, top, "search") == null);
    _ = try tmp.dir.readFileAlloc(io, "out/dir/div.inc", a, .unlimited);
    // A single-file translation cannot resolve it: reported, not dropped.
    var r: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ngspice", "t\n.option search='dir'\n.end\n", &r);
    try reported(&r, .@"error", "options.search");
}

test "c4: .parameters is .param in HSPICE" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\n.parameters a=2 b=3\n.end\n", &r), ".param a=2 b=3\n");
    try clean(&r);
}

test "c4: unary ! and % are written only where the target has them" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // HSPICE refuses `%` (measured): an error on reading.
    var r1: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ngspice", "t\nv1 a 0 1\nr1 a 0 '10 % 3'\n.end\n", &r1);
    try reported(&r1, .@"error", "% is not an operator the hspice grammar lists");
    // HSPICE, ngspice and Spectre take a unary `!`; Xyce refuses it.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\nr1 a 0 '1k*(!0)'\n.end\n", &r2), "r1 a 0 {1k*(!0)}\n");
    try clean(&r2);
    var r3: ir.Report = .init(a);
    _ = try tr(a, "hspice", "xyce", "t\nr1 a 0 '1k*(!0)'\n.end\n", &r3);
    try reported(&r3, .@"error", "operator 'not' has no spelling in xyce");
    // `!=` is a comparison, not a not.
    var r4: ir.Report = .init(a);
    _ = try tr(a, "hspice", "xyce", "t\n.param t='(2!=3)'\n.end\n", &r4);
    try clean(&r4);
    // ngspice's % (in .param) has no spelling in Spectre, which refuses it.
    var r5: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "spectre", "t\n.param q={10 % 3}\n.end\n", &r5);
    try reported(&r5, .@"error", "operator 'mod' has no spelling in spectre");
}

test "c4: a .measure that names no analysis measures the last one" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    const out = try tr(a, "hspice", "xyce", "t\nr1 a 0 1k\n.tran 10n 5u\n.measure t50 when v(out)=0.5\n.measure tran slope derivative v(out) at=1u\n.end\n", &r);
    try has(out, ".measure tran t50 when v(out)=0.5\n");
    try has(out, ".measure tran slope deriv v(out) at=1u\n");
    try clean(&r);
    // ngspice 45 measures no derivative.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ngspice", "t\n.tran 10n 5u\n.measure tran slope deriv v(out) at=1u\n.end\n", &r2);
    try testing.expect(r2.count(.@"error") > 0);
}

test "c4: ngspice .noise takes the summary interval" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    const out = try tr(a, "hspice", "ngspice", "t\nvin in 0 ac 1\nr1 in out 1k\n.ac dec 10 1 1meg\n.noise v(out) vin 1\n.end\n", &r);
    try has(out, ".noise v(out) vin dec 10 1 1meg 1\n");
    try clean(&r);
}

test "c5: HSPICE ABSV, ABSI and RELV are vntol, abstol and reltol" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // ABSV and ABSI are VNTOL and ABSTOL in HSPICE: plain.
    var r: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\n.option absv=1e-6 absi=1e-12\n.end\n", &r), ".options abstol=1p vntol=1u\n");
    try clean(&r);
    // The one caveat is the TNOM and TEMP defaults.
    try testing.expectEqual(1, r.countCode(.caveat));
    // RELV bounds voltages only there; ngspice's reltol bounds currents too.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\n.option relv=1e-3\n.end\n", &r2), ".options reltol=1m\n");
    try clean(&r2);
    try reported(&r2, .warning, "options.reltol: HSPICE's RELTOL (RELV) bounds node voltages only");
    // Into HSPICE one reltol is RELTOL and RELI; within HSPICE, RELTOL alone.
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "hspice", "t\n.options vntol=1u abstol=1p reltol=1e-3\n.end\n", &r3), ".option reltol=1m reli=1m abstol=1p vntol=1u\n");
    try clean(&r3);
    try testing.expectEqual(1, r3.countCode(.caveat));
    var r4: ir.Report = .init(a);
    try has(try tr(a, "hspice", "hspice", "t\n.option relv=1e-3 absv=1u\n.end\n", &r4), ".option reltol=1m vntol=1u\n");
    try clean(&r4);
    // RELV and RELTOL are one option: two values are a loss.
    var r5: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ngspice", "t\n.option relv=1e-3 reltol=2e-3\n.end\n", &r5);
    try reported(&r5, .@"error", "options.reltol is given twice with different values");
}

test "c5: HSPICE GMINDC and GMIN are one gmin elsewhere" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\n.option gmindc=1e-9\n.end\n", &r), ".options gmin=1n\n");
    try clean(&r);
    try reported(&r, .warning, "options.gmindc: HSPICE's GMINDC acts in DC");
    // Equal values say one gmin; different ones cannot both be said.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\n.option gmin=1n gmindc=1n\n.end\n", &r2), ".options gmin=1n\n");
    try clean(&r2);
    var r3: ir.Report = .init(a);
    try has(try tr(a, "hspice", "spectre", "t\n.option gmin=1n gmindc=1p\n.end\n", &r3), "options gmin=1n\n");
    try reported(&r3, .@"error", "options: gmin = 1n and gmindc = 1p are both 'gmin' in spectre");
    // ngspice's gmin is both in HSPICE; HSPICE's own GMINDC stays GMINDC.
    var r4: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "hspice", "t\n.options gmin=1e-9\n.end\n", &r4), ".option gmin=1n gmindc=1n\n");
    try clean(&r4);
    var r5: ir.Report = .init(a);
    try has(try tr(a, "hspice", "hspice", "t\n.option gmindc=1e-9\n.end\n", &r5), ".option gmindc=1n\n");
    try clean(&r5);
}

test "c5: HSPICE METHOD=BDF is gear elsewhere, with a caveat; POST is dropped" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\n.option method=bdf post\n.tran 1n 1u\n.end\n", &r), ".options method=gear\n");
    try clean(&r);
    try reported(&r, .warning, "options.method: HSPICE's BDF is not its GEAR");
    try reported(&r, .info, "options: 'post' is not written");
    var r2: ir.Report = .init(a);
    try has(try tr(a, "hspice", "spectre", "t\n.option method=bdf\n.tran 1n 1u\n.end\n", &r2), "method=gear2");
    try clean(&r2);
    // GEAR is GEAR: no caveat. Within HSPICE, both are kept.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ngspice", "t\n.option method=gear\n.tran 1n 1u\n.end\n", &r3);
    try testing.expect(!r3.contains(.warning, "BDF"));
    var r4: ir.Report = .init(a);
    try has(try tr(a, "hspice", "hspice", "t\n.option method=bdf post\n.end\n", &r4), ".option method=bdf post\n");
    try clean(&r4);
}

test "c5: HSPICE RELI and GMINDC that repeat reltol and gmin read back as one value" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\n.option reltol=1m reli=1m gmin=1n gmindc=1n\n.end\n", &r), ".options reltol=1m gmin=1n\n");
    try clean(&r);
    // A RELI of its own has no counterpart elsewhere.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ngspice", "t\n.option reltol=1m reli=1e-2\n.end\n", &r2);
    try reported(&r2, .@"error", "options: 'reli=0.01' has no spelling in ngspice");
}

test "d2: ngspice .pz node pairs as HSPICE and Spectre output and source" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nvin in 0 dc 0 ac 1\nr1 in out 1k\nc1 out 0 1n\n.pz in 0 out 0 vol pz\n.end\n";
    var r: ir.Report = .init(a);
    const hs = try tr(a, "ngspice", "hspice", src, &r);
    try has(hs, ".pz v(out) vin\n");
    try clean(&r);
    // Round trip: the same .pz.
    var r1: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", hs, &r1), ".pz in 0 out 0 vol pz\n");
    try clean(&r1);
    var r2: ir.Report = .init(a);
    const sx = try tr(a, "ngspice", "spectre", src, &r2);
    try has(sx, "pz1 (out 0) pz iprobe=vin\n");
    try clean(&r2);
    var r3: ir.Report = .init(a);
    try has(try tr(a, "spectre", "ngspice", sx, &r3), ".pz in 0 out 0 vol pz\n");
    // Read back by HSPICE the output is a signal, not the node pair: said.
    var r3h: ir.Report = .init(a);
    try has(try tr(a, "spectre", "hspice", sx, &r3h), ".pz v(out) vin\n");
    try reported(&r3h, .info, "pz: the output nodes out 0 are the signal v(out), as hspice names it");

    // A current input is the current source across the pair, either way round.
    var r4: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "hspice", "t\niin 0 in ac 1\nr1 in 0 1k\n.pz in 0 in 0 cur pol\n.end\n", &r4), ".pz v(in) iin\n");
    try reported(&r4, .info, "the reverse of the input pair; the transfer function changes sign, its poles and zeros do not");
    try reported(&r4, .warning, "pz: hspice finds both poles and zeros; only the poles were asked for");

    // A differential output: Spectre takes both nodes, HSPICE only the first.
    const diff = "t\nvin in 0 ac 1\nr1 in a 1k\nr2 a b 1k\nc1 b 0 1n\n.pz in 0 a b vol pz\n.end\n";
    var r5: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "spectre", diff, &r5), "pz1 (a b) pz iprobe=vin\n");
    try clean(&r5);
    var r6: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "hspice", diff, &r6);
    try reported(&r6, .@"error", "hspice takes the poles and zeros of v(a) alone for v(a,b)");
    var r7: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", "t\nvin in 0 ac 1\nr1 in a 1k\nr2 a b 1k\n.pz v(a,b) vin\n.end\n", &r7), ".pz in 0 a b vol pz\n");
    try reported(&r7, .warning, "hspice took the poles and zeros of v(a) alone for v(a,b)");

    // No source across the pair, or two: no source is made up.
    var r8: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "hspice", "t\nvin x 0 ac 1\nr1 x in 1k\nr2 in 0 1k\n.pz in 0 in 0 vol pz\n.end\n", &r8);
    try reported(&r8, .@"error", "no voltage sources connect nodes in and 0");
    var r9: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "spectre", "t\ni1 in 0 1m\ni2 0 in 1m\nr1 in 0 1k\n.pz in 0 in 0 cur pz\n.end\n", &r9);
    try reported(&r9, .@"error", "several current sources connect nodes in and 0");
}

test "c6: a delimited expression joined to more by an operator is one expression" {
    // ngspice 45 takes `.param a = {1+1}*3 + 0*gauss(0,1,1)` as 4: the
    // braces dropped, the rest of the line kept (measured).
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    const src = "t\n.param sw = {0.0+cf*0.0} + pm*mc*agauss(0,1.5e-09,1)\n.param b = {2}*{cf} c = 1 + {cf} d={1+1}*3 e={cf}\n.end\n";
    const ng = try tr(a, "ngspice", "ngspice", src, &r);
    try has(ng, ".param sw={0.0+cf*0.0 + pm*mc*agauss(0,1.5n,1)}\n");
    try has(ng, ".param b={2*cf} c={1 + cf} d={1+1*3} e={cf}\n");
    try testing.expectEqual(0, r.count(.@"error"));
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "hspice", src, &r2), ".param b='2*cf' c='1 + cf' d='1+1*3' e='cf'\n");
    try testing.expectEqual(0, r2.countCode(.untranslated));
    // Undelimited where a bare expression may follow `=`; a sign alone is a number.
    var r3: ir.Report = .init(a);
    const ng3 = try tr(a, "ngspice", "ngspice", "t\n.param p = 0.0 + mc*agauss(0,1.0,1)\n.param q = 1 r=-2 s = -3\n.end\n", &r3);
    try has(ng3, ".param p={0.0 + mc*agauss(0,1.0,1)}\n");
    try has(ng3, ".param q=1 r=-2 s=-3\n");
    // A list of values (CPL matrices) is no subtraction.
    try has(try tr(a, "ngspice", "ngspice", "t\n.model cm cpl c = 100p -60p 100p\n.end\n", &r3), "c=100p -60p 100p");
    // A stray `+` between two parameters joins nothing.
    try has(try tr(a, "ngspice", "ngspice", "t\n.param x = '-1*y' + z = '0 - 2.5'\n.end\n", &r3), ".param x={-1*y} z={0 - 2.5}\n");
    try testing.expectEqual(0, r3.count(.@"error"));
}

test "c6: a model renamed for Spectre across the files of a project" {
    // The model in one file, the subcircuit of its name in another, the
    // transistor that uses the model in a third: each file gets the rename.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = sprack.find("ngspice").?;
    const files = [_][]const u8{
        ".model nch.1 nmos level=14 lmin=0 lmax=1\n",
        ".subckt nch d g s b\nm0 d g s b nch\n.ends nch\n",
        "M1 d g 0 0 nch\nX1 d g 0 0 nch\n",
    };
    var env: ir.Env = .{};
    for (files) |f| {
        var r: ir.Report = .init(a);
        const nl = try sprack.reader.read(g, a, f, &r, .{ .library = true });
        try env.absorb(a, nl.stmts);
    }
    var out: [3][]const u8 = undefined;
    var r: ir.Report = .init(a);
    for (files, 0..) |f, i| {
        const nl = try sprack.reader.read(g, a, f, &r, .{ .env = &env, .library = true });
        var aw: std.Io.Writer.Allocating = .init(a);
        try sprack.writeIn(a, sprack.find("spectre").?, &aw.writer, &nl, &r, &env);
        out[i] = aw.written();
    }
    try has(out[0], "model nch__m bsim4 {\n");
    try has(out[1], "m0 (d g s b) nch__m\n");
    try has(out[2], "M1 (d g 0 0) nch__m\n");
    try has(out[2], "X1 (d g 0 0) nch\n");
    try testing.expectEqual(0, r.count(.@"error"));
}

test "r1: ngspice's psp103va is PSP103; its N instances are transistors" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The module's own LEVEL parameter and the NQS module are on the cards
    // of a PDK; Xyce 7.10's PSP103 has no NQS (docs/verification.md 3.2).
    const src = "t\n.model nm psp103va type=+1 level=103.6 tr=27\n.model pm PSP103VA type = -1 tr=27\n.model nq pspnqs103va type=1 tr=27\n" ++
        "N1 d g 0 0 nm w=1u l=0.13u nf=1 mult=1 dta=0\nN2 d g v v pm w=1u l=0.13u\nN3 d g 0 0 nq w=1u l=0.13u\n" ++
        "Vd d 0 1.2\nVg g 0 0.6\nVv v 0 1.2\n.op\n.end\n";
    var r1: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", src, &r1);
    try has(xy, ".model nm nmos level=103 tr=27\n.model pm pmos level=103 tr=27\n");
    try has(xy, "MN1 d g 0 0 nm w=1u l=0.13u nf=1 mult=1 dta=0\nMN2 d g v v pm w=1u l=0.13u\n");
    try reported(&r1, .warning, "model 'nm': its own 'level' is not written: in xyce that parameter names the model");
    try reported(&r1, .@"error", "model 'nq' is of the Verilog-A module 'pspnqs103va'");
    try testing.expectEqual(2, r1.count(.@"error"));
    var r2: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre", src, &r2);
    try has(sp, "model nm psp103 type=n level=103.6 tr=27\nmodel pm psp103 type=p tr=27\n");
    try has(sp, "N1 (d g 0 0) nm w=1u l=0.13u nf=1 mult=1 dta=0\n");
    try testing.expectEqual(0, r2.count(.@"error"));
    var r3: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", src, &r3);
    try has(va, "load \"psp103v4.osdi\"\nmodel nm psp103va (type=1 level=103.6 tr=27)\n");
    try testing.expectEqual(0, r3.count(.@"error"));
    // Within ngspice nothing changes: an N card stays an N card.
    var r4: ir.Report = .init(a);
    const ng = try tr(a, "ngspice", "ngspice", src, &r4);
    try has(ng, ".model nm psp103va type=1 level=103.6 tr=27\n");
    try has(ng, "N1 d g 0 0 nm w=1u l=0.13u nf=1 mult=1 dta=0\nN2 d g v v pm w=1u l=0.13u\nN3 d g 0 0 nq w=1u l=0.13u\n");
    try testing.expectEqual(0, r4.items.items.len);
    // Into ngspice a PSP103 transistor is an N card whatever its name was,
    // and the deck is told to load the module.
    var r5: ir.Report = .init(a);
    const back = try tr(a, "xyce", "ngspice", "t\n.model nm nmos level=103 tr=27\nM1 d g 0 0 nm w=1u l=0.13u\nVd d 0 1.2\nVg g 0 0.6\n.op\n.end\n", &r5);
    try has(back, ".model nm psp103va type=1 tr=27\nNM1 d g 0 0 nm w=1u l=0.13u\n");
    try reported(&r5, .warning, "the deck must load psp103.osdi with pre_osdi");
    try testing.expectEqual(0, r5.count(.@"error"));
    // Xyce 7.10's PSP103 lacks parameters of PSP 103.6: one that acts is an
    // error by name, one at the value that changes nothing a warning.
    var r6: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", "t\n.model nm psp103va type=1 ctgo=0 thecso=1.2 tr=27\n.end\n", &r6), ".model nm nmos level=103 tr=27\n");
    try reported(&r6, .@"error", "model 'nm': thecso not written: Xyce's PSP103 has no such parameter and ignores it");
    try reported(&r6, .warning, "model 'nm': ctgo not written: Xyce's PSP103 has no such parameter; at 0 it changes nothing");
    try testing.expectEqual(1, r6.count(.@"error"));
    // HSPICE's level 69 takes factuo, and the temperature offset as dtemp.
    var r7: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "hspice", "t\n.model nm psp103va type=1 tr=27\nN1 d g 0 0 nm w=1u l=0.13u dta=5 factuo=1\n.end\n", &r7), "MN1 d g 0 0 nm w=1u l=0.13u dtemp=5 factuo=1\n");
    try testing.expectEqual(0, r7.count(.@"error"));
}

test "r1: a parameter named like a variable Xyce keeps is renamed where it is defined and used" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Xyce refuses `.param vt=` and a subcircuit parameter `vt`
    // (docs/verification.md 4.15). A node and a model parameter of the name
    // are not the parameter.
    const src = "t\n.param vt=3.5m Temp=2 vt__p=1\n.func f(vt,b) {vt*b}\n.subckt s a b vt=1 w=1\nr1 a b {vt*w}\nr3 a b r=vt\n.ends\n" ++
        "X1 a 0 s vt=2 w={vt}\nB1 a 0 v={v(vt)*vt+temp+f(1,2)}\nV1 vt 0 1\n.model sm sw vt=0.5 vh=0.1\nS1 a 0 vt 0 sm\n.op\n.end\n";
    var r1: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", src, &r1);
    try has(xy, ".param vt__p2=3.5m temp__p=2 vt__p=1\n.func f(vt__p2,b) {vt__p2*b}\n.subckt s a b params: vt__p2=1 w=1\nr1 a b {vt__p2*w}\nr3 a b {vt__p2}\n.ends s\n");
    try has(xy, "X1 a 0 s params: vt__p2=2 w={vt__p2}\nB1 a 0 v={v(vt)*vt__p2+temp__p+f(1,2)}\nV1 vt 0 dc 1\n");
    try has(xy, ".model sm vswitch von=600m voff=400m\nS1 a 0 vt 0 sm\n");
    try reported(&r1, .info, "parameter 'vt' is written as 'vt__p2', where it is defined and wherever it is used: Xyce keeps this name");
    try reported(&r1, .info, "parameter 'Temp' is written as 'temp__p'");
    try testing.expectEqual(0, r1.count(.@"error"));
    try testing.expectEqual(2, r1.countCode(.rename));
    // Nothing is renamed for a dialect that keeps no such names.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "hspice", src, &r2), ".param vt=3.5m Temp=2 vt__p=1\n");
    // `time` is the variable wherever it is used: that one stays an error.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\n.param time=1\nR1 a 0 {time}\n.end\n", &r3);
    try reported(&r3, .@"error", "parameter 'time': Xyce keeps this name for a variable of its own and refuses a parameter called so; rename it");
    // In a project: defined in one file, used in another.
    const g = sprack.find("ngspice").?;
    const xyce = sprack.find("xyce").?;
    const files = [_][]const u8{ ".param vt=3.5m\n", ".subckt s a b\nr1 a b {1k*vt}\n.ends s\n" };
    var env: ir.Env = .{};
    for (files) |f| {
        var r: ir.Report = .init(a);
        const nl = try sprack.reader.read(g, a, f, &r, .{ .library = true });
        try env.absorb(a, nl.stmts);
        try sprack.writer.collectReserved(a, xyce, nl.stmts, &env.params, null);
    }
    var r4: ir.Report = .init(a);
    inline for (.{ ".param vt__p=3.5m\n", "r1 a b {1k*vt__p}\n" }, files) |want, f| {
        const nl = try sprack.reader.read(g, a, f, &r4, .{ .env = &env, .library = true });
        var aw: std.Io.Writer.Allocating = .init(a);
        try sprack.writeIn(a, xyce, &aw.writer, &nl, &r4, &env);
        try has(aw.written(), want);
    }
    try testing.expectEqual(0, r4.count(.@"error"));
}

test "r1: an instance parameter the target says under another name, or that changes no result" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // ngspice's capacitor scale multiplies the capacitance as m does, and
    // Xyce has only m (docs/verification.md 4.16).
    const cap = "t\n.model cm c cj=1.5m cjsw=40p\nV1 a 0 dc 0 ac 1\nC1 a 0 cm l=10u w=10u ";
    var r1: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", cap ++ "scale=3\n.end\n", &r1), "C1 a 0 cm l=10u w=10u m=3\n");
    try reported(&r1, .info, "capacitor: the instance parameter 'scale' is spelled 'm' in xyce");
    try testing.expectEqual(0, r1.count(.@"error"));
    // Both on one instance: their product is not something the table can say.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", cap ++ "m=2 scale=3\n.end\n", &r2), "C1 a 0 cm l=10u w=10u m=2\n");
    try reported(&r2, .@"error", "capacitor: 'scale=3' is 'm' in xyce, which the instance gives as well");
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", cap ++ "scale=3 m=2\n.end\n", &r3), "C1 a 0 cm l=10u w=10u m=3\n");
    try reported(&r3, .@"error", "capacitor: 'm=2' is 'm' in xyce, which the instance gives as well");
    // Xyce's own m is still m.
    var r4: ir.Report = .init(a);
    try has(try tr(a, "xyce", "ngspice", "t\nV1 a 0 1\nC1 a 0 1p m=3\n.end\n", &r4), "C1 a 0 1p m=3\n");
    // A diode's OFF only starts the operating-point iteration elsewhere:
    // left out, with a note, where the target's diode has none.
    const dio = "t\n.model dm d is=1e-14\nV1 a 0 0.8\nR1 a k 100\nD1 k 0 dm off area=2\n.op\n.end\n";
    inline for (.{ "spectre", "vacask" }) |to| {
        var r: ir.Report = .init(a);
        try has(try tr(a, "ngspice", to, dio, &r), "D1 (k 0) dm area=2\n");
        try reported(&r, .info, "diode: 'off' is not written: OFF only sets where ngspice starts the operating-point iteration");
        try testing.expectEqual(0, r.count(.@"error"));
    }
    var r5: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", dio, &r5), "D1 k 0 dm area=2 off\n");
    // VACASK has no initial condition on a device: a DC source in series says it.
    var r6: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "vacask", "t\nV1 a 0 1\nC1 a 0 1n ic=0.5\n.end\n", &r6), "VC1__ic (C1__ic 0) vsource dc=0.5\n");
    try testing.expectEqual(0, r6.count(.@"error"));
}

test "r1: a model in another file of a project decides its instances' form" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = sprack.find("ngspice").?;
    const files = [_][]const u8{
        ".model nm psp103va type=1 tr=27\n",
        ".subckt nfet d g s b w=1u l=1u\nN1 d g s b nm w=w l=l\n.ends nfet\n",
    };
    var env: ir.Env = .{};
    for (files) |f| {
        var r: ir.Report = .init(a);
        const nl = try sprack.reader.read(g, a, f, &r, .{ .library = true });
        try env.absorb(a, nl.stmts);
    }
    var r: ir.Report = .init(a);
    const nl = try sprack.reader.read(g, a, files[1], &r, .{ .env = &env, .library = true });
    inline for (.{ "xyce", "ngspice" }, .{ "MN1 d g s b nm w={w} l={l}\n", "N1 d g s b nm w={w} l={l}\n" }) |to, want| {
        var aw: std.Io.Writer.Allocating = .init(a);
        try sprack.writeIn(a, sprack.find(to).?, &aw.writer, &nl, &r, &env);
        try has(aw.written(), want);
    }
    try testing.expectEqual(0, r.count(.@"error"));
}

// e1: the analyses decide whether a topology is reported (src/topology.zig)

test "e1: a deck with no analysis reports no topology; the analyses a rule lists gate it" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A cell netlisted on its own (Schemify's inv.shcomp): its input is
    // driven by whatever uses it, and nothing solves it as it stands.
    const inv = "t\n.global vdd!\nMMN Y A 0 0 nm\nMMP Y A vdd! vdd! pm\n.model nm nmos level=1\n.model pm pmos level=1\n";
    try testing.expectEqual(0, (try topo(a, "vacask", inv ++ ".end\n")).items.items.len);
    try testing.expectEqual(0, (try topo(a, "vacask", "t\nV1 a 0 1\nV2 a 0 1\nC1 a x 1p\n.end\n")).items.items.len);
    // An operating point fails on it in VACASK.
    try reported(&(try topo(a, "vacask", inv ++ ".op\n.end\n")), .@"error", "node 'A' has no DC path to ground: only MMN, MMP reach it");
    // VACASK's transient solves the operating point first, and fails on an
    // island.
    const island = "t\nV1 in 0 1\nC1 in x 1p\nC2 x 0 1p\n.tran 1n 10n\n.end\n";
    try reported(&(try topo(a, "vacask", island)), .@"error", "node 'x' has no DC path to ground");
    // LTspice logs an error on an unbalanced current cutset in every
    // analysis that solves an operating point: a transient without UIC too.
    try reported(&(try topo(a, "ltspice", "t\nI1 0 a 1m\nR1 b 0 1k\nC1 a b 1p\n.tran 1n 10n\n.end\n")), .@"error", "node 'a' has no DC path to ground");
    // A loop needs only some analysis.
    try reported(&(try topo(a, "xyce", "t\nV1 a 0 1\nV2 a 0 1\n.tran 1n 10n\n.end\n")), .@"error", "V1, V2 form a loop of voltage sources");
}

test "e1: statements all read in the target's dialect are not translated: no topology report" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    // As Python's `code(..., "xyce")` builds it: a netlist of no dialect,
    // each statement tagged with the one it was read in.
    var nl = try readAs(a, "xyce", "t\nV1 in 0 1\nC1 in x 1p\nC2 x 0 1p\n.op\n.end\n", &report);
    nl.dialect = "sprack";
    const xyce = (try sprack.internDialect("xyce")).?;
    for (nl.stmts) |*s| s.dialect = xyce;
    _ = try writeAs(a, "xyce", &nl, &report);
    try testing.expect(!report.contains(.warning, "DC path"));
    // One statement from another dialect makes it a translation.
    nl.stmts[1].dialect = (try sprack.internDialect("ngspice")).?;
    _ = try writeAs(a, "xyce", &nl, &report);
    try reported(&report, .warning, "node 'x' has no DC path to ground");
}

test "d3: a double-quoted HSPICE value is an expression; a path or label stays a string" {
    // Measured in HSPICE on decks written for it: `.param t2="a^3"` is 8
    // with a=2, and `"2*rv"` is 2k as an instance, `r=`, subcircuit, model,
    // source, `.temp` and `.meas param=` value; `.include`, `.lib` and
    // `.option search` keep a path, `.meas "ia"` is the measurement ia, and
    // `tstonefile=` / `rlgcfile=` take a file name quoted or not.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\t
        \\.param a=2 t2="a^3" n="4"
        \\.option search="sub"
        \\.include "dir/inc-a.sp"
        \\.temp "a*2"
        \\.subckt ld n rv="3*a"
        \\r1 n 0 rv
        \\.ends ld
        \\r1 n1 0 "2*a"
        \\r2 n2 0 r="2 * a"
        \\x1 n3 ld rv="2*a"
        \\.model rmod r rsh="a/10"
        \\.model smod s tstonefile="m.s1p"
        \\v1 n1 0 "a*3"
        \\.dc v1 1 1 1
        \\.meas dc "ia" find i(v1) at=1
        \\.meas dc ib param="ia*2"
        \\.end
        \\
    ;
    var r: ir.Report = .init(a);
    const ng = try tr(a, "hspice", "ngspice", src, &r);
    try has(ng, ".param a=2 t2={a**3} n=4\n");
    try has(ng, ".temp {a*2}\n");
    try has(ng, ".include \"dir/inc-a.sp\"\n");
    try has(ng, ".subckt ld n rv={3*a}\n");
    try has(ng, "r1 n1 0 {2*a}\nr2 n2 0 {2 * a}\nx1 n3 ld rv={2*a}\n");
    try has(ng, ".model rmod r rsh={a/10}\n.model smod s tstonefile=\"m.s1p\"\n");
    try has(ng, "v1 n1 0 dc {a*3}\n");
    try has(ng, ".meas dc ia find i(v1) at=1\n.meas dc ib param={ia*2}\n");
    try testing.expectEqual(0, r.countCode(.untranslated));
    var r2: ir.Report = .init(a);
    const hs = try tr(a, "hspice", "hspice", src, &r2);
    try has(hs, ".param a=2 t2='a**3' n=4\n");
    try has(hs, ".option search=\"sub\"\n.include \"dir/inc-a.sp\"\n");
    try has(hs, "r1 n1 0 '2*a'\n");
    try testing.expectEqual(0, r2.count(.@"error"));
    // ngspice 45, Xyce 7.10 and Spectre refuse a double-quoted value or
    // keep it a string: there it stays one.
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "ngspice", "t\n.param t=\"a*3\"\n.end\n", &r3), ".param t=\"a*3\"\n");
}

test "g1: Spectre's != is written with blanks; one global line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Spectre 25.10 reads the `!` of `a!=b` as part of the name `a!`.
    const src = "t\n.global vdd\n.param a=2 b=3\n.param t1='(a<b) && (a!=b) || 0' t2='a != b' t3='(a)!=-b' t4='a&&!b'\n.end\n";
    var r: ir.Report = .init(a);
    const sp = try tr(a, "hspice", "spectre", src, &r);
    try has(sp, "parameters t1=((a<b) && (a != b) || 0) t2=(a != b) t3=((a) != -b) t4=a&&!b\n");
    // `global 0 vdd` says what the preamble's `global 0` does: once only.
    try has(sp, "\nglobal 0 vdd\n");
    try testing.expect(std.mem.indexOf(u8, sp, "global 0\n") == null);
    // Read back from Spectre, either spacing is `!=`.
    var r2: ir.Report = .init(a);
    const ng = try tr(a, "spectre", "ngspice", "// t\nsimulator lang=spectre\nparameters a=2 b=3 t=a!=b u=(a != b)\n", &r2);
    try has(ng, ".param a=2 b=3 t={a!=b} u={a != b}\n");
    // Without a global statement the preamble stays.
    var r3: ir.Report = .init(a);
    try has(try tr(a, "hspice", "spectre", "t\nr1 a 0 1k\n.end\n", &r3), "insensitive=yes\nglobal 0\n");
}

// h1: a current cutset is an error in every analysis that solves an
// operating point (grammars/ltspice.spgrammar).

test "h1: a current cutset follows its own requires line: not under a UIC transient" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cut = "t\nI1 0 a 1m\nR1 b 0 1k\nC1 a b 1p\n";
    try testing.expectEqual(0, (try topo(a, "ltspice", cut ++ ".tran 1n 10n uic\n.end\n")).items.items.len);
    try reported(&(try topo(a, "ltspice", cut ++ ".op\n.end\n")), .@"error", "node 'a' has no DC path to ground: only I1, C1 reach it, which conduct no DC there, and the currents of the sources into it must balance; LTspice logs an error and solves on");
    try reported(&(try topo(a, "ltspice", cut ++ ".tran 1n 10n\n.end\n")), .@"error", "LTspice logs an error and solves on");
    // A UIC transient beside an operating point: the operating point reports it.
    try reported(&(try topo(a, "ltspice", cut ++ ".tran 1n 10n uic\n.op\n.end\n")), .@"error", "node 'a' has no DC path to ground");
    // A grammar with no cutset line reports it under its dc-path rule.
    try reported(&(try topo(a, "hspice", cut ++ ".tran 1n 10n\n.end\n")), .warning, "the currents of the sources into it must balance; HSPICE solves it");
}

// s1: a conditional block where the target has none but has a choice inside
// an expression (src/cond.zig). Measured: docs/verification.md 4.11.

test "s1: a conditional block of the same statements is written once, with conditional values" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sub =
        \\.subckt rsel a b n=1 sw=0
        \\.if (sw == 0)
        \\  .if (floor(n/2)*2 != n)
        \\* n is odd
        \\R1 a b r={1k*n} tc1=0
        \\  .else
        \\R1 a b tc1=0 r={2k*n}
        \\  .endif
        \\.elseif (sw == 1)
        \\R1 a b r=5k tc1=0
        \\.else
        \\R1 a b r={7k+n} tc1=0
        \\.endif
        \\.ends
        \\
    ;
    const src = "t\n" ++ sub ++ "V1 1 0 1\nX1 1 0 rsel n=3 sw=0\n.op\n.end\n";
    // Xyce has `c ? a : b`; the nested block is merged first.
    const xyce = "\n* n is odd\nR1 a b {(sw == 0) ? ((floor(n/2)*2 != n) ? (1k*n) : (2k*n)) : ((sw == 1) ? (5k) : (7k+n))} tc1=0\n.ends rsel\n";
    var r: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", src, &r), xyce);
    try testing.expectEqual(0, r.count(.@"error"));
    try testing.expectEqual(1, r.countCode(.oneway));
    try reported(&r, .info, "cond_if: xyce has no conditional blocks; every branch holds the same statements, so they are written once");
    // LTspice has only `if()`.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "ltspice", src, &r2), "\nR1 a b {if(sw == 0, if(floor(n/2)*2 != n, 1k*n, 2k*n), if(sw == 1, 5k, 7k+n))} tc1=0\n");
    try testing.expectEqual(0, r2.count(.@"error"));
    // CDL has neither: the error it was.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "cdl", "t\n" ++ sub ++ ".end\n", &r3);
    try reported(&r3, .@"error", "statement 'cond_if' cannot be written for cdl: CDL has no conditional blocks; nor is its subcircuit written once for each branch: 'floor' in the condition 'floor(n/2)*2 != n' is not a number, an operator or one of the subcircuit's own parameters. Dialects");
    // A file of a project.
    var r4: ir.Report = .init(a);
    var env: ir.Env = .{};
    const nl = try sprack.reader.read(sprack.find("ngspice").?, a, sub, &r4, .{ .env = &env, .library = true });
    var aw: std.Io.Writer.Allocating = .init(a);
    try sprack.writeIn(a, sprack.find("xyce").?, &aw.writer, &nl, &r4, &env);
    try has(aw.written(), xyce);
    try testing.expectEqual(0, r4.count(.@"error"));

    // What is not the same statements with other values stays an error,
    // which says what it was, where the subcircuit's own parameters do not
    // decide the condition (`s` is not one of them).
    const refused = [_][2][]const u8{
        .{ ".if (s == 0)\nR1 p n 1k\n.endif\n", "it has no else branch" },
        .{ ".if (s == 0)\nR1 p n 1k\n.else\nR1 p n 2k\nR2 p n 2k\n.endif\n", "a statement is in one branch only" },
        .{ ".if (s == 0)\nR1 p n 1k\n.else\nC1 p n 1p\n.endif\n", "'resistor' stands in one branch where 'capacitor' stands in another" },
        .{ ".if (s == 0)\nR1 p n 1k\n.else\nR1 p x 1k\n.endif\n", "'R1' has another node in another branch ('n', 'x')" },
        .{ ".if (s == 0)\nR1 p n 1k\n.else\nR2 p n 1k\n.endif\n", "'R1' has another name in another branch ('R1', 'R2')" },
        .{ ".if (s == 0)\nM1 p n n n nch w=1u\n.else\nM1 p n n n pch w=1u\n.endif\n", "'M1' has another model in another branch ('nch', 'pch')" },
        .{ ".if (s == 0)\nC1 p n 1p\n.else\nC1 p n 1p ic=1\n.endif\n", "'C1' has parameter 'ic' in one branch only" },
        .{ ".if (s == 0)\nC1 p n 1p ic=1\n.else\nC1 p n 1p\n.endif\n", "'C1' has parameter 'ic' in one branch only" },
        .{ ".if (s == 0)\nR1 p n rm l=1u\n.model rm r rsh=1\n.else\nR1 p n rm l=2u\n.model rm r rsh=2\n.endif\n", "a branch holds a model card" },
        .{ ".if (s == 0)\n.param k=1\n.else\n.param k=2\n.endif\n", "'param' is not the same in every branch, and only a device's value is written as a choice" },
        .{ ".if (s == 0)\nR1 p n 1k\n.else\n.if (s == 1)\nR1 p n 2k\n.endif\n.endif\n", "in the block at line 6 inside it, it has no else branch" },
    };
    for (refused) |c| {
        var rr: ir.Report = .init(a);
        const out = try tr(a, "ngspice", "xyce", try std.fmt.allocPrint(a, "t\n.subckt q p n\n{s}.ends\n.end\n", .{c[0]}), &rr);
        try has(out, "* [sprack] not written: statement 'cond_if' has no xyce form\n");
        try testing.expectEqual(1, rr.countCode(.unsupported));
        try reported(&rr, .@"error", try std.fmt.allocPrint(a, "Xyce has no conditional blocks in a netlist, and this block is not the same statements with other values in every branch: {s}; nor is its subcircuit written once for each branch: ", .{c[1]}));
    }
}

// v1: a conditional block in a subcircuit that is not the same statements
// with other values: the subcircuit once for each branch (`cond.split`).
// Measured: docs/verification.md 4.17.

const split_lib =
    \\.model ra r tc1=0
    \\.model rb r tc1=0.01
    \\.subckt msel a b r0=1k rfmode=0
    \\.if (rfmode == 0)
    \\R1 a b ra r=r0
    \\.else
    \\R1 a b rb r=r0
    \\.endif
    \\.ends
    \\.subckt csel a b
    \\.param r0=1k
    \\.param tc=1E10
    \\.if (tc>1E9)
    \\R1 a b r=r0
    \\.else
    \\R1 a b r=r0 tc1=tc
    \\.endif
    \\.ends
    \\.subckt dsel a b
    \\.param xd=0 scaling=1e-6 xds=xd/scaling
    \\.if (xds<0.6)
    \\Rin a b ra r=4k
    \\.else
    \\Rout a b rb r=4k
    \\.endif
    \\.ends
    \\
;

test "v1: a subcircuit is written once for each branch of a conditional block" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // By default and by value: a header parameter, a body parameter, one derived from it.
    const top = "V1 1 0 1\nX1 1 0 msel\nX2 1 0 msel rfmode=0\nX3 1 0 msel r0=2k rfmode=1\nX4 1 0 csel\nX5 1 0 csel tc=0.03\nX6 1 0 dsel\nX7 1 0 dsel xd=1u\n";
    const instances = "X1 1 0 msel\nX2 1 0 msel params: rfmode=0\nX3 1 0 msel__1 params: r0=2k rfmode=1\nX4 1 0 csel\nX5 1 0 csel__1 params: tc=0.03\nX6 1 0 dsel\nX7 1 0 dsel__1 params: xd=1u\n";
    var r: ir.Report = .init(a);
    const out = try tr(a, "ngspice", "xyce", "t\n" ++ split_lib ++ top ++ ".op\n.end\n", &r);
    try has(out,
        \\* [sprack] 'msel' where (rfmode == 0)
        \\.subckt msel a b params: r0=1k rfmode=0
        \\R1 a b {r0} ra
        \\.ends msel
        \\* [sprack] 'msel' where !(rfmode == 0)
        \\.subckt msel__1 a b params: r0=1k rfmode=0
        \\R1 a b {r0} rb
        \\.ends msel__1
        \\* [sprack] 'csel' where (tc>1e9)
        \\.subckt csel a b
    );
    try has(out, "R1 a b {r0}\n.ends csel\n* [sprack] 'csel' where !(tc>1e9)\n.subckt csel__1 a b");
    try has(out, "R1 a b {r0} tc1={tc}\n.ends csel__1\n* [sprack] 'dsel' where (xds<0.6)\n.subckt dsel a b");
    try has(out, "Rin a b 4k ra\n.ends dsel\n* [sprack] 'dsel' where !(xds<0.6)\n.subckt dsel__1 a b");
    try has(out, "Rout a b 4k rb\n.ends dsel__1\n");
    try has(out, instances);
    try testing.expectEqual(0, r.count(.@"error"));
    // One for each subcircuit, and one for the body's parameters on the header.
    try testing.expectEqual(4, r.countCode(.oneway));
    try reported(&r, .info, "subckt 'csel': xyce has no conditional blocks, so the subcircuit is written once for each branch of the block at line 14: 'csel' where (tc>1e9), 'csel__1' where !(tc>1e9); an instance is written with the one its parameters select; it reads back as 2 subcircuits");
    // A target with no choice in an expression either: every block is the subcircuit's branches.
    var rc: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "cdl", "t\n" ++ split_lib ++ top ++ ".end\n", &rc), "X5 1 0 / csel__1 tc=0.03\n");

    // The subcircuits in another file of a project: what the files declare chooses.
    const ng = sprack.find("ngspice").?;
    const xy = sprack.find("xyce").?;
    var r2: ir.Report = .init(a);
    var env: ir.Env = .{};
    const lib = try sprack.reader.read(ng, a, split_lib, &r2, .{ .library = true });
    try env.absorb(a, lib.stmts);
    try testing.expectEqual(3, env.conditional.items.len);
    const nl = try sprack.reader.read(ng, a, "t\n" ++ top ++ ".end\n", &r2, .{ .env = &env });
    var aw: std.Io.Writer.Allocating = .init(a);
    try sprack.writeIn(a, xy, &aw.writer, &nl, &r2, &env);
    try has(aw.written(), instances);
    // Written as it is read.
    var sw: std.Io.Writer.Allocating = .init(a);
    try testing.expectEqual(null, try sprack.stream.translate(a, ng, xy, "t\n" ++ top ++ ".end\n", &sw.writer, &r2, &sprack.caps, .{ .env = &env }));
    try has(sw.written(), instances);
    try testing.expectEqual(0, r2.count(.@"error"));
    // Through the JSON form, as the Python package gives a PDK's declarations.
    var ej: std.Io.Writer.Allocating = .init(a);
    try sprack.json.writeEnv(&ej.writer, &env);
    const doc = try std.fmt.allocPrint(a, "{{\"stmts\":[{{\"kind\":\"instance\",\"name\":\"X1\",\"nodes\":[\"1\",\"0\"],\"master\":\"dsel\",\"params\":{{\"xd\":\"1u\"}}}}],\"env\":{s}}}", .{ej.written()});
    const jn = try sprack.json.parseNetlist(a, doc, &r2);
    var again: std.Io.Writer.Allocating = .init(a);
    try sprack.json.writeEnv(&again.writer, jn.env.?);
    try testing.expectEqualStrings(ej.written(), again.written());
    var jw: std.Io.Writer.Allocating = .init(a);
    try sprack.write(a, xy, &jw.writer, &jn, &r2);
    try has(jw.written(), "X1 1 0 dsel__1 params: xd=1u\n");
    try testing.expectEqual(0, r2.count(.@"error"));
}

test "a subcircuit written once for each branch: constant values, and values passed down from a parent" {
    // Issue 41: IHP's isolbox gives ddnwpsub xds=xds, its own parameter.
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\t
        \\.subckt msel a b r0=1k rfmode=0
        \\.if (rfmode == 0)
        \\R1 a b ra r={r0}
        \\.else
        \\R1 a b rb r={r0}
        \\.endif
        \\.ends
        \\.subckt wrap a b mode=0
        \\X1 a b msel rfmode=mode
        \\.ends
        \\X1 n1 0 wrap mode=1
        \\X2 n2 0 msel rfmode={1}
        \\X3 n3 0 msel rfmode='2-1'
        \\X4 n4 0 msel RFMODE=1
        \\X5 n5 0 wrap
        \\V1 n 0 1
        \\.model ra r tc1=0
        \\.model rb r tc1=0.01
        \\.op
        \\.end
    ;
    var r1: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", src, &r1);
    try has(xy, ".subckt wrap a b params: mode=0\nX1 a b msel params: rfmode={mode}\n.ends wrap\n");
    try has(xy, ".subckt wrap__1 a b params: mode=0\nX1 a b msel__1 params: rfmode={mode}\n.ends wrap__1\n");
    try has(xy, "X1 n1 0 wrap__1 params: mode=1\n");
    try has(xy, "X2 n2 0 msel__1 params: rfmode={1}\n");
    try has(xy, "X3 n3 0 msel__1 params: rfmode={2-1}\n");
    try has(xy, "X5 n5 0 wrap\n");
    try clean(&r1);
    // A global parameter can be swept or altered: still an error, in a parent too.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\n.param m=1\n.model ra r tc1=0\n.model rb r tc1=0.01\n.subckt msel a b rfmode=0\n.if (rfmode == 0)\nR1 a b ra r=1k\n.else\nR1 a b rb r=1k\n.endif\n.ends\n.subckt wrap a b\nX1 a 0 msel rfmode=m\n.ends\n.end\n", &r2);
    try reported(&r2, .@"error", "depends on parameter 'rfmode', which is not a number here");
}

test "v1: where a subcircuit is not written once for each branch, the error says why" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // An instance whose deciding value is a global parameter: never the default one silently.
    var r: ir.Report = .init(a);
    const out = try tr(a, "ngspice", "xyce", "t\n" ++ split_lib ++ ".param m=0\nX1 a b msel rfmode=m\nX2 a b msel r0={m*1k} rfmode=1\n.end\n", &r);
    try has(out, "\n* [sprack] not written: instance 'X1'\nX2 a b msel__1 params: r0={m*1k} rfmode=1\n");
    try testing.expectEqual(1, r.count(.@"error"));
    try reported(&r, .@"error", "instance 'X1': subcircuit 'msel' is written once for each branch of its conditional block, and which of them this instance is depends on parameter 'rfmode', which is not a number here");

    const refused = [_][2][]const u8{
        // A global, a function: not the subcircuit's own parameters.
        .{ ".if (g == 0)\nR1 p n 1k\n.endif\n", "'g' in the condition 'g == 0' is not a number, an operator or one of the subcircuit's own parameters" },
        .{ ".if (floor(k) == 0)\nR1 p n 1k\n.endif\n", "'floor' in the condition 'floor(k) == 0' is not a number, an operator or one of the subcircuit's own parameters" },
        .{ ".param d=g\n.if (d == 0)\nR1 p n 1k\n.endif\n", "'g' in the condition 'd == 0' is not a number, an operator or one of the subcircuit's own parameters" },
        .{ ".if (k == 0)\n.param z=1\nR1 p n 1k\n.endif\n", "a branch of the block at line 3 holds something other than devices" },
        .{ ".if (k == 0)\nR1 p n 1k\n.endif\n.ends\n.subckt q__1 p n\n", "'q__1', the name one of them would take, is already declared" },
    };
    for (refused) |c| {
        var rr: ir.Report = .init(a);
        _ = try tr(a, "ngspice", "xyce", try std.fmt.allocPrint(a, "t\n.subckt q p n k=0\n{s}.ends\n.param g=1\n.end\n", .{c[0]}), &rr);
        try testing.expectEqual(1, rr.countCode(.unsupported));
        try reported(&rr, .@"error", try std.fmt.allocPrint(a, "it has no else branch; nor is its subcircuit written once for each branch: {s}. Dialects", .{c[1]}));
    }
    // What a statement outside the block reports is said once, though each subcircuit holds it.
    var r2: ir.Report = .init(a);
    const twice = try tr(a, "ngspice", "xyce", "t\n.subckt q p n k=0\nR9 p n r={nosuch(2)}\n.if (k == 0)\nR1 p n 1k\n.endif\n.ends\n.end\n", &r2);
    try testing.expectEqual(2, std.mem.count(u8, twice, "R9 p n {nosuch(2)}\n"));
    try testing.expectEqual(1, r2.count(.@"error"));
    // A parameter of the header that the body gives again: the later value is the default.
    var r7: ir.Report = .init(a);
    const later = try tr(a, "ngspice", "xyce", "t\n.subckt q p n k=0\n.param k=1\n.if (k == 0)\nR1 p n 1k\n.endif\n.ends\nX1 1 0 q\nX2 1 0 q k=0\n.end\n", &r7);
    try has(later, "R1 p n 1k\n.ends q__1\n");
    try has(later, "X1 1 0 q\nX2 1 0 q__1 params: k=0\n");
    // An instance of one that a name keeps from it.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\n.subckt q p n k=0\n.if (k == 0)\nR1 p n 1k\n.endif\n.ends\n.subckt q__1 p n\n.ends\nX1 1 0 q k=1\n.end\n", &r3);
    try reported(&r3, .@"error", "instance 'X1': subcircuit 'q' holds a conditional block, which xyce has not, and is not written once for each branch: 'q__1', the name one of them would take, is already declared");
    // No else, and a block after it: a subcircuit for every choice, up to eight.
    var r4: ir.Report = .init(a);
    const many = "t\n.subckt q p n k=0\n.if (k == 0)\nR1 p n 1k\n.elseif (k == 1)\nR1 p n 2k\n.endif\n.if (k < 2)\nR2 p n 1k\n.endif\n.ends\nX1 1 0 q k=1\nX2 1 0 q k=7\n.end\n";
    const out4 = try tr(a, "ngspice", "xyce", many, &r4);
    try has(out4, "* [sprack] 'q' where !(k == 0) && (k == 1) && (k < 2)\n.subckt q__2 p n params: k=0\nR1 p n 2k\nR2 p n 1k\n.ends q__2\n");
    try has(out4, "* [sprack] 'q' where !(k == 0) && !(k == 1) && !(k < 2)\n.subckt q__5 p n params: k=0\n.ends q__5\nX1 1 0 q__2 params: k=1\nX2 1 0 q__5 params: k=7\n");
    try reported(&r4, .info, "written once for each branch of the blocks from line 3: 'q' where (k == 0) && (k < 2), 'q__1' where");
    var r5: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\n.subckt q p n k=0\n.if (k == 0)\nR1 p n 1k\n.endif\n.if (k == 1)\nR2 p n 1k\n.endif\n.if (k == 2)\nR3 p n 1k\n.endif\n.if (k == 3)\nR4 p n 1k\n.endif\n.ends\n.end\n", &r5);
    try testing.expectEqual(4, r5.countCode(.unsupported));
    try reported(&r5, .@"error", "nor is its subcircuit written once for each branch: that would be more than 8 subcircuits. Dialects");
    // Outside any subcircuit: the error it was.
    var r6: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\n.param k=0\n.if (k == 0)\nR1 1 0 1k\n.endif\n.end\n", &r6);
    try reported(&r6, .@"error", "in every branch: it has no else branch. Dialects");
}

// s2: what an EXP source leaves out. Measured: docs/verification.md 4.12.

test "s2: an EXP source's left-out values are written out where the target means others" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nV1 a 0 EXP(0 1)\nR1 a 0 1k\n.tran 1n 20n\n.end\n";
    // ngspice's TD1 is the time step, Xyce's is 0; the other three agree.
    var r: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", src, &r), "V1 a 0 exp(0 1 1n)\n");
    try reported(&r, .warning, "vsource.td1 is not given: ngspice means the tran.step by that, and xyce needs it said; wrote 1n");
    try testing.expectEqual(1, r.countCode(.synthesized));
    try testing.expectEqual(0, r.count(.@"error"));
    // And back: Xyce's 0 is said by the smallest delay ngspice takes as
    // given, where it reads a 0 as left out (y1).
    var r2: ir.Report = .init(a);
    try has(try tr(a, "xyce", "ngspice", src, &r2), "V1 a 0 exp(0 1 1a)\n");
    try reported(&r2, .warning, "vsource.td1 is 0: ngspice reads a 0 there as not given and would take the tran.step; wrote 1a, which it takes as given");
    try testing.expectEqual(0, r2.count(.@"error"));
    try testing.expectEqual(1, r2.countCode(.synthesized));
    // A 0 that Xyce assumes is still written where a later value needs its
    // place (HSPICE's TD1 is 0 too; a 0 in ngspice is its step, y1).
    var r3: ir.Report = .init(a);
    try has(try tr(a, "hspice", "xyce", "t\nV1 a 0 EXP(0 1 0 2n 5n 1n)\nR1 a 0 1k\n.tran 1n 20n\n.end\n", &r3), "V1 a 0 exp(0 1 0 2n 5n 1n)\n");
    try testing.expectEqual(0, r3.count(.@"error") + r3.countCode(.synthesized));
    // LTspice assumes 0 for all four; TD2 counts from TD1.
    var r4: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "ltspice", src, &r4), "V1 a 0 exp(0 1 1n 1n 2n 1n)\n");
    try reported(&r4, .warning, "vsource.td2 is not given: ngspice means td1 plus the tran.step by that, and ltspice needs it said; wrote 2n");
    try testing.expectEqual(0, r4.count(.@"error"));
    var r5: ir.Report = .init(a);
    try has(try tr(a, "xyce", "ltspice", src, &r5), "V1 a 0 exp(0 1 0 1n 1n 1n)\n");
    // VACASK's delay is 0 and its td2 counts from the delay.
    var r6: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "vacask", src, &r6), "V1 (a 0) vsource type=\"exp\" val0=0 val1=1 delay=1n td2=1n tau1=1n tau2=1n\n");
    try testing.expectEqual(0, r6.count(.@"error"));
    var r7: ir.Report = .init(a);
    const va = "t\nground 0\nmodel vsource vsource\nV1 (a 0) vsource type=\"exp\" val0=0 val1=1 td2=3n tau1=1n tau2=1n\ncontrol\nanalysis tran1 tran step=1n stop=20n\nendc\n";
    try has(try tr(a, "vacask", "ngspice", va, &r7), "V1 a 0 exp(0 1 1a 1n 3n 1n)\n");
    // What LTspice leaves out is an instant edge: no other dialect means that.
    var r8: ir.Report = .init(a);
    _ = try tr(a, "ltspice", "ngspice", src, &r8);
    try reported(&r8, .@"error", "vsource.tau1 is not given: LTspice's default rise time constant is 0, an instant rise");
    // Nothing in the netlist to take the step from.
    var r9: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\nV1 a 0 EXP(0 1)\nR1 a 0 1k\n.op\n.end\n", &r9);
    try reported(&r9, .@"error", "vsource.td1 is not given: ngspice means the tran.step by that and xyce does not, and this netlist has no tran to take it from");
}

// y1: HSPICE and Spectre say what they mean by an EXP value left out, and
// what a 0 is to ngspice. Measured: docs/verification.md 4.18.

test "y1: an EXP source crossing into or out of HSPICE and Spectre says what was left out" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tran = "R1 a 0 1k\n.tran 2n 50n\n.end\n";
    const ng = "t\nV1 a 0 EXP(0 1)\nI1 0 a EXP(0 1 3n 0.5n 6n)\n" ++ tran;
    // Into them: ngspice's step, and TD1 plus the step.
    var r: ir.Report = .init(a);
    const hs = try tr(a, "ngspice", "hspice", ng, &r);
    try has(hs, "V1 a 0 exp(0 1 2n 2n 4n 2n)\n");
    try has(hs, "I1 0 a exp(0 1 3n 0.5n 6n 2n)\n");
    try reported(&r, .warning, "vsource.tau1 is not given: ngspice means the tran.step by that, and hspice needs it said; wrote 2n");
    try reported(&r, .warning, "isource.tau2 is not given: ngspice means the tran.step by that, and hspice needs it said; wrote 2n");
    try testing.expectEqual(0, r.count(.@"error"));
    var r1: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre", ng, &r1);
    try has(sp, "V1 (a 0) vsource type=exp val0=0 val1=1 td1=2n tau1=2n td2=4n tau2=2n\n");
    try has(sp, "I1 (0 a) isource type=exp val0=0 val1=1 td1=3n tau1=0.5n td2=6n tau2=2n\n");
    try testing.expectEqual(0, r1.count(.@"error"));
    // Xyce's TD1 is 0, as theirs; the rest is the step.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "xyce", "hspice", ng, &r2), "V1 a 0 exp(0 1 0 2n 2n 2n)\n");
    var r3: ir.Report = .init(a);
    try has(try tr(a, "xyce", "spectre", ng, &r3), "V1 (a 0) vsource type=exp val0=0 val1=1 tau1=2n td2=2n tau2=2n\n");

    // Out of HSPICE: TAU1 is half of what is left after TD1, nothing falls
    // within the run (TD2 is the stop, and TAU2 then plays no part), TAU2 is
    // half of what is left after TD2.
    const hsrc = "t\nV1 a 0 EXP(0 1)\nV2 b 0 EXP(0 1 3n)\nI1 0 a EXP(0 1 3n 0.5n 6n)\nR2 b 0 1k\n" ++ tran;
    var r4: ir.Report = .init(a);
    const xy = try tr(a, "hspice", "xyce", hsrc, &r4);
    try has(xy, "V1 a 0 exp(0 1 0 25n 50n)\n");
    try has(xy, "V2 b 0 exp(0 1 3n 23500p 50n)\n");
    try has(xy, "I1 0 a exp(0 1 3n 0.5n 6n 22n)\n");
    try reported(&r4, .warning, "vsource.tau1 is not given: hspice means (tran.stop - td1) / 2 by that, and xyce needs it said; wrote 23500p");
    try reported(&r4, .warning, "vsource.td2 is not given: hspice means the tran.stop by that, and xyce needs it said; wrote 50n");
    try reported(&r4, .warning, "isource.tau2 is not given: hspice means (tran.stop - td2) / 2 by that, and xyce needs it said; wrote 22n");
    try testing.expectEqual(0, r4.count(.@"error") + r4.countCode(.ambiguous));
    // Spectre's TAU1 and TAU2 are a hundredth of the stop: only those differ.
    var r5: ir.Report = .init(a);
    const hsp = try tr(a, "hspice", "spectre", hsrc, &r5);
    try has(hsp, "V1 (a 0) vsource type=exp val0=0 val1=1 tau1=25n\n");
    try has(hsp, "I1 (0 a) isource type=exp val0=0 val1=1 td1=3n tau1=0.5n td2=6n tau2=22n\n");
    try testing.expectEqual(0, r5.count(.@"error"));
    // Out of Spectre.
    const ssrc = "// t\nsimulator lang=spectre\nV1 (a 0) vsource type=exp val0=0 val1=1\nI1 (0 a) isource type=exp val0=0 val1=1 td1=3n tau1=0.3n td2=6n\nR1 (a 0) resistor r=1k\ntran1 tran step=2n stop=50n\n";
    var r6: ir.Report = .init(a);
    const sx = try tr(a, "spectre", "xyce", ssrc, &r6);
    try has(sx, "V1 a 0 exp(0 1 0 500p 50n)\n");
    try has(sx, "I1 0 a exp(0 1 3n 0.3n 6n 500p)\n");
    try reported(&r6, .warning, "vsource.tau1 is not given: spectre means tran.stop / 100 by that, and xyce needs it said; wrote 500p");
    try testing.expectEqual(0, r6.count(.@"error"));
    var r7: ir.Report = .init(a);
    const sh = try tr(a, "spectre", "hspice", ssrc, &r7);
    try has(sh, "V1 a 0 exp(0 1 0 500p)\n");
    try has(sh, "I1 0 a exp(0 1 3n 0.3n 6n 500p)\n");
    try testing.expectEqual(0, r7.count(.@"error"));
    // LTspice and VACASK cannot leave TAU2 out: where it plays no part (no
    // TD2, so no fall within the run) it is written as the step (#75).
    var r8: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ltspice", hsrc, &r8), "V2 b 0 exp(0 1 3n 23500p 50n 2n)\n");
    try reported(&r8, .warning, "vsource.tau2 is not given: without vsource.td2 hspice means it plays no part within the run, and ltspice needs it said; wrote 2n");
    try testing.expectEqual(0, r8.count(.@"error"));
    const one = "t\nV1 a 0 EXP(0 1 3n 0.5n)\n" ++ tran;
    for ([_][]const u8{ "ltspice", "vacask" }) |to| {
        var rt: ir.Report = .init(a);
        _ = try tr(a, "hspice", to, one, &rt);
        try testing.expectEqual(0, rt.count(.@"error"));
    }
    // A Spectre run with no step: a hundredth of the stop.
    var r11: ir.Report = .init(a);
    try has(try tr(a, "spectre", "ltspice", "// t\nsimulator lang=spectre\nV1 (a 0) vsource type=exp val0=0 val1=1 td1=3n tau1=0.5n\nR1 (a 0) resistor r=1k\ntran1 tran stop=50n\n", &r11), "V1 a 0 exp(0 1 3n 0.5n 50n 500p)\n");
    try testing.expectEqual(0, r11.count(.@"error"));

    // No .tran to take the stop from.
    var r9: ir.Report = .init(a);
    _ = try tr(a, "hspice", "xyce", "t\nV1 a 0 EXP(0 1)\nR1 a 0 1k\n.op\n.end\n", &r9);
    try reported(&r9, .@"error", "vsource.tau1 is not given: hspice means (tran.stop - td1) / 2 by that and xyce does not, and this netlist has no tran to take it from");
    var r10: ir.Report = .init(a);
    _ = try tr(a, "spectre", "hspice", "// t\nsimulator lang=spectre\nV1 (a 0) vsource type=exp val0=0 val1=1\nR1 (a 0) resistor r=1k\n", &r10);
    try reported(&r10, .@"error", "vsource.tau1 is not given: spectre means tran.stop / 100 by that and hspice does not, and this netlist has no tran to take it from");
}

test "y1: a 0 in an ngspice EXP source is a value left out" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Out of ngspice a 0 is its default, said where the target reads a 0 as 0.
    const src = "t\nV1 a 0 EXP(0 1 0 0.5n 0 0)\nR1 a 0 1k\n.tran 2n 50n\n.end\n";
    var r: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", src, &r), "V1 a 0 exp(0 1 2n 0.5n 4n 2n)\n");
    try reported(&r, .warning, "vsource.td1 is 0: ngspice means the tran.step by that, and xyce needs it said; wrote 2n");
    try reported(&r, .warning, "vsource.td2 is 0: ngspice means td1 plus the tran.step by that, and xyce needs it said; wrote 4n");
    try testing.expectEqual(0, r.count(.@"error"));
    // Into ngspice a 0 delay is the smallest one it takes as given.
    var r2: ir.Report = .init(a);
    const out = try tr(a, "hspice", "ngspice", "t\nV1 a 0 EXP(0 1 3n 0.5n)\nI2 0 b EXP(0 1)\nR1 a 0 1k\nR2 b 0 1k\n.tran 2n 50n\n.end\n", &r2);
    try has(out, "V1 a 0 exp(0 1 3n 0.5n 50n)\n");
    try has(out, "I2 0 b exp(0 1 1a 25n 50n)\n");
    try reported(&r2, .warning, "isource.td1 is 0: ngspice reads a 0 there as not given and would take the tran.step; wrote 1a, which it takes as given");
    try testing.expectEqual(0, r2.count(.@"error"));
    // An instant edge has no ngspice form, and neither has a TD2 of 0.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "xyce", "ngspice", "t\nV1 a 0 EXP(0 1 3n 0 0 0)\nR1 a 0 1k\n.tran 2n 50n\n.end\n", &r3);
    try reported(&r3, .@"error", "vsource.tau1 is 0: ngspice reads a 0 there as not given and takes the tran.step for it; a 0 cannot be said");
    try reported(&r3, .@"error", "vsource.td2 is 0: ngspice reads a 0 there as not given and takes td1 plus the tran.step for it; a 0 cannot be said");
    try testing.expectEqual(3, r3.count(.@"error"));
}

test "y1: HSPICE's step cap is .OPTION DELMAX, and a fourth .TRAN number is nothing" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Written as the option, on the first options statement there is (here
    // the one that says ngspice's nominal temperature), or one of its own.
    var r: ir.Report = .init(a);
    const hs = try tr(a, "ngspice", "hspice", "t\nr1 a 0 1k\n.tran 2n 50n 0 0.05n\n.end\n", &r);
    try has(hs, ".option tnom=27 delmax=0.05n\n");
    try has(hs, ".tran 2n 50n start=0\n");
    // A netlist with no options statement gets one.
    var r0: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", "t\nr1 a 0 1k\n.tran 2n 50n\n.end\n", &r0);
    for (@constCast(nl.stmts)) |*st| {
        if (st.kind == .tran) try st.set(a, sprack.schema.slot(.tran, "maxstep"), .{ .num = .init("50", -12) });
    }
    var aw: std.Io.Writer.Allocating = .init(a);
    try sprack.write(a, sprack.find("hspice").?, &aw.writer, &nl, &r0);
    try has(aw.written(), ".option delmax=50p\n.tran 2n 50n\n");
    try testing.expectEqual(0, r.count(.@"error"));
    // Read back as the cap by each target.
    const src = "t\n.option delmax=0.05n\nr1 a 0 1k\n.tran 2n 50n\n.end\n";
    var r1: ir.Report = .init(a);
    try has(try tr(a, "hspice", "xyce", src, &r1), ".tran 2n 50n 0 0.05n\n");
    try reported(&r1, .info, "options.delmax is written as tran.maxstep");
    try testing.expectEqual(0, r1.count(.@"error"));
    var r2: ir.Report = .init(a);
    try has(try tr(a, "hspice", "spectre", src, &r2), "tran1 tran step=2n stop=50n maxstep=0.05n\n");
    var r3: ir.Report = .init(a);
    try has(try tr(a, "hspice", "vacask", src, &r3), "analysis tran1 tran step=2n stop=50n maxstep=0.05n\n");
    var r4: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ltspice", src, &r4), ".tran 2n 50n 0 0.05n\n");
    // The fourth number caps nothing in HSPICE, so no cap is carried.
    var r5: ir.Report = .init(a);
    try has(try tr(a, "hspice", "xyce", "t\nr1 a 0 1k\n.tran 2n 50n 0 0.05n\n.end\n", &r5), ".tran 2n 50n 0\n");
    try reported(&r5, .info, "tran: HSPICE takes a fourth .TRAN number that is no second segment as nothing");
    // One option holds for every .tran: another cap has no place, and a
    // .tran without one is told.
    var r6: ir.Report = .init(a);
    const two = try tr(a, "ngspice", "hspice", "t\nr1 a 0 1k\n.tran 2n 50n 0 0.05n\n.tran 2n 80n\n.tran 2n 90n 0 0.05n\n.tran 2n 99n 0 1n\n.end\n", &r6);
    try has(two, ".option tnom=27 delmax=0.05n\n");
    try has(two, ".tran 2n 50n start=0\n.tran 2n 80n\n.tran 2n 90n start=0\n");
    try reported(&r6, .warning, "tran.maxstep is not given: hspice says it once for the whole netlist (options.delmax), so the 0.05n another tran gives holds here too");
    try reported(&r6, .@"error", "tran.maxstep = 1n has no spelling in hspice");
    try testing.expectEqual(1, r6.count(.@"error"));
}

// s4: a condition in parentheses is the text between them, as written.

test "s4: a Spectre condition keeps its two-character operators, whatever its first token" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The lexer cuts at every `=`; joined with blanks that was `a = = 1`.
    // And `a` alone is a value, which the `)` does not follow.
    const conds = [_][]const u8{ "a == 1", "a != 1", "a <= b", "a >= b", "a > 1 && b < 3", "a > 1 || b < 3", "a==1", "a<=b&&a>=b||a==b", "(a == 1) && (b != 2)" };
    for (conds) |c| {
        const src = try std.fmt.allocPrint(a, "// t\nsimulator lang=spectre\nparameters a=1 b=2\nif ({s}) {{\nR1 (p 0) resistor r=1k\n}} else if ({s}) {{\nR1 (p 0) resistor r=2k\n}} else {{\nR1 (p 0) resistor r=3k\n}}\n", .{ c, c });
        var r: ir.Report = .init(a);
        const nl = try readAs(a, "spectre", src, &r);
        const block = for (nl.stmts) |*s| {
            if (s.kind == .cond_if) break s;
        } else return error.TestExpectedBlock;
        try testing.expectEqualStrings(c, block.get("cond").expr);
        try testing.expectEqualStrings(c, block.body[1].get("cond").expr);
        var r2: ir.Report = .init(a);
        const ng = try tr(a, "spectre", "ngspice", src, &r2);
        try has(ng, try std.fmt.allocPrint(a, "\n.if ({s})\nR1 p 0 1k\n.elseif ({s})\nR1 p 0 2k\n.else\n", .{ c, c }));
        try testing.expectEqual(0, r2.countCode(.untranslated));
    }
    // VACASK's condition is the rest of its line: the same operators.
    var r3: ir.Report = .init(a);
    const va = "t\nground 0\nparameters a=1 b=2\n@if a==1&&b<=2||b>=3\nR1 (p 0) resistor r=1k\n@elseif (a != 1) && (b >= 2)\nR1 (p 0) resistor r=2k\n@else\nR1 (p 0) resistor r=3k\n@end\n";
    try has(try tr(a, "vacask", "ngspice", va, &r3), "\n.if (a==1&&b<=2||b>=3)\nR1 p 0 1k\n.elseif ((a != 1) && (b >= 2))\n");
}

// s3, y2: a resistor model's NARROW and SHORT, and an inductor model's IND.
// Measured: docs/verification.md 4.13 and section 9.

test "y2: a resistor model's NARROW and SHORT are written by the target's names" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const deck = "t\n.model rm R RSH=1000 {s}\nR1 1 0 rm L=11u W=5u\nV1 1 0 1\n.op\n.end\n";
    // { from, to, the card's parameters, the card written, a rename reported }
    const cases = [_][5][]const u8{
        .{ "ngspice", "hspice", "narrow=1u short=0.5u", ".model rm r rsh=1000 dw=1u dlr=0.5u\n", "the parameter 'narrow' is spelled 'dw' in hspice" },
        .{ "hspice", "ngspice", "dw=1u dlr=0.5u", ".model rm r rsh=1000 narrow=1u short=0.5u\n", "the parameter 'dlr' is spelled 'short' in ngspice" },
        .{ "ngspice", "spectre", "narrow=1u short=0.5u", "model rm resistor rsh=1000 etch=1u etchl=0.5u\n", "the parameter 'short' is spelled 'etchl' in spectre" },
        .{ "hspice", "spectre", "dw=1u dlr=0.5u", "model rm resistor rsh=1000 etch=1u etchl=0.5u\n", "the parameter 'dw' is spelled 'etch' in spectre" },
        .{ "hspice", "vacask", "dw=1u", "model rm sp_resistor (rsh=1000 narrow=1u)\n", "the parameter 'dw' is spelled 'narrow' in vacask" },
        // ngspice and VACASK take DW and DLR for the two as well.
        .{ "ngspice", "spectre", "dw=1u dlr=0.5u", "model rm resistor rsh=1000 etch=1u etchl=0.5u\n", "the parameter 'dw' is spelled 'etch' in spectre" },
        .{ "vacask", "hspice", "narrow=1u short=0.5u", ".model rm r rsh=1000 dw=1u dlr=0.5u\n", "the parameter 'short' is spelled 'dlr' in hspice" },
    };
    for (cases) |c| {
        var r: ir.Report = .init(a);
        const src = if (std.mem.eql(u8, c[0], "vacask"))
            try std.fmt.allocPrint(a, "t\nground 0\nload \"spice/resistor.osdi\"\nmodel rm sp_resistor (rsh=1000 {s})\nR1 (1 0) rm l=11u w=5u\n", .{c[2]})
        else
            try std.fmt.allocPrint(a, deck, .{c[2]});
        try has(try tr(a, c[0], c[1], src, &r), c[3]);
        try reported(&r, .info, c[4]);
        try clean(&r);
    }
    var back: ir.Report = .init(a);
    try has(try tr(a, "spectre", "ngspice", "// t\nsimulator lang=spectre\nmodel rm resistor rsh=1000 etch=1u etchl=0.5u\nR1 (1 0) rm l=11u w=5u\n", &back), ".model rm r rsh=1000 narrow=1u short=0.5u\n");
    try reported(&back, .info, "the parameter 'etch' is spelled 'narrow' in ngspice");

    // Between ngspice and VACASK the names are the same, and a card with
    // neither parameter is the card it was: nothing is renamed.
    const kept = [_][4][]const u8{
        .{ "ngspice", "vacask", "narrow=1u short=0.5u", "model rm sp_resistor (rsh=1000 narrow=1u short=0.5u)\n" },
        .{ "ngspice", "hspice", "TC1=0.01", ".model rm r rsh=1000 tc1=0.01\n" },
        .{ "ngspice", "xyce", "TC1=0.01", ".model rm r rsh=1000 tc1=0.01\n" },
        .{ "xyce", "spectre", "TC1=0.01", "model rm resistor rsh=1000 tc1=0.01\n" },
    };
    for (kept) |c| {
        var r: ir.Report = .init(a);
        try has(try tr(a, c[0], c[1], try std.fmt.allocPrint(a, deck, .{c[2]}), &r), c[3]);
        try testing.expectEqual(0, r.countCode(.rename) + r.countCode(.loss));
    }

    // The name itself is no parameter of HSPICE's model or Spectre's
    // (ignored there with a warning): it is not handed to one that takes it.
    var r1: ir.Report = .init(a);
    try has(try tr(a, "hspice", "ngspice", try std.fmt.allocPrint(a, deck, .{"dw=1u narrow=3u"}), &r1), ".model rm r rsh=1000 narrow=1u\n");
    try reported(&r1, .warning, "model 'rm': narrow not written: the resistor model of hspice does not take it; that parameter is 'dw' there");
}

test "y2: Xyce's NARROW is ngspice's NARROW and SHORT at twice the number, or the card has no Xyce form" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const deck = "t\n.model rm R RSH=1000 {s}\nR1 1 0 rm L=11u W=5u\nV1 1 0 1\n.op\n.end\n";
    const ng = "ngspice computes R = RSH (L - 2 SHORT) / (W - 2 NARROW)";
    const xy = "xyce computes R = RSH (L - NARROW) / (W - NARROW), with no SHORT";
    // { from, to, the card's parameters, the card written, an info reported }
    const exact = [_][5][]const u8{
        .{ "xyce", "ngspice", "NARROW=1u", ".model rm r rsh=1000 narrow=500n short=500n\n", "model 'rm': narrow=1u of xyce is narrow=500n short=500n, each half its value" },
        .{ "xyce", "vacask", "NARROW=1u", "model rm sp_resistor (rsh=1000 narrow=500n short=500n)\n", "each half its value" },
        .{ "xyce", "hspice", "NARROW=1u", ".model rm r rsh=1000 dw=500n dlr=500n\n", "the parameter 'short' is spelled 'dlr' in hspice" },
        .{ "xyce", "spectre", "NARROW=1u", "model rm resistor rsh=1000 etch=500n etchl=500n\n", "the parameter 'narrow' is spelled 'etch' in spectre" },
        .{ "xyce", "ngspice", "NARROW={a}", ".model rm r rsh=1000 narrow={(a)/2} short={(a)/2}\n", "each half its value" },
        .{ "ngspice", "xyce", "NARROW=1u SHORT=1u", ".model rm r rsh=1000 narrow=2u\n", "model 'rm': narrow=1u short=1u is written narrow=2u, twice the value: xyce has the one parameter for narrow and short" },
        .{ "ngspice", "xyce", "SHORT=0.25u DW=250n", ".model rm r rsh=1000 narrow=500n\n", "twice the value" },
        .{ "hspice", "xyce", "DW='a' DLR='a'", ".model rm r rsh=1000 narrow={(a) * (2)}\n", "twice the value" },
        .{ "spectre", "xyce", "etch=1u etchl=1u", ".model rm r rsh=1000 narrow=2u\n", "twice the value" },
    };
    for (exact) |c| {
        var r: ir.Report = .init(a);
        const src = if (std.mem.eql(u8, c[0], "spectre"))
            try std.fmt.allocPrint(a, "// t\nsimulator lang=spectre\nmodel rm resistor rsh=1000 {s}\nR1 (1 0) rm l=11u w=5u\n", .{c[2]})
        else
            try std.fmt.allocPrint(a, deck, .{c[2]});
        try has(try tr(a, c[0], c[1], src, &r), c[3]);
        try reported(&r, .info, c[4]);
        try clean(&r);
    }
    // Xyce's own SHORT is ignored there with a warning: it is not handed on.
    var r1: ir.Report = .init(a);
    try has(try tr(a, "xyce", "ngspice", try std.fmt.allocPrint(a, deck, .{"NARROW=1u SHORT=0.3u"}), &r1), ".model rm r rsh=1000 narrow=500n short=500n\n");
    try reported(&r1, .warning, "model 'rm': short not written: the resistor model of xyce does not take it; that parameter is 'narrow' there");

    // SHORT is not NARROW (one left out is 0): no Xyce card computes the
    // same, so neither is written and the error states both formulas.
    const none = [_][2][]const u8{ .{ "NARROW=1u", "narrow=1u" }, .{ "SHORT=1u", "short=1u" }, .{ "NARROW=1u SHORT=0.5u", "narrow=1u short=0.5u" }, .{ "NARROW={a} SHORT={b}", "narrow=a short=b" } };
    for (none) |c| {
        var r: ir.Report = .init(a);
        try has(try tr(a, "ngspice", "xyce", try std.fmt.allocPrint(a, deck, .{c[0]}), &r), ".model rm r rsh=1000\n");
        try reported(&r, .@"error", try std.fmt.allocPrint(a, "model 'rm': {s} not written: xyce has the one parameter 'narrow' for narrow and short, and they are not equal here (one left out is 0): " ++ xy, .{c[1]}));
        try reported(&r, .@"error", "; " ++ ng);
    }
    var r2: ir.Report = .init(a);
    _ = try tr(a, "hspice", "xyce", try std.fmt.allocPrint(a, deck, .{"DW=1u"}), &r2);
    try reported(&r2, .@"error", "model 'rm': dw=1u not written: xyce has the one parameter 'narrow' for narrow and short, and they are not equal here (one left out is 0): " ++ xy);
    try reported(&r2, .@"error", "; hspice computes R = RSH (L - 2 DLR) / (W - 2 DW)");
    // NARROW = 0 with no SHORT is Xyce's NARROW = 0: nothing to say.
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", try std.fmt.allocPrint(a, deck, .{"NARROW=0"}), &r3), ".model rm r rsh=1000 narrow=0\n");
    try testing.expectEqual(0, r3.countCode(.rename) + r3.countCode(.loss));
}

test "y2: an inductor's model in Spectre, and its IND" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The card's IND is the inductance of a line that gives none: Spectre's
    // card says `l` for it, and the line names the model as its master.
    const ng = "t\nI1 0 a dc 0 ac 1\nL1 a 0 lmod 1m tc1=0.03\nI2 0 b dc 0 ac 1\nL2 b 0 lmod\n.model lmod l tc1=0.01 ind=3m\n.end\n";
    var r1: ir.Report = .init(a);
    const sp = try tr(a, "ngspice", "spectre", ng, &r1);
    try has(sp, "L1 (a 0) lmod l=1m tc1=0.03\n");
    try has(sp, "L2 (b 0) lmod\n");
    try has(sp, "model lmod inductor tc1=0.01 l=3m\n");
    try reported(&r1, .info, "model 'lmod': the parameter 'ind' is spelled 'l' in spectre");
    try clean(&r1);
    var r2: ir.Report = .init(a);
    const back = try tr(a, "spectre", "ngspice", sp, &r2);
    try has(back, "L1 a 0 lmod 1m tc1=0.03\n");
    try has(back, "L2 b 0 lmod\n");
    try has(back, ".model lmod l tc1=0.01 ind=3m\n");
    try reported(&r2, .info, "model 'lmod': the parameter 'l' is spelled 'ind' in ngspice");
    try clean(&r2);
    var r3: ir.Report = .init(a);
    try has(try tr(a, "spectre", "vacask", sp, &r3), "model lmod sp_inductor (tc1=0.01 ind=3m)\n");
    try clean(&r3);
    // Xyce's model has no IND (a warning there, and the line's value is
    // read): not written, from ngspice's `ind` or from Spectre's `l`, which
    // is a multiplier on a Xyce card.
    inline for (.{ .{ "ngspice", ng }, .{ "spectre", sp } }) |c| {
        var r: ir.Report = .init(a);
        try has(try tr(a, c[0], "xyce", c[1], &r), ".model lmod l tc1=0.01\n");
        try reported(&r, .warning, "model 'lmod': ind not written: Xyce's inductor model has no IND");
    }
}

// u1: a parameter a subcircuit defines inside its body, written for a
// dialect whose instances set only what the header declares (`hoist param`).
// Measured: docs/verification.md 4.14.

test "u1: a subcircuit's inner parameters are written on the header where an instance sets only those" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rr = "t\n.subckt rr a b\n.param r0=1k\nR1 a b {r0}\n.ends\n.end\n";
    const src = "t\n.subckt rr a b\n.param r0=1k $ ohms\n.param k={2*r0}\nR1 a b {k}\n.ends\n" ++
        ".subckt cc a b\n.param c0=1p\nC1 a b {c0}\n.ends\nV1 1 0 1\nX1 1 0 rr r0=4k\nX2 1 0 rr\n.op\n.end\n";
    // Xyce: all of them, in order, the derived one too; one entry for the file.
    var r: ir.Report = .init(a);
    const out = try tr(a, "ngspice", "xyce", src, &r);
    try has(out, ".subckt rr a b params: r0=1k k={2*r0}\n* ohms\nR1 a b {k}\n.ends rr\n.subckt cc a b params: c0=1p\nC1");
    try has(out, "X1 1 0 rr params: r0=4k\nX2 1 0 rr\n");
    try reported(&r, .info, "subckt 'rr' and 1 more in this file: the parameters defined inside are written on the header, which reads back there; xyce gives an instance's value to that instance alone only for a parameter of the header");
    try testing.expectEqual(1, r.countCode(.oneway));
    try testing.expectEqual(0, r.count(.@"error") + r.count(.warning));
    // Back in ngspice they are header parameters, per instance there too.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "xyce", "ngspice", out, &r2), ".subckt rr a b r0=1k k={2*r0}\n");
    try testing.expectEqual(0, excuses(&r2));
    // Where the header has the name too, the inner value is the default (ngspice 45).
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", "t\n.subckt rr a b r0=1k w=2\n.param r0=3k\nR1 a b {r0*w}\n.ends\n.end\n", &r3), ".subckt rr a b params: r0=3k w=2\nR1");
    // LTspice means the same by an inner parameter.
    var r4: ir.Report = .init(a);
    try has(try tr(a, "ltspice", "xyce", rr, &r4), ".subckt rr a b params: r0=1k\nR1");
    try testing.expectEqual(1, r4.countCode(.oneway));
    // The targets that take an inner parameter per instance keep it inside.
    for ([_][]const u8{ "ngspice", "ltspice" }) |to| {
        var r5: ir.Report = .init(a);
        try has(try tr(a, "ngspice", to, rr, &r5), ".subckt rr a b\n.param r0=1k\nR1");
        try testing.expectEqual(0, excuses(&r5));
    }
    // So does Xyce one of its own.
    var r6: ir.Report = .init(a);
    try has(try tr(a, "xyce", "xyce", rr, &r6), ".subckt rr a b\n.param r0=1k\nR1");
    try testing.expectEqual(0, excuses(&r6));
    // HSPICE is not measured: written as it was, and the report says so.
    var r7: ir.Report = .init(a);
    try has(try tr(a, "hspice", "xyce", "t\n.subckt rr a b\n.param r0=1k\nR1 a b r0\n.ends\n.end\n", &r7), ".subckt rr a b\n.param r0=1k\nR1");
    try reported(&r7, .warning, "subckt 'rr': the parameters defined inside are written as they were; xyce gives an instance's value to that instance alone only for a parameter of the header, and what hspice does with one defined inside is not measured");
    try testing.expectEqual(1, r7.countCode(.ambiguous));
}

// z2: what the LTspice verification left open. Measured: docs/verification.md
// 8.7 to 8.11.

test "z2: more analyses than LTspice loads in one deck are an error on each that names them" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ckt = "t\nV1 a 0 1\nR1 a 0 1k\n";
    const why = "LTspice refuses a deck with more than one analysis (\"More than one analysis specified.\"), unless there are two and one is .op, which it then does not run on its own";
    // Both are written: none is dropped or picked.
    var r1: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "ltspice", ckt ++ ".dc V1 0 1 0.5\n.ac dec 2 1 1k\n.end\n", &r1), ".dc V1 0 1 0.5\n.ac dec 2 1 1k\n");
    try reported(&r1, .@"error", "dc: one of 2 analyses in this netlist (dc, ac); " ++ why);
    try reported(&r1, .@"error", "ac: one of 2 analyses in this netlist (dc, ac); " ++ why);
    try testing.expectEqual(2, r1.count(.@"error"));
    try testing.expectEqual(4, r1.items.items[0].line);
    try testing.expectEqual(5, r1.items.items[1].line);
    // A second .op is one too many beside another analysis.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "ltspice", ckt ++ ".op\n.tran 1u 1m\n.op\n.end\n", &r2);
    try reported(&r2, .@"error", "tran: one of 3 analyses in this netlist (op, tran, op); " ++ why);
    try testing.expectEqual(3, r2.count(.@"error"));
    // One .op beside one other loads, and only the other runs.
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "ltspice", ckt ++ ".tran 1u 1m\n.op\n.end\n", &r3), ".tran 1u 1m\n.op\n");
    try clean(&r3);
    try reported(&r3, .warning, "op beside tran; " ++ why);
    // A Fourier line and a measure do not count, and neither does a sweep.
    var r4: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "ltspice", ckt ++ ".tran 1u 1m\n.four 1k v(a)\n.meas tran m1 max v(a)\n.end\n", &r4);
    try testing.expectEqual(0, r4.count(.@"error") + r4.countCode(.caveat));
    // Two .op are one analysis said twice; a deck of LTspice's own is not judged.
    var r5: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "ltspice", ckt ++ ".op\n.op\n.end\n", &r5);
    try testing.expectEqual(0, r5.count(.@"error") + r5.countCode(.caveat));
    var r6: ir.Report = .init(a);
    _ = try tr(a, "ltspice", "ltspice", ckt ++ ".dc V1 0 1 0.5\n.ac dec 2 1 1k\n.end\n", &r6);
    try testing.expectEqual(0, r6.items.items.len);
    // Where every analysis runs, nothing is said.
    var r7: ir.Report = .init(a);
    _ = try tr(a, "ltspice", "ngspice", ckt ++ ".op\n.tran 1u 1m\n.end\n", &r7);
    try clean(&r7);
    try testing.expect(!r7.contains(.warning, "beside"));
}

test "z2: an LTspice .lib with no section loads the whole file; a section is one an .endl closes" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const deck = try tr(a, "ltspice", "ngspice", "t\nR1 a 0 {rv}\n.lib f.lib\n.lib \"g.lib\"\n.lib \"s.lib\" slow\n.op\n.end\n", &r1);
    try has(deck, ".include \"f.lib\"\n.include \"g.lib\"\n.lib \"s.lib\" slow\n");
    try clean(&r1);
    // In a file of sections every opening line has an .endl after it.
    var r2: ir.Report = .init(a);
    const lib = try tr(a, "ltspice", "ngspice", "* sections\n.lib fast\n.param rv=100\n.endl fast\n.lib slow\n.param rv=400\n.lib \"o.lib\" slow\n.endl\n", &r2);
    try has(lib, ".lib fast\n.param rv=100\n.endl fast\n.lib slow\n.param rv=400\n.lib \"o.lib\" slow\n.endl slow\n");
    try clean(&r2);
}

test "z2: a choice with blanks around its operators is read after an equals sign, in LTspice and in ngspice" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nV1 c 0 1\nB1 a 0 I=v(c) > 0.5 ? 1m : 2m\nB2 b 0 V=v(c) != 2 ? v(c) * 2 : 0\nR1 a 0 1k\nR2 b 0 1k\n.param p = 1 >= 0 ? 5 : 6 q = 2\n.op\n.end\n";
    inline for (.{ "ltspice", "ngspice" }) |from| {
        var r: ir.Report = .init(a);
        const out = try tr(a, from, "xyce", src, &r);
        try has(out, "B1 a 0 i={v(c) > 0.5 ? 1m : 2m}\nB2 b 0 v={v(c) != 2 ? v(c) * 2 : 0}\n");
        try has(out, ".param p={1 >= 0 ? 5 : 6} q=2\n");
        try clean(&r);
    }
    // Two parameters, not a comparison: the second `=` assigns.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "xyce", "t\n.param x = 2 * 3 y = 4\n.end\n", &r2), ".param x={2 * 3} y=4\n");
}

test "z2: a PWL's repeat into LTspice: from the first point REPEAT FOREVER, from another a loss (#73)" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const out = try tr(a, "ngspice", "ltspice", "t\nV1 a 0 pwl(0 0 1m 1 2m 0) r=0\nI1 0 b pwl(0 0 1m 1m 2m 0) r=1m td=1m m=2\nR1 a 0 1k\nR2 b 0 1k\n.tran 10u 5m\n.end\n", &r1);
    try has(out, "V1 a 0 pwl repeat forever (0 0 1m 1 2m 0) endrepeat\nI1 0 b pwl(0 0 1m 1m 2m 0)\n");
    try reported(&r1, .@"error", "isource.repeat = 1m has no spelling in ltspice: LTspice repeats a PWL from its first point only");
    try reported(&r1, .@"error", "isource: 'td=1m' has no spelling in ltspice, whose isource takes no such instance parameter");
    try testing.expectEqual(3, r1.countCode(.loss));
    // And back: REPEAT FOREVER is SPICE's r=0.
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ltspice", "ngspice", "t\nV1 a 0 PWL REPEAT FOREVER (0 0 1m 1 2m 0) ENDREPEAT\nR1 a 0 1k\n.tran 10u 5m\n.end\n", &r3), "V1 a 0 pwl(0 0 1m 1 2m 0) r=0\n");
    // What LTspice's own sources take stays, and is a loss elsewhere.
    const lt = "t\nV1 a 0 pwl(0 0 1m 1) Rser=1 Cpar=1p\nI1 0 b 1m load\nR1 a 0 1k\nR2 b 0 1k\n.tran 10u 5m\n.end\n";
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ltspice", "ltspice", lt, &r2), "V1 a 0 pwl(0 0 1m 1) rser=1 cpar=1p\nI1 0 b dc 1m load\n");
    try testing.expectEqual(0, r2.items.items.len);
    var r4: ir.Report = .init(a);
    try has(try tr(a, "ltspice", "ngspice", lt, &r4), "V1 a 0 pwl(0 0 1m 1)\nI1 0 b dc 1m\n");
    try reported(&r4, .@"error", "vsource.rser = 1 has no spelling in ngspice");
    try reported(&r4, .@"error", "isource.load = yes has no spelling in ngspice");
    // LTspice's r= on a current source is no repeat: never written as ngspice's r=.
    var r5: ir.Report = .init(a);
    try has(try tr(a, "ltspice", "ngspice", "t\nI1 0 b 1m r=1k\nR2 b 0 1k\n.op\n.end\n", &r5), "I1 0 b dc 1m\n");
    try reported(&r5, .@"error", "isource: 'r=1k' has no spelling in ngspice");
}

test "#73: an instance parameter LTspice 26.0.2 does not take is a loss into it, and its own are a loss out" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r1: ir.Report = .init(a);
    const lt = try tr(a, "ngspice", "ltspice", "t\nR1 a b 1k tc=1m dtemp=2 m=2\nC1 b 0 1p tc1=1m ic=0\nL1 b c 1u tc1=1m\nD1 a 0 dm l=1u off\nQ1 c b 0 qm areab=2 m=2\nJ1 c b 0 jm l=1u\n.model dm d\n.model qm npn\n.model jm njf\n.op\n.end\n", &r1);
    try has(lt, "R1 a b 1k tc=1m m=2\nC1 b 0 1p ic=0\nL1 b c 1u tc1=1m\nD1 a 0 dm off\nQ1 c b 0 qm m=2\nJ1 c b 0 jm\n");
    try reported(&r1, .@"error", "resistor: 'dtemp=2' has no spelling in ltspice");
    try reported(&r1, .@"error", "capacitor: 'tc1=1m' has no spelling in ltspice");
    try reported(&r1, .@"error", "diode: 'l=1u' has no spelling in ltspice");
    try reported(&r1, .@"error", "bjt: 'areab=2' has no spelling in ltspice");
    try reported(&r1, .@"error", "jfet: 'l=1u' has no spelling in ltspice");
    try testing.expectEqual(5, r1.countCode(.loss));
    // LTspice's own: kept in LTspice, a loss in ngspice; noiseless is read.
    const src = "t\nR1 a b 1k noiseless\nC1 b 0 1p Rser=1 Lser=1n\nL1 b 0 1u Rpar=1k\nD1 a 0 dm n=2\n.model dm d\n.op\n.end\n";
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ltspice", "ltspice", src, &r2), "R1 a b 1k noiseless\nC1 b 0 1p rser=1 lser=1n\nL1 b 0 1u rpar=1k\nD1 a 0 dm n=2\n");
    try clean(&r2);
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ltspice", "ngspice", src, &r3), "C1 b 0 1p\nL1 b 0 1u\nD1 a 0 dm\n");
    try reported(&r3, .@"error", "resistor: 'noiseless' has no spelling in ngspice");
    try reported(&r3, .@"error", "capacitor: 'rser=1' has no spelling in ngspice");
    try reported(&r3, .@"error", "diode: 'n=2' has no spelling in ngspice");
}

test "z2: the cycles of an LTspice sine have a slot, and are a loss where a sine has none" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nV1 a 0 sine(0 1 1k 0 0 0 3)\nI1 0 b sine(0 1m 1k 0.5m 0 90 2.5)\nR1 a 0 1k\nR2 b 0 1k\n.tran 10u 5m\n.end\n";
    var r1: ir.Report = .init(a);
    try has(try tr(a, "ltspice", "ltspice", src, &r1), "V1 a 0 sine(0 1 1k 0 0 0 3)\nI1 0 b sine(0 1m 1k 0.5m 0 90 2.5)\n");
    try testing.expectEqual(0, r1.items.items.len);
    var r2: ir.Report = .init(a);
    try has(try tr(a, "ltspice", "ngspice", src, &r2), "V1 a 0 sin(0 1 1k 0 0 0)\n");
    try reported(&r2, .@"error", "vsource.count = 3 has no spelling in ngspice");
    try reported(&r2, .@"error", "isource.count = 2.5 has no spelling in ngspice");
    // A pulse's number of pulses is the same in both (two, then the first value).
    var r3: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "ltspice", "t\nV1 a 0 pulse(0 1 0 1u 1u 0.5m 1m 2)\nR1 a 0 1k\n.tran 10u 5m\n.end\n", &r3), "V1 a 0 pulse(0 1 0 1u 1u 0.5m 1m 2)\n");
    try clean(&r3);
}

// #45: HSPICE analysis forms of kinds the schema has.

test "#45: an HSPICE .ac POI list of frequencies is the ac's values" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nv1 in 0 dc 0 ac 1\nr1 in out 1k\nc1 out 0 1p\n.ac poi 3 10 159.1549431 1k\n.end\n";
    var r: ir.Report = .init(a);
    try has(try tr(a, "hspice", "spectre", src, &r), "ac1 ac values=[10 159.1549431 1k]\n");
    try clean(&r);
    var r1: ir.Report = .init(a);
    try has(try sameBack(a, "hspice", "hspice", src, &r1), ".ac poi 3 10 159.1549431 1k\n");
    // A list before an .LSTB, which has no list: the .ac stays an analysis.
    var r2: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", "t\nv1 in 0 dc 0 ac 1\nr1 in 0 1k\n.ac poi 2 1k 2k\n.lstb mode=single vsource=v1\n.end\n", &r2);
    try testing.expectEqual(1, countKind(nl, .ac));
    try testing.expectEqual(1, countKind(nl, .stb));
}

test "#45: HSPICE .lin parameters, .hblin POI and a positional .hb" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nv1 in 0 dc 0 ac 1 sin 0 1 1meg\nr1 in 0 1k\n.ac dec 10 1 1g\n.lin gdcalc=1 noisecalc=1\n.hb 1meg 4\n.hblin poi 2 1meg 2meg\n.end\n";
    var r: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", src, &r);
    try clean(&r);
    try testing.expectEqual(1, countKind(nl, .sp));
    try testing.expectEqual(1, countKind(nl, .hb));
    try testing.expectEqual(1, countKind(nl, .psp));
    var r1: ir.Report = .init(a);
    const hs = try sameBack(a, "hspice", "hspice", src, &r1);
    try has(hs, ".ac dec 10 1 1g\n.lin gdcalc=1 noisecalc=1\n");
    try has(hs, ".hb tones=1meg nharms=4\n");
    try has(hs, ".hblin poi 2 1meg 2meg\n");
    var r2: ir.Report = .init(a);
    const sc = try tr(a, "hspice", "spectre", src, &r2);
    try has(sc, "hb1 hb fundfreqs=[1M] maxharms=[4]\n");
    try has(sc, "hbsp values=[1M 2M]");
    try reported(&r2, .@"error", "sp: 'gdcalc=1' has no spelling in spectre");
    // Another dialect's S-parameter options have no place on .LIN.
    var r3: ir.Report = .init(a);
    _ = try tr(a, "spectre", "hspice", "simulator lang=spectre\nsp1 sp start=1 stop=1G dec=10 ports=[p1 p2]\n", &r3);
    try reported(&r3, .@"error", "whose sp takes no such parameter");
}

test "#45: HSPICE .sn by period and time resolution, and an .snnoise band" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nv1 in 0 sin 0 1 100meg\nr1 in out 1k\nc1 out 0 1p\n.sn tres=1n period=10n trinit=5n\n" ++
        ".snnoise v(out) v1 dec 10 1k 1meg 0 1\n.snnoise v(out) v1 dec 10 1k 1meg 1, -1\n.end\n";
    var r: ir.Report = .init(a);
    const hs = try tr(a, "hspice", "hspice", src, &r);
    // NHARMS = round(PERIOD/TRES), TONE = 1/PERIOD.
    try has(hs, ".sn tone=100000000 nharms=10 trinit=5n\n");
    // `0 1` is the output band itself: as without it.
    try has(hs, ".snnoise v(out) v1 dec 10 1k 1meg\n.snnoise v(out) v1 dec 10 1k 1meg 1 -1\n");
    try clean(&r);
    var r1: ir.Report = .init(a);
    const sc = try tr(a, "hspice", "spectre", src, &r1);
    try has(sc, "pss1 pss fund=100000000 harms=10 tstab=5n\n");
    try reported(&r1, .@"error", "pnoise.band = 1 -1 has no spelling in spectre");
    try testing.expectEqual(1, r1.count(.@"error"));
    var r2: ir.Report = .init(a);
    try has(try tr(a, "hspice", "vacask", src, &r2), "analysis pss1 pss tper=1e-8 tstab=5n maxharm=10\n");
}

test "#45: HSPICE .op times, .dc monte= and a Monte Carlo trial list" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nr1 a 0 1k\n.op 1n 5n\n.dc monte=30\n.op sweep monte=list 3\n.tran 1n 1u sweep monte=list(2 5)\n.end\n";
    var r: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", src, &r);
    try clean(&r);
    try testing.expectEqual(3, countKind(nl, .montecarlo));
    try testing.expectEqualStrings("[\"1e-9\",\"5e-9\"]", blk: {
        const j = try jsonOf(a, &nl);
        const at = std.mem.indexOf(u8, j, "\"times\":").? + 8;
        break :blk j[at .. std.mem.indexOfScalarPos(u8, j, at, ']').? + 1];
    });
    var r1: ir.Report = .init(a);
    const hs = try sameBack(a, "hspice", "hspice", src, &r1);
    try has(hs, ".op 1n 5n\n.op sweep monte=30\n.op sweep monte=list(3)\n.tran 1n 1u sweep monte=list(2 5)\n");
    var r2: ir.Report = .init(a);
    const sc = try tr(a, "hspice", "spectre", src, &r2);
    try has(sc, "montecarlo numruns=30 variations=all {\nop");
    try reported(&r2, .@"error", "op.times = 1n 5n has no spelling in spectre");
    try reported(&r2, .@"error", "montecarlo.trials = 3 has no spelling in spectre");
}

// #46: HSPICE element variation, port, pattern and data forms.

test "#46: a bracketed parameter value with blanks in it is one value, in HSPICE and ngspice" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{ "hspice", "ngspice" }) |d| {
        var r: ir.Report = .init(a);
        const nl = try readAs(a, d, "t\nr1 a b 1k foo=[1, -1]\n.end\n", &r);
        try testing.expectEqual(1, countKind(nl, .resistor));
        try has(try jsonOf(a, &nl), "\"foo\":\"[1, -1]\"");
        var r1: ir.Report = .init(a);
        try has(try tr(a, d, d, "t\nr1 a b 1k foo=[1, -1]\n.end\n", &r1), "r1 a b 1k foo=[1, -1]\n");
    }
    var r2: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", "t\nP2 if 0 port=2 z0=50 dc=5 hblin=[1, -1]\n.end\n", &r2);
    try testing.expectEqual(1, countKind(nl, .vsource));
}

test "#46: a balanced HSPICE port, its legs against a third node" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nP1 a b 0 port=1 z0=50\nP2 c 0 port=2 z0=50\nr1 a b 100\nr2 b c 1k\n.ac dec 10 1 1g\n.lin\n.end\n";
    var r: ir.Report = .init(a);
    try has(try sameBack(a, "hspice", "hspice", src, &r), "P1 a b 0 port=1 z0=50\nP2 c 0 port=2 z0=50\n");
    var r1: ir.Report = .init(a);
    try has(try tr(a, "hspice", "spectre", src, &r1), "P1 (a b) port num=1 r=50\n");
    try reported(&r1, .@"error", "vsource.portref = 0 has no spelling in spectre");
}

test "#46: HSPICE PAT sources: repeats between bit groups, and a named .pat" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\n.pat a2=[b10 b01] r=1\nv1 a 0 pat (1 0 1n 0.2n 0.4n 2n b1011 r=1 rb=2 b0m1)\nv2 b 0 pat 2 0 0 0.1n 0.1n 1n a2\nr1 a b 1k\n.tran 1n 10n\n.end\n";
    var r: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", src, &r);
    try clean(&r);
    try testing.expectEqual(1, countKind(nl, .pattern));
    try testing.expectEqual(2, countKind(nl, .vsource));
    var r1: ir.Report = .init(a);
    const hs = try sameBack(a, "hspice", "hspice", src, &r1);
    try has(hs, ".pat a2=[b10 b01] r=1\n");
    try has(hs, "v1 a 0 pat(1 0 1n 0.2n 0.4n 2n b1011 r=1 rb=2 b0m1)\n");
    var r2: ir.Report = .init(a);
    _ = try tr(a, "hspice", "spectre", src, &r2);
    try reported(&r2, .@"error", "statement 'pattern' cannot be written for spectre");
    // A function's arguments are not taken for such repeats.
    var r3: ir.Report = .init(a);
    const f = try readAs(a, "hspice", "t\n.param f(x)='x*2'\n.end\n", &r3);
    try testing.expectEqual(1, countKind(f, .func));
}

test "#46: HSPICE .data read from files" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\n.param rl=1k\nr1 a 0 rl\nv1 a 0 1\n.data rows LAM FILE='l1.dat' rl=1\n.enddata\n.dc data=rows\n.end\n";
    var r: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", src, &r);
    try clean(&r);
    try testing.expectEqual(1, countKind(nl, .data));
    try has(try jsonOf(a, &nl), "\"join\":\"lam\",\"files\":\"FILE='l1.dat' rl=1\"");
    var r1: ir.Report = .init(a);
    try has(try sameBack(a, "hspice", "hspice", src, &r1), ".data rows lam FILE='l1.dat' rl=1\n.enddata\n");
    var r2: ir.Report = .init(a);
    _ = try tr(a, "hspice", "xyce", src, &r2);
    try testing.expect(r2.countCode(.unsupported) >= 1);
}

test "#46: an HSPICE element variation is read, and Spectre says it has no form for it" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "* ev\nv1 a 0 1\nr1 a b 1k\nc1 b 0 1p\nd1 b 0 dm\n.model dm d is=1e-14\n.variation\n.element_variation\nr r=10%\nc c=5 %\n" ++
        ".end_element_variation\n.local_variation\nd dm is=10%\n.end_local_variation\n.end_variation\n.tran 1n 10n sweep monte=10\n.end\n";
    var r: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", src, &r);
    try clean(&r);
    const j = try jsonOf(a, &nl);
    try testing.expectEqual(3, std.mem.count(u8, j, "\"kind\":\"vary\""));
    try has(j, "\"scope\":\"element\"");
    try has(j, "{\"kind\":\"vary\",\"line\":9,\"param\":\"r\",\"mtype\":\"r\",\"std\":\"10\",\"rel\":\"yes\"}");
    var r1: ir.Report = .init(a);
    const hs = try sameBack(a, "hspice", "hspice", src, &r1);
    try has(hs, ".element_variation\nr r=10 %\nc c=5 %\n.end_element_variation\n");
    // A lone Monte Carlo is the ending of its analysis, not a line of its own.
    try has(hs, ".tran 1n 10n sweep monte=10\n");
    var r2: ir.Report = .init(a);
    const sc = try tr(a, "hspice", "spectre", src, &r2);
    try has(sc, "// [sprack] not written: statgroup scope=element\n// [sprack] not written: vary\n// [sprack] not written: vary\n");
    try reported(&r2, .@"error", "statgroup scope=element cannot be written for spectre: Spectre varies netlist parameters");
    try testing.expectEqual(1, r2.countCode(.unsupported));
}

// #47: HSPICE statements no kind held.

test "#47: .fft is a statement of HSPICE and Xyce, its windows and keys checked" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "* fft\nv1 a 0 sin(0 1 1meg)\nr1 a 0 1k\n.tran 10n 8u\n.fft v(a)\n" ++
        ".fft v(a) start=0 stop=8u np=256 format=unorm window=hann alfa=3 freq=1meg fmin=1meg fmax=5meg\n.end\n";
    var r: ir.Report = .init(a);
    const xy = try tr(a, "hspice", "xyce", src, &r);
    try has(xy, ".fft v(a)\n.fft v(a) start=0 stop=8u np=256 window=hann alfa=3 format=unorm freq=1meg fmin=1meg fmax=5meg\n");
    try clean(&r);
    var r1: ir.Report = .init(a);
    _ = try sameBack(a, "xyce", "hspice", xy, &r1);
    // Xyce has no Kaiser window; ngspice no .FFT statement.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "hspice", "xyce", "t\nv1 a 0 1\n.tran 1n 1u\n.fft v(a) window=kaiser\n.end\n", &r2);
    try reported(&r2, .@"error", "fft.window = kaiser has no spelling in xyce");
    var r3: ir.Report = .init(a);
    _ = try tr(a, "hspice", "ngspice", src, &r3);
    try reported(&r3, .@"error", "statement 'fft' cannot be written for ngspice: ngspice's spectrum is the fft command of its control language");
    // A key HSPICE does not take: it drops the statement.
    var r4: ir.Report = .init(a);
    _ = try readAs(a, "hspice", "t\n.fft v(a) zzfoo=1\n.end\n", &r4);
    try reported(&r4, .@"error", "fft: 'zzfoo' is not a key hspice takes there");
    // Xyce's own spellings of a window.
    var r5: ir.Report = .init(a);
    try has(try tr(a, "xyce", "hspice", "t\nv1 a 0 1\n.tran 1n 1u\n.fft v(a) window=hanning\n.end\n", &r5), ".fft v(a) window=hann\n");
}

test "#47: an HSPICE optimization is the ending of its analysis, and nowhere else" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "* opt\n.param rx=opt1(1k, 100, 10k)\nv1 a 0 1\nr1 a b rx\nr2 b 0 1k\n.model optmod opt itropt=30\n" ++
        ".dc v1 0 5 1 sweep optimize=opt1 results=vout model=optmod\n.end\n";
    var r: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", src, &r);
    try testing.expectEqual(1, countKind(nl, .optimize));
    var r1: ir.Report = .init(a);
    try has(try sameBack(a, "hspice", "hspice", src, &r1), ".dc v1 0 5 1 sweep optimize=opt1 results=vout model=optmod\n");
    var r2: ir.Report = .init(a);
    const xy = try tr(a, "hspice", "xyce", src, &r2);
    try reported(&r2, .@"error", "model 'optmod' of type 'opt' cannot be written for xyce: HSPICE's optimizer is set by a .MODEL of type OPT");
    try reported(&r2, .@"error", "analysis 'optimize' cannot be written for xyce: Xyce has no optimizer statement");
    // What it holds is left out with it, as the report says.
    try testing.expect(std.mem.indexOf(u8, xy, "\n.dc ") == null);
}

test "#47: a comma after = parts two values: an optimization's results=va,vb is two results" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "* opt\n.param ra=opt2(1k, 100, 10k)\nv1 a 0 1\nr1 a b ra\nr2 b 0 1k\n.model optmod opt relin=1e-6\n" ++
        ".dc v1 0 5 1 sweep optimize=opt2 results=va,vb model=optmod\n.end\n";
    var r: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", src, &r);
    try testing.expectEqual(1, countKind(nl, .optimize));
    try testing.expectEqual(0, countKind(nl, .@"opaque"));
    var r1: ir.Report = .init(a);
    try has(try sameBack(a, "hspice", "hspice", src, &r1), ".dc v1 0 5 1 sweep optimize=opt2 results=va,vb model=optmod\n");
}

test "#47: an HSPICE optimization reads result= in the singular, written back as results=" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "* opt\n.param rx=opt1(5k, 100, 10k)\nv1 a 0 5\nr1 a b 1k\nr2 b 0 rx\n.model optmod opt method=bisection\n" ++
        ".dc v1 0 5 1 sweep optimize=opt1 result=vout model=optmod\n.end\n";
    var r: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", src, &r);
    try testing.expectEqual(1, countKind(nl, .optimize));
    var r1: ir.Report = .init(a);
    try has(try tr(a, "hspice", "hspice", src, &r1), ".dc v1 0 5 1 sweep optimize=opt1 results=vout model=optmod\n");
}

test "#47: HSPICE statements of its own are unsupported elsewhere, with the reason" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lines = [_][]const u8{
        ".connect b c",                          ".dcsens v(d)",                   ".acmatch v(d)",       ".net v(out) vin",
        ".power v1",                             ".check edge (a b) 1n 2n",        ".dout a 0.5 (0n 1)",  ".biaschk 'nmos' region=cutoff",
        ".mosra reltotaltime=1e8",               ".appendmodel m1 mosra nch nmos", ".ptdnoise v(a) 1n",   ".sample fs=1meg",
        ".acphasenoise v(a) (v1) dec 10 1 1meg", ".load file=load_ic.ic0",         ".vec 'vec_stim.vec'", "s1 p1 p2 mname=smod",
    };
    for (lines) |l| {
        const src = try std.fmt.allocPrint(a, "t\nr1 a 0 1k\n{s}\n.end\n", .{l});
        var r: ir.Report = .init(a);
        _ = try tr(a, "hspice", "spectre", src, &r);
        try testing.expectEqual(0, r.countCode(.untranslated));
        try testing.expectEqual(1, r.countCode(.unsupported));
        // In HSPICE itself the line is understood: no note that it was not.
        var r1: ir.Report = .init(a);
        try has(try tr(a, "hspice", "hspice", src, &r1), l);
        try testing.expectEqual(0, r1.countCode(.oneway));
    }
}

test "#48: each family ngspice gained has a row or a reason in every target" {
    const fams = [_][]const u8{ "mos6", "mos9", "bsim1", "bsim2", "b3soifd", "b3soidd", "b3soipd", "mesa" };
    for ([_][]const u8{ "xyce", "hspice", "spectre", "vacask", "ltspice", "ngspice" }) |d| {
        const g = sprack.find(d).?;
        for (fams) |f| {
            const row = for (g.models) |e| {
                if (std.mem.eql(u8, e.family, f)) break true;
            } else false;
            if (!row and g.noFamilyReason(f) == null) {
                std.debug.print("{s}: family {s} has neither a row nor a reason\n", .{ d, f });
                return error.TestMissingFamily;
            }
        }
    }
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    const out = try tr(a, "ngspice", "xyce", "t\nm1 d g 0 0 m6 l=1u w=1u\n.model m6 nmos level=6 vto=0.5\n.model b1 pmos level=4\n.end\n", &r);
    try has(out, ".model m6 nmos level=6 vto=0.5\n");
    try reported(&r, .@"error", "model 'b1' (bsim1 p) cannot be written for xyce");
    var r1: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "hspice", "t\n.model b1 nmos level=4 k1=0.5\n.model b2 nmos level=5\n.end\n", &r1), ".model b1 nmos level=13 k1=0.5\n.model b2 nmos level=39\n");
}

test "#49: an S-parameter port into VACASK says how to rebuild it" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "vacask", "t\nV1 in 0 dc 0 ac 1 portnum 1 z0 50\nV2 out 0 dc 0 ac 0 portnum 2 z0 50\nr1 in out 1k\n.sp dec 10 1k 1g\n.end\n", &r);
    try reported(&r, .@"error", "vsource.portnum = 1 has no spelling in vacask: a VACASK acsp port is a voltage source and a series resistor");
    try reported(&r, .@"error", "vsource.z0 = 50 has no spelling in vacask: the port impedance is a series resistor");
    try testing.expectEqual(4, r.countCode(.loss));
}

test "#68: noise between two nodes into Xyce is a loss that says why; one node is not" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    const out = try tr(a, "ngspice", "xyce", "t\nV1 in 0 dc 0 ac 1\nR1 in a 1k\nR2 a b 1k\nR3 b 0 1k\n.noise v(a,b) V1 dec 1 1k 10k\n.end\n", &r);
    try has(out, ".noise v(a) V1 dec 1 1k 10k\n");
    try reported(&r, .@"error", "noise.ref = b has no spelling in xyce: Xyce 7.10 takes one output node");
    var r1: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\nV1 in 0 dc 0 ac 1\nR1 in a 1k\nR2 a 0 1k\n.noise v(a) V1 dec 1 1k 10k\n.end\n", &r1);
    try testing.expectEqual(0, r1.countCode(.loss));
}

test "#70: a Monte Carlo run into Spectre varies the mismatch block too" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const deck = "t\n.param p1=agauss(1k,30,3)\nI1 0 a 1m\nR1 a 0 p1\n.tran 1n 10n sweep monte=20\n.end\n";
    for ([_][]const u8{ "hspice", "xyce" }) |from| {
        var r0: ir.Report = .init(a);
        const src = if (std.mem.eql(u8, from, "hspice")) deck else try tr(a, "hspice", "xyce", deck, &r0);
        var r: ir.Report = .init(a);
        try has(try tr(a, from, "spectre", src, &r), "mc1 montecarlo numruns=20 variations=all {\n");
    }
    // Spectre to Spectre keeps what was said, or nothing.
    const scs = "// t\nsimulator lang=spectre\nmc1 montecarlo numruns=5 {\ntran1 tran stop=1n\n}\n";
    var r1: ir.Report = .init(a);
    try has(try tr(a, "spectre", "spectre", scs, &r1), "mc1 montecarlo numruns=5 {\n");
    // Back into HSPICE: all is what it does; process alone is a loss.
    var r2: ir.Report = .init(a);
    var r3: ir.Report = .init(a);
    _ = try tr(a, "spectre", "hspice", "// t\nsimulator lang=spectre\nmc1 montecarlo numruns=5 variations=all {\ntran1 tran stop=1n\n}\n", &r2);
    try testing.expectEqual(0, r2.countCode(.loss));
    _ = try tr(a, "spectre", "hspice", "// t\nsimulator lang=spectre\nmc1 montecarlo numruns=5 variations=process {\ntran1 tran stop=1n\n}\n", &r3);
    try reported(&r3, .@"error", "montecarlo.variations = process has no spelling in hspice");
}

test "#72: names in probes and function arguments keep their own spellings" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\nV1 OUT 0 1\nM1 OUT OUT 0 0 nch w=1u l=1u\n.model nch nmos level=1\n.func f(X) {X*2}\n" ++
        "B1 a 0 v={f(1)*id(m1)*vdb(out)*@m1[gm]}\nR1 a 0 1k\n.dc V1 0 1 0.1\n.end\n";
    var r: ir.Report = .init(a);
    var nl = try sprack.read(a, sprack.find("ngspice").?, src, &r);
    // Spectre told the names are as written: no insensitive=yes, so each
    // name must be the one its device or node is written with.
    nl.folds_case = false;
    nl.dialect = "sprack";
    var w: std.Io.Writer.Allocating = .init(a);
    try sprack.write(a, sprack.find("spectre").?, &w.writer, &nl, &r);
    const out = w.written();
    try testing.expect(std.mem.indexOf(u8, out, "insensitive") == null);
    try has(out, "id(M1)*vdb(OUT)");
    try has(out, "real f(real x) {\nreturn (x*2)\n}\n");
    // ngspice's own device-quantity form names the device as written.
    var r1: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "ngspice", src, &r1), "@M1[gm]");
    // A terminal current read from a print list: one spelling of its letter.
    var r2: ir.Report = .init(a);
    try has(try tr(a, "xyce", "xyce", "t\nV1 OUT 0 1\nM1 OUT OUT 0 0 nch w=1u l=1u\n.model nch nmos level=1\n.print dc ID(M1) vdb(out)\n.dc V1 0 1 0.1\n.end\n", &r2), ".print dc id(M1) vdb(OUT)\n");
}

test "#50: an ngspice .control block is a script of statements" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "* control\n.param freq=1k\n.csparam freq = {freq}\nv1 a 0 dc 1\nr1 a 0 1k\n.control\nop\ndc v1 0 1 0.1\n" ++
        "print v(a)\nlet vth = v(a)*2\nmeas dc vmax max v(a)\nrun\nquit\n.endc\n.end\n";
    var r: ir.Report = .init(a);
    const nl = try readAs(a, "ngspice", src, &r);
    try clean(&r);
    try testing.expectEqual(0, countKind(nl, .@"opaque"));
    try testing.expectEqual(1, countKind(nl, .script));
    try testing.expectEqual(1, countKind(nl, .csparam));
    const j = try jsonOf(a, &nl);
    try has(j, "{\"kind\":\"op\",\"line\":7}");
    try has(j, "{\"kind\":\"simctl\",\"line\":10,\"cmd\":\"let\",\"args\":\"vth = v(a)*2\"}");
    var r1: ir.Report = .init(a);
    try has(try sameBack(a, "ngspice", "ngspice", src, &r1), ".control\nop\ndc v1 0 1 0.1\nprint v(a)\nlet vth = v(a)*2\nmeas dc vmax max v(a)\nrun\nquit\n.endc\n");
    try testing.expectEqual(0, r1.countCode(.oneway));
    // Into Xyce: the analyses and the measure are the deck's; run and quit
    // have nothing to say; print and let are ngspice's.
    var r2: ir.Report = .init(a);
    const xy = try tr(a, "ngspice", "xyce", src, &r2);
    try has(xy, ".op\n.dc v1 0 1 0.1\n");
    try has(xy, ".measure dc vmax max v(a)\n");
    try reported(&r2, .@"error", "simctl: 'let vth = v(a)*2' is a command of ngspice's control language");
    try reported(&r2, .info, "simctl: 'run' is not written");
    try reported(&r2, .@"error", "statement 'csparam' cannot be written for xyce");
    // What SPRack writes for an .alter reads back as a script, not as text.
    var r3: ir.Report = .init(a);
    const ng = try tr(a, "hspice", "ngspice", "t\n.param r=1k\nR1 a 0 r\nV1 a 0 1\n.op\n.alter\n.param r=2k\n.end\n", &r3);
    var r4: ir.Report = .init(a);
    try testing.expectEqual(0, countKind(try readAs(a, "ngspice", ng, &r4), .@"opaque"));
}

test "Schemify: a command of no dialect is the target's own; an inert line names elsewhere" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // What the Python builder makes of `with c.script() as s: s.op();
    // s.simctl("run")`: ngspice's own `run`, kept in its script.
    const json =
        \\{"title":"t","dialect":"sprack","stmts":[{"kind":"resistor","name":"R1","pos":"a","neg":"0","r":"1k"},
        \\{"kind":"script","body":[{"kind":"op"},{"kind":"simctl","cmd":"run"},{"kind":"simctl","cmd":"let","args":"x = 1"}]}]}
    ;
    var r1: ir.Report = .init(a);
    const nl = try sprack.json.parseNetlist(a, json, &r1);
    try has(try writeAs(a, "ngspice", &nl, &r1), ".control\nop\nrun\nlet x = 1\n.endc\n");
    try clean(&r1);
    // Into Xyce, `run` has nothing to say (ngspice's inert line).
    var r2: ir.Report = .init(a);
    _ = try writeAs(a, "xyce", &nl, &r2);
    try reported(&r2, .info, "simctl: 'run' is not written");
}

test "#51: a statement only its dialect has is its words; HSPICE measure forms; VACASK embed" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const hs = "t\nr1 d 0 1k\n.acmatch v(d)\ns1 p1 p2 mname=smod\n.end\n";
    var r: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", hs, &r);
    try testing.expectEqual(2, countKind(nl, .native));
    try testing.expectEqual(0, countKind(nl, .@"opaque"));
    var r1: ir.Report = .init(a);
    try has(try sameBack(a, "hspice", "hspice", hs, &r1), ".acmatch v(d)\ns1 p1 p2 mname=smod\n");
    var r2: ir.Report = .init(a);
    _ = try tr(a, "hspice", "spectre", hs, &r2);
    try reported(&r2, .@"error", "'.acmatch v(d)' is a hspice statement and cannot be written for spectre: HSPICE's .ACMATCH");
    // Spectrum measurements and goal= are typed, not text.
    var r3: ir.Report = .init(a);
    const m = try readAs(a, "hspice", "t\n.meas tran thd1 thd v(out)\n.meas fft s1 snr v(out) binsiz=1\n.meas tran a1 avg v(out) from=0 to=1m goal=0.5\n.end\n", &r3);
    try testing.expect(std.mem.indexOf(u8, try jsonOf(a, &m), "\"spec\"") == null);
    var r4: ir.Report = .init(a);
    try has(try tr(a, "hspice", "xyce", "t\nv1 o 0 sin(0 1 1k)\n.tran 1u 2m\n.fft v(o)\n.meas fft s1 snr v(o)\n.end\n", &r4), ".measure fft s1 snr v(o)\n");
    // An embedded file is a name and a text.
    const v = "t\nembed \"runme.py\" <<<FILE\nprint(1)\n>>>FILE\n";
    var r5: ir.Report = .init(a);
    const vn = try readAs(a, "vacask", v, &r5);
    try testing.expectEqual(1, countKind(vn, .embed));
    var r6: ir.Report = .init(a);
    try has(try sameBack(a, "vacask", "vacask", v, &r6), "embed \"runme.py\" <<<FILE\nprint(1)\n>>>FILE\n");
}

test "#52: a Verilog-A instance into Xyce is a Y line of its module, with a plugin" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\n.model rmod r3_cmc rsh=100\nN1 a b c rmod w=1u l=2u\nv1 a 0 1\n.op\n.end\n";
    // Without a plugin: the card and the instance say how to get one.
    var r: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", src, &r);
    try reported(&r, .@"error", "model 'rmod' is of the Verilog-A module 'r3_cmc': xyce takes it only from a plugin of the module");
    try reported(&r, .@"error", "device: xyce instantiates the Verilog-A module 'r3_cmc' only through a plugin of it");
    // With one: `Y<module> name nodes model params`, read back the same.
    const env: ir.Env = .{ .provided = &.{.{ "r3_cmc", "r3_cmc.so" }} };
    var r1: ir.Report = .init(a);
    var aw: std.Io.Writer.Allocating = .init(a);
    _ = try sprack.stream.translate(a, sprack.find("ngspice").?, sprack.find("xyce").?, src, &aw.writer, &r1, &sprack.caps, .{ .env = &env });
    const xy = aw.written();
    try has(xy, "Yr3_cmc N1 a b c rmod w=1u l=2u\n");
    try reported(&r1, .warning, "the Verilog-A module 'r3_cmc' is the plugin r3_cmc.so: run xyce with -plugin r3_cmc.so");
    try testing.expectEqual(0, r1.count(.@"error"));
    var r2: ir.Report = .init(a);
    const back = try readAs(a, "xyce", xy, &r2);
    try has(try jsonOf(a, &back), "{\"kind\":\"device\",\"line\":3,\"name\":\"N1\",\"nodes\":[\"a\",\"b\",\"c\"],\"master\":\"rmod\"");
    try testing.expect(std.mem.indexOf(u8, try jsonOf(a, &back), "\"module\"") == null);
    // A Y line whose model card is elsewhere keeps its module.
    var r3: ir.Report = .init(a);
    try has(try jsonOf(a, &try readAs(a, "xyce", "t\nYrlc rlc1 1 0 rmod R=1k\n.end\n", &r3)), "\"module\":\"rlc\"");
}

test "#52: a Xyce plugin's Y line has no m, and its card no level" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const env: ir.Env = .{ .provided = &.{.{ "mosvar", "mosvar.so" }} };
    const src = "t\n.model cv mosvar level=1000 type=-1\nN1 g b w cv l=1u m=1\nN2 g b w cv l=1u m=2\nN3 g b w cv l=1u m={k}\n.op\n.end\n";
    var r: ir.Report = .init(a);
    var aw: std.Io.Writer.Allocating = .init(a);
    _ = try sprack.stream.translate(a, sprack.find("ngspice").?, sprack.find("xyce").?, src, &aw.writer, &r, &sprack.caps, .{ .env = &env });
    const xy = aw.written();
    // Xyce 7.10: `level=1000` is "no valid model card" for the plugin.
    try has(xy, ".model cv mosvar type=-1\n");
    try reported(&r, .warning, "model 'cv': level not written: xyce takes a plugin's card only at the plugin's own level");
    // m=1 is the same device; any other m has no form.
    try has(xy, "Ymosvar N1 g b w cv l=1u\n");
    try has(xy, "Ymosvar N2 g b w cv l=1u\n");
    try reported(&r, .@"error", "device: 'm=2' not written: a xyce plugin has no device multiplier ($mfactor), so the module 'mosvar' is simulated as one device");
    try reported(&r, .@"error", "device: 'm=k' not written");
    try testing.expectEqual(2, r.count(.@"error"));
}

test "#53: a family a dialect has only as a module given to the translation" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // ngspice's own `bsimcmg n = bsimcmg devtype=1 provided` line (4.43).
    const g = sprack.find("ngspice").?;
    const src = "t\n.model nmos_lvt nmos level=72 version=107\nm1 d g 0 0 nmos_lvt l=20n nfin=3\n.op\n.end\n";
    var r: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", src, &r);
    // Nothing given: an error that names the option.
    var r1: ir.Report = .init(a);
    var w1: std.Io.Writer.Allocating = .init(a);
    try sprack.writeIn(a, g, &w1.writer, &nl, &r1, null);
    try reported(&r1, .@"error", "has no built-in bsimcmg; it runs one as a compiled module given to the translation: --provide bsimcmg=FILE");
    // Given: the card, the load line once with the file, one caveat.
    const env: ir.Env = .{ .provided = &.{.{ "bsimcmg", "/m/bsimcmg.osdi" }} };
    var r2: ir.Report = .init(a);
    var w2: std.Io.Writer.Allocating = .init(a);
    try sprack.writeIn(a, g, &w2.writer, &nl, &r2, &env);
    try has(w2.written(), ".control\npre_osdi /m/bsimcmg.osdi\n.endc\n");
    try has(w2.written(), ".model nmos_lvt bsimcmg devtype=1");
    try reported(&r2, .warning, "written for the module /m/bsimcmg.osdi given to the translation");
    try testing.expectEqual(0, r2.count(.@"error"));
}

test "#27: a BSIM-CMG card into ngspice is an N device of the module given" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\n.model pmos_rvt pmos level=72 version=107\nm1 d g 0 0 pmos_rvt l=20n nfin=3\n.op\n.end\n";
    var r: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", src, &r);
    const env: ir.Env = .{ .provided = &.{.{ "bsimcmg", "/m/bsimcmg.osdi" }} };
    var r1: ir.Report = .init(a);
    var w1: std.Io.Writer.Allocating = .init(a);
    try sprack.writeIn(a, sprack.find("ngspice").?, &w1.writer, &nl, &r1, &env);
    // ngspice 45 ran this as `nm1` on BSIM-CMG 107.0.0: 98.6313428 uA (4.43).
    try has(w1.written(), ".model pmos_rvt bsimcmg devtype=0\n");
    try has(w1.written(), "nm1 d g 0 0 pmos_rvt l=20n nfin=3\n");
    try testing.expectEqual(0, r1.count(.@"error"));
}

test "#27: a BSIM-CMG card into VACASK loads the module given" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "t\n.model nmos_rvt nmos level=72 version=107\nVd d 0 0.7\nVg g 0 0.7\nm1 d g 0 0 nmos_rvt l=20n nfin=3\n.op\n.end\n";
    var r: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", src, &r);
    const g = sprack.find("vacask").?;
    var r1: ir.Report = .init(a);
    var w1: std.Io.Writer.Allocating = .init(a);
    try sprack.writeIn(a, g, &w1.writer, &nl, &r1, null);
    try reported(&r1, .@"error", "vacask has no built-in bsimcmg; it runs one as a compiled module given to the translation: --provide bsimcmg=FILE");
    const env: ir.Env = .{ .provided = &.{.{ "bsimcmg", "/m/bsimcmg.osdi" }} };
    var r2: ir.Report = .init(a);
    var w2: std.Io.Writer.Allocating = .init(a);
    try sprack.writeIn(a, g, &w2.writer, &nl, &r2, &env);
    // VACASK b2c1551 ran this on BSIM-CMG 107.0.0: 113.550354 uA (4.43).
    try has(w2.written(), "load \"/m/bsimcmg.osdi\"\n");
    try has(w2.written(), "model nmos_rvt bsimcmg (devtype=1)\n");
    try has(w2.written(), "m1 (d g 0 0) nmos_rvt l=20n nfin=3\n");
    try testing.expectEqual(0, r2.count(.@"error"));
}

test "#27: a BSIM-CMG card's version is dropped for the module given, and only 107 was measured" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const env: ir.Env = .{ .provided = &.{.{ "bsimcmg", "/m/bsimcmg.osdi" }} };
    for ([_][]const u8{ "ngspice", "vacask" }) |to| {
        for ([_]struct { []const u8, ir.Severity }{ .{ "107", .warning }, .{ "110", .@"error" } }) |case| {
            const src = try std.fmt.allocPrint(a, "t\n.model n1 nmos level=72 version={s}\nm1 d g 0 0 n1 l=20n nfin=3\n.op\n.end\n", .{case[0]});
            var r: ir.Report = .init(a);
            const nl = try readAs(a, "hspice", src, &r);
            var r1: ir.Report = .init(a);
            var w1: std.Io.Writer.Allocating = .init(a);
            try sprack.writeIn(a, sprack.find(to).?, &w1.writer, &nl, &r1, &env);
            try testing.expect(std.mem.indexOf(u8, w1.written(), "version") == null);
            try reported(&r1, case[1], "version not written: the module given has no version parameter");
        }
    }
}

test "#53: ASAP7 into ngspice and VACASK: 24 errors, or with the module given 0 and one caveat a file" {
    const io = testing.io;
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const pdks = testing.environ.getAlloc(a, "SPRACK_TEST_PDKS") catch return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var tops: [3][]const u8 = undefined;
    for (&tops, [_][]const u8{ "TT", "FF", "SS" }) |*t, c| t.* = try std.fmt.allocPrint(a, "{s}/asap7/models/hspice/7nm_{s}.pm", .{ pdks, c });
    for ([_][]const u8{ "ngspice", "vacask" }) |to| {
        for ([_]bool{ false, true }) |given| {
            var log: std.Io.Writer.Allocating = .init(a);
            const sum = try sprack.project.run(io, testing.allocator, .{
                .from = sprack.find("hspice").?,
                .to = sprack.find(to).?,
                .tops = &tops,
                .out_dir = try std.fmt.allocPrint(a, "{s}/{s}{}", .{ base, to, given }),
                .library = true,
                .provided = if (given) &.{.{ "bsimcmg", "/m/bsimcmg.osdi" }} else &.{},
                .log = &log.writer,
            });
            // The writer kept the caveat's set in a statement's arena: the
            // second file crashed it (sprack project, 3 files, 4.43).
            try testing.expectEqual(@as(usize, if (given) 0 else 24), sum.errors);
            try testing.expectEqual(@as(usize, if (given) 3 else 0), std.mem.count(u8, log.written(), "written for the module /m/bsimcmg.osdi given to the translation"));
        }
    }
}

test "#27: a needs line keeps a long file given whole" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // ngspice 45 lowercased the continuation line of a wrapped pre_osdi and
    // could not open /tmp/.../-home-omare-Documents-.../bsimcmg108.osdi (4.43).
    const file = "/a/Long-Directory-Name/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/bsimcmg.osdi";
    const env: ir.Env = .{ .provided = &.{.{ "bsimcmg", file }} };
    const src = "t\n.model n1 nmos level=72\nm1 d g 0 0 n1 l=20n nfin=3\n.op\n.end\n";
    var r: ir.Report = .init(a);
    const nl = try readAs(a, "hspice", src, &r);
    var w1: std.Io.Writer.Allocating = .init(a);
    try sprack.writeIn(a, sprack.find("ngspice").?, &w1.writer, &nl, &r, &env);
    try has(w1.written(), "\npre_osdi " ++ file ++ "\n");
    var w2: std.Io.Writer.Allocating = .init(a);
    _ = try sprack.stream.translate(a, sprack.find("hspice").?, sprack.find("ngspice").?, src, &w2.writer, &r, &sprack.caps, .{ .env = &env });
    try has(w2.written(), "\npre_osdi " ++ file ++ "\n");
}

test "#74: a requires line with an analysis list checks only those analyses" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;
    // The mini grammar of docs/src/adding-a-simulator.md, and one line.
    const mini = try std.Io.Dir.cwd().readFileAlloc(io, "docs/src/examples/mini.spgrammar", a, .unlimited);
    const src = try std.fmt.allocPrint(a, "{s}\nrequires dc-path error [op dc ac] : mini's operating point fails on a node with no DC path\n", .{mini});
    var diag: sprack.grammar.Diag = .{};
    const g = try sprack.grammar.compile(a, src, "mini.spgrammar", &diag);
    const island = "t\nV1 a 0 dc 1\nC1 a b 1u\nC2 b 0 1u\n";
    for ([_]struct { []const u8, bool }{ .{ ".tran 1n 1u\n", false }, .{ ".op\n", true } }) |case| {
        var r: ir.Report = .init(a);
        const nl = try sprack.read(a, sprack.find("ngspice").?, try std.fmt.allocPrint(a, "{s}{s}.end\n", .{ island, case[0] }), &r);
        var w: std.Io.Writer.Allocating = .init(a);
        try sprack.write(a, &g, &w.writer, &nl, &r);
        try testing.expectEqual(case[1], r.contains(.@"error", "mini's operating point fails on a node with no DC path"));
    }
}

test "#76: HSPICE's floor resistance and Xyce's inductor multiplier are said" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: ir.Report = .init(a);
    try has(try tr(a, "ngspice", "hspice", "t\n.model rm r rsh=1k narrow=1u\nR1 a 0 rm l=11u w=2u\nV1 a 0 1\n.op\n.end\n", &r), ".model rm r rsh=1k dw=1u\n");
    try reported(&r, .warning, "model 'rm': narrow: where W - 2 DW is 0, HSPICE takes a floor resistance");
    // Within one dialect nothing crosses.
    var r1: ir.Report = .init(a);
    _ = try tr(a, "hspice", "hspice", "t\n.model rm r rsh=1k dw=1u\nR1 a 0 rm l=11u w=2u\nV1 a 0 1\n.op\n.end\n", &r1);
    try testing.expect(!r1.contains(.warning, "floor resistance"));
    const xy = "t\nL1 a 0 1m lmod\n.model lmod ind l=3 tc1=0.01\nI1 0 a ac 1\n.ac lin 1 159 159\n.end\n";
    var r2: ir.Report = .init(a);
    try has(try tr(a, "xyce", "ngspice", xy, &r2), ".model lmod l tc1=0.01\n");
    try reported(&r2, .@"error", "Xyce's inductor card L multiplies the line's inductance");
    var r3: ir.Report = .init(a);
    try has(try tr(a, "xyce", "xyce", xy, &r3), ".model lmod l l=3 tc1=0.01\n");
}

test "a netlist says what the files it names declare" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    // What a library declares, as its project's catalogue lists it.
    const lib = try sprack.json.parseNetlist(a,
        \\{"stmts":[{"kind":"model","name":"Rmod","family":"resistor"},{"kind":"func","name":"twice","args":["x"],"body":"2*x"},
        \\ {"kind":"subckt","name":"cell","ports":["a"],"body":[{"kind":"model","name":"nch.1","family":"bsim4"}]}]}
    , &report);
    var env: ir.Env = .{};
    try env.absorb(a, lib.stmts);
    var listed: std.Io.Writer.Allocating = .init(a);
    try sprack.json.writeEnv(&listed.writer, &env);

    // A netlist of its own that uses them, written for HSPICE with and without.
    for ([_][]const u8{ "", listed.written() }) |e| {
        const text = try std.fmt.allocPrint(a,
            \\{{"stmts":[{{"kind":"resistor","name":"R1","pos":"a","neg":0,"master":"rmod","params":{{"w":"1u"}}}},
            \\ {{"kind":"resistor","name":"R2","pos":"a","neg":0,"master":"nowhere","params":{{"w":"1u"}}}},
            \\ {{"kind":"vsource","name":"V1","pos":"a","neg":0,"dc":{{"expr":"twice(1)"}}}}]{s}{s}}}
        , .{ if (e.len > 0) ",\"env\":" else "", e });
        var r: ir.Report = .init(a);
        const nl = try sprack.json.parseNetlist(a, text, &r);
        if (nl.env) |back| {
            // Nothing is lost on the way.
            var again: std.Io.Writer.Allocating = .init(a);
            try sprack.json.writeEnv(&again.writer, back);
            try testing.expectEqualStrings(listed.written(), again.written());
        }
        var aw: std.Io.Writer.Allocating = .init(a);
        try sprack.write(a, sprack.find("hspice").?, &aw.writer, &nl, &r);
        try testing.expect(r.contains(.warning, "'nowhere' on R2 is a model name in sprack, but no model of that name is declared here"));
        try testing.expectEqual(e.len == 0, r.contains(.warning, "'rmod' on R1"));
        try testing.expectEqual(e.len == 0, r.contains(.@"error", "function 'twice' has no spelling in hspice"));
    }
}

test "every field of Env is in its JSON form, and back (#71)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const lib = try sprack.json.parseNetlist(a,
        \\{"stmts":[{"kind":"param","params":{"vt":"0.4"}},{"kind":"model","name":"nch","family":"bsim4","params":{"vth0":{"expr":"vt"}}},
        \\ {"kind":"model","name":"rpoly","type":"r3_cmc"}]}
    , &report);
    var env: ir.Env = .{};
    try env.absorb(a, lib.stmts);
    for (sprack.grammars) |*g| try sprack.writer.collectReserved(a, g, lib.stmts, &env.params, null);
    try testing.expect(env.params.contains("vt"));
    try testing.expectEqualStrings("bsim4", env.family_of.get("nch").?);
    try testing.expectEqualStrings("r3_cmc", env.modules.get("rpoly").?);
    var listed: std.Io.Writer.Allocating = .init(a);
    try sprack.json.writeEnv(&listed.writer, &env);
    // `provided` is what the command line gives, not what a file declares.
    inline for (@typeInfo(ir.Env).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "provided")) continue;
        if (std.mem.indexOf(u8, listed.written(), "\"" ++ name ++ "\":") == null) {
            std.debug.print("Env.{s} is not in its JSON form\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
    var r: ir.Report = .init(a);
    const nl = try sprack.json.parseNetlist(a, try std.fmt.allocPrint(a, "{{\"stmts\":[],\"env\":{s}}}", .{listed.written()}), &r);
    var again: std.Io.Writer.Allocating = .init(a);
    try sprack.json.writeEnv(&again.writer, nl.env.?);
    try testing.expectEqualStrings(listed.written(), again.written());
}

// The engine names no device and no dialect for this: what a dialect's device
// does not take and its other statements can say is a `rewrite` block of its
// grammar. VACASK's capacitor (ic=, q=) is two such blocks; here a grammar
// made up for the test does the same for a resistor.
test "rewrite: a parameter a dialect's device lacks is said by other statements, from grammar lines alone" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tiny = tinyGrammar(
        \\dialect tiny
        \\lexer
        \\  title yes
        \\  scale k=3 u=-6
        \\end
        \\rule resistor = name~"R" pos neg r {...params}
        \\rule isource  = name~"I" pos neg dc
        \\rule bsource  = name~"B" pos neg { i=i }
        \\functions
        \\  same v
        \\end
        \\params resistor
        \\  same m
        \\end
        \\rewrite resistor gleak
        \\  when   bsource
        \\  become bsource name={name} pos={pos} neg={neg} i=[{m}*]{gleak}*v({pos},{neg})
        \\  loss   : resistor '{name}': {what} has no place on the source it is written as for {to}
        \\  oneway : resistor '{name}': a leak alone is the current {i}
        \\end
        \\rewrite resistor leak
        \\  when   isource
        \\  keep
        \\  add    isource name=I{name}__leak pos={pos} neg={neg} dc={leak}
        \\  oneway : resistor '{name}': {to} has no leak= ({leak}); the source I{name}__leak carries it
        \\end
    );
    var report: ir.Report = .init(a);
    const nl = try readAs(a, "ngspice", "t\nR1 a 0 1k leak=1u m=2\nR2 b 0 gleak={g0*2} m=3\n.end\n", &report);
    var out: std.Io.Writer.Allocating = .init(a);
    try sprack.write(a, &tiny, &out.writer, &nl, &report);
    // The statement stays, without the parameter, and another is added.
    try has(out.written(), "R1 a 0 1k m=2\nIR1__leak a 0 1u\n");
    try reported(&report, .info, "resistor 'R1': tiny has no leak= (1u); the source IR1__leak carries it");
    // Another statement in its place: an expression among operands is
    // parenthesised, a parameter the template names is used up, and what
    // has no place is a loss in the grammar's words. (The source is a B
    // device here, so its name gets the letter, as any renamed device.)
    try has(out.written(), "BR2 b 0 i=3*(g0*2)*v(b,0)\n");
    try reported(&report, .info, "resistor 'R2': a leak alone is the current 3*(g0*2)*v(b,0)");
    try testing.expectEqual(0, report.count(.@"error"));

    // The same netlist for a dialect whose grammar has no such block: the
    // parameter is the loss it always was.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", "t\nR1 a 0 1k leak=1u\n.end\n", &r2);
    try reported(&r2, .@"error", "'leak=1u' has no spelling in xyce");
}

/// One file of tests/fixtures: a netlist, the dialects it goes between, and
/// the output and the report that must come out, byte for byte.
const Fixture = struct {
    from: []const u8 = "",
    to: []const u8 = "",
    input: []const u8 = "",
    output: []const u8 = "",
    report: []const u8 = "",

    /// The parts of a fixture file (`tools/fixture.py` writes them): `from:`
    /// and `to:` lines, then the three sections, each after its `--- name` line.
    fn parse(text: []const u8) !Fixture {
        var fixture: Fixture = .{};
        const input_at = std.mem.indexOf(u8, text, "--- input\n") orelse return error.FixtureWithoutInput;
        var head = std.mem.tokenizeScalar(u8, text[0..input_at], '\n');
        while (head.next()) |line| {
            if (std.mem.startsWith(u8, line, "from:")) fixture.from = std.mem.trim(u8, line[5..], " ");
            if (std.mem.startsWith(u8, line, "to:")) fixture.to = std.mem.trim(u8, line[3..], " ");
        }
        const rest = text[input_at + "--- input\n".len ..];
        const output_at = std.mem.indexOf(u8, rest, "--- output\n") orelse return error.FixtureWithoutOutput;
        const after = rest[output_at + "--- output\n".len ..];
        const report_at = std.mem.indexOf(u8, after, "--- report\n") orelse return error.FixtureWithoutReport;
        fixture.input = rest[0..output_at];
        fixture.output = after[0..report_at];
        fixture.report = after[report_at + "--- report\n".len ..];
        if (sprack.find(fixture.from) == null or sprack.find(fixture.to) == null) return error.FixtureOfUnknownDialect;
        return fixture;
    }
};

// A fix for a reported netlist adds a file here (docs/src/testing.md): the
// netlist, and what it must be written as. `python3 -I tools/fixture.py new`
// makes one from the binary's present answer.
test "fixtures: every case of tests/fixtures gives the output and the report it holds" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/fixtures", .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".case")) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    try testing.expect(names.items.len > 0);
    var failed: usize = 0;
    for (names.items) |name| {
        const fixture = try Fixture.parse(try dir.readFileAlloc(io, name, a, .limited(1 << 20)));
        var report: ir.Report = .init(a);
        const out = try sprack.translateAlloc(a, fixture.from, fixture.to, fixture.input, &report);
        var said: std.Io.Writer.Allocating = .init(a);
        try report.print(&said.writer);
        if (!std.mem.eql(u8, fixture.output, out) or !std.mem.eql(u8, fixture.report, said.written())) {
            failed += 1;
            std.debug.print("\n--- tests/fixtures/{s}: expected\n{s}{s}--- got\n{s}{s}", .{
                name, fixture.output, fixture.report, out, said.written(),
            });
            continue;
        }
        // What holds for any translation holds for these too.
        _ = try anyInput(a, fixture.from, fixture.to, fixture.input, out);
    }
    try testing.expectEqual(0, failed);
}

test "plugin: what a dialect tells and leaves out for a compiled module is its grammar's, in any dialect" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A dialect made up here: another tool, another flag, two parameters
    // of its own. Nothing of it is known to the writer.
    const tiny = tinyGrammar(
        \\dialect tiny
        \\lexer
        \\  title yes
        \\  scale k=3 u=-6
        \\end
        \\rule model  = ".model" name type {...params}
        \\rule device = module~"Z" name nodes+ master {...params}
        \\plugin
        \\  missing : compile it with zcc and pass --provide {module}=FILE
        \\  given : load {file} into {to} with -z
        \\  card version warning : a {to} module has one version
        \\  instance area=1 error : the module '{module}' has no area in {to}
        \\  instance trise=0 warning : {to} modules run at the circuit's temperature
        \\end
    );
    const src = "t\n.model cv mosvar version=2 type=-1\nN1 g b cv l=1u area=1\n" ++
        "N2 g b cv area=3 trise=5\n.end\n";
    var none: ir.Report = .init(a);
    const nl = try readAs(a, "ngspice", src, &none);
    var out: std.Io.Writer.Allocating = .init(a);
    try sprack.write(a, &tiny, &out.writer, &nl, &none);
    try reported(&none, .@"error", "model 'cv' is of the Verilog-A module 'mosvar': tiny takes it only from a plugin of the module; compile it with zcc and pass --provide mosvar=FILE");
    try reported(&none, .@"error", "device: tiny instantiates the Verilog-A module 'mosvar' only through a plugin of it: compile it with zcc and pass --provide mosvar=FILE");

    const env: ir.Env = .{ .provided = &.{.{ "mosvar", "mosvar.z" }} };
    var report: ir.Report = .init(a);
    var given: std.Io.Writer.Allocating = .init(a);
    try sprack.writeIn(a, &tiny, &given.writer, &nl, &report, &env);
    try reported(&report, .warning, "device: the Verilog-A module 'mosvar' is the plugin mosvar.z: load mosvar.z into tiny with -z");
    // The card's parameter goes whatever its value; an instance's at the
    // plugin's own value goes in silence, at another with its line's text.
    try has(given.written(), ".model cv mosvar type=-1\n");
    try reported(&report, .warning, "model 'cv': version not written: a tiny module has one version");
    try has(given.written(), "Zmosvar N1 g b cv l=1u\n");
    try has(given.written(), "Zmosvar N2 g b cv\n");
    try reported(&report, .@"error", "device: 'area=3' not written: the module 'mosvar' has no area in tiny");
    try reported(&report, .warning, "device: 'trise=5' not written: tiny modules run at the circuit's temperature");
    try testing.expectEqual(1, report.count(.@"error"));
}

test "plugin: a device rule that names the module and a plugin block go together" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const head = "dialect tiny\nlexer\n  title yes\nend\n";
    const rule = "rule device = module~\"Z\" name nodes+ master {...params}\n";
    const block = "plugin\n  missing : build it\n  given : load {file}\nend\n";
    for ([_][]const u8{
        head ++ rule,
        head ++ block,
        head ++ rule ++ "plugin\n  missing : build it\nend\n",
        head ++ rule ++ "plugin\n  missing : build it\n  given : load it\n  card level=1 warning : x\nend\n",
        head ++ rule ++ "plugin\n  missing : build it\n  given : load it\n  instance m=one error : x\nend\n",
        head ++ rule ++ "plugin\n  missing : build it\n  given : load it\n  instance m=1 fatal : x\nend\n",
        head ++ rule ++ block ++ block,
    }) |src| {
        var diag: sprack.grammar.Diag = .{};
        try testing.expectError(error.BadGrammar, sprack.grammar.compile(a, src, "f.spgrammar", &diag));
    }
    var diag: sprack.grammar.Diag = .{};
    _ = try sprack.grammar.compile(a, head ++ rule ++ block, "f.spgrammar", &diag);
}

test "cktimg: the circuit only, devices and names as they are" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const out = try tr(a, "ngspice", "cktimg",
        \\amp
        \\.subckt inv in out vdd
        \\M1 out in vdd vdd pmos w=1u
        \\M2 out in 0 0 nmos w=1u
        \\.ends
        \\.model pmos pmos level=1
        \\.model nmos nmos level=1
        \\X1 vin vout vdd inv
        \\V1 vdd 0 1.8
        \\.tran 1n 1u
        \\.meas tran t1 max v(vout)
        \\.control
        \\run
        \\.endc
        \\.options reltol=1e-4
        \\.end
        \\
    , &report);
    try has(out, "M1 out in vdd vdd pmos w=1u\nM2 out in 0 0 nmos w=1u\n");
    try has(out, "X1 vin vout vdd inv\n");
    for ([_][]const u8{ ".tran", ".meas", ".control", ".options" }) |gone|
        try testing.expect(std.mem.indexOf(u8, out, gone) == null);
    // Left out as changing nothing in a drawing: notes, once a kind, no error.
    try reported(&report, .info, "tran: not written: cktimg draws the circuit");
    try reported(&report, .info, "script: not written: cktimg draws the circuit");
    try testing.expectEqual(0, report.count(.@"error"));
    // What cktImg refuses is refused here, so it never gets there.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "cktimg", "t\n.include \"models.lib\"\nE1 a 0 poly(1) b 0 0 1\n.end\n", &r2);
    try reported(&r2, .@"error", "cktImg reads one file");
    try reported(&r2, .@"error", "expand the polynomial first");
}

test "annotation: a line for a tool is written whole, with each dialect's mark, in its scope" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var top = try ir.newStmt(a, .annotation, 2);
    try top.set(a, schema.slot(.annotation, "text"), .{ .atom = "order m1 m2" });
    var inner = try ir.newStmt(a, .annotation, 4);
    try inner.set(a, schema.slot(.annotation, "text"), .{ .atom = "left a" });
    var sub = try ir.newStmt(a, .subckt, 3);
    try sub.set(a, schema.slot(.subckt, "name"), .{ .atom = "inv" });
    try sub.set(a, schema.slot(.subckt, "ports"), .{ .list = try a.dupe(ir.Value, &.{ .{ .atom = "a" }, .{ .atom = "y" } }) });
    sub.body = try a.dupe(ir.Stmt, &.{inner});
    const stmts = try a.dupe(ir.Stmt, &.{ top, sub });
    const nl: ir.Netlist = .{ .title = "t", .dialect = "sprack", .stmts = stmts };
    var report: ir.Report = .init(a);
    const ng = try writeAs(a, "ngspice", &nl, &report);
    try has(ng, "*@ order m1 m2\n.subckt inv a y\n*@ left a\n.ends inv\n");
    const sp = try writeAs(a, "spectre", &nl, &report);
    try has(sp, "// *@ order m1 m2\nsubckt inv (a y)\n// *@ left a\nends inv\n");
    try testing.expectEqual(0, report.items.items.len);
    // The JSON form holds it as it is.
    const json = try jsonOf(a, &nl);
    try has(json, "{\"kind\":\"annotation\",\"line\":2,\"text\":\"order m1 m2\"}");
}

test "annotation: read back in its scope, and named as the target names its devices" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\amp
        \\*@ order m1 m2
        \\.subckt inv a y vdd
        \\*@ left a
        \\*@ face m1.g left
        \\M1 y a vdd vdd pmos w=1u
        \\.ends
        \\X1 in out vdd inv
        \\.end
        \\
    ;
    var report: ir.Report = .init(a);
    const nl = try readAs(a, "ngspice", src, &report);
    try testing.expectEqual(.annotation, nl.stmts[0].kind);
    try testing.expectEqual(.annotation, nl.stmts[1].body[0].kind);
    // Through Spectre and back: every line where it was, as it was.
    const sp = try tr(a, "ngspice", "spectre", src, &report);
    try has(sp, "// *@ order m1 m2\nsubckt inv (a y vdd)\n// *@ left a\n// *@ face m1.g left\n");
    // Spectre reads M1 with no model card as an instance, which ngspice
    // names with an X: the line that names it in its scope does too, the
    // one at the top level, where no M1 is, does not, and `left` is a word.
    var r2: ir.Report = .init(a);
    const back = try tr(a, "spectre", "ngspice", sp, &r2);
    try has(back, "*@ order m1 m2\n.subckt inv a y vdd\n*@ left a\n*@ face XM1.g left\nXM1 y a vdd vdd pmos w=1u\n");
}

test "a unit after a value is ignored, in any script: 15kΩ is 15k" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    // ngspice 45 solves R1 a b 15kΩ as 15k: v(b) = 2.439024e-02 with 375Ω
    // to ground, as with 15k and 375.
    const out = try tr(a, "ngspice", "spectre", "t\nV1 a 0 1\nR1 a b 15kΩ\nR2 b 0 375Ω\n.op\n.end\n", &report);
    try has(out, "R1 (a b) resistor r=15k\n");
    try has(out, "R2 (b 0) resistor r=375\n");
    try testing.expectEqual(0, report.count(.@"error"));
}

test "parentheses that do not pair are text, not a crash" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A `)` with nothing open: once a counter that went below zero (an
    // integer overflow in ReleaseSafe).
    var r1: ir.Report = .init(a);
    _ = try tr0(a, "ngspice", "xyce", "t\n.param a=1 b=2\n.if (a)) (b)\nr1 1 0 1k\n.endif\n.end\n", &r1);
    var r2: ir.Report = .init(a);
    _ = try tr0(a, "spectre", "ngspice", "simulator lang=spectre\nparameters x=(a[))]b)\nr1 (1 0) resistor r=x\n", &r2);
    // Two groups side by side are not one: `(a) (b)` keeps its parentheses.
    try testing.expectEqualStrings("(a) (b)", sprack.lexer.unwrapWhole("(a) (b)"));
    try testing.expectEqualStrings("a) (b", sprack.lexer.unwrapWhole("((a) (b))")[1..6]);
    try testing.expectEqualStrings("a+b", sprack.lexer.unwrapWhole("(a+b)"));
}

test "annotation: a device keeps its name in a hint where the target keeps it" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // ngspice writes a PSP103 MOSFET as an N device; a BSIM4 one stays M1,
    // and so does the hint that names it.
    var report: ir.Report = .init(a);
    const out = try tr(a, "spectre", "ngspice",
        \\simulator lang=spectre
        \\model nch bsim4 type=n
        \\// *@ order m1 m2
        \\M1 (d g 0 0) nch w=1u l=180n
        \\
    , &report);
    try has(out, "*@ order m1 m2\nM1 d g 0 0 nch");
}
