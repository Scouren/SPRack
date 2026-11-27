//! A form chosen by a word the statement leaves out: a statement that gives
//! slots only the forms of one word say (a measure's `trig` and `targ`,
//! said by its `trig` form) but not the word (`op`) is one error that names
//! the word and the words there are, not a loss for each slot.
//!
//! Contents:
//! - `pub fn unchosen(w: *Writer, a: Allocator, st: *const ir.Stmt) Writer.Error!bool`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const output = @import("output.zig");
const Writer = @import("statement.zig").Writer;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Node = grammar.Node;

/// Where `st` leaves out the word slot that chooses the forms which say
/// what it gives: that error, and the statement not written. False where it
/// does not, and nothing is said.
pub fn unchosen(w: *Writer, a: Allocator, st: *const ir.Stmt) Writer.Error!bool {
    const slots = schema.info(st.kind).slots;
    // A statement of a kind has no more slots than the schema bounds.
    assert(slots.len <= schema.max_slots);
    for (slots, 0..) |sl, si| {
        const s: u8 = @intCast(si);
        if (sl.ty != .atom or st.at(s) != .none) continue;
        const given = needs(w, st, s) orelse continue;
        var words: std.ArrayList(u8) = .empty;
        for (w.g.rulesOf(st.kind)) |ri| {
            const r = &w.g.rules[ri];
            if (r.dir != .read and r.within == null) try allWords(a, r.pat, s, &words);
        }
        w.report.add(.@"error", .invalid, st.line, "{s}: '{s}' is not given, and the forms " ++
            "that say '{s}' need it; it is one of: {s}", .{
            @tagName(st.kind), sl.name, slots[given].name, words.items,
        });
        try output.comment(w, try a.print("[sprack] not written: {s}", .{@tagName(st.kind)}));
        return true;
    }
    return false;
}

// ---- private ----

/// A slot `st` gives that only the write rules setting word slot `s` say,
/// where some do; null where every slot given has a form without it.
fn needs(w: *const Writer, st: *const ir.Stmt, s: u8) ?u8 {
    const slots = schema.info(st.kind).slots;
    for (slots, 0..) |sl, xi| {
        const x: u8 = @intCast(xi);
        if (x == s or sl.ty == .params or st.at(x) == .none) continue;
        var with = false;
        var without = false;
        for (w.g.rulesOf(st.kind)) |ri| {
            const r = &w.g.rules[ri];
            if (r.dir == .read or r.within != null or !grammar.mentions(r.pat, x)) continue;
            if (required(r.pat, s)) with = true else without = true;
        }
        if (with and !without) return x;
    }
    return null;
}

/// Every word a pattern sets slot `s` to, once each, after `out`'s.
// tidy: allow(recursion) bounded by the nesting of a pattern (the parser's max_depth)
fn allWords(
    a: Allocator,
    nodes: []const Node,
    s: u8,
    out: *std.ArrayList(u8),
) Allocator.Error!void {
    for (nodes) |*n| {
        if (n.tag == .taglit and n.slot == s and std.mem.indexOf(u8, out.items, n.atom) == null)
            try out.print(a, "{s}{s}", .{ if (out.items.len > 0) " " else "", n.atom });
        try allWords(a, n.kids, s, out);
    }
}

/// Does every way through the pattern set word slot `s` (a tagged
/// literal outside any optional or repeated group, or every alternative of
/// a choice that does)?
// tidy: allow(recursion) bounded by the nesting of a pattern (the parser's max_depth)
fn required(nodes: []const Node, s: u8) bool {
    for (nodes) |*n| switch (n.tag) {
        // A soft literal (`package:"timeint"?`) is written whatever the
        // slot holds: it chooses nothing.
        .taglit => if (n.slot == s and !n.soft) return true,
        .seq => if (required(n.kids, s)) return true,
        .alt => {
            const all = for (n.kids) |*alt| {
                if (!required(alt.kids, s)) break false;
            } else n.kids.len > 0;
            if (all) return true;
        },
        else => {},
    };
    return false;
}
