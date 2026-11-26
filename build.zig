const std = @import("std");
const lint = @import("lint/lint.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Every grammars/*.spgrammar file becomes a dialect. There is no list to
    // keep in sync: drop a file in the directory and rebuild.
    const io = b.graph.io;
    b.dependOnDirectoryContents(b.path("grammars"));
    var dir = b.root.openDir(
        io,
        "grammars",
        .{ .iterate = true },
    ) catch @panic("grammars/ directory not found");
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch @panic("cannot list grammars/")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".spgrammar")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);

    // The grammars are compiled now, by the compiler a grammar file given by
    // path goes through at run time, and their tables written out as Zig
    // source: the `registry` module. A mistake in a file stops the build
    // here, with the file and the line.
    const grammar_gen = b.addRunArtifact(b.addExecutable(.{
        .name = "grammar-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/grammar_gen.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "grammar", .module = grammarModule(b, b.graph.host, .Debug) }},
        }),
    }));
    const registry_source = grammar_gen.addOutputFileArg("registry.zig");
    for (names.items) |n| grammar_gen.addFileArg(b.path(b.fmt("grammars/{s}", .{n})));

    const grammar = grammarModule(b, target, optimize);
    const registry = b.createModule(.{
        .root_source_file = registry_source,
        .imports = &.{.{ .name = "grammar", .module = grammar }},
    });

    // The module graph, leaves first: each module is handed only modules
    // defined above it, so an import cycle cannot be written, and each has
    // a test binary of its own, compiled against only what it imports.
    var modules: std.StringArrayHashMapUnmanaged(*std.Build.Module) = .empty;
    modules.put(b.allocator, "schema", grammar.import_table.get("schema").?) catch @panic("OOM");
    modules.put(b.allocator, "grammar", grammar) catch @panic("OOM");
    modules.put(b.allocator, "registry", registry) catch @panic("OOM");
    const test_step = b.step("test", "Run all tests");
    for (module_specs) |spec| {
        const module = b.createModule(
            .{ .root_source_file = b.path(spec.path), .target = target, .optimize = optimize },
        );
        for (spec.imports) |dep| {
            const dep_module = modules.get(dep) orelse
                std.debug.panic(
                    "module '{s}' imports '{s}', which is not above it in module_specs",
                    .{ spec.name, dep },
                );
            module.addImport(dep, dep_module);
        }
        modules.put(b.allocator, spec.name, module) catch @panic("OOM");
    }
    for (modules.keys(), modules.values()) |name, module| {
        if (std.mem.eql(u8, name, "registry")) continue;
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    }
    // `-Dtsan`: every module watched by the thread sanitizer, which stops
    // the run at the first write two threads make to one place unguarded
    // (`sprack project` translates its files at once).
    const tsan = b.option(bool, "tsan", "Build with the thread sanitizer") orelse false;
    if (tsan) for (modules.values()) |module| {
        module.sanitize_thread = true;
    };
    const sprack = modules.get("sprack").?;
    b.modules.put(b.graph.arena, "sprack", sprack) catch @panic("OOM");

    // No binary and no test run from a tree that breaks a rule it already
    // kept (lint/lint.zig lists the files held to them).
    const lint_step = lint.addTo(b);
    b.getInstallStep().dependOn(lint_step);
    test_step.dependOn(lint_step);

    const exe = b.addExecutable(.{
        .name = "sprack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sprack", .module = sprack }},
            .sanitize_thread = tsan,
        }),
    });
    b.installArtifact(exe);

    // C ABI for the Python package and any other host language.
    const lib = b.addLibrary(.{
        .name = "sprack",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sprack", .module = sprack }},
        }),
    });
    b.installArtifact(lib);

    // The CPython extension module, `zig build py`. It is built against
    // the limited C API and resolves the interpreter's symbols when loaded,
    // so no Python headers or libraries are needed to build it.
    const pyext = b.addLibrary(.{
        .name = "_core",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pyext.zig"),
            // Zig's own TLS is not set up in a dlopen'd library; glibc's is.
            .link_libc = true,
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sprack", .module = sprack }},
        }),
    });
    pyext.linker_allow_shlib_undefined = true;
    if (target.result.os.tag == .windows) {
        // A PE file cannot leave symbols to the loading process: link an
        // import library for python3.dll, made here from src/python3.def.
        const machine = switch (target.result.cpu.arch) {
            .x86_64 => "i386:x86-64",
            .aarch64 => "arm64",
            else => @panic("Windows Python extension: x86_64 or aarch64 only"),
        };
        const dlltool = b.addSystemCommand(&.{ b.graph.zig_exe, "dlltool", "-m", machine, "-d" });
        dlltool.addFileArg(b.path("src/python3.def"));
        dlltool.addArg("-l");
        pyext.root_module.addObjectFile(dlltool.addOutputFileArg("python3.lib"));
    }
    const ext_name = if (target.result.os.tag == .windows) "_core.pyd" else "_core.abi3.so";
    const install_py = b.addInstallFileWithDir(
        pyext.getEmittedBin(),
        .{ .custom = "../python/sprack" },
        ext_name,
    );
    // The same package as a self-contained directory to ship: zig-out/python
    // goes on PYTHONPATH and `import sprack` works, PDK manifests included.
    const bundle_pkg = b.addInstallDirectory(.{
        .source_dir = b.path("python/sprack"),
        .install_dir = .prefix,
        .install_subdir = "python/sprack",
        .include_extensions = &.{ ".py", ".json" },
    });
    const bundle_ext = b.addInstallFileWithDir(
        pyext.getEmittedBin(),
        .{ .custom = "python/sprack" },
        ext_name,
    );
    const py_step = b.step(
        "py",
        "Build the Python extension into python/sprack/, and the package to ship into " ++
            "zig-out/python/sprack/",
    );
    py_step.dependOn(&install_py.step);
    py_step.dependOn(&bundle_pkg.step);
    py_step.dependOn(&bundle_ext.step);
    // Only the shipped package, under the install prefix: what a sandboxed or
    // cross build (`-Dtarget=`, `--prefix`) runs, leaving python/ untouched.
    const bundle_step = b.step(
        "bundle",
        "Install only the package to ship, into <prefix>/python/sprack/",
    );
    bundle_step.dependOn(&bundle_pkg.step);
    bundle_step.dependOn(&bundle_ext.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the sprack command line tool").dependOn(&run.step);

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lib.root_module })).step);
    // Line coverage of src/ by the Zig tests (issue 65): the test binary
    // built with the LLVM backend (kcov reads its DWARF line table), run
    // under kcov, the report in zig-out/coverage. Needs kcov on PATH (the
    // flake's ci shell has it).
    const cov_tests = b.addTest(.{ .root_module = sprack, .use_llvm = true });
    const kcov = b.addSystemCommand(&.{ "kcov", "--include-path=src" });
    const report = kcov.addOutputDirectoryArg("coverage");
    kcov.addArtifactArg(cov_tests);
    kcov.has_side_effects = true;
    const install_report = b.addInstallDirectory(
        .{ .source_dir = report, .install_dir = .prefix, .install_subdir = "coverage" },
    );
    b.step(
        "coverage",
        "Run the Zig tests under kcov: line coverage of src/ into zig-out/coverage",
    ).dependOn(&install_report.step);
    const cli_step = b.step(
        "test-cli",
        "Run the sprack command on small inputs: what it prints and how it exits",
    );
    cliTests(.{ .b = b, .step = cli_step, .exe = exe });
    test_step.dependOn(cli_step);
}

