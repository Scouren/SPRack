//! sprack: SPICE dialect translator.
//!
//! Each file in `grammars/` is compiled when the binary is built into the
//! tables a reader and a writer for one dialect run on. Any dialect can be read into the shared IR and
//! written back out as any other.

const std = @import("std");
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

const Allocator = std.mem.Allocator;
pub const Grammar = grammar.Grammar;

pub const dialect_count = dialects.count;

/// One compiled grammar per `.spgrammar` file, in file name order: the
/// table itself, so a grammar found by name is one of these by address.
pub const grammars: *const [dialect_count]Grammar = &dialects.grammars;

/// Which dialects can write each kind and each model family, worked out at
/// compile time from the grammars themselves.
pub const caps: writer.Caps = blk: {
    @setEvalBranchQuota(1_000_000);
    var kinds: [schema.kind_count][]const u8 = undefined;
    for (schema.table, 0..) |info, k| {
        var s: []const u8 = "";
        for (grammars) |g| {
            if (g.canWrite(info.kind)) s = s ++ (if (s.len > 0) ", " else "") ++ g.name;
        }
        kinds[k] = s;
    }
    var fams: []const writer.Caps.FamilyCap = &.{};
    for (schema.families) |f| {
        for ([_][]const u8{ "", "n", "p", "npn", "pnp" }) |pol| {
            var s: []const u8 = "";
            for (grammars) |g| {
                if (g.hasModel(f.name, pol)) s = s ++ (if (s.len > 0) ", " else "") ++ g.name;
            }
            if (s.len > 0) fams = fams ++ &[_]writer.Caps.FamilyCap{.{ .family = f.name, .polarity = pol, .dialects = s }};
        }
    }
    var words: []const writer.Caps.WordCap = &.{};
    for (.{ "functions", "variables", "operators" }) |field| {
        for (@field(schema, field)) |name| {
            var s: []const u8 = "";
            for (grammars) |g| {
                for (@field(g, field)) |e| {
                    if (std.mem.eql(u8, e.canon, name)) s = s ++ (if (s.len > 0) ", " else "") ++ g.name;
                }
            }
            if (s.len > 0) words = words ++ &[_]writer.Caps.WordCap{.{ .name = name, .dialects = s }};
        }
    }
    break :blk .{ .kinds = kinds, .families = fams, .words = words, .grammars = grammars };
};

pub const find = dialects.find;
/// The index a statement carries for dialect `name` (`ir.Stmt.dialect`).
pub const internDialect = dialects.intern;
pub const dialectName = dialects.nameOf;

/// Whether a dialect argument names a grammar file rather than a built-in.
pub fn isGrammarPath(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".spgrammar");
}

pub const LoadError = error{ UnknownDialect, CannotRead, BadGrammar, TooManyDialects, OutOfMemory };

/// A built-in dialect by name, or a `.spgrammar` file by path compiled now.
/// A loaded grammar lives in `arena` with its source. On `CannotRead` and
/// `BadGrammar`, `diag.msg` says why (`file:line: message` for the latter).
/// `caps` knows only the built-ins, so an error naming "dialects that define
/// it" never lists a loaded grammar.
pub fn resolve(arena: Allocator, io: std.Io, name: []const u8, diag: *grammar.Diag) LoadError!*const Grammar {
    if (!isGrammarPath(name)) return find(name) orelse error.UnknownDialect;
    const src = std.Io.Dir.cwd().readFileAlloc(io, name, arena, .limited(16 << 20)) catch |e| {
        diag.msg = try std.fmt.allocPrint(arena, "cannot read {s}: {s}", .{ name, @errorName(e) });
        return error.CannotRead;
    };
    const g = try arena.create(Grammar);
    g.* = try grammar.compile(arena, src, name, diag);
    if (try internDialect(g.name) == null) {
        diag.msg = try std.fmt.allocPrint(arena, "{s}: dialect '{s}' is one more than the 255 dialect names a process can hold", .{ name, g.name });
        return error.TooManyDialects;
    }
    return g;
}

/// A dialect chosen at compile time. A misspelt name is a compile error.
pub fn Dialect(comptime name: []const u8) type {
    const g: *const Grammar = comptime find(name) orelse @compileError("no grammars/" ++ name ++ ".spgrammar");
    return struct {
        pub const spec = g;

        pub fn read(arena: Allocator, src: []const u8, report: *ir.Report) Allocator.Error!ir.Netlist {
            return reader.read(g, arena, src, report, .{});
        }

        pub fn write(arena: Allocator, out: *std.Io.Writer, nl: *const ir.Netlist, report: *ir.Report) !void {
            return writer.write(g, arena, out, nl, report, &caps, null);
        }
    };
}

pub fn read(arena: Allocator, g: *const Grammar, src: []const u8, report: *ir.Report) Allocator.Error!ir.Netlist {
    return reader.read(g, arena, src, report, .{});
}

pub fn write(arena: Allocator, g: *const Grammar, out: *std.Io.Writer, nl: *const ir.Netlist, report: *ir.Report) !void {
    return writer.write(g, arena, out, nl, report, &caps, null);
}

/// `back`, a translation of `src` into `g` read back, is the same circuit,
/// counting the options `g` was given because `src`'s dialect assumes other
/// defaults (`writer.defaultOptions`).
pub fn sameTranslation(arena: Allocator, g: *const Grammar, src: *const ir.Netlist, back: *const ir.Netlist) Allocator.Error!bool {
    const d = try writer.defaultOptions(arena, g, src) orelse return ir.sameCircuit(src, back);
    var with = src.*;
    with.stmts = try arena.alloc(ir.Stmt, src.stmts.len + 1);
    with.stmts[0] = d;
    @memcpy(with.stmts[1..], src.stmts);
    return ir.sameCircuit(&with, back);
}

/// As `read` and `write`, for one file of a project: `env` holds the names
/// the project's other files declare.
pub fn readIn(arena: Allocator, g: *const Grammar, src: []const u8, report: *ir.Report, env: ?*const ir.Env) Allocator.Error!ir.Netlist {
    return reader.read(g, arena, src, report, .{ .env = env });
}

pub fn writeIn(arena: Allocator, g: *const Grammar, out: *std.Io.Writer, nl: *const ir.Netlist, report: *ir.Report, env: ?*const ir.Env) !void {
    return writer.write(g, arena, out, nl, report, &caps, env);
}

pub const TranslateError = error{UnknownDialect} || Allocator.Error || std.Io.Writer.Error;

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
pub fn translateAlloc(arena: Allocator, from: []const u8, to: []const u8, src: []const u8, report: *ir.Report) TranslateError![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try translate(arena, from, to, src, &aw.writer, report);
    return aw.written();
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
