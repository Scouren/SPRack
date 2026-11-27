//! Project, pass one: every file found by following includes, and what
//! each declares learned.
//!
//! Contents:
//! - `pub fn noteSearch(r: *Run, dir: []const u8, st: *const ir.Stmt) Allocator.Error!void`
//! - `pub fn findIncludes(r: *Run, file: []const u8, stmts: []const ir.Stmt, scratch: Allocator,
//!   top: bool) Allocator.Error!void`
//! - `pub fn collectRefs(r: *Run, dir: []const u8, stmts: []const ir.Stmt, scratch: Allocator,
//!   out: *std.ArrayList(Ref)) Allocator.Error!void`
//! - `pub fn want(r: *Run, name: []const u8) Allocator.Error!void`
//! - `pub fn discover(r: *Run) Allocator.Error!void`
//! - for `Ahead`, the slot of a file read and parsed has `pub fn init`, `pub fn reset`,
//!   `pub fn deinit`

const std = @import("std");
const ir = @import("ir");
const reader = @import("reader");
const writer = @import("writer");
const dialects = @import("dialects");
const paths = @import("paths.zig");
const errata_ = @import("errata.zig");
const ahead_ = @import("ahead.zig");
const run_ = @import("run.zig");
const Allocator = std.mem.Allocator;
const Run = run_.Run;
const Ref = Run.Ref;
const Fresh = Run.Fresh;
const File = ahead_.File;
const Ahead = ahead_.Ahead;
const Loaded = errata_.Loaded;
const slot_keep = ahead_.slot_keep;
const dirOf = paths.dirOf;
const resolve = paths.resolve;
const pathOf = Run.pathOf;
const sectionOf = Run.sectionOf;
const spellingKey = Run.spellingKey;

/// One file of the first pass, read and parsed.
const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    loaded: Loaded,
    stmts: []ir.Stmt,
    failed: bool,

    pub fn init(p: *Parsed, gpa: Allocator) void {
        p.* = .{ .arena = .init(gpa), .loaded = .{}, .stmts = &.{}, .failed = false };
    }

    pub fn reset(p: *Parsed) void {
        _ = p.arena.reset(.{ .retain_with_limit = slot_keep });
        p.loaded = .{};
        p.stmts = &.{};
        p.failed = false;
    }

    pub fn deinit(p: *Parsed) void {
        p.arena.deinit();
    }
};

pub fn noteSearch(r: *Run, dir: []const u8, st: *const ir.Stmt) Allocator.Error!void {
    if (st.kind != .options or st.get("search") != .str) return;
    var fresh: Fresh = .{ .arena = r.arena };
    const sd = try resolve(r.arena, if (r.leadsWithDefined(st.get("search").str))
        r.cwd
    else
        dir, try r.expand(r.arena, st.get("search").str, &fresh));
    try r.absorb(&fresh);
    for (r.search.items) |x| if (std.mem.eql(u8, x, sd)) return;
    try r.search.append(r.arena, sd);
}

pub fn findIncludes(
    r: *Run,
    file: []const u8,
    stmts: []const ir.Stmt,
    scratch: Allocator,
    top: bool,
) Allocator.Error!void {
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
            if (r.wanted) |*w| if (!w.contains(name) and !(top and r.top_sections)) {
                var refs: std.ArrayList(Ref) = .empty;
                try r.collectRefs(dir, st.body, scratch, &refs);
                try r.skipped.append(
                    r.arena,
                    .{ .path = file, .name = try r.arena.dupe(u8, name), .refs = refs.items },
                );
                continue;
            };
        }
        try r.noteSearch(dir, st);
        if (pathOf(st)) |p| {
            try r.enqueue(try r.locateNow(scratch, dir, p));
            if (st.kind == .lib) try r.want(sectionOf(st));
        }
        if (st.kind == .hdl and st.get("path") == .str) {
            const target = try r.locateNow(scratch, dir, st.get("path").str);
            for (r.hdls.items) |h| {
                if (std.mem.eql(u8, h, target)) break;
            } else try r.hdls.append(r.arena, try r.arena.dupe(u8, target));
        }
        try r.findIncludes(file, st.body, scratch, top);
    }
}

