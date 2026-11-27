//! JSON: the IR written as JSON, and what every dialect can write.
//!
//! Contents:
//! - `pub fn writeNetlist(w: *Writer, nl: *const ir.Netlist) Writer.Error!void`
//! - `pub fn writeEnv(w: *Writer, env: *const ir.Env) Writer.Error!void`
//! - `pub fn writeReport(w: *Writer, report: *const ir.Report) Writer.Error!void`
//! - `pub fn writeInfo(w: *Writer, grammars: []const grammar.Grammar) Writer.Error!void`: each
//!   slot with its name space, and the words the grammars give it (`atoms`, `closed`)

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir");
const dialects = @import("dialects");
const grammar = @import("grammar");
const json_read = @import("json_read.zig");
const assert = std.debug.assert;
const Value = ir.Value;
const Writer = std.Io.Writer;
const Pos = json_read.Pos;
const posOf = json_read.posOf;
const plainTag = json_read.plainTag;

/// The words a slot is given across the grammars, each once.
const Words = struct {
    list: [64][]const u8 = undefined,
    n: usize = 0,
    /// Some rule captures the slot as a word of the netlist's own.
    free: bool = false,

    fn add(ws: *Words, word: []const u8) void {
        for (ws.list[0..ws.n]) |have| if (std.ascii.eqlIgnoreCase(have, word)) return;
        // More than a closed set holds: the slot takes words of its own.
        if (ws.n == ws.list.len) {
            ws.free = true;
            return;
        }
        ws.list[ws.n] = word;
        ws.n += 1;
    }

    // tidy: allow(recursion) bounded by the nesting of a pattern (the parser's max_depth)
    fn pattern(ws: *Words, nodes: []const grammar.Node, slot: u8) void {
        for (nodes) |*n| {
            if (n.slot == slot) switch (n.tag) {
                .taglit => ws.add(n.atom),
                .cap, .rest => ws.free = true,
                else => {},
            };
            for (n.bag) |e| {
                if (e.tag_slot == slot and e.tag_atom.len > 0) ws.add(e.tag_atom);
                if (e.slot == slot or e.slot2 == slot) ws.free = true;
            }
            ws.pattern(n.kids, slot);
        }
    }
};

pub fn writeNetlist(w: *Writer, nl: *const ir.Netlist) Writer.Error!void {
    try w.writeAll("{\"title\":");
    try str(w, nl.title);
    try w.writeAll(",\"dialect\":");
    try str(w, nl.dialect);
    if (nl.defaults.len > 0) {
        try w.writeAll(",\"defaults\":");
        try str(w, nl.defaults);
    }
    if (nl.folds_case) try w.writeAll(",\"folds_case\":true");
    try w.writeAll(",\"stmts\":");
    try stmts(w, nl.stmts);
    try w.writeAll("}\n");
}

/// What the files of a project declare, field by field. A netlist written
/// apart from those files gives it back as its `env` (`parseNetlist`).
pub fn writeEnv(w: *Writer, env: *const ir.Env) Writer.Error!void {
    try w.writeAll("{\"models\":{");
    var first = true;
    var it = env.models.iterator();
    while (it.next()) |kv| {
        if (!first) try w.writeByte(',');
        first = false;
        try str(w, kv.key_ptr.*);
        try w.print(":\"{s}\"", .{@tagName(kv.value_ptr.*)});
    }
    try w.writeAll("},\"declared\":");
    try keys(w, &env.declared);
    try w.writeAll(",\"subckts\":");
    try keys(w, &env.subckts);
    try w.writeAll(",\"funcs\":");
    try keys(w, &env.funcs);
    try w.writeAll(",\"used\":[");
    first = true;
    for (schema.table, env.used, 0..) |info, used, i| {
        // `used` is indexed by kind, as the table is.
        assert(@backingInt(info.kind) == i);
        if (!used) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("\"{s}\"", .{@tagName(info.kind)});
    }
    try w.writeAll("],\"families\":[");
    first = true;
    for (schema.families, env.families) |f, used| {
        if (!used) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("\"{s}\"", .{f.name});
    }
    try w.writeAll("],\"conditional\":");
    try stmts(w, env.conditional.items);
    try w.writeAll(",\"params\":");
    try keys(w, &env.params);
    try w.writeAll(",\"family_of\":");
    try names(w, &env.family_of);
    try w.writeAll(",\"modules\":");
    try names(w, &env.modules);
    try w.writeByte('}');
}

