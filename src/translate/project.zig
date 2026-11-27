//! A netlist is rarely one file. A PDK is hundreds: a library file whose
//! sections include model files that include more.
//!
//! `run` follows every `.include` and `.lib` from the files it is given,
//! reads the whole set twice — once to learn what each file declares, once
//! with that knowledge — and then either writes a translated copy of the
//! tree, or lists the devices the tree defines, or both. Knowing the
//! declarations of the other files is what lets a Spectre instance line be
//! recognised as a MOSFET when its model lives three includes away.
//!
//! The copy keeps the layout and file names of the original, so the include
//! lines inside it stay valid; they are rewritten as paths relative to the
//! including file.
//!
//! The run is in the files beside this one: `run.zig` (what a run is asked,
//! gives and shares between its passes), `paths.zig`, `errata.zig` (a PDK's
//! errata, and reading a file through them), `ahead.zig` (files worked on
//! at once), `discover.zig` (pass one), `copy.zig` (pass two), `includes.zig`
//! (include lines of the copy) and `catalog.zig`.
//!
//! Contents:
//! - `pub const Summary`, `pub const Options` (`run.zig`)
//! - `pub const Erratum`, `pub const parseErrata` (`errata.zig`)
//! - `pub const normalize`, `pub const resolve`, `pub const relative` (`paths.zig`)
//! - `pub fn run(io: std.Io, gpa: Allocator,
//!   opts: Options) (Allocator.Error || Writer.Error)!Summary`

const std = @import("std");
const grammar = @import("grammar");
const dialects = @import("dialects");
const paths = @import("paths.zig");
const errata_ = @import("errata.zig");
const run_ = @import("run.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Writer = std.Io.Writer;
const Run = run_.Run;

pub const Summary = run_.Summary;
pub const Options = run_.Options;
pub const Erratum = errata_.Erratum;
pub const parseErrata = errata_.parseErrata;
pub const normalize = paths.normalize;
pub const resolve = paths.resolve;
pub const relative = paths.relative;

pub fn run(io: std.Io, gpa: Allocator, opts: Options) (Allocator.Error || Writer.Error)!Summary {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var r: Run = .{ .gpa = gpa, .arena = arena_state.allocator(), .io = io, .opts = opts };
    // Absolute paths throughout, so files reached by different routes are
    // recognised as the same file.
    var buf: [4096]u8 = undefined;
    if (std.Io.Dir.cwd().realPath(io, &buf)) |n| {
        r.cwd = try resolve(r.arena, ".", buf[0..n]);
    } else |_| {}
    // A deck's `.lib file tt` reaches `tt` alone, as the simulator does;
    // a library given itself is followed whole unless sections are named.
    r.wanted = .empty;
    r.top_sections = opts.sections.len == 0;
    for (opts.sections) |sec| try r.wanted.?.put(r.arena, sec, {});
    r.env.provided = opts.provided;
    r.errata_seen = try r.arena.alloc(bool, opts.errata.len);
    r.errata_found = try r.arena.alloc(bool, opts.errata.len);
    @memset(r.errata_seen, false);
    @memset(r.errata_found, false);
    for (opts.tops) |t| try r.enqueue(try resolve(r.arena, r.cwd, t));
    try r.discover();
    try r.process();
    try r.staleErrata();
    if (opts.expanded) |w| try r.writeExpanded(w);
    // A file is read in the second pass or missing in the first, not both.
    assert(r.sum.files + r.sum.missing <= r.files.items.len);
    return r.sum;
}

test "errata: a line the PDK's own simulator refuses is read as the manifest says, once" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "in/cells");
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "in/lib.spice", .data = "* lib\n.include \"cells/r.spice\"\n" },
    );
    try tmp.dir.writeFile(
        io,
        .{
            .sub_path = "in/cells/r.spice",
            .data = "* cell\n.subckt rr a b\nres a b rm r = 1k tc1r = 1m\n.ends\n",
        },
    );
    const errata = try parseErrata(a,
        \\{"name": "x", "errata": [
        \\  {"file": "cells/r.spice", "was": "res a b rm r = 1k tc1r = 1m",
        \\   "read": "Rres a b rm r = 1k tc1 = 1m", "why": "a switch to ngspice"},
        \\  {"file": "cells/r.spice", "was": "gone a b 1k", "read": "Rgone a b 1k"}
        \\]}
    );
    try std.testing.expectEqual(2, errata.len);
    const ngspice = dialects.find("ngspice").?.*;
    const xyce = dialects.find("xyce").?.*;
    var log: Writer.Allocating = .init(a);
    const sum = try run(io, std.testing.allocator, .{
        .from = &ngspice,
        .to = &xyce,
        .tops = &.{try std.fmt.allocPrint(a, "{s}/in/lib.spice", .{base})},
        .out_dir = try std.fmt.allocPrint(a, "{s}/out", .{base}),
        .library = true,
        .log = &log.writer,
        .errata = errata,
    });
    try std.testing.expectEqual(0, sum.errors);
    const out = try tmp.dir.readFileAlloc(io, "out/cells/r.spice", a, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, out, "Rres a b 1k rm tc1=1m\n") != null);
    // Said once, though both passes read the file.
    try std.testing.expectEqual(
        1,
        std.mem.count(
            u8,
            log.written(),
            "r.spice:3: warning[caveat]: read through an erratum of the PDK: 'res a b rm r = " ++
                "1k tc1r = 1m': a switch to ngspice; read as 'Rres a b rm r = 1k tc1 = 1m'",
        ),
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            log.written(),
            "info[cosmetic]: the PDK's erratum for this file no longer applies: 'gone a b 1k' " ++
                "is not in it",
        ) != null,
    );
    try std.testing.expectError(error.BadErrata, parseErrata(a, "[1]"));
}

