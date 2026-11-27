//! Annotations under the target's names: an annotation names devices and
//! nets of its scope (cktImg's `*@ order m1 m2`, `*@ face m3.g left`), and
//! where the target writes a device under another name (`M1` as `XM1`,
//! where it tells devices apart by their first letter) the annotation names
//! it so too. A word is renamed only when it is a device's name in that
//! scope, whole, or before `.pin`; keywords and numbers never are, nor
//! the name a `*@ stage <name>` line of the scope gives a stage.
//!
//! Contents:
//! - `pub fn renamed(a: Allocator, w: *const Writer, stmts: []const ir.Stmt)
//!   Allocator.Error![]const ir.Stmt`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Kind = schema.Kind;
const Writer = @import("statement.zig").Writer;

const Names = std.HashMapUnmanaged(
    []const u8,
    []const u8,
    ir.Caseless,
    std.hash_map.default_max_load_percentage,
);

/// An argument of an annotation that names no device: the `at`th (from 0)
/// after the verb. cktImg's vocabulary, the one the writer knows.
const Fixed = struct { verb: []const u8, at: usize };

/// `*@ stage <name> ...`: a stage may be named as a device is, and its name
/// is never renamed, in that line or any other of the scope (`unmapStages`).
/// `*@ face <block> <port> <side>`: the port is a port of the block's
/// subcircuit, not a device of this scope.
/// `*@ label <net> at <dev>.<pin> ...`, `*@ wire <net> at ...`: the net.
const fixed = [_]Fixed{
    .{ .verb = "stage", .at = 0 },
    .{ .verb = "face", .at = 1 },
    .{ .verb = "label", .at = 0 },
    .{ .verb = "wire", .at = 0 },
};
const stage = fixed[0];

/// `stmts` with each annotation's words renamed as the devices of its scope
/// are written by `g`; the statements themselves where nothing changes.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn renamed(
    a: Allocator,
    w: *const Writer,
    stmts: []const ir.Stmt,
) Allocator.Error![]const ir.Stmt {
    const g = w.g;
    var map: Names = .empty;
    for (stmts) |*st| {
        const name = deviceName(st) orelse continue;
        const master = if (st.get("master") == .atom) st.get("master").atom else "";
        const letter = nameLetter(g, st.kind, w.familyOf(master)) orelse continue;
        if (std.ascii.startsWithIgnoreCase(name, letter)) continue;
        try map.put(a, name, try withLetter(a, letter, name));
    }
    if (map.count() > 0) unmapStages(&map, stmts);
    var out: ?[]ir.Stmt = null;
    for (stmts, 0..) |*st, i| {
        var cur = st.*;
        if (st.body.len > 0) {
            const b = try renamed(a, w, st.body);
            if (b.ptr != st.body.ptr) cur.body = @constCast(b);
        }
        if (st.kind == .annotation and map.count() > 0) {
            if (try renamedText(a, &map, textOf(st))) |t| {
                try cur.own(a);
                try cur.set(a, schema.slot(.annotation, "text"), .{ .atom = t });
            }
        }
        if (cur.body.ptr == st.body.ptr and cur.bound == st.bound) continue;
        if (out == null) out = try a.dupe(ir.Stmt, stmts);
        out.?[i] = cur;
    }
    const result: []const ir.Stmt = out orelse stmts;
    assert(result.len == stmts.len);
    return result;
}

// ---- private ----

/// Out of `map`, the first argument of every `stage` annotation of `stmts`.
fn unmapStages(map: *Names, stmts: []const ir.Stmt) void {
    for (stmts) |*st| {
        if (st.kind != .annotation) continue;
        var it = std.mem.tokenizeScalar(u8, textOf(st), ' ');
        var verb = it.next() orelse continue;
        if (std.mem.eql(u8, verb, "weak")) verb = it.next() orelse continue;
        if (!std.mem.eql(u8, verb, stage.verb)) continue;
        comptime assert(stage.at == 0);
        _ = map.remove(it.next() orelse continue);
    }
}

