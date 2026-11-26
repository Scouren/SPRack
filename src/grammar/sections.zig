//! Directives of what a dialect writes around the statements, or keeps as
//! it is: `preamble`, `header`, `needs`, `wrap`, `own` and `raw`.
//!
//! Contents:
//! - `pub fn preamble(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void`
//! - `pub fn header(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void`
//! - `pub fn needs(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void`
//! - `pub fn wrap(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn own(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn raw(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`

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
const literalLines = context.literalLines;
const Grammar = tables.Grammar;
const Needs = types.Needs;
const Own = types.Own;
const RawBlock = types.RawBlock;
const Wrap = types.Wrap;

/// `preamble [unless kind]`, then its lines up to `end`.
pub fn preamble(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void {
    if (std.mem.startsWith(u8, rest, "unless "))
        g.preamble_unless = try kindOf(c, lines.no, rest["unless ".len..]);
    g.preamble = try literalLines(c, lines);
}

/// `header [folded]`, then its lines up to `end`.
pub fn header(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void {
    if (std.mem.eql(u8, rest, "folded")) {
        g.header_folded = try literalLines(c, lines);
    } else if (rest.len > 0) {
        return c.fail(lines.no, "`header {s}`: only `header folded` takes a word", .{rest});
    } else g.header = try literalLines(c, lines);
}

/// `needs kind` or `needs family`, then its lines up to `end`.
pub fn needs(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void {
    if (schema.kindFromName(rest) == null and schema.familyKind(rest) != null) {
        g.needs = try c.add(
            Needs,
            g.needs,
            .{ .kind = .model, .family = rest, .lines = try literalLines(c, lines) },
        );
    } else {
        const kind = try kindOf(c, lines.no, rest);
        g.needs = try c.add(
            Needs,
            g.needs,
            .{ .kind = kind, .lines = try literalLines(c, lines) },
        );
    }
}

/// `wrap "open" "close" : kind ...`.
pub fn wrap(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const fold = !g.lex.case_sensitive;
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "wrap is `wrap \"open\" \"close\" : kind ...`",
        .{},
    );
    const lits = try args(c, no, rest[0..colon]);
    if (lits.len != 2)
        return c.fail(no, "wrap needs an opening and a closing literal", .{});
    // `args` gives no empty word: an empty literal would match everywhere.
    std.debug.assert(lits[0].len > 0);
    var kinds: []const Kind = &.{};
    for (try args(c, no, rest[colon + 3 ..])) |k|
        kinds = try c.add(Kind, kinds, try kindOf(c, no, k));
    g.wraps = try c.add(Wrap, g.wraps, .{
        .open = try c.foldIf(fold, lits[0]),
        .close = try c.foldIf(fold, lits[1]),
        .kinds = kinds,
    });
}

/// `own ["model"] "word"... : reason`.
pub fn own(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const fold = !g.lex.case_sensitive;
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "own is `own \"word\"... : reason`",
        .{},
    );
    var words = try args(c, no, rest[0..colon]);
    const model = words.len > 1 and std.mem.eql(
        u8,
        words[0],
        "model",
    ) and !std.mem.startsWith(u8, rest, "\"");
    if (model) words = words[1..];
    if (words.len == 0) return c.fail(no, "own needs a word", .{});
    // `args` gives no empty word.
    std.debug.assert(words[0].len > 0);
    for (words) |wd|
        g.owns = try c.add(
            Own,
            g.owns,
            .{
                .word = try c.foldIf(fold, wd),
                .reason = rest[colon + 3 ..],
                .model = model,
            },
        );
}

/// `raw "open" "close" [as kind] [: reason]`.
pub fn raw(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const fold = !g.lex.case_sensitive;
    const colon = std.mem.indexOf(u8, rest, " : ");
    var lits = try args(c, no, if (colon) |k| rest[0..k] else rest);
    var as_kind: ?Kind = null;
    if (lits.len == 4 and std.mem.eql(u8, lits[2], "as")) {
        as_kind = try kindOf(c, no, lits[3]);
        lits = lits[0..2];
    }
    if (lits.len != 2)
        return c.fail(no, "raw is `raw \"open\" \"close\" [as kind] [: reason]`", .{});
    // `args` gives no empty word.
    std.debug.assert(lits[1].len > 0);
    g.raws = try c.add(RawBlock, g.raws, .{
        .open = try c.foldIf(fold, lits[0]),
        .close = try c.foldIf(fold, lits[1]),
        .reason = if (colon) |k| rest[k + 3 ..] else "",
        .kind = as_kind,
    });
}
