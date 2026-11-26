//! The `models ... end` section: each model family's spellings as a
//! `.model` card of this dialect, `family [polarity] = spelling | spelling`.
//!
//! Contents:
//! - `pub fn models(c: *C, g: *Grammar, lines: *Lines) Error!void`

const std = @import("std");
const schema = @import("schema");
const context = @import("context.zig");
const tables = @import("tables.zig");
const types = @import("types.zig");
const C = context.C;
const Error = context.Error;
const Lines = context.Lines;
const args = context.args;
const isNumber = context.isNumber;
const Grammar = tables.Grammar;
const ModelEntry = types.ModelEntry;
const ModelKv = types.ModelKv;
const ModelSpelling = types.ModelSpelling;
const ModelWhen = types.ModelWhen;

/// `models`, then its lines up to `end`.
pub fn models(c: *C, g: *Grammar, lines: *Lines) Error!void {
    g.models = try parseModels(c, lines, !g.lex.case_sensitive);
}

// ---- private ----

fn parseModels(c: *C, lines: *Lines, fold: bool) Error![]const ModelEntry {
    var out: []const ModelEntry = &.{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return out;
        out = try c.add(ModelEntry, out, try modelLine(c, lines.no, fold, line));
    }
    return c.fail(lines.no, "models section is missing 'end'", .{});
}

/// `family [polarity] = spelling | spelling [provided]`.
fn modelLine(c: *C, no: u32, fold: bool, line: []const u8) Error!ModelEntry {
    const eq = std.mem.indexOf(u8, line, " = ") orelse return c.fail(
        no,
        "model lines are `family [polarity] = spelling | spelling`",
        .{},
    );
    const lhs = try args(c, no, line[0..eq]);
    if (lhs.len < 1 or lhs.len > 2)
        return c.fail(no, "expected `family [polarity]` before '='", .{});
    if (schema.familyKind(lhs[0]) == null)
        return c.fail(no, "unknown model family '{s}'", .{lhs[0]});
    var spellings: []const ModelSpelling = &.{};
    var rhs = std.mem.trimEnd(u8, line[eq + 3 ..], " \t");
    const provided = std.mem.endsWith(u8, rhs, " provided");
    if (provided) rhs = rhs[0 .. rhs.len - " provided".len];
    var it = std.mem.splitScalar(u8, rhs, '|');
    while (it.next()) |alt|
        spellings = try c.add(ModelSpelling, spellings, try modelSpelling(c, no, fold, alt));
    // `splitScalar` gives at least one piece, empty or not.
    std.debug.assert(spellings.len > 0);
    return .{
        .family = lhs[0],
        .polarity = if (lhs.len == 2) lhs[1] else "",
        .spellings = spellings,
        .provided = provided,
    };
}

/// `type key=value ... [when cond ...]`, one spelling of a family.
fn modelSpelling(c: *C, no: u32, fold: bool, alt: []const u8) Error!ModelSpelling {
    const w = try args(c, no, alt);
    if (w.len == 0) return c.fail(no, "empty model spelling", .{});
    var kv: []const ModelKv = &.{};
    var when: []const ModelWhen = &.{};
    var conds = false;
    for (w[1..]) |pair| {
        if (std.mem.eql(u8, pair, "when")) {
            conds = true;
            continue;
        }
        if (conds) {
            when = try c.add(ModelWhen, when, try whenCond(c, no, fold, pair));
        } else kv = try c.add(ModelKv, kv, try modelKv(c, no, fold, pair));
    }
    if (conds and when.len == 0)
        return c.fail(no, "`when` with no condition after it", .{});
    // `args` gives no empty word.
    std.debug.assert(w[0].len > 0);
    return .{ .type = try c.foldIf(fold, w[0]), .kv = kv, .when = when };
}

/// `key=value` or `nodes>=n`, after `when`.
fn whenCond(c: *C, no: u32, fold: bool, pair: []const u8) Error!ModelWhen {
    // `args` gives no empty word.
    std.debug.assert(pair.len > 0);
    const ge = std.mem.indexOf(u8, pair, ">=");
    const pe = ge orelse (std.mem.indexOfScalar(u8, pair, '=') orelse return c.fail(
        no,
        "expected key=value or nodes>=n after `when` in '{s}'",
        .{pair},
    ));
    const key = pair[0..pe];
    const val = pair[pe + @as(usize, if (ge != null) 2 else 1) ..];
    if (val.len == 0 or !isNumber(val))
        return c.fail(no, "a `when` value is a number: '{s}'", .{pair});
    if (ge != null and !std.mem.eql(u8, key, "nodes"))
        return c.fail(
            no,
            "only `nodes>=n` compares; a parameter is `key=value`: '{s}'",
            .{pair},
        );
    return .{ .key = try c.foldIf(fold, key), .val = val, .ge = ge != null };
}

/// `!key`, `key>=n` or `key=value`, before any `when`.
fn modelKv(c: *C, no: u32, fold: bool, pair: []const u8) Error!ModelKv {
    // `args` gives no empty word.
    std.debug.assert(pair.len > 0);
    if (pair[0] == '!')
        return .{ .key = try c.foldIf(fold, pair[1..]), .val = "", .absent = true };
    if (std.mem.indexOf(u8, pair, ">=")) |ge| {
        if (!isNumber(pair[ge + 2 ..]))
            return c.fail(no, "`key>=n` takes a number: '{s}'", .{pair});
        return .{
            .key = try c.foldIf(fold, pair[0..ge]),
            .val = pair[ge + 2 ..],
            .absent = false,
            .min = true,
        };
    }
    const pe = std.mem.indexOfScalar(u8, pair, '=') orelse return c.fail(
        no,
        "expected key=value or !key in '{s}'",
        .{pair},
    );
    return .{ .key = try c.foldIf(fold, pair[0..pe]), .val = pair[pe + 1 ..], .absent = false };
}
