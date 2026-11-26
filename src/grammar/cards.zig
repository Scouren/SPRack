//! Directives of how a dialect's model of a family computes, by the
//! parameters of its card: `threshold`, `computes`, `edge` and `noparam`.
//!
//! Contents:
//! - `pub fn threshold(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn computes(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn edge(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn noparam(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`

const std = @import("std");
const schema = @import("schema");
const context = @import("context.zig");
const tables = @import("tables.zig");
const types = @import("types.zig");
const C = context.C;
const Error = context.Error;
const args = context.args;
const Grammar = tables.Grammar;
const Computes = types.Computes;
const Edge = types.Edge;
const NoParam = types.NoParam;
const Threshold = types.Threshold;

/// `threshold family : on off = mid half`.
pub fn threshold(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const e = try args(c, no, rest);
    if (e.len != 7 or !std.mem.eql(u8, e[1], ":") or !std.mem.eql(u8, e[4], "="))
        return c.fail(no, "threshold is `threshold family : on off = mid half`", .{});
    if (schema.familyKind(e[0]) == null)
        return c.fail(no, "unknown model family '{s}'", .{e[0]});
    g.thresholds = try c.add(
        Threshold,
        g.thresholds,
        .{ .family = e[0], .on = e[2], .off = e[3], .mid = e[5], .half = e[6] },
    );
}

/// `computes family key... : formula`.
pub fn computes(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "computes is `computes family key... : formula`",
        .{},
    );
    const e = try args(c, no, rest[0..colon]);
    if (e.len < 2) return c.fail(no, "computes needs a model family and a parameter", .{});
    if (schema.familyKind(e[0]) == null)
        return c.fail(no, "unknown model family '{s}'", .{e[0]});
    g.computes = try c.add(
        Computes,
        g.computes,
        .{ .family = e[0], .keys = e[1..], .text = rest[colon + 3 ..] },
    );
}

/// `edge family key : text`.
pub fn edge(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "edge is `edge family key : text`",
        .{},
    );
    const e = try args(c, no, rest[0..colon]);
    if (e.len != 2) return c.fail(no, "edge needs a model family and a parameter", .{});
    if (schema.familyKind(e[0]) == null)
        return c.fail(no, "unknown model family '{s}'", .{e[0]});
    g.edges = try c.add(
        Edge,
        g.edges,
        .{ .family = e[0], .key = e[1], .text = rest[colon + 3 ..] },
    );
}

/// `noparam family key[=value] warning|error : text`.
pub fn noparam(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "noparam is `noparam family key[=value] warning|error : text`",
        .{},
    );
    const e = try args(c, no, rest[0..colon]);
    if (e.len != 3)
        return c.fail(no, "noparam needs a model family, a parameter and a severity", .{});
    if (!(std.mem.eql(u8, e[2], "error") or std.mem.eql(u8, e[2], "warning")))
        return c.fail(no, "noparam severity is warning or error, not '{s}'", .{e[2]});
    if (schema.familyKind(e[0]) == null)
        return c.fail(no, "unknown model family '{s}'", .{e[0]});
    const eq = std.mem.indexOfScalar(u8, e[1], '=') orelse e[1].len;
    // The key is the word before any '=' in it.
    std.debug.assert(eq <= e[1].len);
    if (eq < e[1].len)
        _ = std.fmt.parseFloat(f64, e[1][eq + 1 ..]) catch return c.fail(
            no,
            "noparam takes a plain number after '='",
            .{},
        );
    g.noparams = try c.add(NoParam, g.noparams, .{
        .family = e[0],
        .key = e[1][0..eq],
        .value = if (eq < e[1].len) e[1][eq + 1 ..] else "",
        .err = std.mem.eql(u8, e[2], "error"),
        .text = rest[colon + 3 ..],
    });
}