pub fn writeReport(w: *Writer, report: *const ir.Report) Writer.Error!void {
    try w.writeByte('[');
    for (report.items.items, 0..) |d, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(
            "{{\"severity\":\"{s}\",\"code\":\"{s}\",\"line\":{d},\"message\":",
            .{ @tagName(d.sev), @tagName(d.code), d.line },
        );
        try str(w, d.msg);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

/// What every dialect can write, the canonical schema and the report
/// vocabulary: everything a front end needs to stay in step with the core.
pub fn writeInfo(w: *Writer, grammars: []const grammar.Grammar) Writer.Error!void {
    try w.writeAll("{\"dialects\":[");
    for (grammars, 0..) |g, i| {
        if (i > 0) try w.writeByte(',');
        try str(w, g.name);
    }
    try w.writeAll("],\"kinds\":{");
    for (schema.table, 0..) |info, i| {
        // The table is in the order of the kinds: `schema.info` indexes it so.
        assert(@backingInt(info.kind) == i);
        if (i > 0) try w.writeByte(',');
        try w.print(
            "\"{s}\":{{\"class\":\"{s}\",\"slots\":[",
            .{ @tagName(info.kind), @tagName(info.class) },
        );
        try slotsInfo(w, grammars, info.kind);
        try w.writeAll("],\"writers\":[");
        var first = true;
        for (grammars) |*g| {
            if (!g.canWrite(info.kind)) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try str(w, g.name);
        }
        try w.writeAll("],\"absent\":{");
        first = true;
        for (grammars) |*g| {
            const why = g.absentReason(info.kind) orelse continue;
            if (!first) try w.writeByte(',');
            first = false;
            try str(w, g.name);
            try w.writeByte(':');
            try str(w, why);
        }
        // Instance parameters per dialect, every spelling it reads.
        try w.writeAll("},\"params\":{");
        first = true;
        for (grammars) |*g| {
            const table = g.paramsOf(info.kind) orelse continue;
            // An open table checks nothing: no list to offer.
            if (grammar.paramsOpen(table)) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try str(w, g.name);
            try w.writeAll(":[");
            var n: usize = 0;
            for (table) |e| for (e.spellings) |sp| {
                if (n > 0) try w.writeByte(',');
                n += 1;
                try str(w, sp);
            };
            try w.writeByte(']');
        }
        try w.writeAll("}}");
    }
    try w.writeAll("},\"functions\":[");
    for (schema.functions, 0..) |f, i| {
        if (i > 0) try w.writeByte(',');
        try str(w, f);
    }
    try w.writeAll("],\"variables\":[");
    for (schema.variables, 0..) |f, i| {
        if (i > 0) try w.writeByte(',');
        try str(w, f);
    }
    try w.writeAll("]}\n");
}

// ---- private ----

/// JSON text is UTF-8, and a reader refuses the whole document over one
/// byte that is not (issue 64). A netlist need not be: a byte that does
/// not start a valid sequence is written as the Latin-1 character of its
/// value, so `\xb5` reads back as "µ".
fn str(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c >= 0x80) {
            const n: usize = std.unicode.utf8ByteSequenceLength(c) catch 1;
            if (n > 1 and i + n <= s.len and std.unicode.utf8ValidateSlice(s[i..][0..n])) {
                try w.writeAll(s[i..][0..n]);
                i += n;
            } else {
                try w.print("\\u{x:0>4}", .{c});
                i += 1;
            }
            continue;
        }
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
        i += 1;
    }
    // A sequence is written whole only where it fits: the last ends at the end.
    assert(i == s.len);
    try w.writeByte('"');
}

fn tagged(w: *Writer, tag: []const u8, s: []const u8) Writer.Error!void {
    try w.print("{{\"{s}\":", .{tag});
    try str(w, s);
    try w.writeByte('}');
}

fn repeatsKey(ps: []const ir.Param) bool {
    for (ps, 0..) |p, i| {
        for (ps[0..i]) |q| if (std.mem.eql(u8, p.key, q.key)) return true;
    }
    return false;
}

// tidy: allow(recursion) through `list` and `params`, bounded by the nesting of a value's
// lists, ir.max_depth
fn value(w: *Writer, v: Value, pos: Pos) Writer.Error!void {
    switch (v) {
        .none => try w.writeAll("null"),
        .atom => |s| if (plainTag(pos, s) == .atom) try str(w, s) else try tagged(w, "raw", s),
        .expr => |s| if (plainTag(pos, s) == .expr) try str(w, s) else try tagged(w, "expr", s),
        .num => |n| {
            try w.writeByte('"');
            try w.writeAll(n.digits());
            if (n.exp10 != 0) try w.print("e{d}", .{n.exp10});
            try w.writeByte('"');
        },
        .str => |s| try tagged(w, "str", s),
        .list => |items| try list(w, items, pos),
        .params => |ps| try params(w, ps),
    }
}

fn list(w: *Writer, items: []const Value, pos: Pos) Writer.Error!void {
    try w.writeByte('[');
    for (items, 0..) |it, i| {
        if (i > 0) try w.writeByte(',');
        try value(w, it, pos);
    }
    try w.writeByte(']');
}

fn params(w: *Writer, ps: []const ir.Param) Writer.Error!void {
    // A JSON object holds a key once: `toxref=1.26n ... toxref=1.3n`
    // is written as pairs.
    const pairs = repeatsKey(ps);
    try w.writeByte(if (pairs) '[' else '{');
    for (ps, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        if (pairs) try w.writeByte('[');
        try str(w, p.key);
        try w.writeByte(if (pairs) ',' else ':');
        try value(w, p.val, .value);
        if (pairs) try w.writeByte(']');
    }
    try w.writeByte(if (pairs) ']' else '}');
}

