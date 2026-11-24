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
const stream = @import("stream.zig");
const json = @import("json.zig");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Writer = std.Io.Writer;
const windows = @import("builtin").os.tag == .windows;

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
    /// Library sections to follow (`tt`): a section of a top file, or of a
    /// file reached by `.lib file name`, is followed only if it is named
    /// here or by a `.lib` line in what is followed. Empty: every one.
    sections: []const []const u8 = &.{},
    /// Written at the end: a JSON object of every `$NAME` an include path
    /// named and what it was replaced by (null: `vars` does not define it).
    /// Another value would reach other files, so a kept result is good
    /// only while these are the same. A catalogue says it as its `vars`.
    expanded: ?*Writer = null,
    /// Lines a PDK ships that its own simulator refuses, and what to read
    /// instead (a manifest's `errata`).
    errata: []const Erratum = &.{},
};

/// `was`, whole lines of a file whose path ends in `file`, is read as
/// `read`: a line the PDK's own simulator refuses (`why`).
pub const Erratum = struct { file: []const u8, was: []const u8, read: []const u8, why: []const u8 = "" };

/// Errata from JSON: a list of `{file, was, read, why}`, or an object that
/// holds one under `errata` (a PDK manifest).
pub fn parseErrata(arena: Allocator, text: []const u8) error{ OutOfMemory, BadErrata }![]const Erratum {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return error.BadErrata;
    const list = switch (v) {
        .array => |a| a,
        .object => |o| if (o.get("errata")) |e| (if (e == .array) e.array else return error.BadErrata) else return &.{},
        else => return error.BadErrata,
    };
    var out: std.ArrayList(Erratum) = .empty;
    for (list.items) |it| {
        if (it != .object) return error.BadErrata;
        const get = struct {
            fn f(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
                const x = o.get(k) orelse return null;
                return if (x == .string) x.string else null;
            }
        }.f;
        try out.append(arena, .{
            .file = get(it.object, "file") orelse return error.BadErrata,
            .was = get(it.object, "was") orelse return error.BadErrata,
            .read = get(it.object, "read") orelse return error.BadErrata,
            .why = get(it.object, "why") orelse "",
        });
    }
    return out.items;
}

/// Where `was` stands in `text` as whole lines, from `from` on.
fn wholeLines(text: []const u8, was: []const u8, from: usize) ?usize {
    var i = from;
    while (std.mem.indexOfPos(u8, text, i, was)) |at| : (i = at + 1) {
        const starts = at == 0 or text[at - 1] == '\n';
        const end = at + was.len;
        const ends = end == text.len or text[end] == '\n' or text[end] == '\r';
        if (starts and ends) return at;
    }
    return null;
}

// ------------------------------------------------------------------- paths

/// How much of `path` is its root: `/`, and on Windows also `C:/` and the
/// `//` of a network share. Nothing for a relative path.
fn rootLen(path: []const u8) usize {
    if (windows) {
        if (path.len >= 3 and path[1] == ':' and path[2] == '/') return 3;
        if (std.mem.startsWith(u8, path, "//")) return 2;
    }
    return @intFromBool(path.len > 0 and path[0] == '/');
}

/// Remove `.` and resolve `..` without touching the file system.
pub fn normalize(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    const root = path[0..rootLen(path)];
    const absolute = root.len > 0;
    var it = std.mem.tokenizeScalar(u8, path[root.len..], '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..") and parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
            _ = parts.pop();
        } else if (std.mem.eql(u8, part, "..") and absolute) {
            continue;
        } else try parts.append(arena, part);
    }
    const joined = try std.mem.join(arena, "/", parts.items);
    if (absolute) return std.fmt.allocPrint(arena, "{s}{s}", .{ root, joined });
    return if (joined.len == 0) "." else joined;
}

fn dirOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
    const root = rootLen(path);
    return if (slash < root) path[0..root] else path[0..slash];
}

/// `path` as an absolute, normalized path: itself, or under `base_dir`.
/// Every path comes in through here, and on Windows leaves written with
/// `/`, which Windows takes as well as `\`: the rest of this file, and the
/// include lines of a translated copy, know one separator.
pub fn resolve(arena: Allocator, base_dir: []const u8, path: []const u8) Allocator.Error![]const u8 {
    const p = if (windows) try arena.dupe(u8, path) else path;
    if (windows) std.mem.replaceScalar(u8, p, '\\', '/');
    if (rootLen(p) > 0) return normalize(arena, p);
    return normalize(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ base_dir, p }));
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

