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
const Node = grammar.Node;
const Value = ir.Value;
const idleCeiling = tables.idleCeiling;

/// Spell a bag node. False means it cannot be written with the values at hand.
pub fn write(e: *Emit, n: Node) Allocator.Error!bool {
    for (n.bag, 0..) |b, bi| {
        switch (b.form) {
            .fixed => {
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
            },
            .rest, .call => {
                if (!e.bound(b.slot) or e.isUsed(b.slot)) continue;
                for (e.st.at(b.slot).params) |p| {
                    if (p.val == .none) {
                        // A bare flag, where the rule takes flags.
                        if (b.flags) try e.tok(p.key) else e.lost_flags += 1;
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
            },
            .pairs => {
                if (!e.bound(b.slot) or e.isUsed(b.slot)) continue;
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
            },
            .pair => {
                if (!e.bound(b.slot) or e.isUsed(b.slot)) continue;
                const first = (try e.slotText(b.slot, true)) orelse continue;
                const v2 = e.val(b.slot2);
                const ground = v2 == .atom and std.mem.eql(u8, v2.atom, "0");
                if (e.bound(b.slot2) and !ground) {
                    const second = (try e.slotText(b.slot2, true)) orelse continue;
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
            },
            .plain, .quoted, .vector => {
                if (b.required and !e.bound(b.slot)) {
                    if (e.why.len == 0)
                        e.why = try e.arena.print(
                            "a statement without '{s}'",
                            .{e.slot(b.slot).name},
                        );
                    return false;
                }
                if (!e.bound(b.slot) and b.default.len > 0 and e.foreign) {
                    // What the source's simulator assumes and this one does not.
                    const raw = try e.expandDefault(b.default);
                    const made: Value = if (lexer.parseNumber(
                        e.arena,
                        &e.g.lex,
                        raw,
                    )) |num| .{ .num = num } else .{ .expr = raw };
                    // Not a ceiling that would be dropped had the source given it.
                    if (idleCeiling(e.st, b.slot, made)) continue;
                    const text = try e.valueText(made, false);
                    try e.tok(try e.arena.print("{s}={s}", .{ b.key, text }));
                    if (!e.quiet)
                        e.report.add(
                            .warning,
                            .synthesized,
                            e.st.line,
                            "{s}: {s} needs '{s}' to behave as {s} does without " ++
                                "it; wrote {s}",
                            .{
                                @tagName(e.st.kind), e.g.name, e.slot(b.slot).name, e.source, text,
                            },
                        );
                    continue;
                }
                // An earlier line of this statement wrote the slot.
                const before = b.also and b.slot < 64 and e.hide & (@as(
                    u64,
                    1,
                ) << @intCast(b.slot)) != 0;
                if (b.also and e.foreign) {
                    // Only after another key wrote it, for another dialect's statement.
                    if (!before and !(e.bound(b.slot) and e.isUsed(b.slot))) continue;
                } else if (!e.bound(b.slot) or e.isUsed(b.slot)) {
                    continue;
                } else if (b.also) {
                    // In its own dialect, only where this key read it: on a
                    // line that says again what an earlier line said.
                    const owned = for (n.bag) |o| {
                        if (!o.also and o.slot == b.slot and (o.form == .plain or o.form == .quoted or o.form == .vector)) break true;
                    } else false;
                    if (owned) continue;
                }
                // Two slots this dialect spells with one key
                // (`gmin=gmin gmin=gmindc`): one value is said; two are a loss.
                const twin = for (n.bag[0..bi]) |o| {
                    if (o.form == .plain and !o.also and o.slot != b.slot and
                        e.isUsed(o.slot) and std.mem.eql(
                        u8,
                        o.key,
                        b.key,
                    )) break o.slot;
                } else null;
                if (twin) |t| {
                    if (!e.val(t).eql(e.val(b.slot)) and !e.quiet)
                        e.report.add(.@"error", .loss, e.st.line, "{s}: {s} = {s} " ++
                            "and {s} = {s} are both '{s}' in {s}; the first is " ++
                            "written", .{
                            @tagName(e.st.kind),           e.slot(t).name, try e.describe(e.val(t)), e.slot(b.slot).name,
                            try e.describe(e.val(b.slot)), b.key,          e.g.name,
                        });
                    e.mark(b.slot);
                    continue;
                }
                // `gmin=gmindc` after `gmin=gmin`: read back, the key fills the other slot.
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
                if (b.tag_slot != grammar.no_slot) {
                    const tv = e.st.at(b.tag_slot);
                    if (tv != .atom or !std.mem.eql(u8, tv.atom, b.tag_atom)) continue;
                    e.mark(b.tag_slot);
                }
                // A value this dialect cannot spell is left
                // unwritten, and reported as such.
                const vt = if (b.form == .vector and e.val(b.slot) == .list)
                    try e.vectorText(e.val(b.slot))
                else if (b.suffix.len > 0)
                    try e.arena.print(
                        "\"{s}{s}\"",
                        .{ (try e.slotText(b.slot, false)) orelse continue, b.suffix },
                    )
                else
                    (try e.slotText(b.slot, b.form == .quoted)) orelse continue;
                const text = if (b.form == .vector)
                    try e.arena.print("{s}=[{s}]", .{ b.key, vt })
                else
                    try e.arena.print("{s}={s}", .{ b.key, vt });
                try e.tok(text);
                e.mark(b.slot);
                e.again += @intFromBool(before);
            },
        }
    }
    return true;
}