test "an include that is no regular file is refused, not read until memory runs out" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "top.sp", .data = "t\n.include /dev/zero\nR1 a 0 1k\n.end\n" },
    );
    const ngspice = dialects.find("ngspice").?.*;
    var log: Writer.Allocating = .init(a);
    const sum = try run(io, std.testing.allocator, .{
        .from = &ngspice,
        .to = &ngspice,
        .tops = &.{try std.fmt.allocPrint(a, "{s}/top.sp", .{base})},
        .out_dir = try std.fmt.allocPrint(a, "{s}/out", .{base}),
        .log = &log.writer,
    });
    try std.testing.expectEqual(1, sum.errors);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            log.written(),
            "/dev/zero: error[invalid]: not a regular file; not read",
        ) != null,
    );
}

test "one section for a target that opens every section: the others' includes are comments" {
    // docs/verification.md 4.24: ngspice 45 stops at the missing ff.mod.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "in");
    try tmp.dir.writeFile(io, .{ .sub_path = "in/corners.lib", .data =
        \\* corners
        \\.lib tt
        \\.include "tt.mod"
        \\.endl tt
        \\.lib ff
        \\.include "ff.mod"
        \\.lib "corners.lib" tt
        \\.endl ff
        \\
    });
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "in/tt.mod", .data = "* tt\n.model nch nmos level=1\n" },
    );
    const ngspice = dialects.find("ngspice").?.*;
    const xyce = dialects.find("xyce").?.*;
    for ([_]*const Grammar{ &ngspice, &xyce }) |to| {
        var log: Writer.Allocating = .init(a);
        const out = try std.fmt.allocPrint(a, "{s}/out-{s}", .{ base, to.name });
        _ = try run(io, std.testing.allocator, .{
            .from = &ngspice,
            .to = to,
            .tops = &.{try std.fmt.allocPrint(a, "{s}/in/corners.lib", .{base})},
            .out_dir = out,
            .library = true,
            .log = &log.writer,
            .sections = &.{"tt"},
        });
        const lib = try tmp.dir.readFileAlloc(
            io,
            try std.fmt.allocPrint(a, "out-{s}/corners.lib", .{to.name}),
            a,
            .unlimited,
        );
        if (to == &ngspice) {
            try std.testing.expect(
                std.mem.indexOf(
                    u8,
                    lib,
                    ".lib ff\n* [sprack] not in this copy: include \"ff.mod\"\n* [sprack] not " ++
                        "in this copy: lib \"corners.lib\" tt\n.endl ff\n",
                ) != null,
            );
            try std.testing.expect(std.mem.indexOf(u8, lib, ".include \"tt.mod\"\n") != null);
            try std.testing.expect(
                std.mem.indexOf(
                    u8,
                    log.written(),
                    "warning[caveat]: section 'ff' is not followed, and ngspice opens the " ++
                        "includes of every section of a library",
                ) != null,
            );
        } else {
            // Xyce opens only the section asked for: the copy keeps the line.
            try std.testing.expect(std.mem.indexOf(u8, lib, ".include \"ff.mod\"\n") != null);
            try std.testing.expect(
                std.mem.indexOf(u8, log.written(), "opens the includes") == null,
            );
        }
    }
}

