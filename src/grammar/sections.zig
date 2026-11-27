//! Directives of what a dialect writes around the statements, or keeps as
//! it is: `preamble`, `header`, `needs`, `once`, `wrap`, `own` and `raw`.
//!
//! Contents:
//! - `pub fn preamble(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void`
//! - `pub fn header(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void`
//! - `pub fn needs(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void`
//! - `pub fn once(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void`
//! - `pub fn modules(c: *C, g: *Grammar, lines: *Lines) Error!void`
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
const slotNamed = context.slotNamed;
const Grammar = tables.Grammar;
const Needs = types.Needs;
const Once = types.Once;
const Modules = types.Modules;
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

/// `once kind slot`, then its lines up to `end`; each `{x}`, `{x.stem}`
/// and `{x|y}` in them names slots of the kind.
pub fn once(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void {
    const no = lines.no;
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse
        return c.fail(no, "once is `once kind slot`", .{});
    const kind = try kindOf(c, no, rest[0..sp]);
    const slot = try slotNamed(c, no, kind, std.mem.trim(u8, rest[sp + 1 ..], " \t"));
    const body = try literalLines(c, lines);
    // `literalLines` ends at `end`, after the directive's own line.
    std.debug.assert(lines.no > no);
    for (body) |l| {
        var it = std.mem.splitScalar(u8, l, '{');
        _ = it.next();
        while (it.next()) |part| {
            const close = std.mem.indexOfScalar(u8, part, '}') orelse
                return c.fail(no, "a `{{` with no `}}` in `{s}`", .{l});
            var names = std.mem.splitScalar(u8, part[0..close], '|');
            while (names.next()) |n| {
                const stem = std.mem.endsWith(u8, n, ".stem");
                _ = try slotNamed(c, no, kind, if (stem) n[0 .. n.len - ".stem".len] else n);
            }
        }
    }
    g.onces = try c.add(Once, g.onces, .{ .kind = kind, .slot = slot, .lines = body });
}

/// `modules`, then a line for each field of `Modules` up to `end`: its
/// name and its text, quoted (`bus`, `dirs` and `name` take several).
pub fn modules(c: *C, g: *Grammar, lines: *Lines) Error!void {
    const start = lines.no;
    var m: Modules = undefined;
    var have: u16 = 0;
    const names = [_][]const u8{
        "open", "port", "net", "instance", "pin", "join", "bus", "close", "dirs", "name",
    };
    const counts = [_]usize{ 1, 1, 1, 1, 1, 1, 2, 1, 3, 4 };
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) break;
        const head, const rest = context.splitHead(line);
        const i = for (names, 0..) |n, k| {
            if (std.mem.eql(u8, n, head)) break k;
        } else return c.fail(lines.no, "unknown line `{s}` of modules", .{head});
        const w = try args(c, lines.no, rest);
        if (w.len != counts[i])
            return c.fail(lines.no, "`{s}` of modules takes {d} texts", .{ head, counts[i] });
        have |= @as(u16, 1) << @intCast(i);
        switch (i) {
            0 => m.open = w[0],
            1 => m.port = w[0],
            2 => m.net = w[0],
            3 => m.instance = w[0],
            4 => m.pin = w[0],
            5 => m.join = w[0],
            6 => {
                m.bus_open = w[0];
                m.bus_close = w[1];
            },
            7 => m.close = w[0],
            8 => m.dirs = .{ w[0], w[1], w[2] },
            else => {
                m.first = w[0];
                m.rest = w[1];
                m.escape_open = w[2];
                m.escape_close = w[3];
            },
        }
    } else return c.fail(lines.no, "section is missing 'end'", .{});
    std.debug.assert(lines.no > start);
    if (have != (1 << names.len) - 1)
        return c.fail(start, "modules needs a line of each: open port net instance pin " ++
            "join bus close dirs name", .{});
    g.modules = m;
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