const ModuleSpec = struct { name: []const u8, path: []const u8, imports: []const []const u8 };

/// The modules of `src/` above `schema`, `grammar` and `registry` (which
/// `build` makes itself), leaves first. A module may import only modules
/// listed above it.
const module_specs = [_]ModuleSpec{
    .{ .name = "ir", .path = "src/ir.zig", .imports = &.{"schema"} },
    .{ .name = "dialects", .path = "src/dialects.zig", .imports = &.{ "grammar", "registry" } },
    .{ .name = "lexer", .path = "src/lexer.zig", .imports = &.{ "grammar", "ir" } },
    .{
        .name = "expr",
        .path = "src/expr.zig",
        .imports = &.{ "schema", "grammar", "ir", "lexer" },
    },
    .{ .name = "cond", .path = "src/cond.zig", .imports = &.{ "schema", "ir", "expr" } },
    .{ .name = "alter", .path = "src/alter.zig", .imports = &.{ "schema", "grammar", "ir" } },
    .{ .name = "stats", .path = "src/stats.zig", .imports = &.{ "schema", "grammar", "ir" } },
    .{ .name = "topology", .path = "src/topology.zig", .imports = &.{ "schema", "grammar", "ir" } },
    .{
        .name = "reader",
        .path = "src/reader.zig",
        .imports = &.{ "schema", "grammar", "ir", "dialects", "lexer", "expr" },
    },
    .{
        .name = "writer",
        .path = "src/writer/root.zig",
        .imports = &.{
            "schema",
            "grammar",
            "ir",
            "dialects",
            "lexer",
            "expr",
            "reader",
            "stats",
            "alter",
            "cond",
            "topology",
        },
    },
    .{
        .name = "stream",
        .path = "src/stream.zig",
        .imports = &.{ "schema", "grammar", "ir", "reader", "writer", "stats", "topology" },
    },
    .{
        .name = "json",
        .path = "src/json.zig",
        .imports = &.{ "schema", "grammar", "ir", "dialects", "lexer", "reader" },
    },
    .{
        .name = "project",
        .path = "src/project.zig",
        .imports = &.{
            "schema",
            "grammar",
            "ir",
            "dialects",
            "reader",
            "writer",
            "stream",
            "json",
        },
    },
    .{
        .name = "sprack",
        .path = "src/root.zig",
        .imports = &.{
            "schema",
            "grammar",
            "ir",
            "dialects",
            "lexer",
            "expr",
            "alter",
            "stats",
            "reader",
            "writer",
            "stream",
            "json",
            "project",
        },
    },
};

