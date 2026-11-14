//! End-to-end tests for the shipped grammars.

const std = @import("std");
const sprack = @import("root.zig");
const testing = std.testing;
const ir = sprack.ir;
const schema = sprack.schema;

const dialects = [_][]const u8{ "ngspice", "hspice", "spectre", "vacask", "xyce", "espice", "ltspice", "cdl" };

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

// ESPice reads ngspice's dialect: core_ngspice is an ESPice deck as written.

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
    \\X1 in out 0 / rcdiv r1=1MEG r2='rload*2'
    \\Cl out 0 cval
    \\Ll out 0 10n
    \\.END
;

fn sample(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "ngspice") or std.mem.eql(u8, name, "espice")) return core_ngspice;
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
        if (schema.info(s.kind).class == .analysis) try c.set(arena, schema.slotIndex(s.kind, "name").?, .none);
        if (s.kind == .noise) {
            const ri = schema.slotIndex(.noise, "ref").?;
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

fn tr(a: std.mem.Allocator, from: []const u8, to: []const u8, src: []const u8, report: *ir.Report) ![]const u8 {
    return sprack.translateAlloc(a, from, to, src, report);
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
    try testing.expectEqual(dialects.len, sprack.dialect_count);
    for (dialects) |n| try testing.expect(sprack.find(n) != null);
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
    return .{ .title = nl.title, .dialect = nl.dialect, .stmts = out.items };
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
            // A netlist-only target has no form for the sources and
            // analyses: one `unsupported` error each, and the rest intact.
            const gt = sprack.find(to).?;
            const dropped = droppedIn(read_nl, gt);
            try testing.expectEqual(dropped, report.count(.@"error"));
            try testing.expectEqual(dropped, report.countCode(.unsupported));
            const src_nl = try writableIn(a, read_nl, gt);

            var report2: ir.Report = .init(a);
            const back = try readAs(a, to, text, &report2);
            try testing.expectEqual(0, countKind(back, .@"opaque"));
            try testing.expect(ir.sameCircuit(&src_nl, &back));
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
    try reported(&report, .@"error", "analysis 'pz' cannot be written for xyce: Xyce has no pole-zero analysis. Dialects that define it: espice, hspice, ngspice, spectre");
    // The rest of the netlist is still produced.
    try has(out, "R1 in out 1k\n");
    try has(out, "* [sprack] not written: analysis 'pz'");

    // Where the grammar simply has no rule, it says that instead.
    // No shipped grammar has such a gap any more; a tiny one does.
    const tiny = comptime sprack.grammar.compileBuiltin(
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
    try has(va, "analysis tran1 tran step=1n stop=100n maxstep=0.5n icmode=\"uic\"\n");
    try reported(&r1, .@"error", "tran.start = 5n has no spelling in vacask");

    // HSPICE has START= but no step ceiling on .TRAN.
    var r2: ir.Report = .init(a);
    const hs = try tr(a, "ngspice", "hspice", "t\n.tran 1n 100n 5n 0.5n uic\n.end\n", &r2);
    try has(hs, ".tran 1n 100n start=5n uic\n");
    try reported(&r2, .@"error", "tran.maxstep = 0.5n has no spelling in hspice");

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
    try has(sp, "// plot v(a) $ nutmeg\n");
    try testing.expectEqual(2, report.countCode(.untranslated));
    try testing.expectEqual(2, report.count(.@"error"));

    // Same dialect: untouched, case and all.
    var r2: ir.Report = .init(a);
    const ng = try tr(a, "ngspice", "ngspice", src, &r2);
    try has(ng, ".alter second run\n.control\nrun\nplot v(a) $ nutmeg\n.endc\n");
    try testing.expectEqual(0, r2.items.items.len);
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
        \\simulator lang=spectre
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
    try has(sp, "dc1 dc dev=Vsup param=dc start=0 stop=1.8 step=0.1\n");
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
    try reported(&report, .warning, "model 'nch' (bsim4): ngspice and xyce ship different implementations and versions");

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
    try has(va, "model nch sp_bsim4v8 (type=1 version=4.5 vth0=0.4)\n");
    try has(va, "M1 (out in 0 0) nch w=1u l=0.18u\n");
    // It ships no HiSIM2: say so, and say who has.
    _ = try tr(a, "ngspice", "vacask", "t\n.model nh nmos level=68\n.end\n", &r4);
    try reported(&r4, .@"error", "vacask.spgrammar has no spelling for model family 'hisim2 n'. Defined by: espice, hspice, ngspice, spectre");

    // FinFET models: HSPICE level 72 is Xyce level 111, and ngspice has neither.
    var r5: ir.Report = .init(a);
    const fin = "t\n.model nfet nmos level=72 version=107\nM1 d g 0 0 nfet nfin=2\n.end\n";
    try has(try tr(a, "hspice", "xyce", fin, &r5), ".model nfet nmos level=111 version=107\n");
    try has(try tr(a, "hspice", "spectre", fin, &r5), "model nfet bsimcmg type=n version=107\n");
    try clean(&r5);
    _ = try tr(a, "hspice", "ngspice", fin, &r5);
    try reported(&r5, .@"error", "no spelling for model family 'bsimcmg n'. Defined by: espice, hspice, spectre, xyce");
}

test "an unknown level is an error across dialects, not a guess" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const out = try tr(a, "ngspice", "xyce", "t\n.model nx nmos level=99 foo=1\n.end\n", &report);
    try reported(&report, .warning, "model type 'nmos' with these parameters is not in the ngspice models table");
    try reported(&report, .@"error", "type 'nmos' with these parameters is not in the ngspice models table");
    try has(out, ".model nx nmos level=99 foo=1\n");
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
    try has(try tr(a, "ngspice", "hspice", "t\nV1 a 0 SFFM(0 1 20k 5 1k)\n.end\n", &r2), "V1 a 0 sffm(0 1 20k 5 1k)\n");
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

test "Schemify decks: paths, scopes, control blocks, XSPICE and Verilog survive the JSON trip" {
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
    _ = try viaJson(a, "ngspice", "espice", ng, &r2);
    try reported(&r2, .@"error", "ESPice has no XSPICE code models");

    // ESPice loads a digital design with .verilog.
    const es = "t\n.verilog \"cnt.v\"\nNU1 clk q cnt vdd=1.8\n.model cnt cnt\n.end\n";
    var r3: ir.Report = .init(a);
    try testing.expectEqualStrings(es, try viaJson(a, "espice", "espice", es, &r3));
    try clean(&r3);
    var r4: ir.Report = .init(a);
    _ = try viaJson(a, "espice", "ngspice", es, &r4);
    try reported(&r4, .@"error", "ngspice runs digital Verilog through an XSPICE d_cosim model");

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
    try has(xy, ".options timeint reltol=1e-4 abstol=1p method=gear\n.options device gmin=1p temp=85 tnom=25\n.options parser scale=1u\n");
    // Xyce has one absolute tolerance, not a separate voltage tolerance.
    try reported(&r2, .@"error", "options.vntol = 1u has no spelling in xyce");
    try testing.expectEqual(1, r2.count(.@"error"));

    var r3: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", src, &r3);
    try has(va, "control\noptions reltol=1e-4 abstol=1p vntol=1u gmin=1p temp=85 tnom=25 scale=1u tran_method=\"gear2\"\n");
    try clean(&r3);

    var r4: ir.Report = .init(a);
    const hs = try tr(a, "ngspice", "hspice", src, &r4);
    try has(hs, ".option reltol=1e-4 abstol=1p vntol=1u gmin=1p tnom=25 scale=1u method=gear\n.temp 85\n");
    try clean(&r4);

    // An option only its own simulator knows is never copied across.
    var r5: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "spectre", "t\n.options klu noacct\n.end\n", &r5);
    try reported(&r5, .@"error", "options: 'klu' has no spelling in spectre");
    try reported(&r5, .@"error", "options: 'noacct' has no spelling in spectre");
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
    try has(sp, "parameters a=2 b=(a**2 + log(a)*temp)\n");
    const xy = try tr(a, "ngspice", "xyce", src, &r1);
    try has(xy, ".param a=2 b={a**2 + ln(a)*temp}\n.func dbl(x) {2*x}\nR1 n 0 {dbl(b) * 1k}\n");
    const hs = try tr(a, "ngspice", "hspice", src, &r1);
    try has(hs, ".param a=2 b='a**2 + log(a)*temper'\n.param dbl(x) = '2*x'\nR1 n 0 'dbl(b) * 1k'\n");

    // Spectre's `^` has no ngspice spelling; a statistical function has no Spectre one.
    var r2: ir.Report = .init(a);
    _ = try tr(a, "spectre", "ngspice", "// t\nparameters m=(3 ^ 5)\n", &r2);
    try reported(&r2, .@"error", "operator 'xor' has no spelling in ngspice. Dialects that have it: ltspice, spectre");
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "spectre", "t\n.param vth={agauss(0.4, 0.01, 3)}\n.end\n", &r3);
    try reported(&r3, .@"error", "function 'agauss' has no spelling in spectre. Dialects that have it: espice, hspice, ngspice, vacask, xyce");
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
    try has(xy, ".measure tran trise trig v(out) val=0.2 rise=1 targ v(out) val=0.8 rise=1\n");
    try has(xy, ".four 1k v(out)\n");
    try reported(&r1, .@"error", "statement 'save' cannot be written for xyce: Xyce records only what .PRINT lists");
    try testing.expectEqual(1, r1.count(.@"error"));

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
    // References are checked: a sweep over something that is not a device.
    var r4: ir.Report = .init(a);
    _ = try tr(a, "hspice", "spectre", "t\n.param rv=1k\nR1 a 0 rv\n.dc rv 1k 10k 1k\n.end\n", &r4);
    try reported(&r4, .@"error", "dc.src = rv does not name a device in this netlist");
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
    try has(ng, ".control\npre_osdi mydiode.va\n.endc\n");
    try has(ng, ".model dmod mydiode is=1e-14\n");
    // An instance of a model that is not a built-in family is an N device.
    try has(ng, "nd1 a 0 dmod area=2\n");
    try reported(&r1, .warning, "hdl.path: ngspice loads compiled OSDI files with pre_osdi");
    try reported(&r1, .warning, "model 'dmod' is of the Verilog-A module 'mydiode': ngspice must load the same module");

    var r2: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", ng, &r2);
    try has(va, "load \"mydiode.va\"\n");
    try has(va, "nd1 (a 0) dmod area=2\n");
    var r3: ir.Report = .init(a);
    _ = try tr(a, "ngspice", "xyce", ng, &r3);
    try reported(&r3, .@"error", "statement 'hdl' cannot be written for xyce: Xyce loads Verilog-A models as compiled plugins");
    try reported(&r3, .@"error", "device 'device' cannot be written for xyce");
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
    try has(xy, "* [sprack] untranslated vacask: postprocess(PYTHON, \"runme.py\")\n");
    // A VACASK pulse without fall or width is not the SPICE pulse of the same words.
    try testing.expectEqual(3, report.count(.@"error"));
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
    var buf: [400]u8 = undefined;
    const n = smith.slice(&buf);
    for (dialects) |from| {
        var report: ir.Report = .init(a);
        const nl = try readAs(a, from, buf[0..n], &report);
        for (dialects) |to| _ = try writeAs(a, to, &nl, &report);
    }
}

