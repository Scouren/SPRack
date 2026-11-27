//! Directives of what a dialect's simulator takes of a netlist as a whole:
//! `libsections`, `variation`, `unique`, `hoist`, `switch`, `requires`,
//! `reserved`, `spread`, `each` and `rerun`.
//!
//! Contents:
//! - `pub fn libsections(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn variation(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn variant(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn unique(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn hoist(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn switchTo(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn requires(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn reserved(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn spread(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn each(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`
//! - `pub fn rerun(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void`

const std = @import("std");
const schema = @import("schema");
const Kind = schema.Kind;
const context = @import("context.zig");
const tables = @import("tables.zig");
const types = @import("types.zig");
const C = context.C;
const Error = context.Error;
const args = context.args;
const kindOf = context.kindOf;
const dotted = context.dotted;
const Grammar = tables.Grammar;
const Require = types.Require;
const Reserved = types.Reserved;
const Spread = types.Spread;
const Each = types.Each;
const Switch = types.Switch;
const Topo = types.Topo;
const UniqueAnalysis = types.UniqueAnalysis;

/// `libsections opened : reason`.
pub fn libsections(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    if (!std.mem.startsWith(u8, rest, "opened : "))
        return c.fail(no, "libsections is `libsections opened : reason`", .{});
    g.libsections_opened = rest["opened : ".len..];
}

/// `variation inline`.
pub fn variation(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    if (!std.mem.eql(u8, rest, "inline"))
        return c.fail(no, "variation is `variation inline`", .{});
    g.variation_inline = true;
}

/// `variant <dialect>`: this grammar is that dialect for another reader.
pub fn variant(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const a = try args(c, no, rest);
    if (a.len != 1) return c.fail(no, "variant is `variant <dialect>`", .{});
    g.variant_of = a[0];
}

/// `unique param|master|analysis kind... [beside kind] : reason`.
pub fn unique(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "unique is `unique param|master|analysis kind... [beside kind] : reason`",
        .{},
    );
    const what = std.mem.trim(u8, rest[0..colon], " \t");
    if (std.mem.eql(u8, what, "param")) {
        g.unique_param = rest[colon + 3 ..];
    } else if (std.mem.eql(u8, what, "master")) {
        g.unique_master = rest[colon + 3 ..];
    } else if (std.mem.startsWith(u8, what, "analysis ")) {
        var u: UniqueAnalysis = .{ .reason = rest[colon + 3 ..] };
        var it = std.mem.tokenizeAny(u8, what["analysis ".len..], " \t");
        while (it.next()) |word| {
            const beside = std.mem.eql(u8, word, "beside");
            const k = try kindOf(c, no, if (beside) it.next() orelse "" else word);
            if (schema.info(k).class != .analysis)
                return c.fail(
                    no,
                    "unique analysis: '{s}' is not an analysis",
                    .{@tagName(k)},
                );
            if (beside) u.beside = k;
            u.kinds = try c.add(Kind, u.kinds, k);
        }
        // `what` goes on after "analysis ", and each word is a kind or fails.
        std.debug.assert(u.kinds.len > 0);
        g.unique_analysis = u;
    } else return c.fail(no, "unique takes param, master or analysis, not '{s}'", .{what});
}

/// `hoist param from dialect...`.
pub fn hoist(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const a = try args(c, no, rest);
    if (a.len < 3 or !std.mem.eql(u8, a[0], "param") or !std.mem.eql(u8, a[1], "from"))
        return c.fail(no, "hoist is `hoist param from dialect...`", .{});
    g.hoist_param = a[2..];
}

/// `switch "words" -> dialect`.
pub fn switchTo(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const arrow = std.mem.indexOf(u8, rest, " -> ") orelse return c.fail(
        no,
        "switch is `switch \"words\" -> dialect`",
        .{},
    );
    const lits = try args(c, no, rest[0..arrow]);
    if (lits.len != 1) return c.fail(no, "switch needs one quoted line start", .{});
    g.switches = try c.add(
        Switch,
        g.switches,
        .{ .words = lits[0], .dialect = std.mem.trim(u8, rest[arrow + 4 ..], " \t") },
    );
}

