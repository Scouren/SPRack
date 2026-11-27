//! The `sprack` command: arguments and standard input → translated text on
//! standard output (or `-o`), the report on standard error, an exit status.
//!
//! Exit status: 0 nothing was lost, 1 the report has an error (or an input
//! was refused for what it is), 2 the command line is wrong or a file could
//! not be read. `docs/src/cli.md` describes every subcommand.
//!
//! Contents:
//! - `pub fn main(init: std.process.Init) !void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const sprack = @import("sprack");
const ir = sprack.ir;

const usage =
    \\usage:
    \\  sprack translate --from <dialect> --to <dialect> [file] [-o out]
    \\        One netlist. Result to stdout (or -o), report to stderr.
    \\  sprack project --from <dialect> --to <dialect> --out <dir> <file>...
    \\        The files and everything they include, as a translated copy of
    \\        the tree. This is how a PDK is translated.
    \\  sprack catalog --from <dialect> <file>...
    \\        JSON list of every subcircuit and model the files and their
    \\        includes define.
    \\        Both expand $NAME in include paths from the environment, or
    \\        from -D NAME=VALUE. With --lib the files named are model
    \\        libraries themselves (no title line), as in a PDK. Each
    \\        --section NAME (a corner: tt) limits the library sections
    \\        followed to those named and the ones they name; without
    \\        it, a section is followed when a followed .lib line names
    \\        it or a file named defines it. The others are listed as
    \\        not followed. --errata FILE reads the lines a
    \\        PDK's own simulator refuses as the JSON file says (a list of
    \\        {file, was, read, why}, or a manifest's "errata").
    \\        -j N (project): how many files are translated at once; as
    \\        many as the machine has processors, up to 8, when not given.
    \\        The result is the same for any N.
    \\        --provide NAME=FILE (translate and project, repeatable): a
    \\        file given by name: a Xyce plugin of a Verilog-A module (built
    \\        with buildxyceplugin; its instances become Y<module> lines;
    \\        --xyce-plugin is the same), or the compiled module of a model
    \\        family the target has only as a module (bsimcmg=FILE).
    \\  sprack read --from <dialect> [file]
    \\        The netlist as JSON (the internal representation).
    \\  sprack write --to <dialect> [file.json] [-o out]
    \\        A netlist from that JSON.
    \\  sprack audit --from <dialect> --to <dialect> <file>
    \\        One TSV line: translate, read the result back, compare.
    \\  sprack dialects | caps | info
    \\        The dialects built in; which can write what; the schema as JSON.
    \\
    \\A <dialect> is a built-in name or a path ending in .spgrammar.
    \\Reads standard input when no file is given. Exit status is 1 when the
    \\report contains an error: something in the input has no form in the
    \\target, so the output does not say everything the input said.
    \\
;

/// The files of a project translated at once when `-j` does not say: each
/// holds its own text in memory, so more processors than this are left idle.
const max_jobs = 8;

/// What the options of a command line say, whatever the subcommand.
const Args = struct {
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    out: ?[]const u8 = null,
    files: std.ArrayList([]const u8) = .empty,
    vars: std.ArrayList([2][]const u8) = .empty,
    library: bool = false,
    sections: std.ArrayList([]const u8) = .empty,
    errata: ?[]const u8 = null,
    provided: std.ArrayList([2][]const u8) = .empty,
    /// Files of a project translated at once; null: as the machine allows.
    jobs: ?usize = null,

    /// The input's name in messages: the first file, or `-` for standard input.
    fn inputName(args: *const Args) []const u8 {
        return if (args.files.items.len > 0) args.files.items[0] else "-";
    }
};

/// What every subcommand works with: where it reads its environment and
/// where its output and its report go. Lives as long as `main`.
const Cli = struct {
    io: std.Io,
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    out: *Writer,
    err: *Writer,
    /// Files given by name (`--provide`): an environment that holds nothing else.
    plugins: ?*const ir.Env = null,

    /// Read and write whole, never as a stream: to compare the two.
    fn whole(cli: *const Cli) bool {
        return cli.environ.get("SPRACK_WHOLE") != null;
    }
};

