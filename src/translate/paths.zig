//! Project: the paths of the files of a project, all absolute, normalized
//! and written with `/`, and the directory they have in common.
//!
//! Contents:
//! - `pub fn normalize(arena: Allocator, path: []const u8) Allocator.Error![]const u8`
//! - `pub fn dirOf(path: []const u8) []const u8`
//! - `pub fn resolve(arena: Allocator, base_dir: []const u8,
//!   path: []const u8) Allocator.Error![]const u8`
//! - `pub fn relative(arena: Allocator, from_dir: []const u8,
//!   to: []const u8) Allocator.Error![]const u8`
//! - `pub fn varValue(vars: []const [2][]const u8, name: []const u8, fold: bool) ?[]const u8`
//! - `pub fn commonDir(arena: Allocator, paths: []const []const u8) Allocator.Error![]const u8`
//! - `pub const windows`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
pub const windows = @import("builtin").os.tag == .windows;

/// Remove `.` and resolve `..` without touching the file system.
pub fn normalize(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    return normalizeOn(windows, arena, path);
}

pub fn dirOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
    const root = rootLen(path);
    return if (slash < root) path[0..root] else path[0..slash];
}

/// `path` as an absolute, normalized path: itself, or under `base_dir`.
/// Every path comes in through here, and on Windows leaves written with
/// `/`, which Windows takes as well as `\`: the rest of this file, and the
/// include lines of a translated copy, know one separator.
pub fn resolve(
    arena: Allocator,
    base_dir: []const u8,
    path: []const u8,
) Allocator.Error![]const u8 {
    return resolveOn(windows, arena, base_dir, path);
}

/// The path that leads from `from_dir` to `to`, both normalized.
pub fn relative(arena: Allocator, from_dir: []const u8, to: []const u8) Allocator.Error![]const u8 {
    // Normalized: no part is `.` but a path that is `.` alone.
    assert(std.mem.indexOf(u8, from_dir, "/./") == null);
    assert(std.mem.indexOf(u8, to, "/./") == null);
    var a = std.mem.tokenizeScalar(u8, from_dir, '/');
    var b = std.mem.tokenizeScalar(u8, to, '/');
    var out: std.ArrayList(u8) = .empty;
    // Bound: the parts of the shorter path; until the first part the two do not share.
    while (true) {
        const save_a = a.index;
        const save_b = b.index;
        const x = a.next();
        const y = b.next();
        if (x != null and y != null and std.mem.eql(u8, x.?, y.?) and !std.mem.eql(u8, x.?, "."))
            continue;
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

/// The value of `$name`: the one spelled so, or on Windows, where the
/// environment ignores case (`$pdk_root` is `PDK_ROOT`), one spelled
/// otherwise when none is spelled so.
pub fn varValue(vars: []const [2][]const u8, name: []const u8, fold: bool) ?[]const u8 {
    for (vars) |kv| if (std.mem.eql(u8, kv[0], name)) return kv[1];
    if (fold) for (vars) |kv| if (std.ascii.eqlIgnoreCase(kv[0], name)) return kv[1];
    return null;
}

// ponytail: files on two Windows drives have no common directory; the first
// file's drive is taken, and a file on another is reported as not written.
// A copy tree per drive if a PDK ever spans two.
pub fn commonDir(arena: Allocator, paths: []const []const u8) Allocator.Error![]const u8 {
    if (paths.len == 0) return ".";
    var common = dirOf(paths[0]);
    for (paths[1..]) |p| {
        const d = dirOf(p);
        while (!(std.mem.eql(u8, common, d) or (std.mem.startsWith(u8, d, common) and
            d.len > common.len and (d[common.len] == '/' or common.len == rootLen(common)))))
        {
            if (std.mem.eql(u8, common, ".") or common.len == rootLen(common)) break;
            common = dirOf(common);
            if (std.mem.eql(u8, common, ".")) break;
        }
    }
    return arena.dupe(u8, common);
}

// ---- private ----

/// How much of `path` is its root: `/`, and on Windows also `C:/` and the
/// `//` of a network share. Nothing for a relative path.
fn rootLen(path: []const u8) usize {
    return rootLenOn(windows, path);
}

/// `rootLen` as on Windows (`win`) or elsewhere, so both are tested on any host.
fn rootLenOn(win: bool, path: []const u8) usize {
    if (win) {
        if (path.len >= 3 and path[1] == ':' and path[2] == '/') return 3;
        if (std.mem.startsWith(u8, path, "//")) return 2;
    }
    return @intFromBool(path.len > 0 and path[0] == '/');
}

fn normalizeOn(win: bool, arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    const root = path[0..rootLenOn(win, path)];
    const absolute = root.len > 0;
    var it = std.mem.tokenizeScalar(u8, path[root.len..], '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..") and parts.items.len > 0 and !std.mem.eql(
            u8,
            parts.items[parts.items.len - 1],
            "..",
        )) {
            _ = parts.pop();
        } else if (std.mem.eql(u8, part, "..") and absolute) {
            continue;
        } else {
            // `..` stops at the root of an absolute path.
            if (absolute) assert(!std.mem.eql(u8, part, ".."));
            try parts.append(arena, part);
        }
    }
    const joined = try std.mem.join(arena, "/", parts.items);
    if (absolute) return std.fmt.allocPrint(arena, "{s}{s}", .{ root, joined });
    return if (joined.len == 0) "." else joined;
}

