//! Project: the include lines of a translated copy, rewritten as paths to
//! the copies of the files they name.

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir");
const paths = @import("paths.zig");
const run_ = @import("run.zig");

const Allocator = std.mem.Allocator;
const Run = run_.Run;
const Fresh = Run.Fresh;
const relative = paths.relative;
const pathOf = Run.pathOf;
const sectionOf = Run.sectionOf;
const spellingKey = Run.spellingKey;

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

/// The includes of an emptied section, as comments.
pub fn commentIncludes(scratch: Allocator, stmts: []ir.Stmt, n: *usize) Allocator.Error!void {
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

pub fn rewriteIncludes(
    r: *const Run,
    path_of_file: []const u8,
    dir: []const u8,
    stmts: []ir.Stmt,
    scratch: Allocator,
    report: *ir.Report,
    fresh: *Fresh,
) Allocator.Error!void {
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
        try r.rewriteIncludes(path_of_file, dir, st.body, scratch, report, fresh);
    }
}

pub const Includes = struct { r: *const Run, path: []const u8, dir: []const u8, fresh: *Fresh };

pub fn includes(
    ctx: *anyopaque,
    a: Allocator,
    stmts: []ir.Stmt,
    report: *ir.Report,
) Allocator.Error!void {
    const in: *Includes = @ptrCast(@alignCast(ctx));
    try in.r.rewriteIncludes(in.path, in.dir, stmts, a, report, in.fresh);
}
