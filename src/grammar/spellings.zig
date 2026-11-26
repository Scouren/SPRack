//! Sections that list spellings, one a line up to `end`: `models`,
//! `functions`, `variables`, `operators`, `params`, `modelparams`, `signals`.
//!
//! Contents:
//! - `pub fn parseModels(c: *C, lines: *Lines, fold: bool) Error![]const ModelEntry`
//! - `pub fn parseSpellings(c: *C, lines: *Lines, fold: bool, what: []const u8,
//!   known: ?[]const []const u8) Error![]const Spellings`
//! - `pub fn parseSignals(c: *C, lines: *Lines, fold: bool) Error![]const SignalForm`

const std = @import("std");
const schema = @import("schema");
const context = @import("context.zig");
const types = @import("types.zig");
const C = context.C;
const Error = context.Error;
const Lines = context.Lines;
const args = context.args;
const isNumber = context.isNumber;
const ModelEntry = types.ModelEntry;
const ModelKv = types.ModelKv;
const ModelSpelling = types.ModelSpelling;
const ModelWhen = types.ModelWhen;
const SignalForm = types.SignalForm;
const Spellings = types.Spellings;

pub fn parseModels(c: *C, lines: *Lines, fold: bool) Error![]const ModelEntry {
    var out: []const ModelEntry = &.{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return out;
        const eq = std.mem.indexOf(u8, line, " = ") orelse return c.fail(
            lines.no,
            "model lines are `family [polarity] = spelling | spelling`",
            .{},
        );
        const lhs = try args(c, lines.no, line[0..eq]);
        if (lhs.len < 1 or lhs.len > 2)
            return c.fail(lines.no, "expected `family [polarity]` before '='", .{});
        if (schema.familyKind(lhs[0]) == null)
            return c.fail(lines.no, "unknown model family '{s}'", .{lhs[0]});
        var spellings: []const ModelSpelling = &.{};
        var rhs = std.mem.trimEnd(u8, line[eq + 3 ..], " \t");
        const provided = std.mem.endsWith(u8, rhs, " provided");
        if (provided) rhs = rhs[0 .. rhs.len - " provided".len];
        var it = std.mem.splitScalar(u8, rhs, '|');
        while (it.next()) |alt| {
            const w = try args(c, lines.no, alt);
            if (w.len == 0) return c.fail(lines.no, "empty model spelling", .{});
            var kv: []const ModelKv = &.{};
            var when: []const ModelWhen = &.{};
            var conds = false;
            for (w[1..]) |pair| {
                if (std.mem.eql(u8, pair, "when")) {
                    conds = true;
                    continue;
                }
                if (conds) {
                    const ge = std.mem.indexOf(u8, pair, ">=");
                    const pe = ge orelse (std.mem.indexOfScalar(u8, pair, '=') orelse return c.fail(
                        lines.no,
                        "expected key=value or nodes>=n after `when` in '{s}'",
                        .{pair},
                    ));
                    const key = pair[0..pe];
                    const val = pair[pe + @as(usize, if (ge != null) 2 else 1) ..];
                    if (val.len == 0 or !isNumber(val))
                        return c.fail(lines.no, "a `when` value is a number: '{s}'", .{pair});
                    if (ge != null and !std.mem.eql(u8, key, "nodes"))
                        return c.fail(
                            lines.no,
                            "only `nodes>=n` compares; a parameter is `key=value`: '{s}'",
                            .{pair},
                        );
                    when = try c.add(
                        ModelWhen,
                        when,
                        .{ .key = try c.foldIf(fold, key), .val = val, .ge = ge != null },
                    );
                    continue;
                }
                if (pair[0] == '!') {
                    kv = try c.add(
                        ModelKv,
                        kv,
                        .{ .key = try c.foldIf(fold, pair[1..]), .val = "", .absent = true },
                    );
                } else if (std.mem.indexOf(u8, pair, ">=")) |ge| {
                    if (!isNumber(pair[ge + 2 ..]))
                        return c.fail(lines.no, "`key>=n` takes a number: '{s}'", .{pair});
                    kv = try c.add(
                        ModelKv,
                        kv,
                        .{
                            .key = try c.foldIf(fold, pair[0..ge]),
                            .val = pair[ge + 2 ..],
                            .absent = false,
                            .min = true,
                        },
                    );
                } else {
                    const pe = std.mem.indexOfScalar(u8, pair, '=') orelse return c.fail(
                        lines.no,
                        "expected key=value or !key in '{s}'",
                        .{pair},
                    );
                    kv = try c.add(
                        ModelKv,
                        kv,
                        .{
                            .key = try c.foldIf(fold, pair[0..pe]),
                            .val = pair[pe + 1 ..],
                            .absent = false,
                        },
                    );
                }
            }
            if (conds and when.len == 0)
                return c.fail(lines.no, "`when` with no condition after it", .{});
            spellings = try c.add(
                ModelSpelling,
                spellings,
                .{ .type = try c.foldIf(fold, w[0]), .kv = kv, .when = when },
            );
        }
        out = try c.add(ModelEntry, out, .{
            .family = lhs[0],
            .polarity = if (lhs.len == 2) lhs[1] else "",
            .spellings = spellings,
            .provided = provided,
        });
    }
    return c.fail(lines.no, "models section is missing 'end'", .{});
}

