//! The core as a freestanding WebAssembly module, for a host with no
//! CPython extension (Pyodide): the four calls of `sprack._core` that take
//! and give text, over the same core functions, and no file, thread or
//! clock. Only the built-in dialects are known: a grammar file given by
//! path cannot be read here.
//!
//! The host writes its strings into memory it takes with `sprack_alloc`,
//! calls one entry point, then reads its results with `sprack_out`: what
//! a call gave lives until the next call. An entry point returns 0, or 1
//! with the reason in `sprack_out(2)` (an unknown dialect), or 2 when out
//! of memory.
//!
//! Contents:
//! - `pub export fn sprack_alloc(n: usize) ?[*]u8`
//! - `pub export fn sprack_free(p: [*]u8, n: usize) void`
//! - `pub export fn sprack_out(which: u32, len: *usize) [*]const u8`
//! - `pub export fn sprack_info() u32`
//! - `pub export fn sprack_translate(from, from_len, to, to_len, src, src_len) u32`
//! - `pub export fn sprack_read(d, d_len, src, src_len, library, env, env_len) u32`
//! - `pub export fn sprack_write(d, d_len, json, json_len, library) u32`

const std = @import("std");
const sprack = @import("sprack");
const ir = sprack.ir;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const gpa = std.heap.wasm_allocator;

/// The last call's text, report and error message, in one arena.
var last: std.heap.ArenaAllocator = .init(gpa);
var outs: [3][]const u8 = .{ "", "", "" };

const Fail = error{ Unknown, OutOfMemory, WriteFailed };

pub export fn sprack_alloc(n: usize) ?[*]u8 {
    const s = gpa.alloc(u8, n) catch return null;
    return s.ptr;
}

pub export fn sprack_free(p: [*]u8, n: usize) void {
    gpa.free(p[0..n]);
}

/// 0: the text (a netlist, or the info's or the IR's JSON); 1: the
/// report's JSON; 2: why the call failed.
pub export fn sprack_out(which: u32, len: *usize) [*]const u8 {
    assert(which < outs.len);
    len.* = outs[which].len;
    return outs[which].ptr;
}

pub export fn sprack_info() u32 {
    return run(infoBody, .{});
}

pub export fn sprack_translate(
    from: [*]const u8,
    from_len: usize,
    to: [*]const u8,
    to_len: usize,
    src: [*]const u8,
    src_len: usize,
) u32 {
    return run(translateBody, .{ from[0..from_len], to[0..to_len], src[0..src_len] });
}

/// `env`, when `env_len` is not 0: a netlist's JSON whose `env` says what
/// other files declare, as `_core.read` takes it.
// tidy: allow(too-many-parameters) the host passes plain numbers across the wasm boundary: a
// struct would have to be laid out in its memory by hand
pub export fn sprack_read(
    d: [*]const u8,
    d_len: usize,
    src: [*]const u8,
    src_len: usize,
    library: u32,
    env: [*]const u8,
    env_len: usize,
) u32 {
    return run(readBody, .{ d[0..d_len], src[0..src_len], library != 0, env[0..env_len] });
}

pub export fn sprack_write(
    d: [*]const u8,
    d_len: usize,
    json: [*]const u8,
    json_len: usize,
    library: u32,
) u32 {
    return run(writeBody, .{ d[0..d_len], json[0..json_len], library != 0 });
}

// ---- private ----

/// One call: the last call's results freed, then this one's kept.
fn run(comptime body: anytype, args: anytype) u32 {
    _ = last.reset(.free_all);
    outs = .{ "", "", "" };
    @call(.auto, body, .{last.allocator()} ++ args) catch |e| return switch (e) {
        error.Unknown => 1,
        error.OutOfMemory, error.WriteFailed => 2,
    };
    return 0;
}

fn dialect(a: Allocator, name: []const u8) Fail!*const sprack.Grammar {
    if (sprack.find(name)) |g| return g;
    var aw: std.Io.Writer.Allocating = .init(a);
    try aw.writer.print("unknown dialect '{s}'. Built in:", .{name[0..@min(name.len, 40)]});
    for (sprack.grammars) |*g| try aw.writer.print(" {s}", .{g.name});
    try aw.writer.writeAll("; a grammar file cannot be read on the web");
    outs[2] = aw.written();
    return error.Unknown;
}

fn report(a: Allocator, r: *const ir.Report) Fail![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    try sprack.json.writeReport(&aw.writer, r);
    return aw.written();
}

fn infoBody(a: Allocator) Fail!void {
    var aw: std.Io.Writer.Allocating = .init(a);
    try sprack.json.writeInfo(&aw.writer, sprack.grammars);
    outs[0] = aw.written();
}

fn translateBody(a: Allocator, from: []const u8, to: []const u8, src: []const u8) Fail!void {
    const gf = try dialect(a, from);
    const gt = try dialect(a, to);
    var r: ir.Report = .init(a);
    // A statement at a time, as the command and the extension do.
    var aw: std.Io.Writer.Allocating = .init(a);
    _ = sprack.stream.translate(a, gf, gt, src, &aw.writer, &r, &sprack.caps, .{}) catch
        return error.OutOfMemory;
    outs = .{ aw.written(), try report(a, &r), "" };
}

fn readBody(
    a: Allocator,
    d: []const u8,
    src: []const u8,
    library: bool,
    env: []const u8,
) Fail!void {
    const gf = try dialect(a, d);
    var r: ir.Report = .init(a);
    const e = if (env.len > 0) (try sprack.json.parseNetlist(a, env, &r)).env else null;
    const nl = try sprack.reader.read(gf, a, src, &r, .{ .env = e, .library = library });
    var aw: std.Io.Writer.Allocating = .init(a);
    try sprack.json.writeNetlist(&aw.writer, &nl);
    outs = .{ aw.written(), try report(a, &r), "" };
}

fn writeBody(a: Allocator, d: []const u8, json: []const u8, library: bool) Fail!void {
    const gt = try dialect(a, d);
    var r: ir.Report = .init(a);
    var nl = try sprack.json.parseNetlist(a, json, &r);
    nl.library = library;
    var aw: std.Io.Writer.Allocating = .init(a);
    sprack.write(a, gt, &aw.writer, &nl, &r) catch return error.OutOfMemory;
    outs = .{ aw.written(), try report(a, &r), "" };
}
