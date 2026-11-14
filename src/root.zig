//! sprack: SPICE dialect translator.
//!
//! Each file in `grammars/` is compiled at build time into a reader and a
//! writer for one dialect. Any dialect can be read into the shared IR and
//! written back out as any other.

const std = @import("std");
const registry = @import("registry");

pub const schema = @import("schema.zig");
pub const ir = @import("ir.zig");
pub const grammar = @import("grammar.zig");
pub const lexer = @import("lexer.zig");
pub const reader = @import("reader.zig");
pub const writer = @import("writer.zig");
pub const expr = @import("expr.zig");
pub const json = @import("json.zig");
pub const project = @import("project.zig");

const Allocator = std.mem.Allocator;
pub const Grammar = grammar.Grammar;

pub const dialect_count = registry.sources.len;

/// One compiled grammar per `.spgrammar` file. A mistake in any of them
/// stops the build here.
pub const grammars: [dialect_count]Grammar = blk: {
    var out: [dialect_count]Grammar = undefined;
    for (registry.sources, 0..) |src, i| out[i] = grammar.compileBuiltin(src);
    break :blk out;
};

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
    break :blk .{ .kinds = kinds, .families = fams, .words = words, .grammars = &grammars };
};

pub fn find(name: []const u8) ?*const Grammar {
    for (&grammars) |*g| if (std.ascii.eqlIgnoreCase(g.name, name)) return g;
    return null;
}

/// Whether a dialect argument names a grammar file rather than a built-in.
pub fn isGrammarPath(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".spgrammar");
}

pub const LoadError = error{ UnknownDialect, CannotRead, BadGrammar, OutOfMemory };

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
    const nl = try reader.read(gf, arena, src, report, .{});
    try writer.write(gt, arena, out, &nl, report, &caps, null);
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
    _ = @import("tests.zig");
}
