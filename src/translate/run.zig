//! Project: a run over the files of a project, what it is asked and what
//! it gives, and the state the passes share.
//!
//! Contents:
//! - `pub const Summary = struct`, with `pub fn root`
//! - `pub const Options = struct`
//! - `pub const Run = struct`, with `pub const Skipped`, `pub const Ref`,
//!   `pub const Lines = struct` (`pub fn add`), `pub const Fresh = struct`, and the methods
//!   `pub fn logLine`, `pub fn absorb`, `pub fn enqueue`, `pub fn pathOf`, `pub fn expand`,
//!   `pub fn locateNow`, `pub fn locate`, `pub fn leadsWithDefined`, `pub fn writeExpanded`,
//!   `pub fn exists`, `pub fn sectionOf`, `pub fn spellingKey`; from `errata.zig`
//!   `pub const load`, `pub const noteErrata`, `pub const readFile`, `pub const staleErrata`;
//!   from `discover.zig` `pub const noteSearch`, `pub const findIncludes`,
//!   `pub const collectRefs`, `pub const want`, `pub const discover`; from `includes.zig`
//!   `pub const emptied`, `pub const rewriteIncludes`; from `catalog.zig`
//!   `pub const catalogStmts`, `pub const noteOpaque`; from `copy.zig` `pub const outPath`,
//!   `pub const translateFile`, `pub const translateInto`, `pub const translateAll`,
//!   `pub const process`

const std = @import("std");
const grammar = @import("grammar");
const ir = @import("ir");
const writer = @import("writer");
const paths = @import("paths.zig");
const errata_ = @import("errata.zig");
const discovery = @import("discover.zig");
const includes = @import("includes.zig");
const catalog = @import("catalog.zig");
const copy = @import("copy.zig");
const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Writer = std.Io.Writer;
const Erratum = errata_.Erratum;
const resolve = paths.resolve;
const varValue = paths.varValue;
const windows = paths.windows;

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
    /// here or by a `.lib` line in what is followed. Empty: every section
    /// of a top file, and those a `.lib` line in what is followed names.
    sections: []const []const u8 = &.{},
    /// Written at the end: a JSON object of every `$NAME` an include path
    /// named and what it was replaced by (null: `vars` does not define it).
    /// Another value would reach other files, so a kept result is good
    /// only while these are the same. A catalogue says it as its `vars`.
    expanded: ?*Writer = null,
    /// Lines a PDK ships that its own simulator refuses, and what to read
    /// instead (a manifest's `errata`).
    errata: []const Erratum = &.{},
    /// Files given to the translation by name (`ir.Env.provided`).
    provided: []const [2][]const u8 = &.{},
    /// How many files are translated at once, each by a task of `io`. The
    /// result is the same for any number: the log and the names read are
    /// taken a file after the other, in the order of the files.
    jobs: usize = 1,
};