test "a small project: includes followed, declarations shared, tree copied" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "in/models");
    // The transistor's model lives two includes away, in a library section,
    // behind an environment variable. A Spectre writer needs it to know that
    // M1 is a MOSFET; the include lines must come out relative.
    try tmp.dir.writeFile(io, .{ .sub_path = "in/top.sp", .data =
        \\Top netlist
        \\.lib '$MODELS/corners.lib' tt
        \\M1 d g 0 0 nch w=1u l=1u
        \\.op
        \\.end
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "in/models/corners.lib", .data =
        \\* corners
        \\.lib tt
        \\.include "nch.mod"
        \\.endl tt
        \\.lib ff
        \\.include "ff.mod"
        \\.endl ff
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "in/models/nch.mod", .data =
        \\* the model
        \\.model nch nmos level=54 vth0=0.4
        \\.include "missing.mod"
        \\
    });

    const hspice = dialects.find("hspice").?.*;
    const spectre = dialects.find("spectre").?.*;

    var log: Writer.Allocating = .init(a);
    var expanded: Writer.Allocating = .init(a);
    const models = try std.fmt.allocPrint(a, "{s}/in/models", .{base});
    const sum = try run(io, std.testing.allocator, .{
        .from = &hspice,
        .to = &spectre,
        .tops = &.{try std.fmt.allocPrint(a, "{s}/in/top.sp", .{base})},
        .out_dir = try std.fmt.allocPrint(a, "{s}/out", .{base}),
        // A path the include starts with is from where sprack runs (#54):
        // given whole here.
        .vars = &.{.{ "MODELS", models }},
        .log = &log.writer,
        .expanded = &expanded.writer,
        // No section asked for: the deck's `.lib` reaches `tt` alone, as
        // the simulator does, so ff.mod (which does not exist) is not
        // reached (#67).
    });
    try std.testing.expectEqual(3, sum.files);
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "{{\"MODELS\":\"{s}\"}}", .{models}),
        expanded.written(),
    );
    try std.testing.expectEqual(1, sum.missing);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            log.written(),
            "missing.mod: error[invalid]: cannot open this file",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            log.written(),
            "corners.lib: info[cosmetic]: section 'ff' not followed: no followed .lib line " ++
                "names it",
        ) != null,
    );

    const top = try tmp.dir.readFileAlloc(io, "out/top.sp", a, .unlimited);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            top,
            "// Top netlist\nsimulator lang=spectre insensitive=yes\nglobal 0\n",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, top, "include \"models/corners.lib\" section=tt\n") != null,
    );
    // Recognised as a transistor of a model declared elsewhere in the project.
    try std.testing.expect(std.mem.indexOf(u8, top, "M1 (d g 0 0) nch w=1u l=1u\n") != null);
    const lib = try tmp.dir.readFileAlloc(io, "out/models/corners.lib", a, .unlimited);
    // An included file: no title, no `global`, but it does say its language,
    // and that HSPICE ignores case: in Spectre the setting is per file.
    try std.testing.expect(
        std.mem.startsWith(
            u8,
            lib,
            "simulator lang=spectre insensitive=yes\n// corners\nsection tt\ninclude " ++
                "\"nch.mod\"\nendsection tt\n",
        ),
    );
    const mod = try tmp.dir.readFileAlloc(io, "out/models/nch.mod", a, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, mod, "model nch bsim4 type=n vth0=0.4\n") != null);

    // The same tree, as a catalogue.
    var cat: Writer.Allocating = .init(a);
    _ = try run(io, std.testing.allocator, .{
        .from = &hspice,
        .tops = &.{try std.fmt.allocPrint(a, "{s}/in/models/corners.lib", .{base})},
        .library = true,
        .catalog = &cat.writer,
    });
    try std.testing.expect(std.mem.indexOf(u8, cat.written(), "\"name\":\"nch\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, cat.written(), "corners.lib\",\"name\":\"tt\"},{\"file\":") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            cat.written(),
            "\"section\":\"\",\"kind\":\"model\",\"device\":\"mosfet\"," ++
                "\"family\":\"bsim4\",\"polarity\":\"n\"",
        ) != null,
    );
}

