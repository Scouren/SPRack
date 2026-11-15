//! The `sprack` command.

const std = @import("std");
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
    \\        followed to those named and the ones they name; the others
    \\        are listed as not followed.
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

fn die(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    fw.interface.print(fmt, args) catch {};
    fw.interface.flush() catch {};
    std.process.exit(2);
}

fn opaqueKeys(arena: std.mem.Allocator, stmts: []const ir.Stmt, keys: *std.StringArrayHashMapUnmanaged(usize)) !void {
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

const Args = struct {
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    out: ?[]const u8 = null,
    files: std.ArrayList([]const u8) = .empty,
    vars: std.ArrayList([2][]const u8) = .empty,
    library: bool = false,
    sections: std.ArrayList([]const u8) = .empty,
};

fn dialect(io: std.Io, arena: std.mem.Allocator, name: ?[]const u8, flag: []const u8) *const sprack.Grammar {
    const n = name orelse die(io, "{s} is required\n{s}", .{ flag, usage });
    var diag: sprack.grammar.Diag = .{};
    return sprack.resolve(arena, io, n, &diag) catch |e| switch (e) {
        error.UnknownDialect => {
            var known: std.ArrayList(u8) = .empty;
            for (&sprack.grammars) |*g| known.print(arena, " {s}", .{g.name}) catch {};
            die(io, "unknown dialect '{s}'. Built in:{s}; or a path to a .spgrammar file\n", .{ n, known.items });
        },
        error.CannotRead, error.BadGrammar, error.TooManyDialects => die(io, "{s}\n", .{diag.msg}),
        error.OutOfMemory => die(io, "out of memory\n", .{}),
    };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);

    var out_buf: [64 * 1024]u8 = undefined;
    var out_file = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_file.interface;
    var err_buf: [8 * 1024]u8 = undefined;
    var err_file = std.Io.File.stderr().writer(io, &err_buf);
    const err = &err_file.interface;

    if (argv.len < 2) die(io, "{s}", .{usage});
    const cmd = argv[1];

    if (std.mem.eql(u8, cmd, "dialects")) {
        for (&sprack.grammars) |*g| try out.print("{s}\n", .{g.name});
        return out.flush();
    }
    if (std.mem.eql(u8, cmd, "info")) {
        try sprack.json.writeInfo(out, &sprack.grammars);
        return out.flush();
    }
    if (std.mem.eql(u8, cmd, "caps")) {
        try out.print("{s:<12}", .{""});
        for (&sprack.grammars) |*g| try out.print("{s:<9}", .{g.name});
        try out.writeByte('\n');
        for (sprack.schema.table) |info| {
            if (info.kind == .@"opaque" or info.kind == .comment) continue;
            try out.print("{s:<12}", .{@tagName(info.kind)});
            for (&sprack.grammars) |*g| {
                const mark: []const u8 = if (g.canWrite(info.kind))
                    "yes"
                else if (g.movedTo(info.kind) != null)
                    "param"
                else if (g.absentReason(info.kind) != null)
                    "none"
                else if (info.class == .device and g.canWrite(.instance) and sprack.schema.slotIndex(info.kind, "master") != null)
                    "inst"
                else
                    "-";
                try out.print("{s:<9}", .{mark});
            }
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

    var a: Args = .{};
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const has_next = i + 1 < argv.len;
        if (std.mem.eql(u8, arg, "--from") and has_next) {
            i += 1;
            a.from = argv[i];
        } else if (std.mem.eql(u8, arg, "--to") and has_next) {
            i += 1;
            a.to = argv[i];
        } else if ((std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) and has_next) {
            i += 1;
            a.out = argv[i];
        } else if (std.mem.eql(u8, arg, "--lib")) {
            a.library = true;
        } else if (std.mem.eql(u8, arg, "--section") and has_next) {
            i += 1;
            try a.sections.append(arena, argv[i]);
        } else if ((std.mem.eql(u8, arg, "-D") or std.mem.eql(u8, arg, "--define")) and has_next) {
            i += 1;
            const eq = std.mem.indexOfScalar(u8, argv[i], '=') orelse die(io, "--define takes NAME=VALUE\n", .{});
            try a.vars.append(arena, .{ argv[i][0..eq], argv[i][eq + 1 ..] });
        } else if (arg.len > 1 and arg[0] == '-') {
            die(io, "unknown option '{s}'\n{s}", .{ arg, usage });
        } else try a.files.append(arena, arg);
    }
    const cwd = std.Io.Dir.cwd();

    if (std.mem.eql(u8, cmd, "project") or std.mem.eql(u8, cmd, "catalog")) {
        const listing = cmd[0] == 'c';
        if (a.files.items.len == 0) die(io, "{s} needs at least one file\n{s}", .{ cmd, usage });
        // Definitions on the command line win over the environment.
        var env_it = init.environ_map.iterator();
        while (env_it.next()) |kv| try a.vars.append(arena, .{ kv.key_ptr.*, kv.value_ptr.* });
        const sum = try sprack.project.run(io, init.gpa, .{
            .from = dialect(io, arena, a.from, "--from"),
            .to = if (listing) null else dialect(io, arena, a.to, "--to"),
            .tops = a.files.items,
            .out_dir = if (listing) "" else a.out orelse die(io, "project needs --out <dir>\n{s}", .{usage}),
            .log = err,
            .catalog = if (listing) out else null,
            .caps = &sprack.caps,
            .vars = a.vars.items,
            .library = a.library or listing,
            .sections = a.sections.items,
        });
        try out.flush();
        try err.print("{d} file{s}, {d} error{s}, {d} warning{s}", .{
            sum.files,    if (sum.files == 1) "" else "s",
            sum.errors,   if (sum.errors == 1) "" else "s",
            sum.warnings, if (sum.warnings == 1) "" else "s",
        });
        if (sum.missing > 0) try err.print(", {d} included file{s} not found", .{ sum.missing, if (sum.missing == 1) "" else "s" });
        try err.writeByte('\n');
        try err.flush();
        if (sum.errors > 0) std.process.exit(1);
        return;
    }

    const src = if (a.files.items.len > 0)
        cwd.readFileAlloc(io, a.files.items[0], arena, .unlimited) catch |e| die(io, "cannot read {s}: {s}\n", .{ a.files.items[0], @errorName(e) })
    else blk: {
        var in_buf: [64 * 1024]u8 = undefined;
        var in_file = std.Io.File.stdin().reader(io, &in_buf);
        break :blk try in_file.interface.allocRemaining(arena, .unlimited);
    };
    var report: ir.Report = .init(arena);
    // Read and write whole, never as a stream: to compare the two.
    const whole = init.environ_map.get("SPRACK_WHOLE") != null;

    if (std.mem.eql(u8, cmd, "audit")) {
        // Translate, read our own output back with the target's reader, and
        // check it is still the same circuit. `same` may be 0 only when the
        // report says why.
        const gf = dialect(io, arena, a.from, "--from");
        const gt = dialect(io, arena, a.to, "--to");
        // Its entries are made again by the translation.
        var read_report: ir.Report = .{ .arena = arena, .mute = true };
        const nl = try sprack.read(arena, gf, src, &read_report);
        // The text is translated as `translate` does, a statement at a time.
        var aw: std.Io.Writer.Allocating = .init(arena);
        _ = try sprack.stream.translate(arena, gf, gt, src, &aw.writer, &report, &sprack.caps, .{ .whole = whole });
        var report_back: ir.Report = .init(arena);
        const back = try sprack.read(arena, gt, aw.written(), &report_back);

        var keys: std.StringArrayHashMapUnmanaged(usize) = .empty;
        try opaqueKeys(arena, nl.stmts, &keys);
        try out.print("{s}\t{d}\t{d}\t{d}\t{d}", .{
            if (a.files.items.len > 0) a.files.items[0] else "-",
            ir.countStmts(nl.stmts, null),
            ir.countStmts(nl.stmts, .@"opaque"),
            @intFromBool(try sprack.sameTranslation(arena, gt, &nl, &back)),
            report.count(.@"error"),
        });
        inline for (.{ .untranslated, .unsupported, .loss, .synthesized, .caveat, .rename, .cosmetic, .invalid, .ambiguous, .oneway }) |code| {
            try out.print("\t{d}", .{report.countCode(code)});
        }
        try out.print("\t{d}\t", .{ir.countStmts(back.stmts, .@"opaque")});
        for (keys.keys(), keys.values(), 0..) |k, v, n| {
            try out.print("{s}{s}:{d}", .{ if (n > 0) "," else "", k, v });
        }
        try out.writeByte('\n');
        return out.flush();
    }

    // The result is streamed, not collected: a netlist can be very large.
    var file_buf: [64 * 1024]u8 = undefined;
    var dest_file: ?std.Io.File = null;
    var dest_writer: std.Io.File.Writer = undefined;
    var result: *std.Io.Writer = out;
    if (a.out) |path| {
        dest_file = cwd.createFile(io, path, .{}) catch |e| die(io, "cannot write {s}: {s}\n", .{ path, @errorName(e) });
        dest_writer = dest_file.?.writer(io, &file_buf);
        result = &dest_writer.interface;
    }
    if (std.mem.eql(u8, cmd, "translate")) {
        const gf = dialect(io, arena, a.from, "--from");
        const gt = dialect(io, arena, a.to, "--to");
        const why = try sprack.stream.translate(arena, gf, gt, src, result, &report, &sprack.caps, .{ .whole = whole });
        if (why) |w| if (init.environ_map.get("SPRACK_STREAM_WHY") != null) try err.print("sprack: read whole: {s}\n", .{w});
    } else if (std.mem.eql(u8, cmd, "read")) {
        const nl = try sprack.read(arena, dialect(io, arena, a.from, "--from"), src, &report);
        try sprack.json.writeNetlist(result, &nl);
    } else if (std.mem.eql(u8, cmd, "write")) {
        const nl = try sprack.json.parseNetlist(arena, src, &report);
        try sprack.write(arena, dialect(io, arena, a.to, "--to"), result, &nl, &report);
    } else die(io, "unknown command '{s}'\n{s}", .{ cmd, usage });
    try result.flush();
    if (dest_file) |f| f.close(io);
    try report.print(err);
    try err.flush();
    if (report.hasErrors()) std.process.exit(1);
}
