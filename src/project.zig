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

const std = @import("std");
const grammar = @import("grammar.zig");
const schema = @import("schema.zig");
const ir = @import("ir.zig");
const reader = @import("reader.zig");
const writer = @import("writer.zig");
const json = @import("json.zig");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Writer = std.Io.Writer;

pub const Summary = struct {
    files: usize = 0,
    errors: usize = 0,
    warnings: usize = 0,
    /// Included files that could not be opened.
    missing: usize = 0,
    /// The directory all files have in common. The translated copy
    /// reproduces the tree below it.
    root_buf: [1024]u8 = undefined,
    root_len: usize = 0,

    pub fn root(s: *const Summary) []const u8 {
        return s.root_buf[0..s.root_len];
    }
};

pub const Options = struct {
    from: *const Grammar,
    /// Null: read only (for a catalogue).
    to: ?*const Grammar = null,
    tops: []const []const u8,
    out_dir: []const u8 = "",
    /// One line per report entry, prefixed with the file it is about.
    log: ?*Writer = null,
    /// JSON list of every subcircuit and model the tree defines.
    catalog: ?*Writer = null,
    caps: ?*const writer.Caps = null,
    /// The files named are libraries themselves (a PDK), not netlists
    /// with a title line. Files reached through an include always are.
    library: bool = false,
    /// `$NAME` and `${NAME}` in include paths are replaced from here: the
    /// environment, or what a PDK manifest defines.
    vars: []const [2][]const u8 = &.{},
};

// ------------------------------------------------------------------- paths

/// Remove `.` and resolve `..` without touching the file system.
pub fn normalize(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    const absolute = path.len > 0 and path[0] == '/';
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..") and parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
            _ = parts.pop();
        } else if (std.mem.eql(u8, part, "..") and absolute) {
            continue;
        } else try parts.append(arena, part);
    }
    const joined = try std.mem.join(arena, "/", parts.items);
    if (absolute) return std.fmt.allocPrint(arena, "/{s}", .{joined});
    return if (joined.len == 0) "." else joined;
}

fn dirOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
    return if (slash == 0) "/" else path[0..slash];
}

pub fn resolve(arena: Allocator, base_dir: []const u8, path: []const u8) Allocator.Error![]const u8 {
    if (path.len > 0 and path[0] == '/') return normalize(arena, path);
    return normalize(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ base_dir, path }));
}

/// The path that leads from `from_dir` to `to`, both normalized.
pub fn relative(arena: Allocator, from_dir: []const u8, to: []const u8) Allocator.Error![]const u8 {
    var a = std.mem.tokenizeScalar(u8, from_dir, '/');
    var b = std.mem.tokenizeScalar(u8, to, '/');
    var out: std.ArrayList(u8) = .empty;
    while (true) {
        const save_a = a.index;
        const save_b = b.index;
        const x = a.next();
        const y = b.next();
        if (x != null and y != null and std.mem.eql(u8, x.?, y.?) and !std.mem.eql(u8, x.?, ".")) continue;
        a.index = save_a;
        b.index = save_b;
        break;
    }
    while (a.next()) |part| {
        if (!std.mem.eql(u8, part, ".")) try out.appendSlice(arena, "../");
    }
    try out.appendSlice(arena, b.rest());
    return out.items;
}

fn commonDir(arena: Allocator, paths: []const []const u8) Allocator.Error![]const u8 {
    if (paths.len == 0) return ".";
    var common = dirOf(paths[0]);
    for (paths[1..]) |p| {
        const d = dirOf(p);
        while (!(std.mem.eql(u8, common, d) or (std.mem.startsWith(u8, d, common) and d.len > common.len and (d[common.len] == '/' or std.mem.eql(u8, common, "/"))))) {
            if (std.mem.eql(u8, common, ".") or std.mem.eql(u8, common, "/")) break;
            common = dirOf(common);
            if (std.mem.eql(u8, common, ".")) break;
        }
    }
    return arena.dupe(u8, common);
}

// ----------------------------------------------------------------- project

