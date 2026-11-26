//! C ABI: netlist text and two dialect names → a result handle holding the
//! translated text and its report, over the same core the command uses.
//!
//! Strings cross the boundary as pointer and length. A result is owned by
//! its handle: what `sprack_result_text` and `sprack_result_report` return
//! lives until `sprack_result_free`.
//!
//! Contents:
//! - `pub const Result = struct`
//! - `pub export fn sprack_abi_version() c_int`
//! - `pub export fn sprack_dialect_count() usize`
//! - `pub export fn sprack_dialect_name(index: usize, len: *usize) ?[*]const u8`
//! - `pub export fn sprack_translate(from, from_len, to, to_len, src, src_len) ?*Result`
//! - `pub export fn sprack_result_text(r: *const Result, len: *usize) [*]const u8`
//! - `pub export fn sprack_result_report(r: *const Result, len: *usize) [*]const u8`
//! - `pub export fn sprack_result_errors(r: *const Result) usize`
//! - `pub export fn sprack_result_warnings(r: *const Result) usize`
//! - `pub export fn sprack_result_free(r: ?*Result) void`

const std = @import("std");
const assert = std.debug.assert;
const sprack = @import("sprack");

/// Where handles and what they hold live: a C caller passes no allocator.
// tidy: allow(global-allocator-in-library) the C ABI takes none; a handle frees its own
const gpa = std.heap.page_allocator;

/// One translation. `text` and `report` are allocated from `arena`.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8 = "",
    report: []const u8 = "",
    errors: usize = 0,
    warnings: usize = 0,
};

pub export fn sprack_abi_version() c_int {
    return 1;
}

pub export fn sprack_dialect_count() usize {
    return sprack.dialect_count;
}

pub export fn sprack_dialect_name(index: usize, len: *usize) ?[*]const u8 {
    if (index >= sprack.dialect_count) return null;
    len.* = sprack.grammars[index].name.len;
    return sprack.grammars[index].name.ptr;
}

/// Returns null only for an unknown dialect name or out of memory.
pub export fn sprack_translate(
    from: [*]const u8,
    from_len: usize,
    to: [*]const u8,
    to_len: usize,
    src: [*]const u8,
    src_len: usize,
) ?*Result {
    const r = gpa.create(Result) catch return null;
    r.* = .{ .arena = .init(gpa) };
    translateInto(r, from[0..from_len], to[0..to_len], src[0..src_len]) catch {
        sprack_result_free(r);
        return null;
    };
    assert(r.errors <= r.report.len);
    return r;
}

pub export fn sprack_result_text(r: *const Result, len: *usize) [*]const u8 {
    len.* = r.text.len;
    return r.text.ptr;
}

pub export fn sprack_result_report(r: *const Result, len: *usize) [*]const u8 {
    len.* = r.report.len;
    return r.report.ptr;
}

pub export fn sprack_result_errors(r: *const Result) usize {
    return r.errors;
}

pub export fn sprack_result_warnings(r: *const Result) usize {
    return r.warnings;
}

pub export fn sprack_result_free(r: ?*Result) void {
    const p = r orelse return;
    p.arena.deinit();
    gpa.destroy(p);
}

// ---- private ----

/// Fills `r` with the translation of `src` and its report as text.
fn translateInto(r: *Result, from: []const u8, to: []const u8, src: []const u8) !void {
    const arena = r.arena.allocator();
    var report: sprack.ir.Report = .init(arena);
    r.text = try sprack.translateAlloc(arena, from, to, src, &report);
    var text: std.Io.Writer.Allocating = .init(arena);
    try report.print(&text.writer);
    r.report = text.written();
    r.errors = report.count(.@"error");
    r.warnings = report.count(.warning);
}

test "C ABI: dialects, translate, report, free" {
    try std.testing.expectEqual(1, sprack_abi_version());
    var len: usize = 0;
    try std.testing.expect(sprack_dialect_count() > 0);
    _ = sprack_dialect_name(0, &len).?;
    try std.testing.expect(len > 0);
    try std.testing.expectEqual(null, sprack_dialect_name(sprack_dialect_count(), &len));

    const src = "t\nR1 a 0 1M\n.pz a 0 b 0 vol pz\n.end\n";
    const r = sprack_translate("ngspice", 7, "xyce", 4, src, src.len).?;
    defer sprack_result_free(r);
    const text = sprack_result_text(r, &len);
    try std.testing.expect(std.mem.indexOf(u8, text[0..len], "R1 a 0 1m") != null);
    const report = sprack_result_report(r, &len);
    try std.testing.expect(std.mem.indexOf(u8, report[0..len], "pole-zero") != null);
    try std.testing.expectEqual(1, sprack_result_errors(r));

    try std.testing.expectEqual(null, sprack_translate("pspice", 6, "xyce", 4, src, src.len));
    sprack_result_free(null);
}
