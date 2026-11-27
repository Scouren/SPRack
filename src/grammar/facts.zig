//! Directives of what a slot of a kind means in a dialect, one line each:
//! `caveat`, `inert`, `implied`, `enum`, `respell`, `move`, `merge`, `no`,
//! `invalid` and `default`.
//!
//! Contents:
//! - `pub fn caveat(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn inert(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn implied(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn enumMap(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn respell(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn move(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn merge(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn absent(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn invalid(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn default(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const schema = @import("schema");
const context = @import("context.zig");
const tables = @import("tables.zig");
const types = @import("types.zig");
const C = context.C;
const Error = context.Error;
const args = context.args;
const condition = context.condition;
const dotted = context.dotted;
const kindOf = context.kindOf;
const kindSlot = context.kindSlot;
const slotNamed = context.slotNamed;
const Grammar = tables.Grammar;
const Absent = types.Absent;
const Caveat = types.Caveat;
const Check = types.Check;
const EnumMap = types.EnumMap;
const EnumPair = types.EnumPair;
const Fill = types.Fill;
const Implied = types.Implied;
const Inert = types.Inert;
const Merge = types.Merge;
const Move = types.Move;
const Respell = types.Respell;
const NoFamily = types.NoFamily;
const no_slot = types.no_slot;

/// `caveat [read] kind slot[=*suffix [-> *suffix]] : text`.
pub fn caveat(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "caveat is `caveat kind slot : text`",
        .{},
    );
    const all = try args(c, no, rest[0..colon]);
    const read = all.len > 0 and std.mem.eql(u8, all[0], "read");
    const ks = all[@intFromBool(read)..];
    // `slot=*.va -> *.osdi`: the value is written with the other suffix.
    const arrow = ks.len == 4 and std.mem.eql(u8, ks[2], "->");
    if (ks.len != 2 and !arrow) return c.fail(no, "caveat needs a kind and a slot", .{});
    const star = std.mem.indexOf(u8, ks[1], "=*");
    if (arrow and (read or star == null or ks[3].len < 2 or ks[3][0] != '*' or
        std.ascii.endsWithIgnoreCase(ks[3], ks[1][star.? + 2 ..])))
        return c.fail(no, "caveat `slot=*a -> *b` is written only, between suffixes", .{});
    const kind, const slot = try kindSlot(c, no, ks[0], if (star) |k|
        ks[1][0..k]
    else
        ks[1]);
    // `kindSlot` gives a slot of the kind.
    std.debug.assert(slot < schema.info(kind).slots.len);
    g.caveats = try c.add(
        Caveat,
        g.caveats,
        .{ .kind = kind, .slot = slot, .text = rest[colon + 3 ..], .suffix = if (star) |k|
            ks[1][k + 2 ..]
        else
            "", .becomes = if (arrow) ks[3][1..] else "", .read = read },
    );
}

/// `inert kind key... : text`.
pub fn inert(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "inert is `inert kind [key...] : text`",
        .{},
    );
    const e = try args(c, no, rest[0..colon]);
    if (e.len == 0) return c.fail(no, "inert needs a kind", .{});
    const kind = try kindOf(c, no, e[0]);
    const text = rest[colon + 3 ..];
    // `inert tran : text`: the whole statement changes nothing here.
    if (e.len == 1) {
        g.inerts = try c.add(Inert, g.inerts, .{ .kind = kind, .key = "", .text = text });
        return;
    }
    // `args` gives no empty word, so no key reads as the whole statement.
    for (e[1..]) |key| assert(key.len > 0);
    for (e[1..]) |key| {
        g.inerts = try c.add(
            Inert,
            g.inerts,
            .{ .kind = kind, .key = key, .text = text },
        );
    }
}

/// `implied kind slot = value [slot=atom]`.
pub fn implied(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const a = try args(c, no, rest);
    if (a.len < 4 or a.len > 5 or !std.mem.eql(u8, a[2], "="))
        return c.fail(no, "implied is `implied kind slot = value [slot=atom]`", .{});
    const kind, const slot = try kindSlot(c, no, a[0], a[1]);
    var im: Implied = .{ .kind = kind, .slot = slot, .text = a[3] };
    if (a.len == 5) im.when_slot, im.when_atom = try condition(c, no, kind, a[4]);
    g.implied = try c.add(Implied, g.implied, im);
}

/// `enum kind slot : canonical=spelling ...`.
pub fn enumMap(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "enum is `enum kind slot : canonical=spelling ...`",
        .{},
    );
    const ks = try args(c, no, rest[0..colon]);
    if (ks.len != 2) return c.fail(no, "enum needs a kind and a slot", .{});
    const kind, const slot = try kindSlot(c, no, ks[0], ks[1]);
    // `kindSlot` gives a slot of the kind.
    std.debug.assert(slot < schema.info(kind).slots.len);
    if (schema.info(kind).slots[slot].ty != .atom)
        return c.fail(no, "enum needs an atom slot", .{});
    var pairs: []const EnumPair = &.{};
    for (try args(c, no, rest[colon + 3 ..])) |pair| {
        const pe = std.mem.indexOfScalar(u8, pair, '=') orelse return c.fail(
            no,
            "expected canonical=spelling in '{s}'",
            .{pair},
        );
        pairs = try c.add(
            EnumPair,
            pairs,
            .{ .canon = pair[0..pe], .spelling = pair[pe + 1 ..] },
        );
    }
    g.enums = try c.add(EnumMap, g.enums, .{ .kind = kind, .slot = slot, .pairs = pairs });
}

