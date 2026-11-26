//! Directives of how a dialect spells and means names: the sections
//! `functions`, `variables`, `operators`, `params`, `modelparams` and
//! `signals`, one name a line up to `end`, and the lines `differs` and `means`.
//!
//! Contents:
//! - `pub fn functions(c: *C, g: *Grammar, lines: *Lines) Error!void`
//! - `pub fn variables(c: *C, g: *Grammar, lines: *Lines) Error!void`
//! - `pub fn operators(c: *C, g: *Grammar, lines: *Lines) Error!void`
//! - `pub fn params(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void`
//! - `pub fn modelparams(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void`
//! - `pub fn signals(c: *C, g: *Grammar, lines: *Lines) Error!void`
//! - `pub fn differs(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn means(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`

const std = @import("std");
const schema = @import("schema");
const Kind = schema.Kind;
const context = @import("context.zig");
const tables = @import("tables.zig");
const types = @import("types.zig");
const C = context.C;
const Error = context.Error;
const Lines = context.Lines;
const args = context.args;
const kindOf = context.kindOf;
const Grammar = tables.Grammar;
const Differs = types.Differs;
const Means = types.Means;
const ModelParamTable = types.ModelParamTable;
const ParamTable = types.ParamTable;
const SignalForm = types.SignalForm;
const Spellings = types.Spellings;

pub fn functions(c: *C, g: *Grammar, lines: *Lines) Error!void {
    const fold = !g.lex.case_sensitive;
    g.functions = try parseSpellings(c, lines, fold, "function", &schema.functions);
}

pub fn variables(c: *C, g: *Grammar, lines: *Lines) Error!void {
    const fold = !g.lex.case_sensitive;
    g.variables = try parseSpellings(c, lines, fold, "variable", &schema.variables);
}

/// Operators are spelled as written, whatever the case of the dialect.
pub fn operators(c: *C, g: *Grammar, lines: *Lines) Error!void {
    g.operators = try parseSpellings(c, lines, false, "operator", &schema.operators);
}

/// `params kind`, then its parameters up to `end`.
pub fn params(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void {
    const fold = !g.lex.case_sensitive;
    const kind = try kindOf(c, lines.no, rest);
    if (schema.slotOf(kind, "params") == null)
        return c.fail(lines.no, "params needs a kind with parameters", .{});
    g.params = try c.add(
        ParamTable,
        g.params,
        .{ .kind = kind, .names = try parseSpellings(c, lines, fold, "parameter", null) },
    );
}

/// `modelparams family [only]`, then its parameters up to `end`.
pub fn modelparams(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void {
    const fold = !g.lex.case_sensitive;
    const only = std.mem.endsWith(u8, rest, " only");
    const fam = if (only) rest[0 .. rest.len - " only".len] else rest;
    if (schema.familyKind(fam) == null)
        return c.fail(lines.no, "unknown model family '{s}'", .{fam});
    g.modelparams = try c.add(
        ModelParamTable,
        g.modelparams,
        .{
            .family = fam,
            .names = try parseSpellings(c, lines, fold, "model parameter", null),
            .only = only,
        },
    );
}

/// `signals`, then `form = "template"` lines up to `end`.
pub fn signals(c: *C, g: *Grammar, lines: *Lines) Error!void {
    g.signals = try parseSignals(c, lines, !g.lex.case_sensitive);
}

/// `differs function-or-operator : reason`.
pub fn differs(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "differs is `differs function-or-operator : reason`",
        .{},
    );
    const canon = std.mem.trim(u8, rest[0..colon], " \t");
    var known = false;
    for (schema.functions) |k| known = known or std.mem.eql(u8, k, canon);
    for (schema.operators) |k| known = known or std.mem.eql(u8, k, canon);
    if (!known) return c.fail(no, "unknown function or operator '{s}'", .{canon});
    g.differs = try c.add(Differs, g.differs, .{ .canon = canon, .text = rest[colon + 3 ..] });
}

/// `means [kind] f(x, y) = expression`.
pub fn means(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const eq = std.mem.indexOf(u8, rest, " = ") orelse return c.fail(
        no,
        "means is `means [kind] f(x, y) = expression`",
        .{},
    );
    var lhs = std.mem.trim(u8, rest[0..eq], " \t");
    var kind: ?Kind = null;
    if (std.mem.indexOfScalar(u8, lhs, ' ')) |sp|
        if (sp < (std.mem.indexOfScalar(u8, lhs, '(') orelse lhs.len)) {
            kind = try kindOf(c, no, lhs[0..sp]);
            lhs = std.mem.trim(u8, lhs[sp + 1 ..], " \t");
        };
    const open = std.mem.indexOfScalar(u8, lhs, '(') orelse return c.fail(
        no,
        "means needs `f(x, y)` before '='",
        .{},
    );
    if (lhs[lhs.len - 1] != ')') return c.fail(no, "means needs `f(x, y)` before '='", .{});
    const canon = lhs[0..open];
    if (!schema.isFunction(canon)) return c.fail(no, "unknown function '{s}'", .{canon});
    // `lhs` ends in ')' and holds a '(': the arguments lie between them.
    std.debug.assert(open < lhs.len - 1);
    var margs: []const []const u8 = &.{};
    var it = std.mem.splitScalar(u8, lhs[open + 1 .. lhs.len - 1], ',');
    while (it.next()) |a| margs = try c.add([]const u8, margs, std.mem.trim(u8, a, " \t"));
    g.means = try c.add(
        Means,
        g.means,
        .{
            .kind = kind,
            .canon = canon,
            .args = margs,
            .body = std.mem.trim(u8, rest[eq + 3 ..], " \t"),
        },
    );
}

// ---- private ----

/// `known` null: any name goes (instance parameters), and `name>0` marks
/// one that must be positive.
fn parseSpellings(
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
        // A line `Lines.next` gives starts with a character that is no blank.
        std.debug.assert(a.len > 0);
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

fn parseSignals(c: *C, lines: *Lines, fold: bool) Error![]const SignalForm {
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
