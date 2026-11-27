//! The dialect table: the built-in grammars, and an index for every dialect
//! name a statement can carry (`ir.Stmt.dialect`) → grammar by name, name by
//! index, index by name.
//!
//! The grammars are compiled when the binary is built (`tools/grammar_gen.zig`
//! writes the `registry` module) and never change. The name table grows: a
//! grammar loaded at run time or a name met in JSON takes the next index and
//! keeps it for the life of the process.
//!
//! Contents:
//! - `pub const count`
//! - `pub const grammars: [count]Grammar`
//! - `pub fn find(name: []const u8) ?*const Grammar`
//! - `pub fn intern(name: []const u8) Allocator.Error!?u8`
//! - `pub fn nameOf(index: u8) []const u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const grammar = @import("grammar");
const registry = @import("registry");
const Grammar = grammar.Grammar;

pub const count = registry.grammars.len;

/// One compiled grammar per `grammars/*.spgrammar` file, in file name order.
/// A mistake in a file stops the build where the tables are made.
pub const grammars: [count]Grammar = registry.grammars;

/// Rows of `names`. Index 0 stands for "the netlist's own dialect", so a
/// process can hold `names_max - 1` names.
const names_max = 256;

comptime {
    assert(count < names_max);
}

/// 0 is "the netlist's"; the built-ins take 1..count in registry order.
/// One table a process, read from any thread: a name is written before
/// `names_len` counts it, and two threads adding at once take `adding` in
/// turn.
var names: [names_max][]const u8 = blk: {
    var table: [names_max][]const u8 = @splat("");
    for (grammars, 1..) |g, i| table[i] = g.name;
    break :blk table;
};
var names_len: std.atomic.Value(usize) = .init(count + 1);
var adding: std.atomic.Value(bool) = .init(false);

/// The built-in grammar of that name, case ignored.
pub fn find(name: []const u8) ?*const Grammar {
    for (&grammars) |*g| if (std.ascii.eqlIgnoreCase(g.name, name)) return g;
    return null;
}

/// The index of dialect `name` (case ignored), added to the table if new.
/// Null when the table is full. A new name is copied and never freed.
pub fn intern(name: []const u8) Allocator.Error!?u8 {
    assert(name.len > 0);
    if (known(name, names_len.load(.acquire))) |index| return index;
    // A name new to the table is rare (a grammar loaded from a file that a
    // netlist switches to): the few who add wait for one another here.
    while (adding.cmpxchgWeak(false, true, .acquire, .monotonic) != null)
        std.atomic.spinLoopHint();
    defer adding.store(false, .release);
    const len = names_len.load(.acquire);
    if (known(name, len)) |index| return index;
    if (len == names.len) return null;
    // tidy: allow(global-allocator-in-library) the table outlives every caller's arena
    names[len] = try std.heap.page_allocator.dupe(u8, name);
    names_len.store(len + 1, .release);
    return @intCast(len);
}

/// The name behind an index from `intern`; "" for 0.
pub fn nameOf(index: u8) []const u8 {
    assert(index < names_len.load(.acquire));
    return names[index];
}

// ---- private ----

/// The index of `name` among the first `len` names of the table.
fn known(name: []const u8, len: usize) ?u8 {
    for (names[1..len], 1..) |have, i| {
        if (std.ascii.eqlIgnoreCase(have, name)) return @intCast(i);
    }
    return null;
}

test "the built-ins are found by name and hold the first indices" {
    try std.testing.expect(count > 0);
    for (&grammars, 1..) |*g, i| {
        try std.testing.expectEqual(g, find(g.name).?);
        try std.testing.expectEqual(@as(?u8, @intCast(i)), try intern(g.name));
        try std.testing.expectEqualStrings(g.name, nameOf(@intCast(i)));
    }
    try std.testing.expectEqual(null, find("no-such-dialect"));
    try std.testing.expectEqualStrings("", nameOf(0));
}