test "files translated at once: the tree, the log and the names expanded are as one at a time" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "in/models");
    // A top file and twelve libraries, each reached through a name of its
    // own, each with something to report, one of them missing and one read
    // through an erratum: every per-file result the run takes is there.
    const count = 12;
    var top: std.ArrayList(u8) = .empty;
    var vars: std.ArrayList([2][]const u8) = .empty;
    try top.appendSlice(a, "Top netlist\n");
    for (0..count) |k| {
        const name = try std.fmt.allocPrint(a, "LIB{d}", .{k});
        try vars.append(a, .{ name, try std.fmt.allocPrint(a, "{s}/in/models", .{base}) });
        try top.print(a, ".include '${s}/m{d}.mod'\n", .{ name, k });
        if (k == 5) continue; // not there
        const text = try std.fmt.allocPrint(a,
            \\* library {d}
            \\.model n{d} nmos level=54 vth0=0.{d}
            \\.subckt cell{d} a b
            \\R1 a b 1k tc1=0.{d}
            \\C1 a b 1p ic=0.{d}
            \\.ends
            \\.param p{d}=1 q{d}='p{d}*2'
            \\
        , .{ k, k, k + 1, k, k + 1, k + 1, k, k, k });
        try tmp.dir.writeFile(
            io,
            .{ .sub_path = try std.fmt.allocPrint(a, "in/models/m{d}.mod", .{k}), .data = text },
        );
    }
    try top.appendSlice(a, "X1 d g cell3\n.op\n.end\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "in/top.sp", .data = top.items });

    const hspice = dialects.find("hspice").?.*;
    const vacask = dialects.find("vacask").?.*;
    const errata: []const Erratum = &.{.{
        .file = "m7.mod",
        .was = "R1 a b 1k tc1=0.8",
        .read = "R1 a b 2k tc1=0.8",
        .why = "a test",
    }};
    var logs: [2][]const u8 = undefined;
    var names: [2][]const u8 = undefined;
    var sums: [2]Summary = undefined;
    for ([_]usize{ 1, 4 }, 0..) |jobs, n| {
        var log: Writer.Allocating = .init(a);
        var expanded: Writer.Allocating = .init(a);
        sums[n] = try run(io, std.testing.allocator, .{
            .from = &hspice,
            .to = &vacask,
            .tops = &.{try std.fmt.allocPrint(a, "{s}/in/top.sp", .{base})},
            .out_dir = try std.fmt.allocPrint(a, "{s}/out{d}", .{ base, jobs }),
            .vars = vars.items,
            .log = &log.writer,
            .expanded = &expanded.writer,
            .errata = errata,
            .jobs = jobs,
        });
        logs[n] = log.written();
        names[n] = expanded.written();
    }
    try std.testing.expectEqual(count, sums[0].files);
    try std.testing.expectEqual(1, sums[0].missing);
    try std.testing.expect(sums[0].warnings > 0);
    try std.testing.expect(std.mem.indexOf(u8, logs[0], "read through an erratum") != null);
    // One at a time and four at once: nothing the run gives differs but
    // the directory it was asked to write to.
    try std.testing.expectEqualStrings(logs[0], logs[1]);
    try std.testing.expectEqualStrings(names[0], names[1]);
    try std.testing.expectEqual(sums[0].files, sums[1].files);
    try std.testing.expectEqual(sums[0].errors, sums[1].errors);
    try std.testing.expectEqual(sums[0].warnings, sums[1].warnings);
    try std.testing.expectEqual(sums[0].missing, sums[1].missing);
    for ([_][]const u8{ "top.sp", "models/m0.mod", "models/m7.mod", "models/m11.mod" }) |file| {
        const one = try tmp.dir.readFileAlloc(
            io,
            try std.fmt.allocPrint(a, "out1/{s}", .{file}),
            a,
            .limited(1 << 20),
        );
        const four = try tmp.dir.readFileAlloc(
            io,
            try std.fmt.allocPrint(a, "out4/{s}", .{file}),
            a,
            .limited(1 << 20),
        );
        try std.testing.expect(one.len > 0);
        try std.testing.expectEqualStrings(one, four);
    }
}
