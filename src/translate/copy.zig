//! Project, pass two: each file read knowing the rest, and written into
//! the copy or listed in the catalogue.

const std = @import("std");
const ir = @import("ir");
const reader = @import("reader");
const writer = @import("writer");
const stream = @import("stream");
const json = @import("json");
const paths = @import("paths.zig");
const ahead_ = @import("ahead.zig");
const includes_ = @import("includes.zig");
const run_ = @import("run.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Run = run_.Run;
const Lines = Run.Lines;
const Fresh = Run.Fresh;
const File = ahead_.File;
const Ahead = ahead_.Ahead;
const slot_keep = ahead_.slot_keep;
const dirOf = paths.dirOf;
const relative = paths.relative;
const commonDir = paths.commonDir;
const Includes = includes_.Includes;
const includes = includes_.includes;

/// Where the copy of `path` goes; its directory is made.
pub fn outPath(
    r: *const Run,
    a: Allocator,
    root_dir: []const u8,
    path: []const u8,
) Allocator.Error![]const u8 {
    const rel = try relative(a, root_dir, path);
    const out_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ r.opts.out_dir, rel });
    std.Io.Dir.cwd().createDirPath(r.io, dirOf(out_path)) catch {};
    return out_path;
}

pub fn translateFile(
    r: *const Run,
    a: Allocator,
    path: []const u8,
    text: []const u8,
    report: *ir.Report,
    library: bool,
    lines: *Lines,
    fresh: *Fresh,
) (Allocator.Error || Writer.Error)!void {
    const out_path = try r.outPath(a, r.root_dir, path);
    var buf: [64 * 1024]u8 = undefined;
    var discard: Writer.Discarding = .init(&buf);
    const file: ?std.Io.File = std.Io.Dir.cwd().createFile(r.io, out_path, .{}) catch null;
    defer if (file) |f| f.close(r.io);
    var fw: std.Io.File.Writer = undefined;
    if (file) |f| fw = f.writer(r.io, &buf);
    const out: *Writer = if (file != null) &fw.interface else &discard.writer;
    var in: Includes = .{ .r = r, .path = path, .dir = dirOf(path), .fresh = fresh };
    const ok = if (stream.translate(a, r.opts.from, r.opts.to.?, text, out, report, r.opts.caps, .{
        .env = &r.env,
        .library = library,
        .hook = .{ .ctx = &in, .run = includes },
    })) |_| true else |e| switch (e) {
        error.WriteFailed => false,
        else => |x| return x,
    };
    var failed = file == null or !ok;
    if (!failed) out.flush() catch {
        failed = true;
    };
    if (failed)
        lines.add(
            out_path,
            .{ .sev = .@"error", .code = .invalid, .line = 0, .msg = "cannot write this file" },
        );
}

/// What translating one file gives the run: the lines of its log,
/// their counts, and the `$NAME`s its include paths named.
pub const Done = struct {
    /// What the run takes of the file lives here; what translating it
    /// needs and no one after, in `scratch`.
    arena: std.heap.ArenaAllocator,
    scratch: std.heap.ArenaAllocator,
    /// The file was there to read.
    read: bool,
    log: []const u8,
    errors: usize,
    warnings: usize,
    fresh: Fresh,
    err: ?(Allocator.Error || Writer.Error),

    pub fn init(d: *Done, gpa: Allocator) void {
        d.* = .{
            .arena = .init(gpa),
            .scratch = .init(gpa),
            .read = false,
            .log = "",
            .errors = 0,
            .warnings = 0,
            .fresh = undefined,
            .err = null,
        };
        d.fresh = .{ .arena = d.arena.allocator() };
    }

    pub fn reset(d: *Done) void {
        _ = d.arena.reset(.{ .retain_with_limit = slot_keep });
        _ = d.scratch.reset(.{ .retain_with_limit = slot_keep });
        d.read = false;
        d.log = "";
        d.errors = 0;
        d.warnings = 0;
        d.fresh = .{ .arena = d.arena.allocator() };
        d.err = null;
    }

    pub fn deinit(d: *Done) void {
        d.scratch.deinit();
        d.arena.deinit();
    }
};

pub fn translateOne(r: *const Run, file: File, done: *Done) void {
    r.translateInto(file, done) catch |e| {
        done.err = e;
    };
}

/// `file`, read and translated straight into the copy, a statement at
/// a time.
pub fn translateInto(
    r: *const Run,
    file: File,
    done: *Done,
) (Allocator.Error || Writer.Error)!void {
    const path = file.path;
    if (path.len == 0) return;
    const scratch = done.scratch.allocator();
    // What there is to say of reading it, the first pass said.
    const text = r.load(path, scratch).text orelse return;
    done.read = true;
    var report: ir.Report = .init(scratch);
    var log: Writer.Allocating = .init(done.arena.allocator());
    var lines: Lines = .{ .out = if (r.opts.log != null) &log.writer else null, .cwd = r.cwd };
    try r.translateFile(scratch, path, text, &report, file.library, &lines, &done.fresh);
    for (report.items.items) |d| {
        if (!withinProject(d)) lines.add(path, d);
    }
    done.log = log.written();
    done.errors = lines.errors;
    done.warnings = lines.warnings;
}

