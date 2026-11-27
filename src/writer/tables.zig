//! Lookups in a grammar's word tables and small facts about values that
//! the emitter and the passes of the writer share.
//!
//! Contents:
//! - `pub const Origin = struct`, with `nameOf(origin, st) []const u8` and
//!   `grammarOf(origin, st) ?*const Grammar`
//! - `pub fn spellingsOf(table: []const grammar.Spellings,
//!   canon: []const u8) ?*const grammar.Spellings`
//! - `pub fn spellingCanon(table: []const grammar.Spellings, key: []const u8) ?[]const u8`
//! - `pub fn takes(table: []const grammar.Spellings, canon: []const u8) bool`
//! - `pub fn idleCeiling(st: *const ir.Stmt, slot: usize, v: Value) bool`
//! - `pub fn describeValue(a: Allocator, v: Value) Allocator.Error![]const u8`
//! - `pub fn filled(arena: Allocator, text: []const u8,
//!   vars: []const [2][]const u8) Allocator.Error![]const u8`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const dialects = @import("dialects");
const expr = @import("expr");
const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Value = ir.Value;

/// Where the statements of a netlist come from: the netlist's own dialect,
/// or for a statement tagged with another (a block of text added to a
/// circuit built in Python) that one.
pub const Origin = struct {
    /// The dialect of the netlist itself.
    source: []const u8,
    /// The grammars this binary has, a statement's own among them or not.
    grammars: []const Grammar,

    /// The name of the dialect `st` was read in.
    pub fn nameOf(origin: Origin, st: *const ir.Stmt) []const u8 {
        return if (st.dialect != 0) dialects.nameOf(st.dialect) else origin.source;
    }

    /// The grammar `st` was read with, where this binary has it.
    pub fn grammarOf(origin: Origin, st: *const ir.Stmt) ?*const Grammar {
        const name = origin.nameOf(st);
        for (origin.grammars) |*g| if (std.mem.eql(u8, g.name, name)) return g;
        return null;
    }
};

pub fn spellingsOf(table: []const grammar.Spellings, canon: []const u8) ?*const grammar.Spellings {
    for (table) |*e| if (std.ascii.eqlIgnoreCase(e.canon, canon)) return e;
    return null;
}

pub fn spellingCanon(table: []const grammar.Spellings, key: []const u8) ?[]const u8 {
    for (table) |e| for (e.spellings) |sp| if (std.ascii.eqlIgnoreCase(sp, key)) return e.canon;
    return null;
}

/// Does a `params` table take the canonical parameter `canon`?
pub fn takes(table: []const grammar.Spellings, canon: []const u8) bool {
    if (grammar.paramsOpen(table)) return true;
    for (table) |e| if (std.ascii.eqlIgnoreCase(e.canon, canon)) return true;
    return false;
}

/// `v` in `slot` of `st` is a `.tran` step ceiling at or above the stop
/// time, which limits nothing.
pub fn idleCeiling(st: *const ir.Stmt, slot: usize, v: Value) bool {
    if (st.kind != .tran or slot != schema.slot(.tran, "maxstep")) return false;
    return v == .num and st.get("stop") == .num and
        !(v.num.toFloat() < st.get("stop").num.toFloat());
}

/// The canonical name a dialect's `params` table gives a spelling.
/// The entry of a spellings table for a canonical name.
/// A value as a message shows it.
pub fn describeValue(a: Allocator, v: Value) Allocator.Error![]const u8 {
    return switch (v) {
        .atom, .expr, .str => |x| x,
        .num => try expr.canonText(a, v),
        else => "...",
    };
}

/// `text`, a line of a grammar, with each mark of `vars` (`{to}`,
/// `{module}`) replaced by what stands for it here.
pub fn filled(
    arena: Allocator,
    text: []const u8,
    vars: []const [2][]const u8,
) Allocator.Error![]const u8 {
    var out = text;
    for (vars) |v| {
        if (std.mem.indexOf(u8, out, v[0]) == null) continue;
        out = try std.mem.replaceOwned(u8, arena, out, v[0], v[1]);
    }
    return out;
}
