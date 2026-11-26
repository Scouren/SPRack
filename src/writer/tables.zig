//! Lookups in a grammar's word tables and small facts about values that
//! the emitter and the passes of the writer share.
//!
//! Contents:
//! - `pub fn spellingsOf(table: []const grammar.Spellings,
//!   canon: []const u8) ?*const grammar.Spellings`
//! - `pub fn spellingCanon(table: []const grammar.Spellings, key: []const u8) ?[]const u8`
//! - `pub fn takes(table: []const grammar.Spellings, canon: []const u8) bool`
//! - `pub fn idleCeiling(st: *const ir.Stmt, slot: usize, v: Value) bool`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const Value = ir.Value;

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
