//! Directives whose text is a pattern: `rule`, `read` and `write`, `block
//! kind ... end`, and `define`, a named fragment of one.
//!
//! Contents:
//! - `pub fn rule(c: *C, g: *Grammar, no: u32, head: []const u8, rest: []const u8,
//!   defs: []const Def) Error!void`
//! - `pub fn block(c: *C, g: *Grammar, lines: *Lines, rest: []const u8,
//!   defs: []const Def) Error!void`
//! - `pub fn define(c: *C, no: u32, rest: []const u8, defs: *[]const Def) Error!void`

const std = @import("std");
const schema = @import("schema");
const Kind = schema.Kind;
const context = @import("context.zig");
const parser = @import("parser.zig");
const tables = @import("tables.zig");
const types = @import("types.zig");
const C = context.C;
const Error = context.Error;
const Lines = context.Lines;
const kindOf = context.kindOf;
const splitHead = context.splitHead;
const Def = parser.Def;
const pattern = parser.pattern;
const Grammar = tables.Grammar;
const Block = types.Block;
const Dir = types.Dir;
const Node = types.Node;
const Rule = types.Rule;

/// `rule|read|write kind[family][@within] = pattern`.
pub fn rule(
    c: *C,
    g: *Grammar,
    no: u32,
    head: []const u8,
    rest: []const u8,
    defs: []const Def,
) Error!void {
    // The directive is one of `rule`, `read` and `write`.
    std.debug.assert(head.len >= 4);
    const eq = std.mem.indexOf(u8, rest, " = ") orelse return c.fail(
        no,
        "expected `{s} kind = pattern`",
        .{head},
    );
    var kname = std.mem.trim(u8, rest[0..eq], " \t");
    var within: ?Kind = null;
    if (std.mem.indexOfScalar(u8, kname, '@')) |at| {
        within = try kindOf(c, no, kname[at + 1 ..]);
        kname = kname[0..at];
    }
    var family: []const u8 = "";
    if (std.mem.indexOfScalar(u8, kname, '[')) |b| {
        if (kname[kname.len - 1] != ']') return c.fail(no, "expected `kind[family]`", .{});
        family = kname[b + 1 .. kname.len - 1];
        kname = kname[0..b];
    }
    const kind = try kindOf(c, no, kname);
    if (family.len > 0) {
        if (schema.familyKind(family) == null)
            return c.fail(no, "unknown model family '{s}'", .{family});
        if (schema.slotOf(kind, "master") == null)
            return c.fail(
                no,
                "'{s}' names no model, so it cannot depend on a family",
                .{kname},
            );
    }
    const dir: Dir = if (head[0] == 'r' and head[1] == 'u')
        .both
    else if (head[0] == 'r') .read else .write;
    const pat = try pattern(c, no, kind, !g.lex.case_sensitive, rest[eq + 3 ..], defs);
    // What a pick leaves out cannot be read back into its place.
    if (c.picks > 0 and dir != .write)
        return c.fail(no, "a pattern that picks items (`slot*@sel=word`) is only written", .{});
    g.rules = try c.add(Rule, g.rules, .{
        .kind = kind,
        .dir = dir,
        .pat = pat,
        .family = family,
        .within = within,
    });
}

/// `block kind`, then `open`, `inner`, `close` and `closed` lines up to `end`.
pub fn block(
    c: *C,
    g: *Grammar,
    lines: *Lines,
    rest: []const u8,
    defs: []const Def,
) Error!void {
    const fold = !g.lex.case_sensitive;
    const kind = try kindOf(c, lines.no, rest);
    var open: []const Node = &.{};
    var close: []const Node = &.{};
    var inner: []const []const Node = &.{};
    var closed = false;
    // Until the `end` line, or the end of the file.
    while (true) {
        const bl = lines.next() orelse return c.fail(
            lines.no,
            "block is missing 'end'",
            .{},
        );
        if (std.mem.eql(u8, bl, "end")) break;
        if (std.mem.eql(u8, bl, "closed")) {
            closed = true;
            continue;
        }
        const bh, const br = splitHead(bl);
        const pat = try pattern(c, lines.no, kind, fold, br, defs);
        // `pattern` refuses an empty pattern.
        std.debug.assert(pat.len > 0);
        if (std.mem.eql(u8, bh, "open")) {
            open = pat;
        } else if (std.mem.eql(u8, bh, "close")) {
            close = pat;
        } else if (std.mem.eql(u8, bh, "inner")) {
            inner = try c.add([]const Node, inner, pat);
        } else return c.fail(lines.no, "expected open, inner, close, closed or end", .{});
    }
    if (open.len == 0 or close.len == 0)
        return c.fail(lines.no, "block needs both open and close", .{});
    if (closed and close[0].tag != .lit)
        return c.fail(lines.no, "a closed block's close starts with a word", .{});
    g.blocks = try c.add(
        Block,
        g.blocks,
        .{ .kind = kind, .open = open, .inner = inner, .close = close, .closed = closed },
    );
}

/// `define name = pattern`, kept as text.
pub fn define(c: *C, no: u32, rest: []const u8, defs: *[]const Def) Error!void {
    const eq = std.mem.indexOf(u8, rest, " = ") orelse return c.fail(
        no,
        "expected `define name = pattern`",
        .{},
    );
    const dname = std.mem.trim(u8, rest[0..eq], " \t");
    for (defs.*) |d|
        if (std.mem.eql(u8, d.name, dname))
            return c.fail(no, "`{s}` is already defined", .{dname});
    defs.* = try c.add(Def, defs.*, .{ .name = dname, .text = rest[eq + 3 ..] });
}