pub const Run = struct {
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
    /// The directory every file is under, once the first pass knows them.
    root_dir: []const u8 = "",
    /// How each file spells its sections, by `path NUL lower-case name`:
    /// a reference spelled `typ` to a section `Typ` is written `Typ`.
    spellings: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Every section a file defines, in the order read.
    sections: std.ArrayList(Ref) = .empty,
    /// Verilog-A sources named by `.hdl`, copied into the translated tree.
    hdls: std.ArrayList([]const u8) = .empty,
    /// The sections to follow: those asked for, and those a followed
    /// `.lib` line names. With none asked for, every section of a top file
    /// too (`top_sections`).
    wanted: ?ir.CaselessSet = null,
    top_sections: bool = false,
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
    pub const Skipped = struct { path: []const u8, name: []const u8, refs: []const Ref, released: bool = false };
    pub const Ref = struct { path: []const u8, section: []const u8 };

    /// Report entries as lines of the log, and how many are errors and
    /// warnings: the run's own, or those of one file translated beside
    /// others, which the run takes when the files before have given theirs.
    pub const Lines = struct {
        out: ?*Writer,
        cwd: []const u8,
        errors: usize = 0,
        warnings: usize = 0,

        pub fn add(l: *Lines, full: []const u8, d: ir.Diag) void {
            if (d.sev == .@"error") l.errors += 1;
            if (d.sev == .warning) l.warnings += 1;
            const w = l.out orelse return;
            const under = full.len > l.cwd.len + 1 and std.mem.startsWith(
                u8,
                full,
                l.cwd,
            ) and full[l.cwd.len] == '/';
            const path = if (under) full[l.cwd.len + 1 ..] else full;
            if (d.line > 0) {
                w.print(
                    "{s}:{d}: {s}[{s}]: {s}\n",
                    .{ path, d.line, @tagName(d.sev), @tagName(d.code), d.msg },
                ) catch {};
            } else w.print(
                "{s}: {s}[{s}]: {s}\n",
                .{ path, @tagName(d.sev), @tagName(d.code), d.msg },
            ) catch {};
        }
    };

    /// The `$NAME`s include paths named that the run had not met, in the
    /// order met. `Run.expanded` takes them a file after the other
    /// (`absorb`), so its order is the files', whichever is worked first.
    pub const Fresh = struct {
        arena: Allocator,
        names: std.ArrayList(struct { []const u8, ?[]const u8 }) = .empty,

        fn note(f: *Fresh, name: []const u8, value: ?[]const u8) Allocator.Error!void {
            for (f.names.items) |nv| if (std.mem.eql(u8, nv[0], name)) return;
            try f.names.append(f.arena, .{ try f.arena.dupe(u8, name), value });
        }
    };

    pub fn logLine(r: *Run, full: []const u8, d: ir.Diag) void {
        var lines: Lines = .{ .out = r.opts.log, .cwd = r.cwd };
        lines.add(full, d);
        r.sum.errors += lines.errors;
        r.sum.warnings += lines.warnings;
    }

    pub fn absorb(r: *Run, fresh: *const Fresh) Allocator.Error!void {
        for (fresh.names.items) |nv| {
            if (r.expanded.contains(nv[0])) continue;
            try r.expanded.put(r.arena, try r.arena.dupe(u8, nv[0]), nv[1]);
        }
    }

    pub fn enqueue(r: *Run, path: []const u8) Allocator.Error!void {
        if (r.known.contains(path)) return;
        const own = try r.arena.dupe(u8, path);
        try r.known.put(r.arena, own, {});
        try r.files.append(r.arena, own);
    }

    pub fn pathOf(st: *const ir.Stmt) ?[]const u8 {
        if (st.kind != .include and st.kind != .lib) return null;
        const v = st.get("path");
        return if (v == .str) v.str else null;
    }

    /// `path` with its `$NAME`s replaced, each noted in `fresh`. It reads
    /// nothing of the run that changes: files worked on at once call it.
    pub fn expand(
        r: *const Run,
        a: Allocator,
        path: []const u8,
        fresh: *Fresh,
    ) Allocator.Error![]const u8 {
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
            const value = varValue(r.opts.vars, name, windows);
            if (name.len > 0) try fresh.note(name, value);
            if (braced and j < path.len and path[j] == '}') j += 1;
            try out.appendSlice(a, value orelse path[i..j]);
            i = j;
        }
        return out.items;
    }

    /// The file an include names: beside the including file, else in the
    /// first search directory that has it.
    /// As `locate`, for the run itself: what is fresh is taken at once.
    pub fn locateNow(
        r: *Run,
        scratch: Allocator,
        dir: []const u8,
        path: []const u8,
    ) Allocator.Error![]const u8 {
        var fresh: Fresh = .{ .arena = scratch };
        const found = try r.locate(scratch, dir, path, &fresh);
        try r.absorb(&fresh);
        return found;
    }

    pub fn locate(
        r: *const Run,
        scratch: Allocator,
        dir_in: []const u8,
        path: []const u8,
        fresh: *Fresh,
    ) Allocator.Error![]const u8 {
        const p = try r.expand(scratch, path, fresh);
        // `$PDK/corners.lib` with `-D PDK=pdk`: the variable's value is a
        // path of its own, from where SPRack runs, whichever file names it.
        const dir = if (r.leadsWithDefined(path)) r.cwd else dir_in;
        const here = try resolve(scratch, dir, p);
        if (r.search.items.len == 0 or std.fs.path.isAbsolute(p) or exists(r, here)) return here;
        for (r.search.items) |sd| {
            const there = try resolve(scratch, sd, p);
            if (exists(r, there)) return there;
        }
        return here;
    }

    /// Does the path begin with a variable that has a value?
    pub fn leadsWithDefined(r: *const Run, path: []const u8) bool {
        if (path.len < 2 or path[0] != '$') return false;
        const braced = path[1] == '{';
        const start: usize = 1 + @intFromBool(braced);
        var j = start;
        while (j < path.len and (std.ascii.isAlphanumeric(path[j]) or path[j] == '_')) j += 1;
        return varValue(r.opts.vars, path[start..j], windows) != null;
    }

    pub fn writeExpanded(r: *const Run, w: *Writer) Writer.Error!void {
        try w.writeByte('{');
        for (r.expanded.keys(), r.expanded.values(), 0..) |name, value, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{f}:{f}", .{ std.json.fmt(name, .{}), std.json.fmt(value, .{}) });
        }
        try w.writeByte('}');
    }

    pub fn exists(r: *const Run, path: []const u8) bool {
        return if (std.Io.Dir.cwd().access(r.io, path, .{})) |_| true else |_| false;
    }

    pub fn sectionOf(st: *const ir.Stmt) []const u8 {
        const v = st.get("section");
        return if (v == .atom) v.atom else "";
    }

    pub fn spellingKey(a: Allocator, path: []const u8, name: []const u8) Allocator.Error![]const u8 {
        const k = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ path, name });
        _ = std.ascii.lowerString(k[path.len + 1 ..], name);
        return k;
    }

    pub const load = errata_.load;
    pub const noteErrata = errata_.noteErrata;
    pub const readFile = errata_.readFile;
    pub const staleErrata = errata_.staleErrata;
    pub const noteSearch = discovery.noteSearch;
    pub const findIncludes = discovery.findIncludes;
    pub const collectRefs = discovery.collectRefs;
    pub const want = discovery.want;
    pub const discover = discovery.discover;
    pub const emptied = includes.emptied;
    pub const rewriteIncludes = includes.rewriteIncludes;
    pub const catalogStmts = catalog.catalogStmts;
    pub const noteOpaque = catalog.noteOpaque;
    pub const outPath = copy.outPath;
    pub const translateFile = copy.translateFile;
    pub const translateInto = copy.translateInto;
    pub const translateAll = copy.translateAll;
    pub const process = copy.process;
};
