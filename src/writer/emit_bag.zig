//! Keyed parameters: the `{...}` bag of a pattern and the statement's
//! values → `key=value` tokens, each slot under the key the target reads
//! it by; what two keys of one spelling or a key that reads back as
//! another slot make of it reported.
//!
//! Contents:
//! - `pub fn write(e: *Emit, n: Node) Allocator.Error!bool`

const std = @import("std");
const grammar = @import("grammar");
const ir = @import("ir");
const lexer = @import("lexer");
const tables = @import("tables.zig");
const Emit = @import("emit.zig").Emit;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const BagEntry = grammar.BagEntry;
const Node = grammar.Node;
const Value = ir.Value;
const idleCeiling = tables.idleCeiling;

/// Spell a bag node. False means it cannot be written with the values at hand.
pub fn write(e: *Emit, n: Node) Allocator.Error!bool {
    assert(n.tag == .bag);
    // Counted over the entries and added once: the flags no entry could
    // write, and the slots an earlier rule wrote that a `k=slot+` said again.
    var lost: usize = 0;
    var again: usize = 0;
    defer {
        e.lost_flags += lost;
        e.again += again;
    }
    for (n.bag, 0..) |b, bi| {
        switch (b.form) {
            .fixed => if (!try fixed(e, b)) return false,
            .rest, .call => lost += try params(e, b),
            .pairs => try pairs(e, b),
            .pair => try pair(e, b),
            .plain, .quoted, .vector => again += (try keyed(e, n, bi)) orelse return false,
        }
    }
    return true;
}

// ---- private ----

/// `key=text`, where the tag slot (if any) holds the entry's word.
fn fixed(e: *Emit, b: BagEntry) Allocator.Error!bool {
    if (b.tag_slot != grammar.no_slot) {
        const tv = e.st.at(b.tag_slot);
        if (tv != .atom or !std.mem.eql(u8, tv.atom, b.tag_atom)) {
            if (tv == .atom)
                e.why = try e.arena.print(
                    "{s} = {s}",
                    .{ e.slot(b.tag_slot).name, tv.atom },
                );
            return false;
        }
        e.mark(b.tag_slot);
    }
    try e.tok(try e.arena.print("{s}={s}", .{ b.key, b.fixed }));
    return true;
}

/// Each parameter of the slot as `name=value` (`key(name)=value` for a
/// call); the number of bare flags the entry had no way to write.
fn params(e: *Emit, b: BagEntry) Allocator.Error!usize {
    if (!e.bound(b.slot) or e.isUsed(b.slot)) return 0;
    assert(e.st.at(b.slot) == .params);
    var lost: usize = 0;
    for (e.st.at(b.slot).params) |p| {
        if (p.val == .none) {
            // A bare flag, where the rule takes flags.
            if (b.flags) try e.tok(p.key) else lost += 1;
            continue;
        }
        e.checkNumber(p);
        // Without a vector syntax, a matrix is the numbers after its key.
        const vt = if (p.val == .list)
            if (e.g.lex.bare_expr)
                try e.arena.print("[{s}]", .{try e.vectorText(p.val)})
            else
                try e.vectorText(p.val)
        else
            try e.valueText(p.val, false);
        if (b.form == .call) {
            try e.tok(
                try e.arena.print("{s}({s})={s}", .{ b.key, p.key, vt }),
            );
        } else try e.tok(try e.arena.print("{s}={s}", .{ p.key, vt }));
    }
    e.mark(b.slot);
    return lost;
}

/// `key={"n1","n2",value,...}`: the parameters of the slot as one word.
fn pairs(e: *Emit, b: BagEntry) Allocator.Error!void {
    if (!e.bound(b.slot) or e.isUsed(b.slot)) return;
    assert(e.st.at(b.slot) == .params);
    // No blanks: a bare value in this form runs to the next one.
    var out: std.ArrayList(u8) = .empty;
    try out.print(e.arena, "{s}={{", .{b.key});
    for (e.st.at(b.slot).params, 0..) |p, i| {
        if (i > 0) try out.append(e.arena, ',');
        var nodes = std.mem.splitScalar(u8, p.key, ',');
        while (nodes.next()) |nd| try out.print(e.arena, "\"{s}\",", .{nd});
        for (try e.valueText(p.val, false)) |c|
            if (c != ' ') try out.append(e.arena, c);
    }
    try out.append(e.arena, '}');
    try e.tok(out.items);
    e.mark(b.slot);
}

/// `key=first` or `key=[first second]`: two slots under one key.
fn pair(e: *Emit, b: BagEntry) Allocator.Error!void {
    assert(b.form == .pair);
    if (!e.bound(b.slot) or e.isUsed(b.slot)) return;
    const first = (try e.slotText(b.slot, true)) orelse return;
    const v2 = e.val(b.slot2);
    const ground = v2 == .atom and std.mem.eql(u8, v2.atom, "0");
    if (e.bound(b.slot2) and !ground) {
        const second = (try e.slotText(b.slot2, true)) orelse return;
        // No blank: the reader takes the vector as one word.
        const sep = std.mem.trim(u8, e.g.lex.vector_sep, " ");
        try e.tok(
            try e.arena.print(
                "{s}=[{s}{s}{s}]",
                .{ b.key, first, if (sep.len > 0) sep else " ", second },
            ),
        );
    } else try e.tok(try e.arena.print("{s}={s}", .{ b.key, first }));
    e.mark(b.slot);
    if (e.present(b.slot2)) e.mark(b.slot2);
}