/// `respell kind c=to ... : reason`: `[=_ ]=`, `]` written as nothing.
pub fn respell(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "respell is `respell kind c=to ... : reason`",
        .{},
    );
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse colon;
    const kind = try kindOf(c, no, rest[0..sp]);
    var pairs: []const [2][]const u8 = &.{};
    var it = std.mem.tokenizeAny(u8, rest[@min(sp, colon)..colon], " \t");
    while (it.next()) |w| {
        // The first character is the one respelled, `=` too.
        const eq = std.mem.indexOfScalarPos(u8, w, 1, '=') orelse
            return c.fail(no, "respell: `{s}` is not c=to", .{w});
        pairs = try c.add([2][]const u8, pairs, .{ w[0..eq], w[eq + 1 ..] });
    }
    if (pairs.len == 0) return c.fail(no, "respell names no character", .{});
    assert(pairs[0][0].len > 0);
    g.respells = try c.add(Respell, g.respells, .{
        .kind = kind,
        .pairs = pairs,
        .reason = rest[colon + 3 ..],
    });
}

/// `move kind.slot -> kind.slot [oneway]`.
pub fn move(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const a = try args(c, no, rest);
    const oneway = a.len == 4 and std.mem.eql(u8, a[3], "oneway");
    if ((a.len != 3 and !oneway) or !std.mem.eql(u8, a[1], "->"))
        return c.fail(no, "move is `move kind.slot -> kind.slot [oneway]`", .{});
    const fk, const fs = try dotted(c, no, a[0]);
    const tk, const ts = try dotted(c, no, a[2]);
    g.moves = try c.add(
        Move,
        g.moves,
        .{ .from = fk, .from_slot = fs, .to = tk, .to_slot = ts, .oneway = oneway },
    );
}

/// `merge kind -> kind`.
pub fn merge(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const a = try args(c, no, rest);
    if (a.len != 3 or !std.mem.eql(u8, a[1], "->"))
        return c.fail(no, "merge is `merge kind -> kind`", .{});
    g.merges = try c.add(
        Merge,
        g.merges,
        .{ .from = try kindOf(c, no, a[0]), .into = try kindOf(c, no, a[2]) },
    );
}

/// `no kind [slot] : reason`, or `no model family : reason`.
pub fn absent(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "no is `no kind [slot] : reason`",
        .{},
    );
    const e = try args(c, no, rest[0..colon]);
    // `no model mos6 : reason`: a family this dialect has no model of.
    if (e.len == 2 and std.mem.eql(u8, e[0], "model")) {
        if (schema.familyKind(e[1]) == null)
            return c.fail(no, "no model: '{s}' is no model family", .{e[1]});
        g.no_families = try c.add(
            NoFamily,
            g.no_families,
            .{ .family = e[1], .reason = rest[colon + 3 ..] },
        );
        return;
    }
    if (e.len != 1 and e.len != 2)
        return c.fail(no, "no needs a kind, or a kind and a slot", .{});
    const kind, const slot = if (e.len == 2)
        try kindSlot(c, no, e[0], e[1])
    else
        .{ try kindOf(c, no, e[0]), no_slot };
    // `rest` holds the " : " found at `colon`, so the reason is a slice of it.
    std.debug.assert(colon + " : ".len <= rest.len);
    g.absent = try c.add(
        Absent,
        g.absent,
        .{ .kind = kind, .slot = slot, .reason = rest[colon + 3 ..] },
    );
}

/// `invalid kind slot[=0] [slot=atom] : text`.
pub fn invalid(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "invalid is `invalid kind slot[=0] [slot=atom] : text`",
        .{},
    );
    const ks = try args(c, no, rest[0..colon]);
    if (ks.len < 2 or ks.len > 3)
        return c.fail(no, "invalid needs a kind, a slot and at most one condition", .{});
    const kind = try kindOf(c, no, ks[0]);
    const zero = std.mem.endsWith(u8, ks[1], "=0");
    const sname = if (zero) ks[1][0 .. ks[1].len - 2] else ks[1];
    var ck: Check = .{
        .kind = kind,
        .slot = try slotNamed(c, no, kind, sname),
        .zero = zero,
        .text = rest[colon + 3 ..],
    };
    // `slotNamed` gives a slot of the kind.
    std.debug.assert(ck.slot < schema.info(kind).slots.len);
    if (ks.len == 3) ck.when_slot, ck.when_atom = try condition(c, no, kind, ks[2]);
    g.checks = try c.add(Check, g.checks, ck);
}

/// `default kind slot[=0] [slot=atom] : kind.slot`.
pub fn default(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "default is `default kind slot[=0] [slot=atom] : kind.slot`",
        .{},
    );
    const ks = try args(c, no, rest[0..colon]);
    if (ks.len < 2 or ks.len > 3)
        return c.fail(no, "default needs a kind, a slot and at most one condition", .{});
    const kind = try kindOf(c, no, ks[0]);
    const zero = std.mem.endsWith(u8, ks[1], "=0");
    const sname = if (zero) ks[1][0 .. ks[1].len - 2] else ks[1];
    const to = try args(c, no, rest[colon + 3 ..]);
    if (to.len != 1) return c.fail(no, "default takes one `kind.slot`", .{});
    const fk, const fs = try dotted(c, no, to[0]);
    var f: Fill = .{
        .kind = kind,
        .slot = try slotNamed(c, no, kind, sname),
        .zero = zero,
        .from = fk,
        .from_slot = fs,
    };
    // `dotted` gives a slot of the kind it names.
    std.debug.assert(f.from_slot < schema.info(fk).slots.len);
    if (ks.len == 3) f.when_slot, f.when_atom = try condition(c, no, kind, ks[2]);
    g.fills = try c.add(Fill, g.fills, f);
}