/// What an audit found, for its row.
const Audit = struct { nl: *const ir.Netlist, back: *const ir.Netlist, same: bool };

/// The report codes `audit` counts, in the order of its columns.
const audit_codes = .{
    .untranslated, .unsupported, .loss,    .synthesized, .caveat,
    .rename,       .cosmetic,    .invalid, .ambiguous,   .oneway,
};

/// The codes that explain a circuit not reading back the same.
const excuse_codes = .{
    .untranslated, .unsupported, .loss,   .synthesized,
    .invalid,      .ambiguous,   .oneway, .rename,
};

const errata_bytes_max = 16 << 20;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);

    var out_buf: [64 * 1024]u8 = undefined;
    var out_file = std.Io.File.stdout().writer(io, &out_buf);
    var err_buf: [8 * 1024]u8 = undefined;
    var err_file = std.Io.File.stderr().writer(io, &err_buf);
    var cli: Cli = .{
        .io = io,
        .arena = arena,
        .environ = init.environ_map,
        .out = &out_file.interface,
        .err = &err_file.interface,
    };

    if (argv.len < 2) die(io, "{s}", .{usage});
    assert(argv.len >= 2);
    const cmd = argv[1];
    if (std.mem.eql(u8, cmd, "dialects")) return printDialects(cli.out);
    if (std.mem.eql(u8, cmd, "info")) return printInfo(cli.out);
    if (std.mem.eql(u8, cmd, "caps")) return printCaps(cli.out);

    var args = try parseArgs(io, arena, argv[2..]);
    var plugin_holder: ir.Env = .{ .provided = args.provided.items };
    if (args.provided.items.len > 0) cli.plugins = &plugin_holder;

    const listing = std.mem.eql(u8, cmd, "catalog");
    if (listing or std.mem.eql(u8, cmd, "project")) return runProject(&cli, init.gpa, &args, cmd);

    const src = readSource(io, &args);
    if (std.mem.eql(u8, cmd, "audit")) return runAudit(&cli, &args, src);

    var report: ir.Report = .init(arena);
    // JSON that is not a document at all: nothing was read, so nothing is
    // written and no -o file is made.
    const doc: ?ir.Netlist = if (std.mem.eql(u8, cmd, "write"))
        try sprack.json.parseDocument(arena, src, &report) orelse {
            try report.print(cli.err);
            try cli.err.flush();
            std.process.exit(1);
        }
    else
        null;

    // The result is streamed, not collected: a netlist can be very large.
    var file_buf: [64 * 1024]u8 = undefined;
    var dest_file: ?std.Io.File = null;
    var dest_writer: std.Io.File.Writer = undefined;
    var result: *Writer = cli.out;
    if (args.out) |path| {
        dest_file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |e|
            die(io, "cannot write {s}: {s}\n", .{ path, @errorName(e) });
        dest_writer = dest_file.?.writer(io, &file_buf);
        result = &dest_writer.interface;
    }
    if (std.mem.eql(u8, cmd, "translate")) {
        try runTranslate(&cli, &args, src, result, &report);
    } else if (std.mem.eql(u8, cmd, "read")) {
        const nl = try sprack.read(arena, dialect(io, arena, args.from, "--from"), src, &report);
        try sprack.json.writeNetlist(result, &nl);
    } else if (doc) |*nl| {
        try sprack.write(arena, dialect(io, arena, args.to, "--to"), result, nl, &report);
    } else die(io, "unknown command '{s}'\n{s}", .{ cmd, usage });
    try result.flush();
    if (dest_file) |f| f.close(io);
    return finish(&cli, &report);
}

// ---- private ----

/// Standard error, then exit status 2: the command line is wrong.
fn die(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    stderrLine(io, fmt, args);
    std.process.exit(2);
}