fn textOf(st: *const ir.Stmt) []const u8 {
    return switch (st.get("text")) {
        .atom, .str, .expr => |t| t,
        else => "",
    };
}

/// The name of a device, or of an instance of a subcircuit.
fn deviceName(st: *const ir.Stmt) ?[]const u8 {
    if (schema.info(st.kind).class != .device) return null;
    const v = st.get("name");
    return if (v == .atom) v.atom else null;
}

/// The letter the rule `g` writes `kind` by puts before a name
/// (`name~"R"`): the rule for the family of the device's model where `g`
/// has one (ngspice's PSP103 MOSFET is an N device), else the first rule
/// for any family. A device `g` has no rule for is written as an instance
/// of its model, with an instance's letter.
fn nameLetter(g: *const Grammar, kind: Kind, family: []const u8) ?[]const u8 {
    const of: Kind = if (g.canWriteRule(kind))
        kind
    else if (g.canWriteRule(.instance))
        .instance
    else
        return null;
    const slot = schema.slot(.instance, "name");
    // `deviceName` asks only of a device, whose name is its first slot.
    assert(schema.info(kind).class == .device);
    assert(schema.slotOf(kind, "name") == slot);
    var general: ?*const grammar.Rule = null;
    for (g.rulesOf(of)) |ri| {
        const r = &g.rules[ri];
        if (r.dir == .read or r.within != null) continue;
        const own = r.family.len > 0 and std.ascii.eqlIgnoreCase(r.family, family);
        if (own) return letterOf(r, slot);
        if (r.family.len == 0 and general == null) general = r;
    }
    return letterOf(general orelse return null, slot);
}

fn letterOf(r: *const grammar.Rule, slot: u8) ?[]const u8 {
    for (r.pat) |n| {
        if (n.tag == .cap and n.slot == slot and n.prefix.len > 0) return n.prefix;
    }
    return null;
}

/// `name` with `letter` before it, in the case of the name's first letter,
/// as the emitter writes it (`emit.Emit.prefixed`).
fn withLetter(a: Allocator, letter: []const u8, name: []const u8) Allocator.Error![]const u8 {
    assert(letter.len > 0);
    if (name.len > 0 and std.ascii.isUpper(name[0]))
        return a.print("{c}{s}{s}", .{ std.ascii.toUpper(letter[0]), letter[1..], name });
    return a.print("{s}{s}", .{ letter, name });
}

/// Is the `at`th argument of an annotation of `verb` one that names no device?
fn isFixed(verb: []const u8, at: usize) bool {
    for (fixed) |f| if (f.at == at and std.mem.eql(u8, f.verb, verb)) return true;
    return false;
}

/// `text` with each word that is a renamed device, whole or before `.pin`,
/// under its new name; null where no word is.
fn renamedText(a: Allocator, map: *const Names, text: []const u8) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var changed = false;
    var it = std.mem.splitScalar(u8, text, ' ');
    var first = true;
    // The verb, and how many words came after it.
    var verb: ?[]const u8 = null;
    var at: usize = 0;
    while (it.next()) |word| {
        if (!first) try out.append(a, ' ');
        first = false;
        const dot = std.mem.indexOfScalar(u8, word, '.') orelse word.len;
        const keep = verb != null and word.len > 0 and isFixed(verb.?, at);
        const new = if (keep) null else map.get(word[0..dot]);
        if (new) |n| {
            try out.appendSlice(a, n);
            try out.appendSlice(a, word[dot..]);
            changed = true;
        } else try out.appendSlice(a, word);
        if (word.len == 0) continue;
        if (verb != null) {
            at += 1;
        } else if (!std.mem.eql(u8, word, "weak")) verb = word;
    }
    // Unchanged, the words are put back as they were.
    assert(changed or out.items.len == text.len);
    return if (changed) out.items else null;
}