/// `key=value` for one slot: null when the statement cannot be written
/// without it, else how many slots an earlier rule wrote it said again.
fn keyed(e: *Emit, n: Node, bi: usize) Allocator.Error!?usize {
    const b = n.bag[bi];
    assert(b.form == .plain or b.form == .quoted or b.form == .vector);
    if (b.required and !e.bound(b.slot)) {
        if (e.why.len == 0)
            e.why = try e.arena.print(
                "a statement without '{s}'",
                .{e.slot(b.slot).name},
            );
        return null;
    }
    if (!e.bound(b.slot) and b.default.len > 0 and e.foreign) {
        try synthesized(e, b);
        return 0;
    }
    // An earlier line of this statement wrote the slot.
    const before = b.also and b.slot < 64 and e.hide & (@as(u64, 1) << @intCast(b.slot)) != 0;
    if (skips(e, n, b, before)) return 0;
    if (try twin(e, n, bi)) return 0;
    readsBack(e, n, bi);
    if (b.tag_slot != grammar.no_slot) {
        const tv = e.st.at(b.tag_slot);
        if (tv != .atom or !std.mem.eql(u8, tv.atom, b.tag_atom)) return 0;
        e.mark(b.tag_slot);
    }
    try e.tok((try keyedText(e, b)) orelse return 0);
    e.mark(b.slot);
    return @intFromBool(before);
}

/// What the source's simulator assumes and this one does not, written
/// for a slot the statement leaves out.
fn synthesized(e: *Emit, b: BagEntry) Allocator.Error!void {
    assert(!e.bound(b.slot));
    const raw = try e.expandDefault(b.default);
    const made: Value = if (lexer.parseNumber(
        e.arena,
        &e.g.lex,
        raw,
    )) |num| .{ .num = num } else .{ .expr = raw };
    // Not a ceiling that would be dropped had the source given it.
    if (idleCeiling(e.st, b.slot, made)) return;
    const text = try e.valueText(made, false);
    try e.tok(try e.arena.print("{s}={s}", .{ b.key, text }));
    if (!e.quiet)
        e.report.add(
            .warning,
            .synthesized,
            e.st.line,
            "{s}: {s} needs '{s}' to behave as {s} does without " ++
                "it; wrote {s}",
            .{ @tagName(e.st.kind), e.g.name, e.slot(b.slot).name, e.source, text },
        );
}

/// The entry has nothing to write: its slot is not bound, another key
/// wrote it, or (`k=slot+`) no earlier line said it.
fn skips(e: *const Emit, n: Node, b: BagEntry, before: bool) bool {
    if (b.also and e.foreign) {
        // Only after another key wrote it, for another dialect's statement.
        return !before and !(e.bound(b.slot) and e.isUsed(b.slot));
    }
    if (!e.bound(b.slot) or e.isUsed(b.slot)) return true;
    if (!b.also) return false;
    // In its own dialect, only where this key read it: on a
    // line that says again what an earlier line said.
    return for (n.bag) |o| {
        if (!o.also and o.slot == b.slot and
            (o.form == .plain or o.form == .quoted or o.form == .vector)) break true;
    } else false;
}

/// Two slots this dialect spells with one key (`gmin=gmin gmin=gmindc`):
/// one value is said; two are a loss. True when an earlier entry has it.
fn twin(e: *Emit, n: Node, bi: usize) Allocator.Error!bool {
    assert(bi < n.bag.len);
    const b = n.bag[bi];
    const t = for (n.bag[0..bi]) |o| {
        if (o.form == .plain and !o.also and o.slot != b.slot and
            e.isUsed(o.slot) and std.mem.eql(
            u8,
            o.key,
            b.key,
        )) break o.slot;
    } else return false;
    if (!e.val(t).eql(e.val(b.slot)) and !e.quiet)
        e.report.add(.@"error", .loss, e.st.line, "{s}: {s} = {s} " ++
            "and {s} = {s} are both '{s}' in {s}; the first is " ++
            "written", .{
            @tagName(e.st.kind),
            e.slot(t).name,
            try e.describe(e.val(t)),
            e.slot(b.slot).name,
            try e.describe(e.val(b.slot)),
            b.key,
            e.g.name,
        });
    e.mark(b.slot);
    return true;
}

/// `gmin=gmindc` after `gmin=gmin`: read back, the key fills the other slot.
fn readsBack(e: *Emit, n: Node, bi: usize) void {
    assert(bi < n.bag.len);
    const b = n.bag[bi];
    for (n.bag[0..bi]) |o|
        if (o.form == .plain and !o.also and o.slot != b.slot and
            std.mem.eql(
                u8,
                o.key,
                b.key,
            ))
        {
            if (!e.quiet)
                e.report.add(
                    .info,
                    .oneway,
                    e.st.line,
                    "{s}.{s} is written as '{s}', which reads back as " ++
                        "{s}.{s}",
                    .{
                        @tagName(e.st.kind),
                        e.slot(b.slot).name,
                        b.key,
                        @tagName(e.st.kind),
                        e.slot(o.slot).name,
                    },
                );
            break;
        };
}

/// `key=value`, `key="value<suffix>"` or `key=[v1 v2]`; null for a value
/// this dialect cannot spell: it is left unwritten, and reported as such.
fn keyedText(e: *Emit, b: BagEntry) Allocator.Error!?[]const u8 {
    const vt = if (b.form == .vector and e.val(b.slot) == .list)
        try e.vectorText(e.val(b.slot))
    else if (b.suffix.len > 0)
        try e.arena.print(
            "\"{s}{s}\"",
            .{ (try e.slotText(b.slot, false)) orelse return null, b.suffix },
        )
    else
        (try e.slotText(b.slot, b.form == .quoted)) orelse return null;
    return if (b.form == .vector)
        try e.arena.print("{s}=[{s}]", .{ b.key, vt })
    else
        try e.arena.print("{s}={s}", .{ b.key, vt });
}