/// A message on standard error, from where no writer is at hand. A write
/// that fails there has nowhere left to be reported.
fn stderrLine(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    // tidy: allow(swallowed-error) standard error itself failed: there is no other place to say so
    fw.interface.print(fmt, args) catch {};
    // tidy: allow(swallowed-error) as the line above
    fw.interface.flush() catch {};
}

/// The report on standard error, then status 1 if it holds an error.
fn finish(cli: *const Cli, report: *const ir.Report) !void {
    try report.print(cli.err);
    try cli.err.flush();
    if (report.hasErrors()) std.process.exit(1);
}

fn printDialects(out: *Writer) !void {
    for (sprack.grammars) |*g| try out.print("{s}\n", .{g.name});
    return out.flush();
}

fn printInfo(out: *Writer) !void {
    try sprack.json.writeInfo(out, sprack.grammars);
    return out.flush();
}

/// The table of which dialect can write which kind of statement.
fn printCaps(out: *Writer) !void {
    try out.print("{s:<12}", .{""});
    for (sprack.grammars) |*g| try out.print("{s:<9}", .{g.name});
    try out.writeByte('\n');
    for (sprack.schema.table) |info| {
        if (info.kind == .@"opaque" or info.kind == .comment) continue;
        try out.print("{s:<12}", .{@tagName(info.kind)});
        for (sprack.grammars) |*g| try out.print("{s:<9}", .{capMark(g, info)});
        try out.writeByte('\n');
    }
    try out.writeAll(
        \\
        \\yes:  has its own statement.
        \\inst: written as a generic instance of its model.
        \\param: written as a parameter of another statement (VACASK tran ic=).
        \\none: the simulator has no such thing; an error that says why.
        \\-:    the grammar has no rule; an error naming the dialects that have one.
        \\
    );
    return out.flush();
}

/// How dialect `g` says a kind, as `caps` prints it.
fn capMark(g: *const sprack.Grammar, info: sprack.schema.KindInfo) []const u8 {
    if (g.canWrite(info.kind)) return "yes";
    if (g.movedTo(info.kind) != null) return "param";
    if (g.absentReason(info.kind) != null) return "none";
    const has_master = sprack.schema.slotOf(info.kind, "master") != null;
    if (info.class == .device and g.canWrite(.instance) and has_master) return "inst";
    return "-";
}

/// The options and files after the subcommand. A wrong option is status 2.
fn parseArgs(io: std.Io, arena: Allocator, argv: []const []const u8) !Args {
    var args: Args = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const value: ?[]const u8 = if (i + 1 < argv.len) argv[i + 1] else null;
        if (flag(arg, "--from", "--from") and value != null) {
            args.from = value;
        } else if (flag(arg, "--to", "--to") and value != null) {
            args.to = value;
        } else if (flag(arg, "-o", "--out") and value != null) {
            args.out = value;
        } else if (flag(arg, "--provide", "--xyce-plugin") and value != null) {
            const eq = std.mem.indexOfScalar(u8, value.?, '=') orelse
                die(io, "{s} takes NAME=FILE\n", .{arg});
            try args.provided.append(arena, .{ value.?[0..eq], value.?[eq + 1 ..] });
        } else if (flag(arg, "--errata", "--errata") and value != null) {
            args.errata = value;
        } else if (flag(arg, "-j", "--jobs") and value != null) {
            args.jobs = std.fmt.parseInt(usize, value.?, 10) catch 0;
            if (args.jobs.? == 0) die(io, "{s} takes a number of files, 1 or more\n", .{arg});
        } else if (flag(arg, "--section", "--section") and value != null) {
            try args.sections.append(arena, value.?);
        } else if (flag(arg, "-D", "--define") and value != null) {
            const eq = std.mem.indexOfScalar(u8, value.?, '=') orelse
                die(io, "--define takes NAME=VALUE\n", .{});
            try args.vars.append(arena, .{ value.?[0..eq], value.?[eq + 1 ..] });
        } else {
            if (std.mem.eql(u8, arg, "--lib")) {
                args.library = true;
            } else if (arg.len > 1 and arg[0] == '-') {
                die(io, "unknown option '{s}'\n{s}", .{ arg, usage });
            } else try args.files.append(arena, arg);
            continue;
        }
        i += 1; // the option's value
    }
    assert(i >= argv.len);
    return args;
}