/// Every file translated into the copy, `opts.jobs` at once; what each
/// gives is taken in the order of the files.
pub fn translateAll(r: *Run) (Allocator.Error || Writer.Error)!void {
    var ahead: Ahead(Done, translateOne) = undefined;
    try ahead.init(r);
    defer ahead.deinit();
    while (ahead.next < r.files.items.len) {
        const done = ahead.take();
        defer ahead.release();
        if (done.err) |e| return e;
        if (!done.read) continue;
        r.sum.files += 1;
        try r.absorb(&done.fresh);
        if (r.opts.log) |w| w.writeAll(done.log) catch {};
        r.sum.errors += done.errors;
        r.sum.warnings += done.warnings;
    }
}

/// Pass two: read each file knowing the rest, then write or list it.
pub fn process(r: *Run) (Allocator.Error || Writer.Error)!void {
    var present: std.ArrayList([]const u8) = .empty;
    for (r.files.items) |p| if (p.len > 0) try present.append(r.arena, p);
    // Verilog-A sources go into the copy too, at the same relative place.
    var sources: std.ArrayList([2][]const u8) = .empty;
    for (r.hdls.items) |h| {
        if (r.known.contains(h)) continue;
        const data = r.readFile(h, r.arena) orelse continue;
        try sources.append(r.arena, .{ h, data });
    }
    var rooted: std.ArrayList([]const u8) = .empty;
    try rooted.appendSlice(r.arena, present.items);
    if (r.opts.to != null) for (sources.items) |sv| try rooted.append(r.arena, sv[0]);
    const root_dir = try commonDir(r.arena, rooted.items);
    if (r.opts.to != null) for (sources.items) |sv| {
        const out_path = try std.fmt.allocPrint(
            r.arena,
            "{s}/{s}",
            .{ r.opts.out_dir, try relative(r.arena, root_dir, sv[0]) },
        );
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(r.io, dirOf(out_path)) catch {};
        cwd.writeFile(r.io, .{ .sub_path = out_path, .data = sv[1] }) catch {
            r.logLine(
                out_path,
                .{
                    .sev = .@"error",
                    .code = .invalid,
                    .line = 0,
                    .msg = "cannot write this file",
                },
            );
        };
    };
    r.sum.root_len = @min(root_dir.len, r.sum.root_buf.len);
    @memcpy(r.sum.root_buf[0..r.sum.root_len], root_dir[0..r.sum.root_len]);
    r.root_dir = root_dir;
    if (r.opts.to != null and r.opts.catalog == null) return r.translateAll();
    if (r.opts.catalog) |w| try w.writeAll("{\"devices\":[\n");
    for (r.files.items, 0..) |path, index| {
        if (path.len == 0) continue;
        var scratch_state: std.heap.ArenaAllocator = .init(r.gpa);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        const text = r.readFile(path, scratch) orelse continue;
        var report: ir.Report = .init(scratch);
        const library = r.opts.library or index >= r.opts.tops.len;
        r.sum.files += 1;
        {
            var nl = try reader.read(
                r.opts.from,
                scratch,
                text,
                &report,
                .{ .env = &r.env, .library = library },
            );
            if (r.opts.catalog) |w| try r.catalogStmts(w, path, "", nl.stmts);
            if (r.opts.to == null) r.noteOpaque(path, nl.stmts);
            if (r.opts.to) |gt| {
                var fresh: Fresh = .{ .arena = scratch };
                try r.rewriteIncludes(path, dirOf(path), nl.stmts, scratch, &report, &fresh);
                try r.absorb(&fresh);
                var aw: Writer.Allocating = .init(scratch);
                try writer.write(.{
                    .g = gt,
                    .out = &aw.writer,
                    .report = &report,
                    .caps = r.opts.caps,
                    .env = &r.env,
                }, scratch, &nl);
                const out_path = try r.outPath(scratch, root_dir, path);
                std.Io.Dir.cwd().writeFile(
                    r.io,
                    .{ .sub_path = out_path, .data = aw.written() },
                ) catch {
                    r.logLine(
                        out_path,
                        .{
                            .sev = .@"error",
                            .code = .invalid,
                            .line = 0,
                            .msg = "cannot write this file",
                        },
                    );
                };
            }
        }
        for (report.items.items) |d| {
            if (!withinProject(d)) r.logLine(path, d);
        }
    }
    if (r.opts.catalog) |w| {
        try w.writeAll("\n],\"files\":[");
        for (present.items, 0..) |p, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{f}", .{std.json.fmt(p, .{})});
        }
        try w.writeAll("],\"sections\":[");
        for (r.sections.items, 0..) |sec, i| {
            if (i > 0) try w.writeByte(',');
            try w.print(
                "{{\"file\":{f},\"name\":{f}}}",
                .{ std.json.fmt(sec.path, .{}), std.json.fmt(sec.section, .{}) },
            );
        }
        try w.writeAll("],\"env\":");
        try json.writeEnv(w, &r.env);
        try w.writeAll(",\"vars\":");
        try r.writeExpanded(w);
        try w.print(",\"root\":{f},\"errors\":{d},\"warnings\":{d},\"missing\":{d}}}\n", .{
            std.json.fmt(root_dir, .{}), r.sum.errors, r.sum.warnings, r.sum.missing,
        });
    }
}

/// Is `d` an entry that says to translate another file too? Within a
/// project the other files are translated.
pub fn withinProject(d: ir.Diag) bool {
    return d.code == .caveat and std.mem.indexOf(u8, d.msg, "translate that file too") != null;
}