/// What a skipped section would reach, to follow if it is named later.
pub fn collectRefs(
    r: *Run,
    dir: []const u8,
    stmts: []const ir.Stmt,
    scratch: Allocator,
    out: *std.ArrayList(Ref),
) Allocator.Error!void {
    for (stmts) |*st| {
        if (pathOf(st)) |p| try out.append(r.arena, .{
            .path = try r.arena.dupe(u8, try r.locateNow(scratch, dir, p)),
            .section = try r.arena.dupe(u8, if (st.kind == .lib) sectionOf(st) else ""),
        });
        try r.collectRefs(dir, st.body, scratch, out);
    }
}

/// A section named by a followed `.lib` line is followed wherever it is.
pub fn want(r: *Run, name: []const u8) Allocator.Error!void {
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

/// Pass one: find every file and learn what each declares.
pub fn discover(r: *Run) Allocator.Error!void {
    var ahead: Ahead(Parsed, parseOne) = undefined;
    try ahead.init(r);
    defer ahead.deinit();
    // A file read names the files after it: the list grows as it is walked.
    while (ahead.next < r.files.items.len) {
        const i = ahead.next;
        const path = r.files.items[i];
        const parsed = ahead.take();
        defer ahead.release();
        if (parsed.failed) return error.OutOfMemory;
        const scratch = parsed.arena.allocator();
        r.refusal = parsed.loaded.refusal;
        try r.noteErrata(path, parsed.loaded.hits);
        if (parsed.loaded.text == null) {
            r.sum.missing += 1;
            r.logLine(
                path,
                .{ .sev = .@"error", .code = .invalid, .line = 0, .msg = if (r.refusal.len > 0)
                    r.refusal
                else
                    "cannot open this file; it is included by the project" },
            );
            // Keep the slot so indices stay stable, but mark it.
            r.files.items[i] = "";
            continue;
        }
        try r.env.absorb(r.arena, parsed.stmts);
        // "": every name is copied, as `text` goes away with the statements.
        // With no target (a catalogue, kept for any): the names any
        // built-in dialect keeps for itself (#71).
        if (r.opts.to) |gt| {
            try writer.collectReserved(r.arena, gt, parsed.stmts, &r.env.params, "");
        } else for (&dialects.grammars) |*g| {
            try writer.collectReserved(r.arena, g, parsed.stmts, &r.env.params, "");
        }
        try r.findIncludes(path, parsed.stmts, scratch, i < r.opts.tops.len);
    }
    // A section asked for by name that no file defines: nothing of it
    // is in the result, and what references it will not find it.
    for (r.opts.sections) |sec| {
        for (r.sections.items) |s| {
            if (std.ascii.eqlIgnoreCase(s.section, sec)) break;
        } else {
            var buf: [200]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "section '{s}' is asked for, but no file read defines it",
                .{sec[0..@min(sec.len, 60)]},
            ) catch "a section asked for is not defined";
            r.logLine(if (r.opts.tops.len > 0)
                r.opts.tops[0]
            else
                "", .{ .sev = .@"error", .code = .invalid, .line = 0, .msg = msg });
        }
    }
    for (r.skipped.items) |sk| {
        if (sk.released) continue;
        var buf: [200]u8 = undefined;
        const why = if (r.top_sections)
            "no followed .lib line names it"
        else
            "it is not among the sections asked for";
        const msg = std.fmt.bufPrint(
            &buf,
            "section '{s}' not followed: {s}, so the files it includes are not translated",
            .{ sk.name[0..@min(sk.name.len, 60)], why },
        ) catch "a section not followed";
        r.logLine(sk.path, .{ .sev = .info, .code = .cosmetic, .line = 0, .msg = msg });
    }
}

// ---- private ----

fn parseOne(r: *const Run, file: File, out: *Parsed) void {
    const a = out.arena.allocator();
    out.loaded = r.load(file.path, a);
    const text = out.loaded.text orelse return;
    // What the file says of itself alone: the report of this reading
    // is the second pass's to give, with the other files known.
    var report: ir.Report = .init(a);
    const nl = reader.read(r.opts.from, a, text, &report, .{ .library = file.library }) catch {
        out.failed = true;
        return;
    };
    out.stmts = nl.stmts;
}