/// Is `arg` this option, under either of its two spellings?
fn flag(arg: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
}

/// The grammar an option names, or status 2 with what is wrong with it.
fn dialect(
    io: std.Io,
    arena: Allocator,
    name: ?[]const u8,
    option: []const u8,
) *const sprack.Grammar {
    const n = name orelse die(io, "{s} is required\n{s}", .{ option, usage });
    assert(option.len > 0);
    var diag: sprack.grammar.Diag = .{};
    return sprack.resolve(arena, io, n, &diag) catch |e| switch (e) {
        error.UnknownDialect => {
            var known: std.ArrayList(u8) = .empty;
            for (sprack.grammars) |*g| {
                known.print(arena, " {s}", .{g.name}) catch die(io, "out of memory\n", .{});
            }
            die(
                io,
                "unknown dialect '{s}'. Built in:{s}; or a path to a .spgrammar file\n",
                .{ n, known.items },
            );
        },
        error.CannotRead, error.BadGrammar, error.TooManyDialects => die(io, "{s}\n", .{diag.msg}),
        error.OutOfMemory => die(io, "out of memory\n", .{}),
    };
}

/// The netlist to work on: the first file named, or standard input.
fn readSource(io: std.Io, args: *const Args) []u8 {
    if (args.files.items.len == 0) {
        return readWhole(io, std.Io.File.stdin()) catch |e| refuse(io, "standard input", e);
    }
    const name = args.files.items[0];
    const file = std.Io.Dir.cwd().openFile(io, name, .{}) catch |e|
        die(io, "cannot read {s}: {s}\n", .{ name, @errorName(e) });
    defer file.close(io);
    return readWhole(io, file) catch |e| refuse(io, name, e);
}

/// An input not read: an entry, and status 1 when it was refused for what
/// it is (a device, too large), 2 when it could not be read at all.
fn refuse(io: std.Io, name: []const u8, e: anyerror) noreturn {
    assert(name.len > 0);
    switch (e) {
        error.NotARegularFile => {
            const why = "not a regular file or a pipe; not read";
            stderrLine(io, "{s}: error[invalid]: {s}\n", .{ name, why });
            std.process.exit(1);
        },
        error.FileTooBig => {
            stderrLine(
                io,
                "{s}: error[invalid]: larger than {d} MiB, the most an input may hold; not read\n",
                .{ name, ir.max_input >> 20 },
            );
            std.process.exit(1);
        },
        else => die(io, "cannot read {s}: {s}\n", .{ name, @errorName(e) }),
    }
}

/// All of `file`, in one buffer of its size where it has one: a buffer that
/// grows as it is read is there twice at its last step, and in an arena
/// every smaller one stays behind. The buffer is never freed: it is the
/// input, and lives as long as the process.
fn readWhole(io: std.Io, file: std.Io.File) ![]u8 {
    // tidy: allow(global-allocator-in-library) the input of the process, held until it exits
    const pages = std.heap.page_allocator;
    // A device (`/dev/zero`) is never done: only a file or a pipe is read.
    if (file.stat(io)) |st| switch (st.kind) {
        .file, .named_pipe, .unix_domain_socket, .unknown => {},
        else => return error.NotARegularFile,
    } else |_| {}
    var fr = file.reader(io, &.{});
    const size = fr.getSize() catch 0;
    if (size > ir.max_input) return error.FileTooBig;
    if (size == 0) {
        const limit: std.Io.Limit = .limited(ir.max_input);
        return fr.interface.allocRemaining(pages, limit) catch |e| switch (e) {
            error.ReadFailed => fr.err.?,
            error.StreamTooLong => error.FileTooBig,
            else => |x| x,
        };
    }
    // ponytail: a file that grows meanwhile is read to the size it had.
    const buf = try pages.alloc(u8, size);
    const read = fr.interface.readSliceShort(buf) catch return fr.err.?;
    assert(read <= size);
    return buf[0..read];
}

