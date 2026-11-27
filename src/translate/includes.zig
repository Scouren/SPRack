//! Project: the include lines of a translated copy, rewritten as paths to
//! the copies of the files they name.
//!
//! Contents:
//! - `pub const Includes = struct`
//! - `pub fn emptied(r: *const Run, path: []const u8, st: *const ir.Stmt) bool`
//! - `pub fn rewriteIncludes(in: *const Includes, stmts: []ir.Stmt, scratch: Allocator,
//!   report: *ir.Report) Allocator.Error!void`
//! - `pub fn includes(ctx: *anyopaque, a: Allocator, stmts: []ir.Stmt,
//!   report: *ir.Report) Allocator.Error!void`

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir");
const paths = @import("paths.zig");
const run_ = @import("run.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Run = run_.Run;
const Fresh = Run.Fresh;
const relative = paths.relative;
const dirOf = paths.dirOf;
const pathOf = Run.pathOf;
const sectionOf = Run.sectionOf;
const spellingKey = Run.spellingKey;

/// The file whose include lines are rewritten: its path and directory, and
/// where the `$NAME`s they name are noted.
pub const Includes = struct { r: *const Run, path: []const u8, dir: []const u8, fresh: *Fresh };

/// A section of `path` not followed, where the target opens the
/// includes of every section (`libsections opened`): its includes would
/// name files the copy has not.
pub fn emptied(r: *const Run, path: []const u8, st: *const ir.Stmt) bool {
    const gt = r.opts.to orelse return false;
    if (gt.libsections_opened.len == 0 or st.kind != .libsection or st.get("name") != .atom)
        return false;
    for (r.skipped.items) |sk| {
        if (!sk.released and std.mem.eql(u8, sk.path, path) and std.ascii.eqlIgnoreCase(
            sk.name,
            st.get("name").atom,
        )) return true;
    }
    return false;
}

// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn rewriteIncludes(
    in: *const Includes,
    stmts: []ir.Stmt,
    scratch: Allocator,
    report: *ir.Report,
) Allocator.Error!void {
    assert(std.mem.eql(u8, in.dir, dirOf(in.path)));
    const r = in.r;
    const path_of_file = in.path;
    const dir = in.dir;
    const fresh = in.fresh;
    for (stmts) |*st| {
        if (r.emptied(path_of_file, st)) {
            var n: usize = 0;
            try commentIncludes(scratch, st.body, &n);
            if (n > 0)
                report.add(.warning, .caveat, st.line, "section '{s}' is not followed, " ++
                    "and {s} opens the includes of every section of a library: its " ++
                    "includes are left out of this copy as comments ({d}), so the section " ++
                    "is empty here ({s})", .{
                    st.get("name").atom, r.opts.to.?.name, n, r.opts.to.?.libsections_opened,
                });
            continue;
        }
        // Every include is rewritten to the copy it resolved to, so the
        // search directories are no longer needed.
        if (st.kind == .options and st.get("search") != .none) {
            try st.own(scratch);
            try st.set(scratch, schema.slot(.options, "search"), .none);
            report.add(
                .info,
                .cosmetic,
                st.line,
                "options.search: the includes it finds are written as paths to their " ++
                    "translated copies",
                .{},
            );
        }
        const p = pathOf(st) orelse if (st.kind == .hdl and st.get("path") == .str)
            st.get("path").str
        else
            null;
        if (p) |path| {
            const target = try r.locate(scratch, dir, path, fresh);
            try st.own(scratch);
            try st.set(
                scratch,
                schema.slotOf(st.kind, "path").?,
                .{ .str = try relative(scratch, dir, target) },
            );
            // The section as the file that defines it spells it.
            const sec = sectionOf(st);
            if (st.kind == .lib and sec.len > 0) {
                if (r.spellings.get(try spellingKey(scratch, target, sec))) |sp| {
                    try st.set(scratch, schema.slot(.lib, "section"), .{ .atom = sp });
                }
            }
        }
        try rewriteIncludes(in, st.body, scratch, report);
    }
}

pub fn includes(
    ctx: *anyopaque,
    a: Allocator,
    stmts: []ir.Stmt,
    report: *ir.Report,
) Allocator.Error!void {
    const in: *Includes = @ptrCast(@alignCast(ctx));
    try rewriteIncludes(in, stmts, a, report);
}

// ---- private ----

/// The includes of an emptied section, as comments.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
fn commentIncludes(scratch: Allocator, stmts: []ir.Stmt, n: *usize) Allocator.Error!void {
    for (stmts) |*st| {
        if (pathOf(st)) |p| {
            const sec = sectionOf(st);
            const raw = try std.fmt.allocPrint(
                scratch,
                "[sprack] not in this copy: {s} \"{s}\"{s}{s}",
                .{ @tagName(st.kind), p, if (sec.len > 0) " " else "", sec },
            );
            st.* = .{ .kind = .comment, .raw = raw, .line = st.line };
            n.* += 1;
            continue;
        }
        try commentIncludes(scratch, st.body, n);
    }
}