fn stmts(w: *Writer, all: []const ir.Stmt) Writer.Error!void {
    try w.writeByte('[');
    for (all, 0..) |*s, i| {
        if (i > 0) try w.writeAll(",\n");
        try stmt(w, s);
    }
    try w.writeByte(']');
}

// tidy: allow(recursion) through `stmts`, bounded by the nesting of blocks, ir.max_depth
fn stmt(w: *Writer, s: *const ir.Stmt) Writer.Error!void {
    try w.print("{{\"kind\":\"{s}\"", .{@tagName(s.kind)});
    if (s.line > 0) try w.print(",\"line\":{d}", .{s.line});
    try kept(w, s);
    for (schema.info(s.kind).slots, 0..) |sl, k| {
        if (s.at(k) == .none) continue;
        try w.writeByte(',');
        try str(w, sl.name);
        try w.writeByte(':');
        try value(w, s.at(k), posOf(sl.ty));
    }
    if (s.body.len > 0 or s.kind == .subckt or s.kind == .libsection) {
        try w.writeAll(",\"body\":");
        try stmts(w, s.body);
    }
    try w.writeByte('}');
}

/// What a statement keeps besides its slots: its text as read (a line
/// no rule read, or a comment), the text after it, and its dialect.
fn kept(w: *Writer, s: *const ir.Stmt) Writer.Error!void {
    if (s.kind == .@"opaque" or s.kind == .comment) {
        try w.writeAll(",\"raw\":");
        try str(w, if (std.mem.eql(u8, s.raw, ir.blank_line)) "" else s.raw);
        if (s.kind == .comment and std.mem.eql(u8, s.raw, ir.blank_line))
            try w.writeAll(",\"blank\":true");
    }
    if (s.tail.len > 0) {
        try w.writeAll(",\"tail\":");
        try str(w, s.tail);
    }
    if (s.dialect != 0) {
        try w.writeAll(",\"dialect\":");
        try str(w, dialects.nameOf(s.dialect));
    }
}

fn keys(w: *Writer, map: anytype) Writer.Error!void {
    try w.writeByte('[');
    var it = map.keyIterator();
    var first = true;
    while (it.next()) |k| {
        if (!first) try w.writeByte(',');
        first = false;
        try str(w, k.*);
    }
    try w.writeByte(']');
}

/// A map of names to names, as a JSON object.
fn names(w: *Writer, map: *const std.StringHashMapUnmanaged([]const u8)) Writer.Error!void {
    try w.writeByte('{');
    var it = map.iterator();
    var first = true;
    while (it.next()) |kv| {
        if (!first) try w.writeByte(',');
        first = false;
        try str(w, kv.key_ptr.*);
        try w.writeByte(':');
        try str(w, kv.value_ptr.*);
    }
    try w.writeByte('}');
}

/// The slots of `kind`: name, type, list, name space and words.
fn slotsInfo(w: *Writer, grammars: []const grammar.Grammar, kind: schema.Kind) Writer.Error!void {
    for (schema.info(kind).slots, 0..) |sl, k| {
        if (k > 0) try w.writeByte(',');
        try w.print(
            "{{\"name\":\"{s}\",\"type\":\"{s}\",\"list\":{},\"space\":",
            .{ sl.name, @tagName(sl.ty), sl.list },
        );
        if (sl.space) |sp| try w.print("\"{s}\"", .{@tagName(sp)}) else try w.writeAll("null");
        try slotWords(w, grammars, kind, @intCast(k));
        try w.writeByte('}');
    }
}

/// `,"atoms":[...],"closed":b`: the words the grammars give slot `slot` of
/// `kind` (a tagged literal, a key that sets it, an enum's canonical
/// values), and whether every grammar takes nothing else there (no rule
/// captures the slot as a free word). For an atom slot only; empty else.
fn slotWords(
    w: *Writer,
    grammars: []const grammar.Grammar,
    kind: schema.Kind,
    slot: u8,
) Writer.Error!void {
    var words: Words = .{};
    if (schema.info(kind).slots[slot].ty == .atom) {
        for (grammars) |*g| {
            for (g.rulesOf(kind)) |ri| words.pattern(g.rules[ri].pat, slot);
            for (g.enums) |e| {
                if (e.kind != kind or e.slot != slot) continue;
                for (e.pairs) |pair| words.add(pair.canon);
            }
        }
    }
    // `add` keeps each word once, and no more than the list holds.
    assert(words.n <= words.list.len);
    // A slot no grammar gives a word to is a free word: nothing to offer.
    const closed = words.n > 0 and !words.free;
    try w.writeAll(",\"atoms\":[");
    for (words.list[0..words.n], 0..) |word, i| {
        if (i > 0) try w.writeByte(',');
        try str(w, word);
    }
    try w.print("],\"closed\":{}", .{closed});
}
