//! C ABI over the same core the CLI uses. Strings cross the boundary as
//! pointer and length; results are owned by the handle that produced them.

const std = @import("std");
const sprack = @import("sprack");

const gpa = std.heap.page_allocator;

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8 = "",
    report: []const u8 = "",
    errors: usize = 0,
    warnings: usize = 0,
};

export fn sprack_abi_version() c_int {
    return 1;
}

export fn sprack_dialect_count() usize {
    return sprack.dialect_count;
}

export fn sprack_dialect_name(index: usize, len: *usize) ?[*]const u8 {
    if (index >= sprack.dialect_count) return null;
    len.* = sprack.grammars[index].name.len;
    return sprack.grammars[index].name.ptr;
}

/// Returns null only for an unknown dialect name or out of memory.
export fn sprack_translate(
    from: [*]const u8,
    from_len: usize,
    to: [*]const u8,
    to_len: usize,
    src: [*]const u8,
    src_len: usize,
) ?*Result {
    const r = gpa.create(Result) catch return null;
    r.* = .{ .arena = .init(gpa) };
    const a = r.arena.allocator();
    var report: sprack.ir.Report = .init(a);
    r.text = sprack.translateAlloc(a, from[0..from_len], to[0..to_len], src[0..src_len], &report) catch {
        sprack_result_free(r);
        return null;
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    report.print(&aw.writer) catch {};
    r.report = aw.written();
    r.errors = report.count(.@"error");
    r.warnings = report.count(.warning);
    return r;
}

export fn sprack_result_text(r: *const Result, len: *usize) [*]const u8 {
    len.* = r.text.len;
    return r.text.ptr;
}

export fn sprack_result_report(r: *const Result, len: *usize) [*]const u8 {
    len.* = r.report.len;
    return r.report.ptr;
}

export fn sprack_result_errors(r: *const Result) usize {
    return r.errors;
}

export fn sprack_result_warnings(r: *const Result) usize {
    return r.warnings;
}

export fn sprack_result_free(r: ?*Result) void {
    const p = r orelse return;
    p.arena.deinit();
    gpa.destroy(p);
}