/// `known` null: any name goes (instance parameters), and `name>0` marks
/// one that must be positive.
pub fn parseSpellings(
    c: *C,
    lines: *Lines,
    fold: bool,
    what: []const u8,
    known: ?[]const []const u8,
) Error![]const Spellings {
    var out: []const Spellings = &.{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return out;
        const a = try args(c, lines.no, line);
        var names: []const []const u8 = &.{};
        var spell: []const []const u8 = &.{};
        if (std.mem.eql(u8, a[0], "same")) {
            names = a[1..];
        } else {
            names = a[0..1];
            const from: usize = if (a.len > 1 and std.mem.eql(u8, a[1], "=")) 2 else 1;
            if (a.len <= from)
                return c.fail(lines.no, "expected `name = spelling ...` or `same name ...`", .{});
            spell = a[from..];
        }
        // `canon = spelling / 2` (a `modelparams` table).
        const halved = known == null and spell.len == 3 and std.mem.eql(u8, spell[1], "/");
        if (halved) {
            if (!std.mem.eql(u8, spell[2], "2"))
                return c.fail(lines.no, "a {s} is halved or not: `name = spelling / 2`", .{what});
            spell = spell[0..1];
        }
        for (names) |raw| {
            const positive = known == null and std.mem.endsWith(u8, raw, ">0");
            const n = if (positive) raw[0 .. raw.len - 2] else raw;
            if (known) |list| {
                var ok = false;
                for (list) |k| {
                    if (std.mem.eql(u8, k, n)) ok = true;
                }
                if (!ok) return c.fail(lines.no, "unknown {s} '{s}'", .{ what, n });
            }
            var sp: []const []const u8 = &.{};
            if (spell.len == 0) sp = try c.add([]const u8, sp, try c.foldIf(fold, n));
            for (spell) |x| sp = try c.add([]const u8, sp, try c.foldIf(fold, x));
            out = try c.add(
                Spellings,
                out,
                .{ .canon = n, .spellings = sp, .positive = positive, .halved = halved },
            );
        }
    }
    return c.fail(lines.no, "{s} section is missing 'end'", .{what});
}

pub fn parseSignals(c: *C, lines: *Lines, fold: bool) Error![]const SignalForm {
    var out: []const SignalForm = &.{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return out;
        const a = try args(c, lines.no, line);
        if (a.len != 3 or !std.mem.eql(u8, a[1], "="))
            return c.fail(lines.no, "signal lines are `form = \"template\"`", .{});
        var ok = false;
        for (schema.signal_forms) |k| {
            if (std.mem.eql(u8, k, a[0])) ok = true;
        }
        if (!ok) return c.fail(lines.no, "unknown signal form '{s}'", .{a[0]});
        out = try c.add(SignalForm, out, .{ .form = a[0], .template = try c.foldIf(fold, a[2]) });
    }
    return c.fail(lines.no, "signals section is missing 'end'", .{});
}