const Run = struct {
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    opts: Options,
    files: std.ArrayList([]const u8) = .empty,
    known: std.StringHashMapUnmanaged(void) = .empty,
    env: ir.Env = .{},
    sum: Summary = .{},
    first_device: bool = true,
    cwd: []const u8 = ".",

    fn logLine(r: *Run, full: []const u8, d: ir.Diag) void {
        if (d.sev == .@"error") r.sum.errors += 1;
        if (d.sev == .warning) r.sum.warnings += 1;
        const w = r.opts.log orelse return;
        const under = full.len > r.cwd.len + 1 and std.mem.startsWith(u8, full, r.cwd) and full[r.cwd.len] == '/';
        const path = if (under) full[r.cwd.len + 1 ..] else full;
        if (d.line > 0) {
            w.print("{s}:{d}: {s}[{s}]: {s}\n", .{ path, d.line, @tagName(d.sev), @tagName(d.code), d.msg }) catch {};
        } else w.print("{s}: {s}[{s}]: {s}\n", .{ path, @tagName(d.sev), @tagName(d.code), d.msg }) catch {};
    }

    fn enqueue(r: *Run, path: []const u8) Allocator.Error!void {
        if (r.known.contains(path)) return;
        const own = try r.arena.dupe(u8, path);
        try r.known.put(r.arena, own, {});
        try r.files.append(r.arena, own);
    }

    fn pathOf(st: *const ir.Stmt) ?[]const u8 {
        if (st.kind != .include and st.kind != .lib) return null;
        const v = st.get("path");
        return if (v == .str) v.str else null;
    }

    fn expand(r: *Run, a: Allocator, path: []const u8) Allocator.Error![]const u8 {
        if (std.mem.indexOfScalar(u8, path, '$') == null) return path;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < path.len) {
            if (path[i] != '$') {
                try out.append(a, path[i]);
                i += 1;
                continue;
            }
            const braced = i + 1 < path.len and path[i + 1] == '{';
            const start = i + 1 + @intFromBool(braced);
            var j = start;
            while (j < path.len and (std.ascii.isAlphanumeric(path[j]) or path[j] == '_')) j += 1;
            const name = path[start..j];
            const value = for (r.opts.vars) |kv| {
                if (std.mem.eql(u8, kv[0], name)) break kv[1];
            } else null;
            if (braced and j < path.len and path[j] == '}') j += 1;
            try out.appendSlice(a, value orelse path[i..j]);
            i = j;
        }
        return out.items;
    }

    fn findIncludes(r: *Run, dir: []const u8, stmts: []const ir.Stmt, scratch: Allocator) Allocator.Error!void {
        for (stmts) |*st| {
            if (pathOf(st)) |p| try r.enqueue(try resolve(scratch, dir, try r.expand(scratch, p)));
            try r.findIncludes(dir, st.body, scratch);
        }
    }

    fn rewriteIncludes(r: *Run, dir: []const u8, stmts: []ir.Stmt, scratch: Allocator) Allocator.Error!void {
        for (stmts) |*st| {
            if (pathOf(st)) |p| {
                const target = try resolve(scratch, dir, try r.expand(scratch, p));
                st.vals[schema.slotIndex(st.kind, "path").?] = .{ .str = try relative(scratch, dir, target) };
            }
            try r.rewriteIncludes(dir, st.body, scratch);
        }
    }

    fn catalogParams(w: *Writer, ps: ir.Value, count: *usize) Writer.Error!void {
        if (ps != .params) return;
        for (ps.params) |p| {
            if (count.* > 0) try w.writeByte(',');
            count.* += 1;
            try w.print("{f}:", .{std.json.fmt(p.key, .{})});
            switch (p.val) {
                .num => |n| if (n.exp10 == 0) try w.print("\"{s}\"", .{n.digits()}) else try w.print("\"{s}e{d}\"", .{ n.digits(), n.exp10 }),
                .expr => |e| try w.print("{f}", .{std.json.fmt(e, .{})}),
                else => try w.writeAll("null"),
            }
        }
    }

    fn catalogStmts(r: *Run, w: *Writer, path: []const u8, section: []const u8, stmts: []const ir.Stmt) Writer.Error!void {
        for (stmts) |*st| {
            const name = st.get("name");
            switch (st.kind) {
                .libsection => {
                    try r.catalogStmts(w, path, if (name == .atom) name.atom else "", st.body);
                    continue;
                },
                .subckt, .model => {},
                else => continue,
            }
            if (name != .atom) continue;
            if (!r.first_device) try w.writeAll(",\n");
            r.first_device = false;
            try w.print("{{\"name\":{f},\"file\":{f},\"section\":{f}", .{ std.json.fmt(name.atom, .{}), std.json.fmt(path, .{}), std.json.fmt(section, .{}) });
            if (st.kind == .subckt) {
                try w.writeAll(",\"kind\":\"subckt\",\"ports\":[");
                const ports = st.get("ports");
                if (ports == .list) for (ports.list, 0..) |p, i| {
                    if (i > 0) try w.writeByte(',');
                    try w.print("{f}", .{std.json.fmt(if (p == .atom) p.atom else "", .{})});
                };
                try w.writeAll("],\"params\":{");
                // The header's parameters, then `.param` lines in the body:
                // PDKs converted from Spectre declare instance parameters there.
                var n_params: usize = 0;
                try catalogParams(w, st.get("params"), &n_params);
                for (st.body) |*child| {
                    if (child.kind == .param) try catalogParams(w, child.get("params"), &n_params);
                }
                try w.writeAll("}}");
            } else {
                const fam = st.get("family");
                const pol = st.get("polarity");
                const ty = st.get("type");
                const dev: []const u8 = if (fam == .atom) @tagName(schema.familyKind(fam.atom) orelse .device) else "device";
                try w.print(",\"kind\":\"model\",\"device\":\"{s}\",\"family\":{f},\"polarity\":{f},\"type\":{f}}}", .{
                    dev,
                    std.json.fmt(if (fam == .atom) fam.atom else "", .{}),
                    std.json.fmt(if (pol == .atom) pol.atom else "", .{}),
                    std.json.fmt(if (ty == .atom) ty.atom else "", .{}),
                });
            }
        }
    }

    /// Reading alone reports nothing about lines no rule understood; a
    /// catalogue should say how much of the library it could not read.
    fn noteOpaque(r: *Run, path: []const u8, stmts: []const ir.Stmt) void {
        for (stmts) |*st| {
            if (st.kind == .@"opaque") {
                var buf: [160]u8 = undefined;
                const first = std.mem.sliceTo(st.raw, '\n');
                const msg = std.fmt.bufPrint(&buf, "not understood: {s}", .{first[0..@min(first.len, 120)]}) catch "not understood";
                r.logLine(path, .{ .sev = .warning, .code = .untranslated, .line = st.line, .msg = msg });
            }
            r.noteOpaque(path, st.body);
        }
    }

    fn readFile(r: *Run, path: []const u8, a: Allocator) ?[]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(r.io, path, a, .unlimited) catch null;
    }

    /// Pass one: find every file and learn what each declares.
    fn discover(r: *Run) Allocator.Error!void {
        var i: usize = 0;
        while (i < r.files.items.len) : (i += 1) {
            const path = r.files.items[i];
            var scratch_state: std.heap.ArenaAllocator = .init(r.gpa);
            defer scratch_state.deinit();
            const scratch = scratch_state.allocator();
            const text = r.readFile(path, scratch) orelse {
                r.sum.missing += 1;
                r.logLine(path, .{ .sev = .@"error", .code = .invalid, .line = 0, .msg = "cannot open this file; it is included by the project" });
                // Keep the slot so indices stay stable, but mark it.
                r.files.items[i] = "";
                continue;
            };
            var report: ir.Report = .init(scratch);
            const nl = try reader.read(r.opts.from, scratch, text, &report, .{ .library = r.opts.library or i >= r.opts.tops.len });
            try r.env.absorb(r.arena, nl.stmts);
            try r.findIncludes(dirOf(path), nl.stmts, scratch);
        }
    }

    /// Pass two: read each file knowing the rest, then write or list it.
    fn process(r: *Run) (Allocator.Error || Writer.Error)!void {
        var present: std.ArrayList([]const u8) = .empty;
        for (r.files.items) |p| if (p.len > 0) try present.append(r.arena, p);
        const root_dir = try commonDir(r.arena, present.items);
        r.sum.root_len = @min(root_dir.len, r.sum.root_buf.len);
        @memcpy(r.sum.root_buf[0..r.sum.root_len], root_dir[0..r.sum.root_len]);
        if (r.opts.catalog) |w| try w.writeAll("{\"devices\":[\n");
        for (r.files.items, 0..) |path, index| {
            if (path.len == 0) continue;
            var scratch_state: std.heap.ArenaAllocator = .init(r.gpa);
            defer scratch_state.deinit();
            const scratch = scratch_state.allocator();
            const text = r.readFile(path, scratch) orelse continue;
            var report: ir.Report = .init(scratch);
            var nl = try reader.read(r.opts.from, scratch, text, &report, .{ .env = &r.env, .library = r.opts.library or index >= r.opts.tops.len });
            r.sum.files += 1;
            if (r.opts.catalog) |w| try r.catalogStmts(w, path, "", nl.stmts);
            if (r.opts.to == null) r.noteOpaque(path, nl.stmts);
            if (r.opts.to) |gt| {
                try r.rewriteIncludes(dirOf(path), nl.stmts, scratch);
                var aw: Writer.Allocating = .init(scratch);
                try writer.write(gt, scratch, &aw.writer, &nl, &report, r.opts.caps, &r.env);
                const rel = try relative(scratch, root_dir, path);
                const out_path = try std.fmt.allocPrint(scratch, "{s}/{s}", .{ r.opts.out_dir, rel });
                const cwd = std.Io.Dir.cwd();
                cwd.createDirPath(r.io, dirOf(out_path)) catch {};
                cwd.writeFile(r.io, .{ .sub_path = out_path, .data = aw.written() }) catch {
                    r.logLine(out_path, .{ .sev = .@"error", .code = .invalid, .line = 0, .msg = "cannot write this file" });
                };
            }
            for (report.items.items) |d| {
                // Within a project the other files are translated too.
                if (d.code == .caveat and std.mem.indexOf(u8, d.msg, "translate that file too") != null) continue;
                r.logLine(path, d);
            }
        }
        if (r.opts.catalog) |w| {
            try w.writeAll("\n],\"files\":[");
            for (present.items, 0..) |p, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{f}", .{std.json.fmt(p, .{})});
            }
            try w.print("],\"root\":{f},\"errors\":{d},\"warnings\":{d},\"missing\":{d}}}\n", .{
                std.json.fmt(root_dir, .{}), r.sum.errors, r.sum.warnings, r.sum.missing,
            });
        }
    }
};