/// The `grammar` module (the `.spgrammar` compiler) over the `schema` module
/// (the canonical vocabulary), for the target or for the build host.
fn grammarModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: ?std.builtin.OptimizeMode,
) *std.Build.Module {
    const schema = b.createModule(
        .{ .root_source_file = b.path("src/schema.zig"), .target = target, .optimize = optimize },
    );
    return b.createModule(.{
        .root_source_file = b.path("src/grammar.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "schema", .module = schema }},
    });
}

/// One run of the built command per case. Standard output and standard
/// error are checked for what they must contain, the exit status exactly:
/// 0 nothing lost, 1 the report has an error, 2 the command line is wrong.
const Cli = struct {
    b: *std.Build,
    step: *std.Build.Step,
    exe: *std.Build.Step.Compile,

    /// `stdin` is "" for a case that exits before it reads its input (a
    /// wrong flag, a grammar it cannot read): bytes written to a process
    /// that is gone end the step in BrokenPipe now and then (#76).
    fn run(c: Cli, args: []const []const u8, stdin: []const u8, code: u8) *std.Build.Step.Run {
        const r = c.b.addRunArtifact(c.exe);
        r.addArgs(args);
        r.setStdIn(.{ .bytes = stdin });
        r.expectExitCode(code);
        c.step.dependOn(&r.step);
        return r;
    }

    fn file(c: Cli, lp: std.Build.LazyPath, matches: []const []const u8) void {
        c.step.dependOn(&c.b.addCheckFile(lp, .{ .expected_matches = matches }).step);
    }
};

fn cliTests(c: Cli) void {
    const b = c.b;
    const deck = "t\nR1 a 0 1k\n.tran 1n 1u\n.end\n";
    const spectre = "// t\nsimulator lang=spectre insensitive=yes\nglobal 0\nR1 (a 0) " ++
        "resistor r=1k\ntran1 tran step=1n stop=1u\n";

    // What needs no input.
    c.run(&.{}, "", 2).expectStdErrMatch(
        "usage:\n  sprack translate --from <dialect> --to <dialect> [file] [-o out]",
    );
    c.run(&.{"dialects"}, "", 0).expectStdOutEqual(
        "cdl\nhspice\nltspice\nngspice\nspectre\nvacask\nxyce\n",
    );
    c.run(&.{"info"}, "", 0).expectStdOutMatch(
        "{\"dialects\":[\"cdl\",\"hspice\",\"ltspice\",\"ngspice\",\"spectre\",\"vacask\",\"xyce\"],\"kinds\":{\"resistor\":{\"class\":\"device\"",
    );
    const caps = c.run(&.{"caps"}, "", 0);
    caps.expectStdOutMatch(
        "            cdl      hspice   ltspice  ngspice  spectre  vacask   xyce     " ++
            "\nresistor    yes      yes      yes      yes      yes      yes      yes      \n",
    );
    caps.expectStdOutMatch("\nnone: the simulator has no such thing; an error that says why.\n");

    // translate: standard input to standard output, the report to standard error.
    const ok = c.run(&.{ "translate", "--from", "ngspice", "--to", "spectre" }, deck, 0);
    ok.expectStdOutEqual(spectre);
    ok.expectStdErrEqual("");
    // An error in the report: the output is still written, and the status is 1.
    const lost = c.run(
        &.{ "translate", "--from", "ngspice", "--to", "xyce" },
        "t\n.pz a 0 b 0 vol pz\n.end\n",
        1,
    );
    lost.expectStdOutEqual("t\n* [sprack] not written: analysis 'pz' has no xyce form\n.end\n");
    lost.expectStdErrEqual(
        "error[unsupported]: line 2: analysis 'pz' cannot be written for xyce: Xyce has no " ++
            "pole-zero analysis. Dialects that define it: hspice, ngspice, spectre\n",
    );
    // A warning alone is status 0.
    c.run(
        &.{ "translate", "--from", "ngspice", "--to", "vacask" },
        deck,
        0,
    ).expectStdErrMatch("warning[synthesized]: line 3: tran: vacask needs 'maxstep'");
    // To a file, and from one.
    const to_file = c.run(&.{ "translate", "--from", "ngspice", "--to", "spectre", "-o" }, deck, 0);
    c.file(to_file.addOutputFileArg("out.scs"), &.{spectre});
    to_file.expectStdOutEqual("");
    const wf = b.addWriteFiles();
    const from_file = c.run(&.{ "translate", "--to", "spectre", "--from", "ngspice" }, "", 0);
    from_file.addFileArg(wf.add("deck.sp", deck));
    from_file.expectStdOutEqual(spectre);
    // A dialect given as its grammar file is that dialect.
    const by_path = c.run(&.{ "translate", "--to", "spectre", "--from" }, deck, 0);
    by_path.addFileArg(b.path("grammars/ngspice.spgrammar"));
    by_path.expectStdOutEqual(spectre);
    const bad_grammar = c.run(&.{ "translate", "--to", "spectre", "--from" }, "", 2);
    bad_grammar.addFileArg(
        wf.add("bad.spgrammar", "dialect bad\nlexer\nend\nrule op = \".op\" zz\n"),
    );
    bad_grammar.expectStdErrMatch("bad.spgrammar:4: unknown slot 'zz' for kind 'op'");

    // read and write: the statements as JSON, and back.
    const json = "{\"title\":\"t\",\"dialect\":\"ngspice\",\"stmts\":[{\"kind\":\"resistor\",\"line\":2,\"name\":\"R1\",\"pos\":\"a\",\"neg\":\"0\",\"r\":\"1e3\"},\n{\"kind\":\"tran\",\"line\":3,\"step\":\"1e-9\",\"stop\":\"1e-6\"}]}\n";
    c.run(&.{ "read", "--from", "ngspice" }, deck, 0).expectStdOutEqual(json);
    c.run(&.{ "write", "--to", "spectre" }, json, 0).expectStdOutEqual(spectre);
    // JSON that is not a document: nothing was read, so nothing is written.
    const cut = c.run(&.{ "write", "--to", "ngspice" }, "{\"stmts\":", 1);
    cut.expectStdErrEqual("error[invalid]: not valid JSON: UnexpectedEndOfInput\n");
    cut.expectStdOutEqual("");
    const list = c.run(&.{ "write", "--to", "ngspice" }, "[]", 1);
    list.expectStdErrEqual("error[invalid]: the top level must be an object with 'stmts'\n");
    list.expectStdOutEqual("");
    // A problem inside a document: what could be understood is written.
    const inside = c.run(
        &.{ "write", "--to", "ngspice" },
        "{\"title\":\"t\",\"stmts\":[{\"kind\":\"zener\"}]}",
        1,
    );
    inside.expectStdErrEqual("error[invalid]: line 1: unknown statement kind 'zener'\n");
    inside.expectStdOutEqual("t\n.end\n");

    // audit: one TSV line; the circuit reads back the same (column 4).
    c.run(
        &.{ "audit", "--from", "ngspice", "--to", "spectre" },
        deck,
        0,
    ).expectStdOutEqual("-\t2\t0\t1\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t\n");
    // A line no rule reads: counted, keyed by its first word, an error for another dialect.
    c.run(
        &.{ "audit", "--from", "ngspice", "--to", "xyce" },
        "t\n.bogus 1\n.end\n",
        0,
    ).expectStdOutEqual("-\t1\t1\t0\t1\t1\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t.bogus:1\n");

    // A wrong command line: status 2 and what is wrong, nothing translated.
    c.run(
        &.{ "translate", "--from", "ngspice" },
        "",
        2,
    ).expectStdErrMatch("--to is required\nusage:");
    c.run(&.{ "translate", "--to", "xyce" }, "", 2).expectStdErrMatch("--from is required\nusage:");
    c.run(&.{ "translate", "--from", "pspice", "--to", "xyce" }, "", 2).expectStdErrEqual(
        "unknown dialect 'pspice'. Built in: cdl hspice ltspice ngspice spectre vacask xyce; " ++
            "or a path to a .spgrammar file\n",
    );
    c.run(
        &.{ "translate", "--frm", "ngspice" },
        "",
        2,
    ).expectStdErrMatch("unknown option '--frm'\nusage:");
    c.run(&.{"frobnicate"}, "", 2).expectStdErrMatch("unknown command 'frobnicate'\nusage:");
    c.run(
        &.{ "translate", "--from", "ngspice", "--to", "xyce", "/no/such.sp" },
        "",
        2,
    ).expectStdErrEqual("cannot read /no/such.sp: FileNotFound\n");
    c.run(
        &.{ "translate", "--from", "/no/such.spgrammar", "--to", "xyce" },
        "",
        2,
    ).expectStdErrEqual("cannot read /no/such.spgrammar: FileNotFound\n");
    c.run(
        &.{ "catalog", "--from", "ngspice", "-D", "PDK", "x.sp" },
        "",
        2,
    ).expectStdErrEqual("--define takes NAME=VALUE\n");
    c.run(
        &.{ "project", "--from", "ngspice", "--to", "xyce", "x.sp" },
        "",
        2,
    ).expectStdErrMatch("project needs --out <dir>\nusage:");
    c.run(
        &.{ "project", "--from", "ngspice", "--to", "xyce", "--out", "x" },
        "",
        2,
    ).expectStdErrMatch("project needs at least one file\nusage:");

    // project: a tree of files, its includes followed and rewritten.
    const top = wf.add(
        "tree/top.sp",
        "top\n.include \"inc/sub.sp\"\n.lib \"$PDK/corners.lib\" tt\nX1 a 0 rdiv\n.op\n.end\n",
    );
    const sub = wf.add("tree/inc/sub.sp", ".subckt rdiv a b\nR1 a b 1k\n.ends rdiv\n");
    _ = wf.add(
        "tree/pdk/corners.lib",
        ".lib tt\n.param rsh=10\n.endl tt\n.lib ff\n.param rsh=8\n.endl ff\n",
    );
    // (A path that starts with $PDK is the value's own path, from the
    // directory sprack runs in: here the tree's.)
    const tree = c.run(
        &.{
            "project",
            "--from",
            "ngspice",
            "--to",
            "spectre",
            "--section",
            "tt",
            "-D",
            "PDK=pdk",
            "--out",
        },
        "",
        0,
    );
    tree.setCwd(wf.getDirectory().path(b, "tree"));
    const out = tree.addOutputDirectoryArg("spectre-tree");
    tree.addFileArg(top);
    tree.expectStdErrMatch("pdk/corners.lib: info[cosmetic]: section 'ff' not followed");
    tree.expectStdErrMatch("3 files, 0 errors, 0 warnings\n");
    c.file(
        out.path(b, "top.sp"),
        &.{
            "include \"inc/sub.sp\"\ninclude \"pdk/corners.lib\" section=tt\nX1 (a 0) rdiv\n",
            "op1 dc\n",
        },
    );
    c.file(out.path(b, "inc/sub.sp"), &.{"subckt rdiv (a b)\nR1 (a b) resistor r=1k\nends rdiv\n"});
    c.file(out.path(b, "pdk/corners.lib"), &.{"section tt\nparameters rsh=10\nendsection tt\n"});
    // An include that is not there: an error, the count says so, status 1.
    const missing = c.run(&.{ "project", "--from", "ngspice", "--to", "xyce", "--out" }, "", 1);
    _ = missing.addOutputDirectoryArg("xyce-tree");
    missing.addFileArg(top);
    missing.expectStdErrMatch(
        "$PDK/corners.lib: error[invalid]: cannot open this file; it is included by the " ++
            "project\n2 files, 1 error, 0 warnings, 1 included file not found\n",
    );
    // A section asked for that no file defines: an error too.
    const nosec = c.run(
        &.{
            "project",
            "--from",
            "ngspice",
            "--to",
            "spectre",
            "--section",
            "typ",
            "-D",
            "PDK=pdk",
            "--out",
        },
        "",
        1,
    );
    nosec.setCwd(wf.getDirectory().path(b, "tree"));
    _ = nosec.addOutputDirectoryArg("nosec-tree");
    nosec.addFileArg(top);
    nosec.expectStdErrMatch(
        "top.sp: error[invalid]: section 'typ' is asked for, but no file read defines it\n",
    );
    nosec.expectStdErrMatch("3 files, 1 error, 0 warnings\n");
    // --lib: the file named is a library itself, no title line (#67).
    const lib = c.run(
        &.{
            "project",
            "--from",
            "ngspice",
            "--to",
            "spectre",
            "--lib",
            "--section",
            "tt",
            "--out",
        },
        "",
        0,
    );
    const lib_out = lib.addOutputDirectoryArg("lib-out");
    lib.addFileArg(
        wf.add(
            "libonly/corners.lib",
            ".lib tt\n.param rsh=10\n.endl tt\n.lib ff\n.param rsh=8\n.endl ff\n",
        ),
    );
    lib.expectStdErrMatch("section 'ff' not followed");
    lib.expectStdErrMatch("1 file, 0 errors, 0 warnings\n");
    c.file(lib_out.path(b, "corners.lib"), &.{"section tt\nparameters rsh=10\nendsection tt\n"});
    // -D NAME=relative/path: one place, whichever file names it (#54).
    const dtop = wf.add(
        "dtree/top.sp",
        "top\n.include \"$INC/sub.sp\"\n.include \"a/b/mid.sp\"\nX1 a 0 rdiv\n.op\n.end\n",
    );
    _ = wf.add("dtree/a/b/mid.sp", ".include \"$INC/sub.sp\"\n");
    _ = wf.add("dtree/common/sub.sp", ".subckt rdiv a b\nR1 a b 1k\n.ends rdiv\n");
    const dproj = c.run(
        &.{ "project", "--from", "ngspice", "--to", "spectre", "-D", "INC=common", "--out" },
        "",
        0,
    );
    dproj.setCwd(wf.getDirectory().path(b, "dtree"));
    _ = dproj.addOutputDirectoryArg("dtree-out");
    dproj.addFileArg(dtop);
    dproj.expectStdErrMatch("3 files, 0 errors, 0 warnings\n");
    // audit: status 1 for a circuit that reads back otherwise in silence
    // (a grammar that writes a resistor's nodes one way and reads them the
    // other), 0 where the report says why, 2 for a wrong flag.
    const swap = wf.add("swap.spgrammar", "dialect swap\nlexer\n  case insensitive\n  title " ++
        "yes\n  comment line \"*\"\nend\n" ++
        "write resistor = name~\"R\" pos neg r\nread resistor = name~\"R\" neg pos r\nrule op " ++
        "= \".op\"\n");
    const silent = c.run(
        &.{ "audit", "--from", "ngspice", "--to" },
        "t\nR1 a 0 1k\n.op\n.end\n",
        1,
    );
    silent.addFileArg(swap);
    silent.expectStdErrMatch(
        "the circuit read back from swap is not the one read, and the report does not say why\n",
    );
    c.run(
        &.{ "audit", "--from", "ngspice", "--to", "xyce", "--frm" },
        "",
        2,
    ).expectStdErrMatch("unknown option '--frm'");
    // catalog: what the files define, as JSON; the files named are libraries.
    const cat = c.run(&.{ "catalog", "--from", "ngspice" }, "", 0);
    cat.addFileArg(sub);
    cat.expectStdOutMatch("{\"devices\":[\n{\"name\":\"rdiv\",\"file\":\"");
    cat.expectStdOutMatch(
        "\"section\":\"\",\"kind\":\"subckt\",\"ports\":[\"a\",\"b\"],\"params\":{}}\n]",
    );
    cat.expectStdOutMatch("\"errors\":0,\"warnings\":0,\"missing\":0}\n");
    cat.expectStdErrEqual("1 file, 0 errors, 0 warnings\n");
}
