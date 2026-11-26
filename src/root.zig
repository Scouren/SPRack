//! sprack: the public surface of the translator.
//!
//! Text of one dialect → canonical statements (`ir.Netlist`) → text of
//! another, with a report of what did not cross. Each file of `grammars/` is
//! one dialect, compiled when the binary is built into the tables a reader
//! and a writer run on; a `.spgrammar` file named by path is compiled when
//! asked for (`resolve`).
//!
//! Contents:
//! - modules: `schema`, `ir`, `grammar`, `lexer`, `reader`, `writer`, `expr`,
//!   `json`, `project`, `stats`, `alter`, `stream`
//! - `pub const Grammar`, `pub const dialect_count`, `pub const grammars`
//! - `pub const caps: writer.Caps`
//! - `pub const LoadError`, `pub const TranslateError`
//! - `pub const find`, `pub const internDialect`, `pub const dialectName`
//! - `pub fn isGrammarPath(name: []const u8) bool`
//! - `pub fn resolve(arena, io, name, diag) LoadError!*const Grammar`
//! - `pub fn Dialect(comptime name: []const u8) type` with `spec`, `read`, `write`
//! - `pub fn read(arena, g, src, report) Allocator.Error!ir.Netlist`
//! - `pub fn write(arena, g, out, nl, report) !void`
//! - `pub fn readIn(arena, g, src, report, env) Allocator.Error!ir.Netlist`
//! - `pub fn writeIn(arena, g, out, nl, report, env) !void`
//! - `pub fn sameTranslation(arena, g, src, back) Allocator.Error!bool`
//! - `pub fn translate(arena, from, to, src, out, report) TranslateError!void`
//! - `pub fn translateAlloc(arena, from, to, src, report) TranslateError![]const u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const dialects = @import("dialects");
pub const schema = @import("schema");
pub const ir = @import("ir");
pub const grammar = @import("grammar");
pub const lexer = @import("lexer");
pub const reader = @import("reader");
pub const writer = @import("writer");
pub const expr = @import("expr");
pub const json = @import("json");
pub const project = @import("project");
pub const stats = @import("stats");
pub const alter = @import("alter");
pub const stream = @import("stream");

pub const Grammar = grammar.Grammar;

pub const dialect_count = dialects.count;

/// One compiled grammar per `.spgrammar` file, in file name order: the
/// table itself, so a grammar found by name is one of these by address.
pub const grammars: *const [dialect_count]Grammar = &dialects.grammars;

/// Which dialects can write each kind, each model family and each word of
/// an expression, worked out when compiling from the grammars themselves.
pub const caps: writer.Caps = .{
    .kinds = kindCaps(),
    .families = familyCaps(),
    .words = wordCaps(),
    .grammars = grammars,
};

pub const LoadError = error{ UnknownDialect, CannotRead, BadGrammar, TooManyDialects, OutOfMemory };

pub const TranslateError = error{UnknownDialect} || Allocator.Error || std.Io.Writer.Error;

/// The built-in grammar of that name, case ignored.
pub const find = dialects.find;
/// The index a statement carries for dialect `name` (`ir.Stmt.dialect`).
pub const internDialect = dialects.intern;
/// The name behind an index from `internDialect`; "" for 0.
pub const dialectName = dialects.nameOf;

/// The largest grammar file `resolve` reads.
const grammar_bytes_max = 16 << 20;

/// Whether a dialect argument names a grammar file rather than a built-in.
pub fn isGrammarPath(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".spgrammar");
}

/// A built-in dialect by name, or a `.spgrammar` file by path compiled now.
/// A loaded grammar lives in `arena` with its source. On `CannotRead` and
/// `BadGrammar`, `diag.msg` says why (`file:line: message` for the latter).
/// `caps` knows only the built-ins, so an error naming "dialects that define
/// it" never lists a loaded grammar.
pub fn resolve(
    arena: Allocator,
    io: std.Io,
    name: []const u8,
    diag: *grammar.Diag,
) LoadError!*const Grammar {
    if (!isGrammarPath(name)) return find(name) orelse error.UnknownDialect;
    assert(name.len > 0);
    const cwd = std.Io.Dir.cwd();
    const src = cwd.readFileAlloc(io, name, arena, .limited(grammar_bytes_max)) catch |e| {
        diag.msg = try std.fmt.allocPrint(arena, "cannot read {s}: {s}", .{ name, @errorName(e) });
        return error.CannotRead;
    };
    const g = try arena.create(Grammar);
    g.* = try grammar.compile(arena, src, name, diag);
    assert(g.name.len > 0);
    if (try internDialect(g.name) == null) {
        diag.msg = try std.fmt.allocPrint(
            arena,
            "{s}: dialect '{s}' is one more than the 255 dialect names a process can hold",
            .{ name, g.name },
        );
        return error.TooManyDialects;
    }
    return g;
}

/// A dialect chosen at compile time. A misspelt name is a compile error.
pub fn Dialect(comptime name: []const u8) type {
    const g: *const Grammar = comptime find(name) orelse
        @compileError("no grammars/" ++ name ++ ".spgrammar");
    return struct {
        pub const spec = g;

        pub fn read(
            arena: Allocator,
            src: []const u8,
            report: *ir.Report,
        ) Allocator.Error!ir.Netlist {
            return reader.read(g, arena, src, report, .{});
        }

        pub fn write(
            arena: Allocator,
            out: *std.Io.Writer,
            nl: *const ir.Netlist,
            report: *ir.Report,
        ) !void {
            return writer.write(g, arena, out, nl, report, &caps, null);
        }
    };
}