pub fn run(io: std.Io, gpa: Allocator, opts: Options) (Allocator.Error || Writer.Error)!Summary {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var r: Run = .{ .gpa = gpa, .arena = arena_state.allocator(), .io = io, .opts = opts };
    // Absolute paths throughout, so files reached by different routes are
    // recognised as the same file.
    var buf: [4096]u8 = undefined;
    if (std.Io.Dir.cwd().realPath(io, &buf)) |n| {
        r.cwd = try r.arena.dupe(u8, buf[0..n]);
    } else |_| {}
    for (opts.tops) |t| try r.enqueue(try resolve(r.arena, r.cwd, t));
    try r.discover();
    try r.process();
    return r.sum;
}

test "paths" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("a/c", try normalize(a, "./a/b/../c"));
    try std.testing.expectEqualStrings("../x", try normalize(a, "../x"));
    try std.testing.expectEqualStrings("/pdk/models/n.lib", try resolve(a, "/pdk/libs", "../models/n.lib"));
    try std.testing.expectEqualStrings("../models/n.lib", try relative(a, "/pdk/libs", "/pdk/models/n.lib"));
    try std.testing.expectEqualStrings("n.lib", try relative(a, "pdk", "pdk/n.lib"));
    try std.testing.expectEqualStrings("sub/n.lib", try relative(a, ".", "sub/n.lib"));
    try std.testing.expectEqualStrings("/pdk", try commonDir(a, &.{ "/pdk/libs/a.lib", "/pdk/models/n.lib" }));
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
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "in/models/nch.mod", .data =
        \\* the model
        \\.model nch nmos level=54 vth0=0.4
        \\.include "missing.mod"
        \\
    });

    const reg = @import("registry");
    const hspice = grammar.compileBuiltin(reg.sources[0]);
    const spectre = grammar.compileBuiltin(reg.sources[2]);
    try std.testing.expectEqualStrings("hspice", hspice.name);
    try std.testing.expectEqualStrings("spectre", spectre.name);

    var log: Writer.Allocating = .init(a);
    const sum = try run(io, std.testing.allocator, .{
        .from = &hspice,
        .to = &spectre,
        .tops = &.{try std.fmt.allocPrint(a, "{s}/in/top.sp", .{base})},
        .out_dir = try std.fmt.allocPrint(a, "{s}/out", .{base}),
        .vars = &.{.{ "MODELS", "models" }},
        .log = &log.writer,
    });
    try std.testing.expectEqual(3, sum.files);
    try std.testing.expectEqual(1, sum.missing);
    try std.testing.expect(std.mem.indexOf(u8, log.written(), "missing.mod: error[invalid]: cannot open this file") != null);

    const top = try tmp.dir.readFileAlloc(io, "out/top.sp", a, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, top, "// Top netlist\nsimulator lang=spectre\nglobal 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, top, "include \"models/corners.lib\" section=tt\n") != null);
    // Recognised as a transistor of a model declared elsewhere in the project.
    try std.testing.expect(std.mem.indexOf(u8, top, "M1 (d g 0 0) nch w=1u l=1u\n") != null);
    const lib = try tmp.dir.readFileAlloc(io, "out/models/corners.lib", a, .unlimited);
    // An included file: no title, no `global`, but it does say its language.
    try std.testing.expect(std.mem.startsWith(u8, lib, "simulator lang=spectre\n// corners\nsection tt\ninclude \"nch.mod\"\nendsection tt\n"));
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
    try std.testing.expect(std.mem.indexOf(u8, cat.written(), "\"section\":\"\",\"kind\":\"model\",\"device\":\"mosfet\",\"family\":\"bsim4\",\"polarity\":\"n\"") != null);
}
