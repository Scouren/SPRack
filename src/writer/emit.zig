//! Emitter: one statement and one pattern of the target's grammar → the
//! statement's text, with what the pattern has no place for counted and
//! reported. `Caps` says which other dialects could have written it.
//! The text of one value is `emit_text.zig`, the keyed parameters of a
//! pattern `emit_bag.zig`, what it had no place for `emit_losses.zig`;
//! their functions are methods of `Emit` under the same names.
//!
//! Contents:
//! - `pub const Caps = struct`: `WordCap`, `word`, `FamilyCap`, `family`
//! - `pub const Emit = struct`
//!   - the attempt: `Save`, `save`, `restore`, `seq`, `one`
//!   - the slots: `slot`, `private`, `bound`, `given`, `isImplied`, `val`,
//!     `present`, `isUsed`, `mark`, `counted`
//!   - the tokens: `gap`, `tok`
//!   - the pattern: `anyBound`, `passCount`, `hasSlots`
//!   - from `emit_text.zig`: `valueText`, `meant`, `exprText`, `vectorText`,
//!     `checkNumber`, `semantics`, `sourceGrammar`, `signalText`,
//!     `slotText`, `describe`, `expandDefault`
//!   - from `emit_losses.zig`: `lost`, `inert`, `lossCount`, `reportLosses`
//! - `pub fn reasonFor(arena: Allocator, text: []const u8,
//!   to: []const u8) Allocator.Error![]const u8`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const expr = @import("expr");
const value_text = @import("emit_text.zig");
const bag = @import("emit_bag.zig");
const losses = @import("emit_losses.zig");
const tables = @import("tables.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Node = grammar.Node;
const Value = ir.Value;

/// What the other registered dialects can do, for error messages.
pub const Caps = struct {
    /// For each kind, the dialects whose grammar can write it ("ngspice, hspice").
    kinds: [schema.kind_count][]const u8,
    /// Same for model families.
    families: []const FamilyCap,
    /// Same for expression functions, variables and operators, by canonical name.
    words: []const WordCap = &.{},
    /// Every grammar, so a writer can ask what the source dialect knows.
    grammars: []const Grammar = &.{},

    pub const WordCap = struct { name: []const u8, dialects: []const u8 };

    pub fn word(c: *const Caps, name: []const u8) []const u8 {
        for (c.words) |f| if (std.mem.eql(u8, f.name, name)) return f.dialects;
        return "";
    }

    pub const FamilyCap = struct { family: []const u8, polarity: []const u8, dialects: []const u8 };

    pub fn family(c: *const Caps, fam: []const u8, pol: []const u8) []const u8 {
        for (c.families) |f| {
            if (std.mem.eql(u8, f.family, fam) and std.mem.eql(u8, f.polarity, pol))
                return f.dialects;
        }
        return "";
    }
};

// tidy: allow-fn(bool-heavy-struct) one Emit per statement attempt, never held in an array
pub const Emit = struct {
    g: *const Grammar,
    arena: Allocator,
    st: *const ir.Stmt,
    report: *ir.Report,
    buf: std.ArrayList(u8) = .empty,
    /// Bit per slot: spelled by the pattern so far.
    used: u64 = 0,
    /// Bit per slot: left out on purpose (`-slot`).
    dropped: u64 = 0,
    /// How many names this attempt had to change.
    renames: usize = 0,
    /// Value-less flags this rule had no way to write.
    lost_flags: usize = 0,
    /// Slots an earlier rule already wrote; this rule must not repeat them.
    hide: u64 = 0,
    /// How many of them a `k=slot+` of this rule said once more.
    again: usize = 0,
    /// Why the last attempt could not write the statement.
    why: []const u8 = "",
    funcs: ?*const expr.Funcs = null,
    caps: ?*const Caps = null,
    ordinal: usize = 0,
    quiet: bool = false,
    /// The statement was read from a different dialect.
    foreign: bool = false,
    /// The dialect the statement was read in.
    source: []const u8 = "",
    /// The next token goes directly after the previous one.
    tight: bool = false,
    /// Inside a repeated group: the pass being written, whose item of
    /// every list slot stands for the whole list.
    pass: ?usize = null,

    pub const Save = struct { len: usize, used: u64, dropped: u64, tight: bool };

    pub fn save(e: *const Emit) Save {
        return .{ .len = e.buf.items.len, .used = e.used, .dropped = e.dropped, .tight = e.tight };
    }

    pub fn restore(e: *Emit, s: Save) void {
        e.buf.shrinkRetainingCapacity(s.len);
        e.used = s.used;
        e.dropped = s.dropped;
        e.tight = s.tight;
    }

    pub fn slot(e: *const Emit, idx: u8) schema.Slot {
        return schema.info(e.st.kind).slots[idx];
    }

    /// `params` on an analysis or a control statement, and the heading an
    /// option is filed under, mean something only in the dialect that
    /// wrote them.
    pub fn private(e: *const Emit, idx: u8) bool {
        const class = schema.info(e.st.kind).class;
        if (class != .analysis and class != .control) return false;
        const name = e.slot(idx).name;
        return std.mem.eql(u8, name, "params") or std.mem.eql(u8, name, "package");
    }

    pub fn bound(e: *const Emit, idx: u8) bool {
        return e.given(idx) and !e.isImplied(idx);
    }

    /// `bound`, or holding what this dialect assumes: left out where the
    /// pattern can leave it out, written where a later value needs its
    /// place (`exp(0 1 0 2n)`).
    pub fn given(e: *const Emit, idx: u8) bool {
        if (idx >= schema.info(e.st.kind).slots.len) return false;
        if (idx < 64 and e.hide & (@as(u64, 1) << @intCast(idx)) != 0) return false;
        if (e.foreign and e.private(idx)) return false;
        return e.present(idx);
    }

    /// The slot holds exactly what this dialect assumes when nothing is
    /// said, so there is no need to say it.
    pub fn isImplied(e: *const Emit, idx: u8) bool {
        // An option the netlist sets is written even at the default: the
        // defaults are what `defaultOptions` compares, not what is said.
        if (e.st.kind == .options) return false;
        const text = for (e.g.implied) |im| {
            if (im.kind != e.st.kind or im.slot != idx) continue;
            if (im.when_slot == grammar.no_slot) break im.text;
            const c = e.st.at(im.when_slot);
            if (c == .atom and std.mem.eql(u8, c.atom, im.when_atom)) break im.text;
        } else return false;
        return switch (e.st.at(idx)) {
            .atom => |a| std.mem.eql(u8, a, text),
            .num => |n| n.exp10 == 0 and std.mem.eql(u8, n.digits(), text),
            else => false,
        };
    }

    /// The value of a slot; in a repeated group, this pass's item of a list.
    pub fn val(e: *const Emit, idx: u8) Value {
        const v = e.st.at(idx);
        const i = e.pass orelse return v;
        if (v != .list) return v;
        return if (i < v.list.len) v.list[i] else .none;
    }

    pub fn present(e: *const Emit, idx: u8) bool {
        return switch (e.val(idx)) {
            .none => false,
            .list => |l| l.len > 0,
            .params => |p| p.len > 0,
            else => true,
        };
    }

    /// Start a new token: blank-separated, but tight against parentheses.
    pub fn gap(e: *Emit, next: []const u8) Allocator.Error!void {
        const b = e.buf.items;
        if (e.tight) {
            e.tight = false;
            return;
        }
        if (b.len == 0 or b[b.len - 1] == '\n' or b[b.len - 1] == '(') return;
        if (std.mem.eql(u8, next, ")")) return;
        try e.buf.append(e.arena, ' ');
    }

    pub fn tok(e: *Emit, text: []const u8) Allocator.Error!void {
        try e.gap(text);
        try e.buf.appendSlice(e.arena, text);
    }

    pub const valueText = value_text.valueText;
    pub const meant = value_text.meant;
    pub const exprText = value_text.exprText;
    pub const vectorText = value_text.vectorText;
    pub const checkNumber = value_text.checkNumber;
    pub const semantics = value_text.semantics;
    pub const sourceGrammar = value_text.sourceGrammar;
    pub const signalText = value_text.signalText;
    pub const slotText = value_text.slotText;
    pub const describe = value_text.describe;
    pub const expandDefault = value_text.expandDefault;

    pub fn anyBound(e: *const Emit, items: []const Node) bool {
        for (items) |n| {
            switch (n.tag) {
                .cap, .rest, .taglit => if (n.slot != grammar.wild_slot and e.bound(n.slot))
                    return true,
                .opt, .alt, .seq, .rep => if (e.anyBound(n.kids)) return true,
                .bag => for (n.bag) |b| {
                    if (b.form != .fixed and e.bound(b.slot)) return true;
                },
                .lit, .glue, .nl, .drop => {},
            }
        }
        return false;
    }

    /// `#slot`: the list must have as many items as that slot says.
    pub fn counted(e: *Emit, n: Node, have: usize) Allocator.Error!bool {
        if (n.count == grammar.no_slot) return true;
        const c = e.st.at(n.count);
        if (c == .num and c.num.toFloat() == @as(f64, @floatFromInt(have))) return true;
        // No count given (a dialect that never says it): one item, as `dim?1` writes.
        if (c == .none and have == 1) return true;
        if (e.why.len == 0)
            e.why = try e.arena.print(
                "{d} items where '{s}' says {s}",
                .{ have, e.slot(n.count).name, try e.describe(c) },
            );
        return false;
    }

    pub fn passCount(e: *const Emit, items: []const Node, out: *usize) void {
        for (items) |n| {
            switch (n.tag) {
                .cap, .taglit => if (n.slot != grammar.wild_slot and e.bound(n.slot) and
                    e.st.at(n.slot) == .list)
                {
                    out.* = @max(out.*, e.st.at(n.slot).list.len);
                },
                else => e.passCount(n.kids, out),
            }
        }
    }

    // tidy: allow(recursion) bounded by the nesting of a pattern (the parser's max_depth)
    pub fn hasSlots(items: []const Node) bool {
        for (items) |n| {
            switch (n.tag) {
                .cap, .rest, .taglit, .bag => return true,
                .opt, .alt, .seq, .rep => if (hasSlots(n.kids)) return true,
                .lit, .glue, .nl, .drop => {},
            }
        }
        return false;
    }

    pub fn isUsed(e: *const Emit, idx: u8) bool {
        return idx < 64 and e.used & (@as(u64, 1) << @intCast(idx)) != 0;
    }

    pub fn mark(e: *Emit, idx: u8) void {
        if (idx < 64) e.used |= @as(u64, 1) << @intCast(idx);
    }

    /// Spell a sequence. False means it cannot be written with the values at hand.
    pub fn seq(e: *Emit, items: []const Node) Allocator.Error!bool {
        for (items) |n| if (!try e.one(n)) return false;
        return true;
    }

    pub fn one(e: *Emit, n: Node) Allocator.Error!bool {
        const len = e.buf.items.len;
        // A node only adds to the text: a group that fails takes back what
        // it wrote itself, never more.
        defer assert(e.buf.items.len >= len);
        switch (n.tag) {
            .lit => try e.tok(n.text),
            .glue => {
                try e.buf.appendSlice(e.arena, n.text);
                e.tight = !std.mem.eql(u8, n.text, ")");
            },
            .nl => try e.buf.append(e.arena, '\n'),
            .drop => if (e.present(n.slot)) {
                e.mark(n.slot);
                if (n.slot < 64) e.dropped |= @as(u64, 1) << @intCast(n.slot);
            },
            .taglit => return e.taglit(n),
            .cap => return e.cap(n),
            .rest => {
                if (!e.bound(n.slot)) return true;
                switch (e.st.at(n.slot)) {
                    .atom => |text| try e.tok(text),
                    // An expression taken from the rest of a line is written
                    // in plain parentheses, as it was read.
                    .expr => |canon| {
                        const text = try e.exprText(canon);
                        try e.tok(try e.arena.print("({s})", .{text}));
                    },
                    else => |v| try e.tok(try e.valueText(v, false)),
                }
                e.mark(n.slot);
            },
            .opt => {
                // Literal-only groups are always written; groups with slots
                // only when one of those slots holds a value.
                if (hasSlots(n.kids) and !e.anyBound(n.kids)) return true;
                const s = e.save();
                if (!try e.seq(n.kids)) e.restore(s);
            },
            .alt => {
                const s = e.save();
                for (n.kids) |alt| {
                    if (try e.seq(alt.kids)) return true;
                    e.restore(s);
                }
                return false;
            },
            .seq => return e.seq(n.kids),
            .rep => return e.rep(n),
            .bag => return bag.write(e, n),
        }
        return true;
    }

    pub const lost = losses.lost;
    pub const inert = losses.inert;
    pub const lossCount = losses.lossCount;
    pub const reportLosses = losses.reportLosses;

    fn taglit(e: *Emit, n: Node) Allocator.Error!bool {
        assert(n.tag == .taglit);
        const v = e.val(n.slot);
        if (n.soft and !e.present(n.slot)) {
            try e.tok(n.text);
            return true;
        }
        // On a value slot (`repeat:"endrepeat"=0`) the literal stands
        // for a number, and a number equal to it is written so.
        const num_ok = v == .num and if (lexer.parseNumber(
            e.arena,
            &e.g.lex,
            n.atom,
        )) |want| want.toFloat() == v.num.toFloat() else false;
        if (!num_ok and (v != .atom or !std.mem.eql(u8, v.atom, n.atom))) {
            if (v == .atom)
                e.why = try e.arena.print("{s} = {s}", .{ e.slot(n.slot).name, v.atom });
            return false;
        }
        try e.tok(n.text);
        e.mark(n.slot);
        return true;
    }

    fn cap(e: *Emit, n: Node) Allocator.Error!bool {
        assert(n.tag == .cap);
        if (n.slot == grammar.wild_slot) {
            try e.tok(try e.expandDefault(n.default));
            return true;
        }
        if (!e.given(n.slot)) return e.capDefault(n);
        if (n.pick != grammar.no_slot) return e.picked(n);
        if (n.count != grammar.no_slot and !try e.counted(
            n,
            if (e.st.at(n.slot) == .list) e.st.at(n.slot).list.len else 1,
        )) return false;
        if (n.one and (e.st.at(n.slot) != .list or e.st.at(n.slot).list.len != 1)) {
            if (e.why.len == 0)
                e.why = try e.arena.print("more than one '{s}'", .{e.slot(n.slot).name});
            return false;
        }
        var text = (try e.slotText(n.slot, false)) orelse return false;
        // `path!`: a path with no blank goes out without quotes.
        const v = e.st.at(n.slot);
        if (n.bare and v == .str and std.mem.indexOfAny(u8, v.str, " \t\"'") == null)
            text = v.str;
        // `name!`: in lower case.
        if (n.bare and std.mem.eql(u8, e.slot(n.slot).name, "name"))
            text = try std.ascii.allocLowerString(e.arena, text);
        if (n.prefix.len > 0) text = try e.prefixed(n, text);
        try e.tok(text);
        e.mark(n.slot);
        return true;
    }

    /// `slot*@sel=atom`: the items of the list whose item of `sel` at the
    /// same place is the word, case ignored. None: no text, which a `+`
    /// capture refuses; a statement without `sel` is refused.
    fn picked(e: *Emit, n: Node) Allocator.Error!bool {
        assert(n.pick != grammar.no_slot);
        assert(e.given(n.slot));
        const sel = e.st.at(n.pick);
        if (sel != .list) {
            if (e.why.len == 0)
                e.why = try e.arena.print("a statement without '{s}'", .{e.slot(n.pick).name});
            return false;
        }
        const v = e.st.at(n.slot);
        const items: []const Value = if (v == .list) v.list else &.{v};
        var kept: std.ArrayList(Value) = .empty;
        for (items, 0..) |it, i| {
            if (i >= sel.list.len or sel.list[i] != .atom) continue;
            if (std.ascii.eqlIgnoreCase(sel.list[i].atom, n.pick_atom))
                try kept.append(e.arena, it);
        }
        if (kept.items.len == 0 and n.plus) return false;
        var said: Value = .{ .list = kept.items };
        if (e.g.names) |*nm| if (value_text.isName(e.slot(n.slot))) {
            said = try tables.escapedValue(e.arena, nm, said);
        };
        if (kept.items.len > 0) try e.tok(try e.valueText(said, false));
        e.mark(n.slot);
        e.mark(n.pick);
        return true;
    }

    /// A capture whose slot the statement does not give: its default, or
    /// nothing where the capture may be left out.
    fn capDefault(e: *Emit, n: Node) Allocator.Error!bool {
        assert(!e.given(n.slot));
        if (n.star) return true;
        if (n.default.len == 0) {
            if (e.why.len == 0)
                e.why = try e.arena.print(
                    "a statement without '{s}'",
                    .{e.slot(n.slot).name},
                );
            return false;
        }
        var text = try e.expandDefault(n.default);
        if (e.slot(n.slot).ty == .value and lexer.parseNumber(
            e.arena,
            &e.g.lex,
            text,
        ) == null) {
            text = try e.valueText(.{ .expr = text }, false);
        }
        try e.tok(text);
        // A node made up for the instance (`tj?dt$name`) is news too.
        const made = e.slot(n.slot).ty == .node and std.mem.indexOfScalar(
            u8,
            n.default,
            '$',
        ) != null;
        if (!e.quiet and (e.slot(n.slot).ty == .value or made)) {
            e.report.add(.warning, .synthesized, e.st.line, "{s}: {s} needs '{s}' " ++
                "but the source gave none; wrote {s}", .{
                @tagName(e.st.kind), e.g.name, e.slot(n.slot).name, text,
            });
        }
        return true;
    }

    /// A capture's text with the letter its pattern puts in front.
    fn prefixed(e: *Emit, n: Node, text: []const u8) Allocator.Error![]const u8 {
        assert(n.prefix.len > 0);
        // A module's letter (Xyce `Y<module>`) is part of the form,
        // not a new name.
        if (!std.mem.eql(u8, e.slot(n.slot).name, "name")) {
            return e.arena.print(
                "{c}{s}{s}",
                .{ std.ascii.toUpper(n.prefix[0]), n.prefix[1..], text },
            );
        }
        if (std.ascii.startsWithIgnoreCase(text, n.prefix)) return text;
        const upper = text.len > 0 and std.ascii.isUpper(text[0]);
        const renamed = if (upper)
            try e.arena.print(
                "{c}{s}{s}",
                .{ std.ascii.toUpper(n.prefix[0]), n.prefix[1..], text },
            )
        else
            try e.arena.print("{s}{s}", .{ n.prefix, text });
        e.renames += 1;
        if (!e.quiet)
            e.report.add(
                .info,
                .rename,
                e.st.line,
                "renamed '{s}' to '{s}': {s} tells devices apart by the first letter",
                .{ text, renamed, e.g.name },
            );
        return renamed;
    }

    fn rep(e: *Emit, n: Node) Allocator.Error!bool {
        assert(n.tag == .rep);
        // As many passes as the longest list in the group has items.
        var passes: usize = 0;
        e.passCount(n.kids, &passes);
        if (!try e.counted(n, passes)) return false;
        if (passes == 0 and n.plus) {
            if (e.why.len == 0) e.why = "a statement without the repeated items";
            return false;
        }
        defer e.pass = null;
        for (0..passes) |i| {
            if (i > 0 and !try e.seq(n.sep)) return false;
            e.pass = i;
            if (!try e.seq(n.kids)) return false;
        }
        return true;
    }
};

/// A grammar's reason with `{to}` in it replaced by the dialect being
/// written; the text itself where it has no such place.
pub fn reasonFor(arena: Allocator, text: []const u8, to: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, text, "{to}") == null) return text;
    return std.mem.replaceOwned(u8, arena, text, "{to}", to);
}