pub fn read(
    arena: Allocator,
    g: *const Grammar,
    src: []const u8,
    report: *ir.Report,
) Allocator.Error!ir.Netlist {
    return reader.read(g, arena, src, report, .{});
}

pub fn write(
    arena: Allocator,
    g: *const Grammar,
    out: *std.Io.Writer,
    nl: *const ir.Netlist,
    report: *ir.Report,
) !void {
    return writer.write(g, arena, out, nl, report, &caps, null);
}

/// As `read` and `write`, for one file of a project: `env` holds the names
/// the project's other files declare.
pub fn readIn(
    arena: Allocator,
    g: *const Grammar,
    src: []const u8,
    report: *ir.Report,
    env: ?*const ir.Env,
) Allocator.Error!ir.Netlist {
    return reader.read(g, arena, src, report, .{ .env = env });
}

pub fn writeIn(
    arena: Allocator,
    g: *const Grammar,
    out: *std.Io.Writer,
    nl: *const ir.Netlist,
    report: *ir.Report,
    env: ?*const ir.Env,
) !void {
    return writer.write(g, arena, out, nl, report, &caps, env);
}

/// `back`, a translation of `src` into `g` read back, is the same circuit,
/// counting the options `g` was given because `src`'s dialect assumes other
/// defaults (`writer.defaultOptions`).
pub fn sameTranslation(
    arena: Allocator,
    g: *const Grammar,
    src: *const ir.Netlist,
    back: *const ir.Netlist,
) Allocator.Error!bool {
    const d = try writer.defaultOptions(arena, g, src) orelse return ir.sameCircuit(src, back);
    var with = src.*;
    with.stmts = try arena.alloc(ir.Stmt, src.stmts.len + 1);
    with.stmts[0] = d;
    @memcpy(with.stmts[1..], src.stmts);
    return ir.sameCircuit(&with, back);
}

/// Read `src` as dialect `from` and write it as dialect `to`. Check
/// `report.hasErrors()` afterwards: output is still produced, with the
/// statements that could not be written left as comments.
pub fn translate(
    arena: Allocator,
    from: []const u8,
    to: []const u8,
    src: []const u8,
    out: *std.Io.Writer,
    report: *ir.Report,
) TranslateError!void {
    const gf = find(from) orelse return error.UnknownDialect;
    const gt = find(to) orelse return error.UnknownDialect;
    _ = try stream.translate(arena, gf, gt, src, out, report, &caps, .{});
}

/// Convenience for tests and bindings: translate into a fresh buffer.
pub fn translateAlloc(
    arena: Allocator,
    from: []const u8,
    to: []const u8,
    src: []const u8,
    report: *ir.Report,
) TranslateError![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try translate(arena, from, to, src, &aw.writer, report);
    return aw.written();
}

// ---- private ----

/// `names` and one more, separated as an error message lists them.
fn joined(comptime names: []const u8, comptime name: []const u8) []const u8 {
    return names ++ (if (names.len > 0) ", " else "") ++ name;
}

/// For each kind, the dialects whose grammar can write it.
fn kindCaps() [schema.kind_count][]const u8 {
    @setEvalBranchQuota(1_000_000);
    var kinds: [schema.kind_count][]const u8 = undefined;
    for (schema.table, &kinds) |info, *names| {
        names.* = "";
        for (grammars) |g| {
            if (g.canWrite(info.kind)) names.* = joined(names.*, g.name);
        }
    }
    return kinds;
}

/// For each model family and polarity some dialect has, those dialects.
fn familyCaps() []const writer.Caps.FamilyCap {
    @setEvalBranchQuota(1_000_000);
    var families: []const writer.Caps.FamilyCap = &.{};
    for (schema.families) |f| {
        for ([_][]const u8{ "", "n", "p", "npn", "pnp" }) |polarity| {
            var names: []const u8 = "";
            for (grammars) |g| {
                if (g.hasModel(f.name, polarity)) names = joined(names, g.name);
            }
            if (names.len == 0) continue;
            const cap: writer.Caps.FamilyCap = .{
                .family = f.name,
                .polarity = polarity,
                .dialects = names,
            };
            families = families ++ &[_]writer.Caps.FamilyCap{cap};
        }
    }
    assert(families.len > 0);
    return families;
}

/// For each function, variable and operator some dialect spells, those
/// dialects: one entry for each spelling line of the word.
fn wordCaps() []const writer.Caps.WordCap {
    @setEvalBranchQuota(1_000_000);
    var words: []const writer.Caps.WordCap = &.{};
    for (.{ "functions", "variables", "operators" }) |field| {
        for (@field(schema, field)) |name| {
            var names: []const u8 = "";
            for (grammars) |g| {
                for (@field(g, field)) |e| {
                    if (std.mem.eql(u8, e.canon, name)) names = joined(names, g.name);
                }
            }
            if (names.len == 0) continue;
            words = words ++ &[_]writer.Caps.WordCap{.{ .name = name, .dialects = names }};
        }
    }
    return words;
}

test {
    _ = schema;
    _ = ir;
    _ = grammar;
    _ = lexer;
    _ = expr;
    _ = json;
    _ = project;
    _ = stats;
    _ = alter;
    _ = stream;
    _ = @import("tests.zig");
}