// ponytail: files on two Windows drives have no common directory; the first
// file's drive is taken, and a file on another is reported as not written.
// A copy tree per drive if a PDK ever spans two.
fn commonDir(arena: Allocator, paths: []const []const u8) Allocator.Error![]const u8 {
    if (paths.len == 0) return ".";
    var common = dirOf(paths[0]);
    for (paths[1..]) |p| {
        const d = dirOf(p);
        while (!(std.mem.eql(u8, common, d) or (std.mem.startsWith(u8, d, common) and d.len > common.len and (d[common.len] == '/' or common.len == rootLen(common))))) {
            if (std.mem.eql(u8, common, ".") or common.len == rootLen(common)) break;
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
    /// How each file spells its sections, by `path NUL lower-case name`:
    /// a reference spelled `typ` to a section `Typ` is written `Typ`.
    spellings: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Every section a file defines, in the order read.
    sections: std.ArrayList(Ref) = .empty,
    /// Verilog-A sources named by `.hdl`, copied into the translated tree.
    hdls: std.ArrayList([]const u8) = .empty,
    /// The sections to follow; null: all of them.
    wanted: ?ir.CaselessSet = null,
    skipped: std.ArrayList(Skipped) = .empty,
    /// Directories an include not found beside its file is looked up in
    /// (HSPICE `.option search='dir'`), absolute.
    search: std.ArrayList([]const u8) = .empty,
    /// Why the last file `readFile` gave nothing was refused; empty: it
    /// could not be opened.
    refusal: []const u8 = "",
    /// For each erratum: a file it names was read, and its text found there.
    errata_seen: []bool = &.{},
    errata_found: []bool = &.{},
    /// `path NUL index` of each erratum said, so each is said once.
    errata_said: std.StringHashMapUnmanaged(void) = .empty,
    /// Every `$NAME` an include path named, with the value it was given.
    expanded: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty,

    /// A section not followed (yet): what following it would reach.
    const Skipped = struct { path: []const u8, name: []const u8, refs: []const Ref, released: bool = false };
    const Ref = struct { path: []const u8, section: []const u8 };

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
            if (name.len > 0 and !r.expanded.contains(name)) try r.expanded.put(r.arena, try r.arena.dupe(u8, name), value);
            if (braced and j < path.len and path[j] == '}') j += 1;
            try out.appendSlice(a, value orelse path[i..j]);
            i = j;
        }
        return out.items;
    }

    /// The file an include names: beside the including file, else in the
    /// first search directory that has it.
    fn locate(r: *Run, scratch: Allocator, dir: []const u8, path: []const u8) Allocator.Error![]const u8 {
        const p = try r.expand(scratch, path);
        const here = try resolve(scratch, dir, p);
        if (r.search.items.len == 0 or std.fs.path.isAbsolute(p) or exists(r, here)) return here;
        for (r.search.items) |sd| {
            const there = try resolve(scratch, sd, p);
            if (exists(r, there)) return there;
        }
        return here;
    }

    fn writeExpanded(r: *const Run, w: *Writer) Writer.Error!void {
        try w.writeByte('{');
        for (r.expanded.keys(), r.expanded.values(), 0..) |name, value, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{f}:{f}", .{ std.json.fmt(name, .{}), std.json.fmt(value, .{}) });
        }
        try w.writeByte('}');
    }

    fn exists(r: *Run, path: []const u8) bool {
        return if (std.Io.Dir.cwd().access(r.io, path, .{})) |_| true else |_| false;
    }

    fn noteSearch(r: *Run, dir: []const u8, st: *const ir.Stmt) Allocator.Error!void {
        if (st.kind != .options or st.get("search") != .str) return;
        const sd = try resolve(r.arena, dir, try r.expand(r.arena, st.get("search").str));
        for (r.search.items) |x| if (std.mem.eql(u8, x, sd)) return;
        try r.search.append(r.arena, sd);
    }

    fn sectionOf(st: *const ir.Stmt) []const u8 {
        const v = st.get("section");
        return if (v == .atom) v.atom else "";
    }

    fn spellingKey(a: Allocator, path: []const u8, name: []const u8) Allocator.Error![]const u8 {
        const k = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ path, name });
        _ = std.ascii.lowerString(k[path.len + 1 ..], name);
        return k;
    }

    fn findIncludes(r: *Run, file: []const u8, stmts: []const ir.Stmt, scratch: Allocator) Allocator.Error!void {
        const dir = dirOf(file);
        for (stmts) |*st| {
            if (st.kind == .libsection and st.get("name") == .atom) {
                const name = st.get("name").atom;
                const key = try spellingKey(r.arena, file, name);
                if (!r.spellings.contains(key)) {
                    const own = try r.arena.dupe(u8, name);
                    try r.spellings.put(r.arena, key, own);
                    try r.sections.append(r.arena, .{ .path = file, .section = own });
                }
                if (r.wanted) |*w| if (!w.contains(name)) {
                    var refs: std.ArrayList(Ref) = .empty;
                    try r.collectRefs(dir, st.body, scratch, &refs);
                    try r.skipped.append(r.arena, .{ .path = file, .name = try r.arena.dupe(u8, name), .refs = refs.items });
                    continue;
                };
            }
            try r.noteSearch(dir, st);
            if (pathOf(st)) |p| {
                try r.enqueue(try r.locate(scratch, dir, p));
                if (st.kind == .lib) try r.want(sectionOf(st));
            }
            if (st.kind == .hdl and st.get("path") == .str) {
                const target = try r.locate(scratch, dir, st.get("path").str);
                for (r.hdls.items) |h| {
                    if (std.mem.eql(u8, h, target)) break;
                } else try r.hdls.append(r.arena, try r.arena.dupe(u8, target));
            }
            try r.findIncludes(file, st.body, scratch);
        }
    }

    /// What a skipped section would reach, to follow if it is named later.
    fn collectRefs(r: *Run, dir: []const u8, stmts: []const ir.Stmt, scratch: Allocator, out: *std.ArrayList(Ref)) Allocator.Error!void {
        for (stmts) |*st| {
            if (pathOf(st)) |p| try out.append(r.arena, .{
                .path = try r.arena.dupe(u8, try r.locate(scratch, dir, p)),
                .section = try r.arena.dupe(u8, if (st.kind == .lib) sectionOf(st) else ""),
            });
            try r.collectRefs(dir, st.body, scratch, out);
        }
    }

    /// A section named by a followed `.lib` line is followed wherever it is.
    fn want(r: *Run, name: []const u8) Allocator.Error!void {
        const w = if (r.wanted) |*w| w else return;
        if (name.len == 0 or w.contains(name)) return;
        try w.put(r.arena, try r.arena.dupe(u8, name), {});
        for (r.skipped.items) |*sk| {
            if (sk.released or !std.ascii.eqlIgnoreCase(sk.name, name)) continue;
            sk.released = true;
            for (sk.refs) |ref| {
                try r.enqueue(ref.path);
                try r.want(ref.section);
            }
        }
    }

    /// A section of `path` not followed, where the target opens the
    /// includes of every section (`libsections opened`): its includes would
    /// name files the copy has not.
    fn emptied(r: *const Run, path: []const u8, st: *const ir.Stmt) bool {
        const gt = r.opts.to orelse return false;
        if (gt.libsections_opened.len == 0 or st.kind != .libsection or st.get("name") != .atom) return false;
        for (r.skipped.items) |sk| {
            if (!sk.released and std.mem.eql(u8, sk.path, path) and std.ascii.eqlIgnoreCase(sk.name, st.get("name").atom)) return true;
        }
        return false;
    }

    /// The includes of an emptied section, as comments.
    fn commentIncludes(scratch: Allocator, stmts: []ir.Stmt, n: *usize) Allocator.Error!void {
        for (stmts) |*st| {
            if (pathOf(st)) |p| {
                const sec = sectionOf(st);
                const raw = try std.fmt.allocPrint(scratch, "[sprack] not in this copy: {s} \"{s}\"{s}{s}", .{ @tagName(st.kind), p, if (sec.len > 0) " " else "", sec });
                st.* = .{ .kind = .comment, .raw = raw, .line = st.line };
                n.* += 1;
                continue;
            }
            try commentIncludes(scratch, st.body, n);
        }
    }

    fn rewriteIncludes(r: *Run, path_of_file: []const u8, dir: []const u8, stmts: []ir.Stmt, scratch: Allocator, report: *ir.Report) Allocator.Error!void {
        for (stmts) |*st| {
            if (r.emptied(path_of_file, st)) {
                var n: usize = 0;
                try commentIncludes(scratch, st.body, &n);
                if (n > 0) report.add(.warning, .caveat, st.line, "section '{s}' is not followed, and {s} opens the includes of every section of a library: its includes are left out of this copy as comments ({d}), so the section is empty here ({s})", .{
                    st.get("name").atom, r.opts.to.?.name, n, r.opts.to.?.libsections_opened,
                });
                continue;
            }
            // Every include is rewritten to the copy it resolved to, so the
            // search directories are no longer needed.
            if (st.kind == .options and st.get("search") != .none) {
                try st.own(scratch);
                try st.set(scratch, schema.slotIndex(.options, "search").?, .none);
                report.add(.info, .cosmetic, st.line, "options.search: the includes it finds are written as paths to their translated copies", .{});
            }
            const p = pathOf(st) orelse if (st.kind == .hdl and st.get("path") == .str) st.get("path").str else null;
            if (p) |path| {
                const target = try r.locate(scratch, dir, path);
                try st.own(scratch);
                try st.set(scratch, schema.slotIndex(st.kind, "path").?, .{ .str = try relative(scratch, dir, target) });
                // The section as the file that defines it spells it.
                const sec = sectionOf(st);
                if (st.kind == .lib and sec.len > 0) {
                    if (r.spellings.get(try spellingKey(scratch, target, sec))) |sp| {
                        try st.set(scratch, schema.slotIndex(.lib, "section").?, .{ .atom = sp });
                    }
                }
            }
            try r.rewriteIncludes(path_of_file, dir, st.body, scratch, report);
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

    /// Where the copy of `path` goes; its directory is made.
    fn outPath(r: *Run, a: Allocator, root_dir: []const u8, path: []const u8) Allocator.Error![]const u8 {
        const rel = try relative(a, root_dir, path);
        const out_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ r.opts.out_dir, rel });
        std.Io.Dir.cwd().createDirPath(r.io, dirOf(out_path)) catch {};
        return out_path;
    }

    const Includes = struct { r: *Run, path: []const u8, dir: []const u8 };

    fn includes(ctx: *anyopaque, a: Allocator, stmts: []ir.Stmt, report: *ir.Report) Allocator.Error!void {
        const in: *Includes = @ptrCast(@alignCast(ctx));
        try in.r.rewriteIncludes(in.path, in.dir, stmts, a, report);
    }

    fn translateFile(r: *Run, a: Allocator, path: []const u8, root_dir: []const u8, text: []const u8, report: *ir.Report, library: bool) (Allocator.Error || Writer.Error)!void {
        const out_path = try r.outPath(a, root_dir, path);
        var buf: [64 * 1024]u8 = undefined;
        var discard: Writer.Discarding = .init(&buf);
        const file: ?std.Io.File = std.Io.Dir.cwd().createFile(r.io, out_path, .{}) catch null;
        defer if (file) |f| f.close(r.io);
        var fw: std.Io.File.Writer = undefined;
        if (file) |f| fw = f.writer(r.io, &buf);
        const out: *Writer = if (file != null) &fw.interface else &discard.writer;
        var in: Includes = .{ .r = r, .path = path, .dir = dirOf(path) };
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
        if (failed) r.logLine(out_path, .{ .sev = .@"error", .code = .invalid, .line = 0, .msg = "cannot write this file" });
    }

    /// The text of an input file; null when it cannot be read, or is
    /// refused (`refusal` says why): not a regular file, or larger than
    /// `ir.max_input`.
    fn readFile(r: *Run, path: []const u8, a: Allocator) ?[]const u8 {
        r.refusal = "";
        const st = std.Io.Dir.cwd().statFile(r.io, path, .{}) catch return null;
        if (st.kind != .file) {
            r.refusal = "not a regular file; not read";
            return null;
        }
        if (st.size > ir.max_input) {
            r.refusal = std.fmt.comptimePrint("larger than {d} MiB, the most an input may hold; not read", .{ir.max_input >> 20});
            return null;
        }
        const text = std.Io.Dir.cwd().readFileAlloc(r.io, path, a, .limited(ir.max_input)) catch return null;
        return r.applyErrata(path, text, a) catch null;
    }

    /// `text`, the file at `path`, with its errata read in: one caveat each.
    fn applyErrata(r: *Run, path: []const u8, text_in: []const u8, a: Allocator) Allocator.Error![]const u8 {
        var text = text_in;
        for (r.opts.errata, 0..) |e, i| {
            if (!std.mem.endsWith(u8, path, e.file)) continue;
            r.errata_seen[i] = true;
            const at = wholeLines(text, e.was, 0) orelse continue;
            r.errata_found[i] = true;
            const line = std.mem.count(u8, text[0..at], "\n") + 1;
            text = try std.mem.concat(a, u8, &.{ text[0..at], e.read, text[at + e.was.len ..] });
            const key = try std.fmt.allocPrint(r.arena, "{s}\x00{d}", .{ path, i });
            if (r.errata_said.contains(key)) continue;
            try r.errata_said.put(r.arena, key, {});
            const msg = try std.fmt.allocPrint(r.arena, "read through an erratum of the PDK: '{s}'{s}{s}; read as '{s}'", .{
                std.mem.sliceTo(e.was, '\n'), if (e.why.len > 0) ": " else "", e.why, std.mem.sliceTo(e.read, '\n'),
            });
            r.logLine(path, .{ .sev = .warning, .code = .caveat, .line = @intCast(line), .msg = msg });
        }
        return text;
    }

    /// An erratum whose file was read and whose text is not in it: the PDK
    /// has changed, and the erratum can go.
    fn staleErrata(r: *Run) Allocator.Error!void {
        for (r.opts.errata, r.errata_seen, r.errata_found) |e, seen, found| {
            if (!seen or found) continue;
            const msg = try std.fmt.allocPrint(r.arena, "the PDK's erratum for this file no longer applies: '{s}' is not in it", .{std.mem.sliceTo(e.was, '\n')});
            r.logLine(e.file, .{ .sev = .info, .code = .cosmetic, .line = 0, .msg = msg });
        }
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
                r.logLine(path, .{ .sev = .@"error", .code = .invalid, .line = 0, .msg = if (r.refusal.len > 0) r.refusal else "cannot open this file; it is included by the project" });
                // Keep the slot so indices stay stable, but mark it.
                r.files.items[i] = "";
                continue;
            };
            var report: ir.Report = .init(scratch);
            const nl = try reader.read(r.opts.from, scratch, text, &report, .{ .library = r.opts.library or i >= r.opts.tops.len });
            try r.env.absorb(r.arena, nl.stmts);
            // "": every name is copied, as `text` goes away with the statements.
            if (r.opts.to) |gt| try writer.collectReserved(r.arena, gt, nl.stmts, &r.env.params, "");
            try r.findIncludes(path, nl.stmts, scratch);
        }
        // A section asked for by name that no file defines: nothing of it
        // is in the result, and what references it will not find it.
        for (r.opts.sections) |sec| {
            for (r.sections.items) |s| {
                if (std.ascii.eqlIgnoreCase(s.section, sec)) break;
            } else {
                var buf: [200]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "section '{s}' is asked for, but no file read defines it", .{sec[0..@min(sec.len, 60)]}) catch "a section asked for is not defined";
                r.logLine(if (r.opts.tops.len > 0) r.opts.tops[0] else "", .{ .sev = .@"error", .code = .invalid, .line = 0, .msg = msg });
            }
        }
        for (r.skipped.items) |sk| {
            if (sk.released) continue;
            var buf: [200]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "section '{s}' not followed: it is not among the sections asked for, so the files it includes are not translated", .{sk.name[0..@min(sk.name.len, 60)]}) catch "a section not followed";
            r.logLine(sk.path, .{ .sev = .info, .code = .cosmetic, .line = 0, .msg = msg });
        }
    }

    /// Pass two: read each file knowing the rest, then write or list it.
    fn process(r: *Run) (Allocator.Error || Writer.Error)!void {
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
            const out_path = try std.fmt.allocPrint(r.arena, "{s}/{s}", .{ r.opts.out_dir, try relative(r.arena, root_dir, sv[0]) });
            const cwd = std.Io.Dir.cwd();
            cwd.createDirPath(r.io, dirOf(out_path)) catch {};
            cwd.writeFile(r.io, .{ .sub_path = out_path, .data = sv[1] }) catch {
                r.logLine(out_path, .{ .sev = .@"error", .code = .invalid, .line = 0, .msg = "cannot write this file" });
            };
        };
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
            const library = r.opts.library or index >= r.opts.tops.len;
            r.sum.files += 1;
            if (r.opts.to != null and r.opts.catalog == null) {
                // Translated a statement at a time, straight into the copy.
                try r.translateFile(scratch, path, root_dir, text, &report, library);
            } else {
                var nl = try reader.read(r.opts.from, scratch, text, &report, .{ .env = &r.env, .library = library });
                if (r.opts.catalog) |w| try r.catalogStmts(w, path, "", nl.stmts);
                if (r.opts.to == null) r.noteOpaque(path, nl.stmts);
                if (r.opts.to) |gt| {
                    try r.rewriteIncludes(path, dirOf(path), nl.stmts, scratch, &report);
                    var aw: Writer.Allocating = .init(scratch);
                    try writer.write(gt, scratch, &aw.writer, &nl, &report, r.opts.caps, &r.env);
                    const out_path = try r.outPath(scratch, root_dir, path);
                    std.Io.Dir.cwd().writeFile(r.io, .{ .sub_path = out_path, .data = aw.written() }) catch {
                        r.logLine(out_path, .{ .sev = .@"error", .code = .invalid, .line = 0, .msg = "cannot write this file" });
                    };
                }
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
            try w.writeAll("],\"sections\":[");
            for (r.sections.items, 0..) |sec, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{{\"file\":{f},\"name\":{f}}}", .{ std.json.fmt(sec.path, .{}), std.json.fmt(sec.section, .{}) });
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
};

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
    if (opts.sections.len > 0) {
        r.wanted = .empty;
        for (opts.sections) |sec| try r.wanted.?.put(r.arena, sec, {});
    }
    r.errata_seen = try r.arena.alloc(bool, opts.errata.len);
    r.errata_found = try r.arena.alloc(bool, opts.errata.len);
    @memset(r.errata_seen, false);
    @memset(r.errata_found, false);
    for (opts.tops) |t| try r.enqueue(try resolve(r.arena, r.cwd, t));
    try r.discover();
    try r.process();
    try r.staleErrata();
    if (opts.expanded) |w| try r.writeExpanded(w);
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

test "errata: a line the PDK's own simulator refuses is read as the manifest says, once" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "in/cells");
    try tmp.dir.writeFile(io, .{ .sub_path = "in/lib.spice", .data = "* lib\n.include \"cells/r.spice\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "in/cells/r.spice", .data = "* cell\n.subckt rr a b\nres a b rm r = 1k tc1r = 1m\n.ends\n" });
    const errata = try parseErrata(a,
        \\{"name": "x", "errata": [
        \\  {"file": "cells/r.spice", "was": "res a b rm r = 1k tc1r = 1m", "read": "Rres a b rm r = 1k tc1 = 1m", "why": "a switch to ngspice"},
        \\  {"file": "cells/r.spice", "was": "gone a b 1k", "read": "Rgone a b 1k"}
        \\]}
    );
    try std.testing.expectEqual(2, errata.len);
    const ngspice = @import("root.zig").find("ngspice").?.*;
    const xyce = @import("root.zig").find("xyce").?.*;
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
    try std.testing.expectEqual(1, std.mem.count(u8, log.written(), "r.spice:3: warning[caveat]: read through an erratum of the PDK: 'res a b rm r = 1k tc1r = 1m': a switch to ngspice; read as 'Rres a b rm r = 1k tc1 = 1m'"));
    try std.testing.expect(std.mem.indexOf(u8, log.written(), "info[cosmetic]: the PDK's erratum for this file no longer applies: 'gone a b 1k' is not in it") != null);
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
    try tmp.dir.writeFile(io, .{ .sub_path = "top.sp", .data = "t\n.include /dev/zero\nR1 a 0 1k\n.end\n" });
    const ngspice = @import("root.zig").find("ngspice").?.*;
    var log: Writer.Allocating = .init(a);
    const sum = try run(io, std.testing.allocator, .{
        .from = &ngspice,
        .to = &ngspice,
        .tops = &.{try std.fmt.allocPrint(a, "{s}/top.sp", .{base})},
        .out_dir = try std.fmt.allocPrint(a, "{s}/out", .{base}),
        .log = &log.writer,
    });
    try std.testing.expectEqual(1, sum.errors);
    try std.testing.expect(std.mem.indexOf(u8, log.written(), "/dev/zero: error[invalid]: not a regular file; not read") != null);
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
    try tmp.dir.writeFile(io, .{ .sub_path = "in/tt.mod", .data = "* tt\n.model nch nmos level=1\n" });
    const ngspice = @import("root.zig").find("ngspice").?.*;
    const xyce = @import("root.zig").find("xyce").?.*;
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
        const lib = try tmp.dir.readFileAlloc(io, try std.fmt.allocPrint(a, "out-{s}/corners.lib", .{to.name}), a, .unlimited);
        if (to == &ngspice) {
            try std.testing.expect(std.mem.indexOf(u8, lib, ".lib ff\n* [sprack] not in this copy: include \"ff.mod\"\n* [sprack] not in this copy: lib \"corners.lib\" tt\n.endl ff\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, lib, ".include \"tt.mod\"\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, log.written(), "warning[caveat]: section 'ff' is not followed, and ngspice opens the includes of every section of a library") != null);
        } else {
            // Xyce opens only the section asked for: the copy keeps the line.
            try std.testing.expect(std.mem.indexOf(u8, lib, ".include \"ff.mod\"\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, log.written(), "opens the includes") == null);
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

    const hspice = @import("root.zig").find("hspice").?.*;
    const spectre = @import("root.zig").find("spectre").?.*;

    var log: Writer.Allocating = .init(a);
    var expanded: Writer.Allocating = .init(a);
    const sum = try run(io, std.testing.allocator, .{
        .from = &hspice,
        .to = &spectre,
        .tops = &.{try std.fmt.allocPrint(a, "{s}/in/top.sp", .{base})},
        .out_dir = try std.fmt.allocPrint(a, "{s}/out", .{base}),
        .vars = &.{.{ "MODELS", "models" }},
        .log = &log.writer,
        .expanded = &expanded.writer,
        // Only the corner asked for: ff.mod (which does not exist) is not reached.
        .sections = &.{"tt"},
    });
    try std.testing.expectEqual(3, sum.files);
    try std.testing.expectEqualStrings("{\"MODELS\":\"models\"}", expanded.written());
    try std.testing.expectEqual(1, sum.missing);
    try std.testing.expect(std.mem.indexOf(u8, log.written(), "missing.mod: error[invalid]: cannot open this file") != null);
    try std.testing.expect(std.mem.indexOf(u8, log.written(), "corners.lib: info[cosmetic]: section 'ff' not followed") != null);

    const top = try tmp.dir.readFileAlloc(io, "out/top.sp", a, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, top, "// Top netlist\nsimulator lang=spectre insensitive=yes\nglobal 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, top, "include \"models/corners.lib\" section=tt\n") != null);
    // Recognised as a transistor of a model declared elsewhere in the project.
    try std.testing.expect(std.mem.indexOf(u8, top, "M1 (d g 0 0) nch w=1u l=1u\n") != null);
    const lib = try tmp.dir.readFileAlloc(io, "out/models/corners.lib", a, .unlimited);
    // An included file: no title, no `global`, but it does say its language,
    // and that HSPICE ignores case: in Spectre the setting is per file.
    try std.testing.expect(std.mem.startsWith(u8, lib, "simulator lang=spectre insensitive=yes\n// corners\nsection tt\ninclude \"nch.mod\"\nendsection tt\n"));
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
    try std.testing.expect(std.mem.indexOf(u8, cat.written(), "corners.lib\",\"name\":\"tt\"},{\"file\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, cat.written(), "\"section\":\"\",\"kind\":\"model\",\"device\":\"mosfet\",\"family\":\"bsim4\",\"polarity\":\"n\"") != null);
}