/// `project` and `catalog`: the files named and everything they include.
fn runProject(cli: *const Cli, gpa: Allocator, args: *Args, cmd: []const u8) !void {
    const io = cli.io;
    const arena = cli.arena;
    assert(cmd.len > 0);
    const listing = cmd[0] == 'c';
    if (args.files.items.len == 0) die(io, "{s} needs at least one file\n{s}", .{ cmd, usage });
    // Definitions on the command line win over the environment.
    var env_it = cli.environ.iterator();
    while (env_it.next()) |kv| try args.vars.append(arena, .{ kv.key_ptr.*, kv.value_ptr.* });
    const sum = try sprack.project.run(io, gpa, .{
        .from = dialect(io, arena, args.from, "--from"),
        .to = if (listing) null else dialect(io, arena, args.to, "--to"),
        .tops = args.files.items,
        .out_dir = if (listing)
            ""
        else
            args.out orelse die(io, "project needs --out <dir>\n{s}", .{usage}),
        .log = cli.err,
        .catalog = if (listing) cli.out else null,
        .caps = &sprack.caps,
        .vars = args.vars.items,
        .library = args.library or listing,
        .sections = args.sections.items,
        .provided = args.provided.items,
        .errata = if (args.errata) |path| try readErrata(io, arena, path) else &.{},
        .jobs = args.jobs orelse @min(std.Thread.getCpuCount() catch 1, max_jobs),
    });
    try cli.out.flush();
    try printSummary(cli.err, sum);
    if (sum.errors > 0) std.process.exit(1);
}

/// The errata of a PDK from the JSON file `--errata` names.
fn readErrata(io: std.Io, arena: Allocator, path: []const u8) ![]const sprack.project.Erratum {
    const cwd = std.Io.Dir.cwd();
    const text = cwd.readFileAlloc(io, path, arena, .limited(errata_bytes_max)) catch |e|
        die(io, "cannot read {s}: {s}\n", .{ path, @errorName(e) });
    return sprack.project.parseErrata(arena, text) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BadErrata => die(
            io,
            "{s}: errata are a list of {{file, was, read, why}}, or a manifest that holds one\n",
            .{path},
        ),
    };
}

/// `3 files, 0 errors, 1 warning`, and the included files not found.
fn printSummary(err: *Writer, sum: sprack.project.Summary) !void {
    try err.print("{d} file{s}, {d} error{s}, {d} warning{s}", .{
        sum.files,    plural(sum.files),
        sum.errors,   plural(sum.errors),
        sum.warnings, plural(sum.warnings),
    });
    if (sum.missing > 0) {
        try err.print(", {d} included file{s} not found", .{ sum.missing, plural(sum.missing) });
    }
    try err.writeByte('\n');
    try err.flush();
}

fn plural(count: usize) []const u8 {
    return if (count == 1) "" else "s";
}

/// `translate`: the netlist as dialect `--to`, a statement at a time.
fn runTranslate(
    cli: *const Cli,
    args: *const Args,
    src: []const u8,
    result: *Writer,
    report: *ir.Report,
) !void {
    assert(src.len <= ir.max_input);
    const gf = dialect(cli.io, cli.arena, args.from, "--from");
    const gt = dialect(cli.io, cli.arena, args.to, "--to");
    const options: sprack.stream.Options = .{ .whole = cli.whole(), .env = cli.plugins };
    const why = try sprack.stream.translate(
        cli.arena,
        gf,
        gt,
        src,
        result,
        report,
        &sprack.caps,
        options,
    );
    const reason = why orelse return;
    if (cli.environ.get("SPRACK_STREAM_WHY") == null) return;
    try cli.err.print("sprack: read whole: {s}\n", .{reason});
}

