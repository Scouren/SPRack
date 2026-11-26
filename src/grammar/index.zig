//! The read index of a grammar (which rules can read a line, from its first
//! byte; which kinds are read and written) and the pass over the rules that
//! marks `spread` endings.

const std = @import("std");
const schema = @import("schema");
const Kind = schema.Kind;
const context = @import("context.zig");
const types = @import("types.zig");
const C = context.C;
const Error = context.Error;
const Block = types.Block;
const Node = types.Node;
const RawBlock = types.RawBlock;
const Rule = types.Rule;
const Spread = types.Spread;
const no_slot = types.no_slot;
const wild_slot = types.wild_slot;

/// Which rules can read a line, from how the line starts: a reader offers a
/// line these, in file order, instead of every rule of the grammar. A rule
/// is left out of a list only where its first item refuses the line's first
/// word outright (a keyword that is another word, a name that must start
/// with another letter), so the first rule that reads a line is the same.
pub const ReadIndex = struct {
    /// For each first byte of a word: indices into `Grammar.rules`.
    by_byte: [256][]const u16 = @splat(&.{}),
    /// Every rule, for a line whose first token is not a word.
    all: []const u16 = &.{},
    /// Bit `k` is set when some rule is `@k`: for lines inside a block of
    /// kind `k` only, where the rules without `@` are then not used.
    own_rules: KindSet = 0,
    /// For each kind, its rules, read or write: indices into `Grammar.rules`.
    by_kind: [schema.kind_count][]const u16 = @splat(&.{}),
    /// The kinds a rule that stands anywhere writes; those written at all
    /// (by such a rule, a raw region or a block); those read (by a rule or
    /// a block); those with a block.
    write_rules: KindSet = 0,
    writes: KindSet = 0,
    reads: KindSet = 0,
    blocks: KindSet = 0,

    pub const KindSet = u128;

    comptime {
        std.debug.assert(schema.kind_count <= @bitSizeOf(KindSet));
    }

    pub fn kindBit(kind: Kind) KindSet {
        return @as(KindSet, 1) << @intCast(@backingInt(kind));
    }
};

/// Does a rule among `rules` that writes `kind` say `slot`?
pub fn anyWrites(rules: []const Rule, kind: Kind, slot: u8) bool {
    for (rules) |*r| {
        if (r.kind == kind and r.dir != .read and mentions(r.pat, slot)) return true;
    }
    return false;
}

/// Does the pattern `nodes` say `slot`, anywhere in it?
// tidy: allow(recursion) bounded by the nesting of a pattern (the parser's max_depth)
pub fn mentions(nodes: []const Node, slot: u8) bool {
    for (nodes) |n| {
        if (n.slot == slot or mentions(n.kids, slot)) return true;
        for (n.bag) |b| if (b.slot == slot or b.slot2 == slot) return true;
    }
    return false;
}

/// `rules` with `ending` set on each rule that starts with its kind's
/// `spread` word. Done last: a `spread` line may follow the rules it marks.
pub fn markEndings(c: *C, rules: []const Rule, spreads: []const Spread) Error![]const Rule {
    const out = try c.gpa.dupe(Rule, rules);
    for (out) |*rule| {
        const word = for (spreads) |sp| {
            if (sp.kind == rule.kind and sp.word.len > 0) break sp.word;
        } else continue;
        if (rule.pat.len == 0 or rule.pat[0].tag != .lit) continue;
        rule.ending = std.mem.eql(u8, rule.pat[0].text, word);
    }
    return out;
}

/// The `ReadIndex` of `rules`: for every first byte, the rules that
/// `startsWith` does not rule out, in file order.
pub fn readIndex(
    c: *C,
    rules: []const Rule,
    blocks: []const Block,
    raws: []const RawBlock,
) Error!ReadIndex {
    std.debug.assert(rules.len <= std.math.maxInt(u16));
    var index: ReadIndex = .{};
    for (rules) |rule| {
        const bit = ReadIndex.kindBit(rule.kind);
        if (rule.dir != .read and rule.within == null) index.write_rules |= bit;
        if (rule.dir != .write) index.reads |= bit;
    }
    for (blocks) |b| index.blocks |= ReadIndex.kindBit(b.kind);
    index.writes = index.write_rules | index.blocks;
    for (raws) |r| if (r.kind) |kind| {
        index.writes |= ReadIndex.kindBit(kind);
    };
    index.reads |= index.blocks;
    const all = try c.gpa.alloc(u16, rules.len);
    for (all, 0..) |*slot, i| slot.* = @intCast(i);
    index.all = all;
    for (rules) |rule| {
        if (rule.within) |kind| index.own_rules |= ReadIndex.kindBit(kind);
    }
    const scratch = try c.gpa.alloc(u16, rules.len);
    for (&index.by_byte, 0..) |*list, byte| {
        var n: usize = 0;
        for (rules, 0..) |*rule, i| {
            if (!startsWith(rule, @intCast(byte))) continue;
            scratch[n] = @intCast(i);
            n += 1;
        }
        list.* = try c.gpa.dupe(u16, scratch[0..n]);
    }
    for (&index.by_kind, schema.table) |*list, row| {
        var n: usize = 0;
        for (rules, 0..) |rule, i| {
            if (rule.kind != row.kind) continue;
            scratch[n] = @intCast(i);
            n += 1;
        }
        list.* = try c.gpa.dupe(u16, scratch[0..n]);
    }
    return index;
}

/// Can a line whose first word starts with `byte` be read by `rule`, as far
/// as the rule's first item tells? A keyword must be that word; a name with
/// a required first letter must start with it (a value or a signal may
/// start otherwise); anything else is not decided here.
pub fn startsWith(rule: *const Rule, byte: u8) bool {
    if (rule.pat.len == 0) return true;
    const first = rule.pat[0];
    switch (first.tag) {
        .lit => return first.text.len > 0 and first.text[0] == byte,
        .cap => {
            if (first.prefix.len == 0 or first.star or first.plus) return true;
            if (first.count != no_slot or first.slot == wild_slot) return true;
            const ty = schema.info(rule.kind).slots[first.slot].ty;
            if (ty == .value or ty == .signal) return true;
            return first.prefix[0] == byte;
        },
        else => return true,
    }
}