fn resolveOn(
    win: bool,
    arena: Allocator,
    base_dir: []const u8,
    path: []const u8,
) Allocator.Error![]const u8 {
    var p = path;
    if (win) {
        const copy = try arena.dupe(u8, path);
        std.mem.replaceScalar(u8, copy, '\\', '/');
        p = copy;
    }
    if (rootLenOn(win, p) > 0) return normalizeOn(win, arena, p);
    return normalizeOn(win, arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ base_dir, p }));
}

test "paths as Windows has them, on any host: a drive or share is a root, a backslash a separator" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(3, rootLenOn(true, "C:/pdk/x.lib"));
    try std.testing.expectEqual(2, rootLenOn(true, "//server/share/x.lib"));
    try std.testing.expectEqual(0, rootLenOn(true, "pdk/x.lib"));
    try std.testing.expectEqual(0, rootLenOn(false, "C:/pdk/x.lib"));
    try std.testing.expectEqualStrings(
        "C:/pdk/models/x.lib",
        try resolveOn(true, a, "C:/work", "C:\\pdk\\lib\\..\\models\\x.lib"),
    );
    try std.testing.expectEqualStrings(
        "C:/work/inc/sub.sp",
        try resolveOn(true, a, "C:/work", "inc\\sub.sp"),
    );
    try std.testing.expectEqualStrings(
        "//srv/share/m.lib",
        try resolveOn(true, a, "C:/work", "\\\\srv\\share\\m.lib"),
    );
    // `..` stops at the drive.
    try std.testing.expectEqualStrings("C:/x.lib", try normalizeOn(true, a, "C:/../x.lib"));
    // Elsewhere a backslash is a character of a name.
    try std.testing.expectEqualStrings(
        "/work/inc\\sub.sp",
        try resolveOn(false, a, "/work", "inc\\sub.sp"),
    );
}

test "a $NAME of another case is the environment's on Windows only" {
    const vars: []const [2][]const u8 = &.{ .{ "PDK_ROOT", "/p" }, .{ "pdk", "/q" } };
    try std.testing.expectEqualStrings("/p", varValue(vars, "pdk_root", true).?);
    try std.testing.expectEqual(null, varValue(vars, "pdk_root", false));
    // A name spelled so wins over one that only folds to it.
    try std.testing.expectEqualStrings("/q", varValue(vars, "pdk", true).?);
}

test "paths" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("a/c", try normalize(a, "./a/b/../c"));
    try std.testing.expectEqualStrings("../x", try normalize(a, "../x"));
    try std.testing.expectEqualStrings(
        "/pdk/models/n.lib",
        try resolve(a, "/pdk/libs", "../models/n.lib"),
    );
    try std.testing.expectEqualStrings(
        "../models/n.lib",
        try relative(a, "/pdk/libs", "/pdk/models/n.lib"),
    );
    try std.testing.expectEqualStrings("n.lib", try relative(a, "pdk", "pdk/n.lib"));
    try std.testing.expectEqualStrings("sub/n.lib", try relative(a, ".", "sub/n.lib"));
    try std.testing.expectEqualStrings(
        "/pdk",
        try commonDir(a, &.{ "/pdk/libs/a.lib", "/pdk/models/n.lib" }),
    );
}