/// `audit`: translate, read our own output back with the target's reader,
/// and check it is still the same circuit. One TSV line; `same` may be 0
/// only when the report says why, else the status is 1 (#54).
fn runAudit(cli: *const Cli, args: *const Args, src: []const u8) !void {
    assert(src.len <= ir.max_input);
    const arena = cli.arena;
    const gf = dialect(cli.io, arena, args.from, "--from");
    const gt = dialect(cli.io, arena, args.to, "--to");
    // Its entries are made again by the translation.
    var read_report: ir.Report = .{ .arena = arena, .mute = true };
    const nl = try sprack.read(arena, gf, src, &read_report);
    // The text is translated as `translate` does, a statement at a time.
    var report: ir.Report = .init(arena);
    var written: Writer.Allocating = .init(arena);
    const options: sprack.stream.Options = .{ .whole = cli.whole(), .env = cli.plugins };
    _ = try sprack.stream.translate(
        arena,
        gf,
        gt,
        src,
        &written.writer,
        &report,
        &sprack.caps,
        options,
    );
    var report_back: ir.Report = .init(arena);
    const back = try sprack.read(arena, gt, written.written(), &report_back);
    const same = try sprack.sameTranslation(arena, gt, &nl, &back);

    try printAuditRow(cli, args.inputName(), .{ .nl = &nl, .back = &back, .same = same }, &report);
    if (same) return;
    var excused: usize = 0;
    inline for (excuse_codes) |code| excused += report.countCode(code);
    if (excused > 0) return;
    try cli.err.print(
        "{s}: the circuit read back from {s} is not the one read, and the report " ++
            "does not say why\n",
        .{ args.inputName(), gt.name },
    );
    try cli.err.flush();
    std.process.exit(1);
}

/// The audit's line: the counts `docs/src/cli.md` lists, tab-separated.
fn printAuditRow(cli: *const Cli, name: []const u8, audit: Audit, report: *const ir.Report) !void {
    assert(name.len > 0);
    const out = cli.out;
    var keys: std.StringArrayHashMapUnmanaged(usize) = .empty;
    try opaqueKeys(cli.arena, audit.nl.stmts, &keys);
    try out.print("{s}\t{d}\t{d}\t{d}\t{d}", .{
        name,
        ir.countStmts(audit.nl.stmts, null),
        ir.countStmts(audit.nl.stmts, .@"opaque"),
        @intFromBool(audit.same),
        report.count(.@"error"),
    });
    inline for (audit_codes) |code| try out.print("\t{d}", .{report.countCode(code)});
    try out.print("\t{d}\t", .{ir.countStmts(audit.back.stmts, .@"opaque")});
    for (keys.keys(), keys.values(), 0..) |k, v, n| {
        try out.print("{s}{s}:{d}", .{ if (n > 0) "," else "", k, v });
    }
    try out.writeByte('\n');
    try out.flush();
}

/// Counts the lines no rule read by their first word, at any depth.
// tidy: allow-fn(recursion) as deep as blocks nest, which the reader caps at ir.max_depth
fn opaqueKeys(
    arena: Allocator,
    stmts: []const ir.Stmt,
    keys: *std.StringArrayHashMapUnmanaged(usize),
) !void {
    for (stmts) |*s| {
        if (s.kind == .@"opaque") {
            var it = std.mem.tokenizeAny(u8, s.raw, " \t\r\n(=,");
            const first = it.next() orelse "";
            const key = try std.ascii.allocLowerString(arena, first[0..@min(first.len, 24)]);
            const gop = try keys.getOrPut(arena, key);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
        try opaqueKeys(arena, s.body, keys);
    }
}