test "fuzz: any bytes in, no crash" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = &.{ core_ngspice, core_spectre, core_vacask, "\x00+\\\n+ ( = = )\n{'\"[", ".ic v(a)=1 v(\n.print tran v(a,b) i(\n.func f(x,\n.options a b=\n" } });
}

test "20,000 randomly damaged netlists, no crash" {
    var arena_state: Arena = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(0x5eed);
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
        _ = try writeAs(a, dialects[rnd.uintLessThan(usize, dialects.len)], &nl, &report);
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
    try has(sp, "sweep1 sweep dev=VGS param=dc start=1 stop=3 step=0.5 {\ndc1 dc dev=VDS param=dc start=0 stop=5 step=0.1\n}\n");

    var r2: ir.Report = .init(a);
    const va = try tr(a, "ngspice", "vacask", "t\nV1 d 0 1\nV2 g 0 1\n.dc V1 0 5 0.1 V2 1 3 0.5\n.end\n", &r2);
    try has(va,
        \\sweep outer1 instance="V2" parameter="dc" from=1 to=3 step=0.5
        \\sweep sweep1 instance="V1" parameter="dc" from=0 to=5 step=0.1
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
    const nl = try readAs(a, "ngspice", "t\nR1 a 0 '10 % 3'\n.end\n", &r4);
    const sp = try writeAs(a, "spectre", &nl, &r4);
    try has(sp, "R1 (a 0) resistor r=(10 % 3)\n");
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
    const g = sprack.grammar.compileBuiltin(
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
    const g = sprack.grammar.compileBuiltin(
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
        // Measured: 11.55x to Spectre, 11.74x to Xyce, with Stmt.dialect a
        // u8 index (13.6x when it was a 16-byte slice). This counts whole
        // arena chunks, untouched pages too; the peak RSS of a 111 MiB mesh
        // is 7.1x. The tokens of the whole file alone would add 5x.
        if (count.peak * 10 > 118 * input.len) {
            std.debug.print("to {s}: peak {d} bytes for {d} of input\n", .{ to, count.peak, input.len });
            return error.TooMuchMemory;
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
    try has(xy, ".param x=2 y={ln(x) + x**3}\n");
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
    try reported(&r1, .@"error", "tf.src = V1 has no spelling in vacask");
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
    try has(va, "Vd (d 0) vsource type=\"fm\" sinedc=0 ampl=1 freq=2M modindex=3 modfreq=200k\n");
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
    try has(out, "analysis tran1 tran step=1u stop=1m icmode=\"uic\" ic={\"out\",0.2} nodeset={\"out\",0.1}\n");
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

// Each written form below was loaded in Spectre 25.10 or HSPICE Y-2026.03.

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
    try reported(&r1, .@"error", "'nmf' is a built-in ngspice model type that the ngspice models table does not list");
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
