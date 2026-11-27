//! Project, pass two: each file read knowing the rest, and written into
//! the copy or listed in the catalogue.
//!
//! Contents:
//! - `pub fn outPath(r: *const Run, a: Allocator, root_dir: []const u8,
//!   path: []const u8) Allocator.Error![]const u8`
//! - `pub fn translateFile(r: *const Run, input: File, text: []const u8, report: *ir.Report,
//!   lines: *Lines, done: *Done) (Allocator.Error || Writer.Error)!void`
//! - `pub fn translateInto(r: *const Run, file: File,
//!   done: *Done) (Allocator.Error || Writer.Error)!void`
//! - `pub fn translateAll(r: *Run) (Allocator.Error || Writer.Error)!void`
//! - `pub fn process(r: *Run) (Allocator.Error || Writer.Error)!void`
//! - for `Ahead`, the slot of a file translated has `pub fn init`, `pub fn reset`,
//!   `pub fn deinit`

const std = @import("std");
const ir = @import("ir");
const reader = @import("reader");
const writer = @import("writer");
const stream = @import("stream");
const catalog = @import("catalog.zig");
const paths = @import("paths.zig");
const ahead_ = @import("ahead.zig");
const includes_ = @import("includes.zig");
const run_ = @import("run.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
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
const rewriteIncludes = includes_.rewriteIncludes;
const includes = includes_.includes;

/// What translating one file gives the run: the lines of its log,
/// their counts, and the `$NAME`s its include paths named.
const Done = struct {
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

/// Where the copy of `path` goes; its directory is made.
pub fn outPath(
    r: *const Run,
    a: Allocator,
    root_dir: []const u8,
    path: []const u8,
) Allocator.Error![]const u8 {
    const rel = try relative(a, root_dir, path);
    const out_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ r.opts.out_dir, rel });
    // tidy: allow(swallowed-error) a directory that cannot be made is said by the write into
    // it, which fails.
    std.Io.Dir.cwd().createDirPath(r.io, dirOf(out_path)) catch {};
    return out_path;
}

/// `text`, the text of `input`, translated straight into its copy; the
/// `$NAME`s its include lines name go to `done`, the scratch it needs is
/// `done`'s.
pub fn translateFile(
    r: *const Run,
    input: File,
    text: []const u8,
    report: *ir.Report,
    lines: *Lines,
    done: *Done,
) (Allocator.Error || Writer.Error)!void {
    // Only with a target: a catalogue alone reads.
    assert(r.opts.to != null);
    const a = done.scratch.allocator();
    const path = input.path;
    const library = input.library;
    const fresh = &done.fresh;
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
    try r.translateFile(file, text, &report, &lines, done);
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
        // tidy: allow(swallowed-error) a log line that cannot be written is let go: the
        // counts and the copy do not depend on the log.
        if (r.opts.log) |w| w.writeAll(done.log) catch {};
        r.sum.errors += done.errors;
        r.sum.warnings += done.warnings;
    }
}

/// Pass two: read each file knowing the rest, then write or list it.
pub fn process(r: *Run) (Allocator.Error || Writer.Error)!void {
    // Once a run: the root is the second pass's to find.
    assert(r.root_dir.len == 0);
    var present: std.ArrayList([]const u8) = .empty;
    for (r.files.items) |p| if (p.len > 0) try present.append(r.arena, p);
    const root_dir = try rootAndSources(r, present.items);
    r.sum.root_len = @min(root_dir.len, r.sum.root_buf.len);
    @memcpy(r.sum.root_buf[0..r.sum.root_len], root_dir[0..r.sum.root_len]);
    r.root_dir = root_dir;
    if (r.opts.to != null and r.opts.catalog == null) return r.translateAll();
    if (r.opts.catalog) |w| try w.writeAll("{\"devices\":[\n");
    for (r.files.items, 0..) |path, index| {
        if (path.len == 0) continue;
        try processFile(r, path, index, root_dir);
    }
    if (r.opts.catalog) |w| try catalog.catalogEnd(r, w, present.items, root_dir);
}

// ---- private ----

/// The directory the files of the run and the Verilog-A sources it names
/// have in common; the sources are copied below it (with a target).
fn rootAndSources(r: *Run, present: []const []const u8) Allocator.Error![]const u8 {
    // Verilog-A sources go into the copy too, at the same relative place.
    var sources: std.ArrayList([2][]const u8) = .empty;
    for (r.hdls.items) |h| {
        if (r.known.contains(h)) continue;
        const data = r.readFile(h, r.arena) orelse continue;
        try sources.append(r.arena, .{ h, data });
    }
    var rooted: std.ArrayList([]const u8) = .empty;
    try rooted.appendSlice(r.arena, present);
    if (r.opts.to != null) for (sources.items) |sv| try rooted.append(r.arena, sv[0]);
    const root_dir = try commonDir(r.arena, rooted.items);
    // `.` at the least: every copy has a directory to go below.
    assert(root_dir.len > 0);
    if (r.opts.to != null) for (sources.items) |sv| {
        const out_path = try std.fmt.allocPrint(
            r.arena,
            "{s}/{s}",
            .{ r.opts.out_dir, try relative(r.arena, root_dir, sv[0]) },
        );
        const cwd = std.Io.Dir.cwd();
        // tidy: allow(swallowed-error) a directory that cannot be made is said by the write
        // into it, which fails.
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
    return root_dir;
}

/// One file of the second pass, read whole: listed in the catalogue, and
/// with a target written into the copy.
fn processFile(
    r: *Run,
    path: []const u8,
    index: usize,
    root_dir: []const u8,
) (Allocator.Error || Writer.Error)!void {
    // A file the run could not read is "", and is not read again.
    assert(path.len > 0);
    var scratch_state: std.heap.ArenaAllocator = .init(r.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const text = r.readFile(path, scratch) orelse return;
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
            const in: Includes = .{ .r = r, .path = path, .dir = dirOf(path), .fresh = &fresh };
            try rewriteIncludes(&in, nl.stmts, scratch, &report);
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

fn translateOne(r: *const Run, file: File, done: *Done) void {
    r.translateInto(file, done) catch |e| {
        done.err = e;
    };
}

/// Is `d` an entry that says to translate another file too? Within a
/// project the other files are translated.
fn withinProject(d: ir.Diag) bool {
    return d.code == .caveat and std.mem.indexOf(u8, d.msg, "translate that file too") != null;
}
