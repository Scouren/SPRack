//! Project: the errata of a PDK, and reading an input file through them.
//!
//! Contents:
//! - `pub const Erratum`
//! - `pub const Loaded = struct`
//! - `pub fn parseErrata(arena: Allocator, text: []const u8)
//!   error{ OutOfMemory, BadErrata }![]const Erratum`
//! - `pub fn load(r: *const Run, path: []const u8, a: Allocator) Loaded`
//! - `pub fn noteErrata(r: *Run, path: []const u8, hits: []const Loaded.Hit) Allocator.Error!void`
//! - `pub fn readFile(r: *Run, path: []const u8, a: Allocator) ?[]const u8`
//! - `pub fn staleErrata(r: *Run) Allocator.Error!void`

const std = @import("std");
const ir = @import("ir");
const run_ = @import("run.zig");
const Allocator = std.mem.Allocator;
const Run = run_.Run;

/// `was`, whole lines of a file whose path ends in `file`, is read as
/// `read`: a line the PDK's own simulator refuses (`why`).
pub const Erratum =
    struct { file: []const u8, was: []const u8, read: []const u8, why: []const u8 = "" };

/// What reading one input file gave: its text with the PDK's errata
/// read through, or why there is none; and the errata that name it,
/// each with the line its text stood on, if it stood there.
pub const Loaded = struct {
    text: ?[]const u8 = null,
    /// Why the file was refused; empty: it could not be opened.
    refusal: []const u8 = "",
    hits: []const Hit = &.{},

    const Hit = struct { erratum: usize, line: ?u32 };
};

/// Errata from JSON: a list of `{file, was, read, why}`, or an object that
/// holds one under `errata` (a PDK manifest).
pub fn parseErrata(
    arena: Allocator,
    text: []const u8,
) error{ OutOfMemory, BadErrata }![]const Erratum {
    const v = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        text,
        .{},
    ) catch return error.BadErrata;
    const list = switch (v) {
        .array => |a| a,
        .object => |o| if (o.get("errata")) |e|
            (if (e == .array) e.array else return error.BadErrata)
        else
            return &.{},
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

/// Reads `path`. It writes nothing of the run: files are read at once.
pub fn load(r: *const Run, path: []const u8, a: Allocator) Loaded {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(r.io, path, .{}) catch return .{};
    if (st.kind != .file) return .{ .refusal = "not a regular file; not read" };
    if (st.size > ir.max_input)
        return .{ .refusal = std.fmt.comptimePrint(
            "larger than {d} MiB, the most an input may hold; not read",
            .{ir.max_input >> 20},
        ) };
    var text = cwd.readFileAlloc(r.io, path, a, .limited(ir.max_input)) catch return .{};
    var hits: std.ArrayList(Loaded.Hit) = .empty;
    for (r.opts.errata, 0..) |e, i| {
        if (!std.mem.endsWith(u8, path, e.file)) continue;
        var hit: Loaded.Hit = .{ .erratum = i, .line = null };
        if (wholeLines(text, e.was, 0)) |at| {
            hit.line = @intCast(std.mem.count(u8, text[0..at], "\n") + 1);
            text = std.mem.concat(a, u8, &.{ text[0..at], e.read, text[at + e.was.len ..] }) catch
                return .{};
        }
        hits.append(a, hit) catch return .{};
    }
    return .{ .text = text, .hits = hits.items };
}

/// What `load` found of the PDK's errata in `path`, taken by the run:
/// which were met, and each one read through said once a file.
pub fn noteErrata(r: *Run, path: []const u8, hits: []const Loaded.Hit) Allocator.Error!void {
    for (hits) |hit| {
        const i = hit.erratum;
        const e = r.opts.errata[i];
        r.errata_seen[i] = true;
        const line = hit.line orelse continue;
        r.errata_found[i] = true;
        const key = try std.fmt.allocPrint(r.arena, "{s}\x00{d}", .{ path, i });
        if (r.errata_said.contains(key)) continue;
        try r.errata_said.put(r.arena, key, {});
        const msg = try std.fmt.allocPrint(r.arena, "read through an erratum of the PDK: " ++
            "'{s}'{s}{s}; read as '{s}'", .{
            std.mem.sliceTo(e.was, '\n'),
            if (e.why.len > 0)
                ": "
            else
                "",
            e.why,
            std.mem.sliceTo(e.read, '\n'),
        });
        r.logLine(path, .{ .sev = .warning, .code = .caveat, .line = line, .msg = msg });
    }
}

/// The text of an input file; null when it cannot be read, or is
/// refused (`refusal` says why): not a regular file, or larger than
/// `ir.max_input`.
pub fn readFile(r: *Run, path: []const u8, a: Allocator) ?[]const u8 {
    const loaded = r.load(path, a);
    r.refusal = loaded.refusal;
    r.noteErrata(path, loaded.hits) catch return null;
    return loaded.text;
}

/// An erratum whose file was read and whose text is not in it: the PDK
/// has changed, and the erratum can go.
pub fn staleErrata(r: *Run) Allocator.Error!void {
    for (r.opts.errata, r.errata_seen, r.errata_found) |e, seen, found| {
        if (!seen or found) continue;
        const msg = try std.fmt.allocPrint(
            r.arena,
            "the PDK's erratum for this file no longer applies: '{s}' is not in it",
            .{std.mem.sliceTo(e.was, '\n')},
        );
        r.logLine(e.file, .{ .sev = .info, .code = .cosmetic, .line = 0, .msg = msg });
    }
}

// ---- private ----

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