/// `requires topology error|warning [analysis ...] : reason`.
pub fn requires(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const usage = "requires is `requires dc-path|cutset|no-vloop|no-vlloop|no-lloop " ++
        "error|warning [analysis ...] : reason`";
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(no, usage, .{});
    var it = std.mem.tokenizeAny(u8, rest[0..colon], " \t[]");
    const what = std.meta.stringToEnum(
        Topo,
        it.next() orelse "",
    ) orelse return c.fail(no, usage, .{});
    const sev = it.next() orelse "";
    if (!(std.mem.eql(u8, sev, "error") or std.mem.eql(u8, sev, "warning")))
        return c.fail(no, usage, .{});
    // `sev` is one of the two words: the severity is its first letter.
    std.debug.assert(sev.len > 0);
    const open = std.mem.indexOfScalar(u8, rest[0..colon], '[');
    const closed = open != null and std.mem.indexOfScalar(u8, rest[open.?..colon], ']') != null;
    if ((open == null) != (it.peek() == null) or (open != null and !closed))
        return c.fail(no, usage, .{});
    var analyses: []const Kind = &.{};
    while (it.next()) |w| {
        const k = std.meta.stringToEnum(Kind, w) orelse return c.fail(
            no,
            "requires: '{s}' is not an analysis",
            .{w},
        );
        if (schema.info(k).class != .analysis)
            return c.fail(no, "requires: '{s}' is not an analysis", .{w});
        analyses = try c.add(Kind, analyses, k);
    }
    g.requires = try c.add(
        Require,
        g.requires,
        .{
            .what = what,
            .err = sev[0] == 'e',
            .analyses = analyses,
            .reason = rest[colon + 3 ..],
        },
    );
}

/// `reserved [shadowed] name ... : reason`.
pub fn reserved(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
        no,
        "reserved is `reserved name ... : reason`",
        .{},
    );
    const names = try args(c, no, rest[0..colon]);
    const shadowed = names.len > 1 and std.mem.eql(u8, names[0], "shadowed");
    g.reserved = try c.add(Reserved, g.reserved, .{ .names = if (shadowed)
        names[1..]
    else
        names, .reason = rest[colon + 3 ..], .shadowed = shadowed });
}

/// `spread kind ["word"]`.
pub fn spread(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const a = try args(c, no, rest);
    if (a.len < 1 or a.len > 2)
        return c.fail(no, "spread is `spread kind [\"word\"]`", .{});
    g.spreads = try c.add(
        Spread,
        g.spreads,
        .{ .kind = try kindOf(c, no, a[0]), .word = if (a.len == 2)
            try c.foldIf(!g.lex.case_sensitive, a[1])
        else
            "" },
    );
}

/// `each kind -> kind.slot analysis[=word]... : why`.
pub fn each(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse rest.len;
    const a = try args(c, no, rest[0..colon]);
    if (colon == rest.len or a.len < 4 or !std.mem.eql(u8, a[1], "->"))
        return c.fail(no, "each is `each kind -> kind.slot analysis... : why`", .{});
    const to, const slot = try dotted(c, no, a[2]);
    if (schema.info(to).slots[slot].ty != .atom)
        return c.fail(no, "each names a slot of a word, found '{s}'", .{a[2]});
    var per: []const Kind = &.{};
    var words: []const []const u8 = &.{};
    for (a[3..]) |k| {
        const eq = std.mem.indexOfScalar(u8, k, '=') orelse k.len;
        per = try c.add(Kind, per, try kindOf(c, no, k[0..eq]));
        words = try c.add([]const u8, words, if (eq < k.len) k[eq + 1 ..] else k);
    }
    // `args` gave at least one analysis after the slot.
    std.debug.assert(per.len > 0);
    g.eaches = try c.add(Each, g.eaches, .{
        .from = try kindOf(c, no, a[0]),
        .to = to,
        .slot = slot,
        .per = per,
        .words = words,
        .text = rest[colon + 3 ..],
    });
}

/// `rerun kind`.
pub fn rerun(c: *C, g: *Grammar, no: u32, rest: []const u8) Error!void {
    g.reruns = try c.add(Kind, g.reruns, try kindOf(c, no, rest));
}
