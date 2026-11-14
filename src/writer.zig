//! Generic writer: runs a grammar's patterns in reverse.
//!
//! The same pattern that binds slots when reading spells them when writing.
//! Every slot that holds a value but has no place in the target pattern is
//! reported; nothing is dropped quietly.

const std = @import("std");
const grammar = @import("grammar.zig");
const schema = @import("schema.zig");
const ir = @import("ir.zig");
/// The dialect table (`internDialect`, `dialectName`).
const sprack = @import("root.zig");
const lexer = @import("lexer.zig");
const expr = @import("expr.zig");
const reader = @import("reader.zig");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Node = grammar.Node;
const Kind = schema.Kind;
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
            if (std.mem.eql(u8, f.family, fam) and std.mem.eql(u8, f.polarity, pol)) return f.dialects;
        }
        return "";
    }
};

const Emit = struct {
    g: *const Grammar,
    arena: Allocator,
    st: *const ir.Stmt,
    report: *ir.Report,
    buf: std.ArrayList(u8) = .empty,
    /// Bit per slot: spelled by the pattern so far.
    used: u64 = 0,
    /// How many names this attempt had to change.
    renames: usize = 0,
    /// Value-less flags this rule had no way to write.
    lost_flags: usize = 0,
    /// Slots an earlier rule already wrote; this rule must not repeat them.
    hide: u64 = 0,
    /// Why the last attempt could not write the statement.
    why: []const u8 = "",
    funcs: ?*const expr.Funcs = null,
    caps: ?*const Caps = null,
    ordinal: usize = 0,
    quiet: bool = false,
    /// The statement was read from a different dialect.
    foreign: bool = false,
    /// The next token goes directly after the previous one.
    tight: bool = false,
    /// Inside a repeated group: the pass being written, whose item of
    /// every list slot stands for the whole list.
    pass: ?usize = null,

    const Save = struct { len: usize, used: u64, tight: bool };

    fn save(e: *const Emit) Save {
        return .{ .len = e.buf.items.len, .used = e.used, .tight = e.tight };
    }

    fn restore(e: *Emit, s: Save) void {
        e.buf.shrinkRetainingCapacity(s.len);
        e.used = s.used;
        e.tight = s.tight;
    }

    fn slot(e: *const Emit, idx: u8) schema.Slot {
        return schema.info(e.st.kind).slots[idx];
    }

    /// `params` on an analysis or a control statement, and the heading an
    /// option is filed under, mean something only in the dialect that
    /// wrote them.
    fn private(e: *const Emit, idx: u8) bool {
        const class = schema.info(e.st.kind).class;
        if (class != .analysis and class != .control) return false;
        const name = e.slot(idx).name;
        return std.mem.eql(u8, name, "params") or std.mem.eql(u8, name, "package");
    }

    fn bound(e: *const Emit, idx: u8) bool {
        if (idx >= schema.info(e.st.kind).slots.len) return false;
        if (idx < 64 and e.hide & (@as(u64, 1) << @intCast(idx)) != 0) return false;
        if (e.foreign and e.private(idx)) return false;
        if (e.isImplied(idx)) return false;
        return e.present(idx);
    }

    /// The slot holds exactly what this dialect assumes when nothing is
    /// said, so there is no need to say it.
    fn isImplied(e: *const Emit, idx: u8) bool {
        const text = e.g.impliedOf(e.st.kind, idx) orelse return false;
        return switch (e.st.at(idx)) {
            .atom => |a| std.mem.eql(u8, a, text),
            .num => |n| n.exp10 == 0 and std.mem.eql(u8, n.digits(), text),
            else => false,
        };
    }

    /// The value of a slot; in a repeated group, this pass's item of a list.
    fn val(e: *const Emit, idx: u8) Value {
        const v = e.st.at(idx);
        const i = e.pass orelse return v;
        if (v != .list) return v;
        return if (i < v.list.len) v.list[i] else .none;
    }

    fn present(e: *const Emit, idx: u8) bool {
        return switch (e.val(idx)) {
            .none => false,
            .list => |l| l.len > 0,
            .params => |p| p.len > 0,
            else => true,
        };
    }

    /// Start a new token: blank-separated, but tight against parentheses.
    fn gap(e: *Emit, next: []const u8) Allocator.Error!void {
        const b = e.buf.items;
        if (e.tight) {
            e.tight = false;
            return;
        }
        if (b.len == 0 or b[b.len - 1] == '\n' or b[b.len - 1] == '(') return;
        if (std.mem.eql(u8, next, ")")) return;
        try e.buf.append(e.arena, ' ');
    }

    fn tok(e: *Emit, text: []const u8) Allocator.Error!void {
        try e.gap(text);
        try e.buf.appendSlice(e.arena, text);
    }

    fn valueText(e: *Emit, v: Value, quoted: bool) Allocator.Error![]const u8 {
        const cfg = &e.g.lex;
        var aw: std.Io.Writer.Allocating = .init(e.arena);
        const w = &aw.writer;
        switch (v) {
            .none => {},
            .atom => |s| if (quoted) w.print("\"{s}\"", .{s}) catch return error.OutOfMemory else w.writeAll(s) catch return error.OutOfMemory,
            .num => |n| lexer.renderNumber(w, cfg, n) catch return error.OutOfMemory,
            .expr => |canon| {
                var problems: std.ArrayList(expr.Problem) = .empty;
                const s = try expr.write(e.arena, e.g, canon, e.funcs, e.foreign, &problems);
                if (!e.quiet) for (problems.items) |pb| {
                    const who = if (e.caps) |c| c.word(pb.text) else "";
                    e.report.add(.@"error", .unsupported, e.st.line, "expression '{s}': {s} '{s}' has no spelling in {s}{s}{s}", .{
                        canon,                                                @tagName(pb.kind), pb.text, e.g.name,
                        if (who.len > 0) ". Dialects that have it: " else "", who,
                    });
                };
                if (cfg.bare_expr) {
                    const needs_parens = std.mem.indexOfAny(u8, s, " \t") != null;
                    (if (needs_parens) w.print("({s})", .{s}) else w.writeAll(s)) catch return error.OutOfMemory;
                } else if (cfg.expr_delims.len > 0) {
                    w.print("{s}{s}{s}", .{ cfg.expr_delims[0][0], s, cfg.expr_delims[0][1] }) catch return error.OutOfMemory;
                } else w.writeAll(s) catch return error.OutOfMemory;
            },
            .str => |s| w.print("\"{s}\"", .{s}) catch return error.OutOfMemory,
            .list => |items| for (items, 0..) |it, i| {
                if (i > 0) w.writeByte(' ') catch return error.OutOfMemory;
                w.writeAll(try e.valueText(it, false)) catch return error.OutOfMemory;
            },
            .params => |ps| for (ps, 0..) |p, i| {
                if (i > 0) w.writeByte(' ') catch return error.OutOfMemory;
                if (p.val == .none) {
                    w.writeAll(p.key) catch return error.OutOfMemory;
                } else w.print("{s}={s}", .{ p.key, try e.valueText(p.val, false) }) catch return error.OutOfMemory;
            },
        }
        return aw.written();
    }

    /// A value as shown in messages: no dialect delimiters around it.
    fn signalText(e: *Emit, canon: []const u8) Allocator.Error!?[]const u8 {
        var args: [3][]const u8 = undefined;
        const form, const n = reader.signalParts(canon, &args) orelse return null;
        for (e.g.signals) |sf| {
            if (!std.mem.eql(u8, sf.form, form)) continue;
            var out: std.ArrayList(u8) = .empty;
            var k: usize = 0;
            for (sf.template) |c| {
                if (c != '%') {
                    try out.append(e.arena, c);
                } else if (k < n) {
                    try out.appendSlice(e.arena, args[k]);
                    k += 1;
                }
            }
            if (k == n) return out.items;
        }
        return null;
    }

    /// The text of a bound slot, or null (with `why` set) when this dialect
    /// has no spelling for the value.
    fn slotText(e: *Emit, idx: u8, quoted: bool) Allocator.Error!?[]const u8 {
        const v = e.val(idx);
        const sl = e.slot(idx);
        if (sl.ty == .atom and v == .atom) {
            if (e.g.enumOf(e.st.kind, idx)) |em| {
                const sp = for (em.pairs) |pr| {
                    if (std.mem.eql(u8, pr.canon, v.atom)) break pr.spelling;
                } else blk: {
                    // A value this dialect's own reader let through goes
                    // back out as it came in.
                    if (!e.foreign) break :blk v.atom;
                    e.why = try e.arena.print("{s} = {s}", .{ sl.name, v.atom });
                    return null;
                };
                return if (quoted) try e.arena.print("\"{s}\"", .{sp}) else sp;
            }
        }
        if (sl.ty == .signal) {
            const items: []const Value = if (v == .list) v.list else &.{v};
            var out: std.ArrayList(u8) = .empty;
            for (items, 0..) |it, i| {
                if (i > 0) try out.append(e.arena, ' ');
                if (it == .atom) {
                    const t = (try e.signalText(it.atom)) orelse {
                        e.why = try e.arena.print("the signal {s}", .{it.atom});
                        return null;
                    };
                    try out.appendSlice(e.arena, t);
                } else try out.appendSlice(e.arena, try e.valueText(it, false));
            }
            return out.items;
        }
        return try e.valueText(v, quoted);
    }

    fn describe(e: *Emit, v: Value) Allocator.Error![]const u8 {
        return switch (v) {
            .expr => |s| s,
            .params => |ps| blk: {
                var out: std.ArrayList(u8) = .empty;
                for (ps, 0..) |p, i| {
                    if (i > 0) try out.append(e.arena, ' ');
                    if (p.val == .none) try out.appendSlice(e.arena, p.key) else try out.print(e.arena, "{s}={s}", .{ p.key, try e.describe(p.val) });
                }
                break :blk out.items;
            },
            else => e.valueText(v, false),
        };
    }

    /// Default text may refer to other slots (`$stop`) and to the ordinal of
    /// this statement among its kind (`$#`).
    fn expandDefault(e: *Emit, text: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] != '$') {
                try out.append(e.arena, text[i]);
                i += 1;
                continue;
            }
            if (i + 1 < text.len and text[i + 1] == '#') {
                try out.print(e.arena, "{d}", .{e.ordinal});
                i += 2;
                continue;
            }
            var j = i + 1;
            while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) j += 1;
            if (schema.slotIndex(e.st.kind, text[i + 1 .. j])) |si| {
                // Inside a delimited expression the value goes in raw.
                const v = e.st.at(si);
                const raw: []const u8 = switch (v) {
                    .none => "0",
                    .expr => |s| s,
                    .num => |n| if (n.exp10 == 0) n.digits() else try e.arena.print("{s}e{d}", .{ n.digits(), n.exp10 }),
                    else => try e.valueText(v, false),
                };
                try out.appendSlice(e.arena, raw);
            } else try out.appendSlice(e.arena, text[i..j]);
            i = j;
        }
        return out.toOwnedSlice(e.arena);
    }

    fn anyBound(e: *const Emit, items: []const Node) bool {
        for (items) |n| {
            switch (n.tag) {
                .cap, .rest, .taglit => if (n.slot != grammar.wild_slot and e.bound(n.slot)) return true,
                .opt, .alt, .seq, .rep => if (e.anyBound(n.kids)) return true,
                .bag => for (n.bag) |b| {
                    if (b.form != .fixed and e.bound(b.slot)) return true;
                },
                .lit, .glue, .nl, .drop => {},
            }
        }
        return false;
    }

    fn passCount(e: *const Emit, items: []const Node, out: *usize) void {
        for (items) |n| {
            switch (n.tag) {
                .cap, .taglit => if (n.slot != grammar.wild_slot and e.bound(n.slot) and e.st.at(n.slot) == .list) {
                    out.* = @max(out.*, e.st.at(n.slot).list.len);
                },
                else => e.passCount(n.kids, out),
            }
        }
    }

    fn hasSlots(items: []const Node) bool {
        for (items) |n| {
            switch (n.tag) {
                .cap, .rest, .taglit, .bag => return true,
                .opt, .alt, .seq, .rep => if (hasSlots(n.kids)) return true,
                .lit, .glue, .nl, .drop => {},
            }
        }
        return false;
    }

    fn isUsed(e: *const Emit, idx: u8) bool {
        return idx < 64 and e.used & (@as(u64, 1) << @intCast(idx)) != 0;
    }

    fn mark(e: *Emit, idx: u8) void {
        if (idx < 64) e.used |= @as(u64, 1) << @intCast(idx);
    }

    /// Spell a sequence. False means it cannot be written with the values at hand.
    fn seq(e: *Emit, items: []const Node) Allocator.Error!bool {
        for (items) |n| if (!try e.one(n)) return false;
        return true;
    }

    fn one(e: *Emit, n: Node) Allocator.Error!bool {
        switch (n.tag) {
            .lit => try e.tok(n.text),
            .glue => {
                try e.buf.appendSlice(e.arena, n.text);
                e.tight = !std.mem.eql(u8, n.text, ")");
            },
            .nl => try e.buf.append(e.arena, '\n'),
            .drop => if (e.present(n.slot)) e.mark(n.slot),
            .taglit => {
                const v = e.val(n.slot);
                if (n.soft and !e.present(n.slot)) {
                    try e.tok(n.text);
                    return true;
                }
                if (v != .atom or !std.mem.eql(u8, v.atom, n.atom)) {
                    if (v == .atom) e.why = try e.arena.print("{s} = {s}", .{ e.slot(n.slot).name, v.atom });
                    return false;
                }
                try e.tok(n.text);
                e.mark(n.slot);
            },
            .cap => {
                if (n.slot == grammar.wild_slot) {
                    try e.tok(try e.expandDefault(n.default));
                    return true;
                }
                if (!e.bound(n.slot)) {
                    if (n.star) return true;
                    if (n.default.len == 0) {
                        if (e.why.len == 0) e.why = try e.arena.print("a statement without '{s}'", .{e.slot(n.slot).name});
                        return false;
                    }
                    var text = try e.expandDefault(n.default);
                    if (e.slot(n.slot).ty == .value and lexer.parseNumber(e.arena, &e.g.lex, text) == null) {
                        text = try e.valueText(.{ .expr = text }, false);
                    }
                    try e.tok(text);
                    if (!e.quiet and e.slot(n.slot).ty == .value) {
                        e.report.add(.warning, .synthesized, e.st.line, "{s}: {s} needs '{s}' but the source gave none; wrote {s}", .{
                            @tagName(e.st.kind), e.g.name, e.slot(n.slot).name, text,
                        });
                    }
                    return true;
                }
                var text = (try e.slotText(n.slot, false)) orelse return false;
                // `path!`: a path with no blank goes out without quotes.
                const v = e.st.at(n.slot);
                if (n.bare and v == .str and std.mem.indexOfAny(u8, v.str, " \t\"'") == null) text = v.str;
                if (n.prefix.len > 0 and !std.ascii.startsWithIgnoreCase(text, n.prefix)) {
                    const upper = text.len > 0 and std.ascii.isUpper(text[0]);
                    const renamed = if (upper)
                        try e.arena.print("{c}{s}{s}", .{ std.ascii.toUpper(n.prefix[0]), n.prefix[1..], text })
                    else
                        try e.arena.print("{s}{s}", .{ n.prefix, text });
                    e.renames += 1;
                    if (!e.quiet) e.report.add(.info, .rename, e.st.line, "renamed '{s}' to '{s}': {s} tells devices apart by the first letter", .{ text, renamed, e.g.name });
                    text = renamed;
                }
                try e.tok(text);
                e.mark(n.slot);
            },
            .rest => {
                if (!e.bound(n.slot)) return true;
                switch (e.st.at(n.slot)) {
                    .atom => |text| try e.tok(text),
                    // An expression taken from the rest of a line is written
                    // in plain parentheses, as it was read.
                    .expr => |canon| {
                        var problems: std.ArrayList(expr.Problem) = .empty;
                        const text = try expr.write(e.arena, e.g, canon, e.funcs, e.foreign, &problems);
                        if (!e.quiet) for (problems.items) |pb| {
                            e.report.add(.@"error", .unsupported, e.st.line, "expression '{s}': {s} '{s}' has no spelling in {s}", .{ canon, @tagName(pb.kind), pb.text, e.g.name });
                        };
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
            .rep => {
                // As many passes as the longest list in the group has items.
                var passes: usize = 0;
                e.passCount(n.kids, &passes);
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
            },
            .bag => {
                for (n.bag) |b| {
                    switch (b.form) {
                        .fixed => try e.tok(try e.arena.print("{s}={s}", .{ b.key, b.fixed })),
                        .rest, .call => {
                            if (!e.bound(b.slot) or e.isUsed(b.slot)) continue;
                            for (e.st.at(b.slot).params) |p| {
                                if (p.val == .none) {
                                    // A bare flag, where the rule takes flags.
                                    if (b.flags) try e.tok(p.key) else e.lost_flags += 1;
                                    continue;
                                }
                                const vt = if (p.val == .list)
                                    try e.arena.print("[{s}]", .{try e.valueText(p.val, false)})
                                else
                                    try e.valueText(p.val, false);
                                if (b.form == .call) {
                                    try e.tok(try e.arena.print("{s}({s})={s}", .{ b.key, p.key, vt }));
                                } else try e.tok(try e.arena.print("{s}={s}", .{ p.key, vt }));
                            }
                            e.mark(b.slot);
                        },
                        .plain, .quoted, .vector => {
                            if (b.required and !e.bound(b.slot)) {
                                if (e.why.len == 0) e.why = try e.arena.print("a statement without '{s}'", .{e.slot(b.slot).name});
                                return false;
                            }
                            if (!e.bound(b.slot) or e.isUsed(b.slot)) continue;
                            if (b.tag_slot != grammar.no_slot) {
                                const tv = e.st.at(b.tag_slot);
                                if (tv != .atom or !std.mem.eql(u8, tv.atom, b.tag_atom)) continue;
                                e.mark(b.tag_slot);
                            }
                            // A value this dialect cannot spell is left
                            // unwritten, and reported as such.
                            const vt = (try e.slotText(b.slot, b.form == .quoted)) orelse continue;
                            const text = if (b.form == .vector)
                                try e.arena.print("{s}=[{s}]", .{ b.key, vt })
                            else
                                try e.arena.print("{s}={s}", .{ b.key, vt });
                            try e.tok(text);
                            e.mark(b.slot);
                        },
                    }
                }
            },
        }
        return true;
    }

    fn lost(e: *Emit, idx: u8) Allocator.Error!bool {
        if (!e.present(idx) or e.isUsed(idx)) return false;
        // The heading alone carries nothing a foreign dialect needs.
        if (e.foreign and std.mem.eql(u8, e.slot(idx).name, "package")) return false;
        // What this dialect assumes anyway need not be said.
        return !e.isImplied(idx);
    }

    fn lossCount(e: *Emit) Allocator.Error!usize {
        var n: usize = e.lost_flags;
        for (0..schema.info(e.st.kind).slots.len) |i| n += @intFromBool(try e.lost(@intCast(i)));
        return n;
    }

    fn reportLosses(e: *Emit) Allocator.Error!void {
        for (e.g.caveats) |c| {
            if (e.foreign and c.kind == e.st.kind and e.isUsed(c.slot)) {
                e.report.add(.warning, .caveat, e.st.line, "{s}.{s}: {s}", .{ @tagName(e.st.kind), e.slot(c.slot).name, c.text });
            }
        }
        if (e.lost_flags > 0) {
            for (e.st.values()) |v| {
                if (v != .params) continue;
                for (v.params) |p| {
                    if (p.val == .none) e.report.add(.@"error", .loss, e.st.line, "{s}: the flag '{s}' has no spelling in {s}", .{ @tagName(e.st.kind), p.key, e.g.name });
                }
            }
        }
        for (0..schema.info(e.st.kind).slots.len) |i| {
            const v = e.st.at(i);
            const idx: u8 = @intCast(i);
            if (!try e.lost(idx)) continue;
            const label = schema.info(e.st.kind).class == .analysis and e.slot(idx).ty == .name;
            if (label) {
                e.report.add(.info, .cosmetic, e.st.line, "{s}: {s} does not name its analyses; the label '{s}' is not written", .{ @tagName(e.st.kind), e.g.name, try e.describe(v) });
                continue;
            }
            if (e.slot(idx).ty == .params and v == .params) {
                // One entry per parameter: each is a separate thing the target cannot say.
                for (v.params) |p| {
                    e.report.add(.@"error", .loss, e.st.line, "{s}: '{s}' has no spelling in {s}", .{
                        @tagName(e.st.kind), try e.describe(.{ .params = &.{p} }), e.g.name,
                    });
                }
                continue;
            }
            e.report.add(.@"error", .loss, e.st.line, "{s}.{s} = {s} has no spelling in {s}", .{
                @tagName(e.st.kind), e.slot(idx).name, try e.describe(v), e.g.name,
            });
        }
    }
};

const Writer = struct {
    g: *const Grammar,
    arena: Allocator,
    out: *std.Io.Writer,
    report: *ir.Report,
    caps: ?*const Caps,
    source: []const u8,
    scratch: std.heap.ArenaAllocator,
    declared: std.StringHashMapUnmanaged(void) = .empty,
    funcs: expr.Funcs = .empty,
    /// Lower-cased names of every device instance, to check references.
    instances: ir.CaselessSet = .empty,
    ordinals: [schema.kind_count]usize = @splat(0),
    last_blank: bool = true,

    const Error = Allocator.Error || std.Io.Writer.Error;

    const wrap_at = 100;

    fn breakLine(w: *Writer) Error!void {
        const cfg = &w.g.lex;
        if (cfg.cont_lead.len > 0) {
            try w.out.print("\n{s} ", .{cfg.cont_lead});
        } else try w.out.print(" {s}\n    ", .{cfg.cont_trail});
    }

    /// Write one statement. A long one is broken at a blank, outside any
    /// quotes and brackets, with the dialect's continuation mark.
    fn line(w: *Writer, text: []const u8) Error!void {
        w.last_blank = false;
        const cfg = &w.g.lex;
        const can_wrap = cfg.cont_lead.len > 0 or cfg.cont_trail.len > 0;
        if (text.len <= wrap_at or !can_wrap or std.mem.indexOfScalar(u8, text, '\n') != null) {
            try w.out.writeAll(text);
            return w.out.writeByte('\n');
        }
        var start: usize = 0;
        var last_break: ?usize = null;
        var depth: usize = 0;
        var quote: u8 = 0;
        for (text, 0..) |c, i| {
            if (quote != 0) {
                if (c == quote) quote = 0;
                continue;
            }
            switch (c) {
                '"', '\'' => quote = c,
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -|= 1,
                ' ' => if (depth == 0) {
                    if (i - start > wrap_at) if (last_break) |b| if (b > start) {
                        try w.out.writeAll(text[start..b]);
                        try w.breakLine();
                        start = b + 1;
                    };
                    last_break = i;
                },
                else => {},
            }
        }
        if (text.len - start > wrap_at) if (last_break) |b| if (b > start) {
            try w.out.writeAll(text[start..b]);
            try w.breakLine();
            start = b + 1;
        };
        try w.out.writeAll(text[start..]);
        try w.out.writeByte('\n');
    }

    fn comment(w: *Writer, text: []const u8) Error!void {
        const marker = if (w.g.lex.line_comments.len > 0) w.g.lex.line_comments[0] else "*";
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| {
            if (l.len == 0) try w.out.print("{s}\n", .{marker}) else try w.out.print("{s} {s}\n", .{ marker, l });
        }
        w.last_blank = false;
    }

    /// A statement and the comment that trailed it in the source.
    fn lineTail(w: *Writer, text: []const u8, tail: []const u8) Error!void {
        if (tail.len == 0) return w.line(text);
        if (w.g.lex.tail_comments.len == 0 or std.mem.indexOfScalar(u8, text, '\n') != null) {
            try w.comment(tail);
            return w.line(text);
        }
        if (text.len + tail.len > wrap_at) {
            try w.comment(tail);
            return w.line(text);
        }
        try w.out.print("{s} {s} {s}\n", .{ text, w.g.lex.tail_comments[0], tail });
        w.last_blank = false;
    }

    /// The dialect `st` was read in.
    fn sourceOf(w: *const Writer, st: *const ir.Stmt) []const u8 {
        return if (st.dialect != 0) sprack.dialectName(st.dialect) else w.source;
    }

    fn supporters(w: *Writer, kind: Kind) []const u8 {
        const c = w.caps orelse return "";
        return c.kinds[@backingInt(kind)];
    }

    fn unmapModel(w: *Writer, a: Allocator, st: *const ir.Stmt) (Error || error{Skip})!?ir.Stmt {
        const fam = st.get("family");
        const same = std.mem.eql(u8, w.sourceOf(st), w.g.name);
        if (fam != .atom) {
            if (!same and st.get("type") == .atom) {
                const ty = st.get("type").atom;
                // A type word the source dialect's table lists, at a level it
                // does not, is a gap in that table. Any other word is the
                // name of a Verilog-A module, which is the same everywhere.
                var builtin = w.caps == null;
                if (w.caps) |c| for (c.grammars) |*sg| {
                    if (!std.mem.eql(u8, sg.name, w.sourceOf(st))) continue;
                    for (sg.models) |*m| for (m.spellings) |*sp| {
                        if (std.ascii.eqlIgnoreCase(sp.type, ty)) builtin = true;
                    };
                };
                if (builtin) {
                    w.report.add(.@"error", .unsupported, st.line, "model '{s}': type '{s}' with these parameters is not in the {s} models table, so its {s} name is unknown; written as it was", .{
                        st.get("name").atom, ty, w.sourceOf(st), w.g.name,
                    });
                } else if (w.g.absentReason(.device)) |why| {
                    w.report.add(.@"error", .unsupported, st.line, "model '{s}' is of the Verilog-A module '{s}': {s}", .{ st.get("name").atom, ty, why });
                } else {
                    w.report.add(.warning, .caveat, st.line, "model '{s}' is of the Verilog-A module '{s}': {s} must load the same module", .{ st.get("name").atom, ty, w.g.name });
                }
            }
            return st.*;
        }
        if (std.mem.eql(u8, fam.atom, ir.unlisted_builtin)) {
            var plain = st.*;
            try plain.own(a);
            try plain.set(a, schema.slotIndex(.model, "family").?, .none);
            if (!same) w.report.add(.@"error", .unsupported, st.line, "model '{s}': '{s}' is a built-in {s} model type that the {s} models table does not list, so its {s} name is unknown; written as it was", .{
                st.get("name").atom, st.get("type").atom, w.sourceOf(st), w.sourceOf(st), w.g.name,
            });
            return plain;
        }
        const pol: []const u8 = if (st.get("polarity") == .atom) st.get("polarity").atom else "";
        const entry = for (w.g.models) |*m| {
            if (std.mem.eql(u8, m.family, fam.atom) and std.mem.eql(u8, m.polarity, pol)) break m;
        } else {
            if (st.get("params") == .none) {
                if (schema.familyKind(fam.atom)) |k| {
                    // Only a kind whose instances name no model can do without
                    // the card; a MESFET still points at its (HFET) model.
                    if (w.g.canWrite(k) and schema.slotIndex(k, "master") == null) {
                        w.report.add(.info, .cosmetic, st.line, "model '{s}' only names a built-in {s}; {s} needs no such line", .{ st.get("name").atom, fam.atom, w.g.name });
                        return error.Skip;
                    }
                }
            }
            const who = if (w.caps) |c| c.family(fam.atom, pol) else "";
            w.report.add(.@"error", .unsupported, st.line, "model '{s}': {s}.spgrammar has no spelling for model family '{s}{s}{s}'. Defined by: {s}", .{
                st.get("name").atom,              w.g.name, fam.atom, if (pol.len > 0) " " else "", pol,
                if (who.len > 0) who else "none",
            });
            return null;
        };
        const sp = entry.spellings[0];
        var out = try ir.newStmt(a, .model, st.line);
        out.tail = st.tail;
        out.mask = st.mask;
        out.bound = st.bound;
        try out.own(a);
        try out.set(a, schema.slotIndex(.model, "type").?, .{ .atom = sp.type });
        try out.set(a, schema.slotIndex(.model, "family").?, .none);
        try out.set(a, schema.slotIndex(.model, "polarity").?, .none);
        var ps: std.ArrayList(ir.Param) = .empty;
        for (sp.kv) |kv| {
            if (kv.absent) continue;
            const v: Value = if (lexer.parseNumber(a, &w.g.lex, kv.val)) |n| .{ .num = n } else .{ .atom = kv.val };
            try ps.append(a, .{ .key = kv.key, .val = v });
        }
        if (st.get("params") == .params) try ps.appendSlice(a, st.get("params").params);
        try out.set(a, schema.slotIndex(.model, "params").?, if (ps.items.len > 0) .{ .params = ps.items } else .none);
        if (!same and st.get("params") == .params) {
            w.report.add(.warning, .caveat, st.line, "model '{s}' ({s}): {s} and {s} ship different implementations and versions of this model; parameters were copied as written, check them against {s}", .{
                st.get("name").atom, fam.atom, w.sourceOf(st), w.g.name, w.g.name,
            });
        }
        return out;
    }

    fn emitter(w: *Writer, a: Allocator, st: *const ir.Stmt) Emit {
        return .{
            .g = w.g,
            .arena = a,
            .st = st,
            .report = w.report,
            .funcs = &w.funcs,
            .caps = w.caps,
            .ordinal = w.ordinals[@backingInt(st.kind)],
            .foreign = !std.mem.eql(u8, w.sourceOf(st), w.g.name),
        };
    }

    fn unsupported(w: *Writer, a: Allocator, st: *const ir.Stmt) Error!void {
        const who = w.supporters(st.kind);
        const what = switch (schema.info(st.kind).class) {
            .analysis => "analysis",
            .device => "device",
            else => "statement",
        };
        const reason = w.g.absentReason(st.kind) orelse try a.print("{s}.spgrammar defines no rule for it", .{w.g.name});
        w.report.add(.@"error", .unsupported, st.line, "{s} '{s}' cannot be written for {s}: {s}. Dialects that define it: {s}", .{
            what, @tagName(st.kind), w.g.name, reason, if (who.len > 0) who else "none",
        });
        try w.comment(try a.print("[sprack] not written: {s} '{s}' has no {s} form", .{ what, @tagName(st.kind), w.g.name }));
    }

    fn stmt(w: *Writer, st: *const ir.Stmt) Error!void {
        for (w.g.blocks) |*b| {
            if (b.kind != st.kind) continue;
            w.ordinals[@backingInt(st.kind)] += 1;
            var e = w.emitter(w.arena, st);
            if (!try e.seq(b.open)) {
                w.report.add(.@"error", .invalid, st.line, "{s}: required values missing for the {s} form", .{ @tagName(st.kind), w.g.name });
                return;
            }
            try w.lineTail(e.buf.items, st.tail);
            for (b.inner) |pat| {
                if (!e.anyBound(pat)) continue;
                e.buf.clearRetainingCapacity();
                if (try e.seq(pat)) try w.line(e.buf.items);
            }
            for (st.body) |*child| try w.stmt(child);
            e.buf.clearRetainingCapacity();
            if (try e.seq(b.close)) try w.line(e.buf.items);
            try e.reportLosses();
            return;
        }
        defer _ = w.scratch.reset(.retain_capacity);
        try w.leaf(w.scratch.allocator(), st);
    }

    fn leaf(w: *Writer, a: Allocator, st_in: *const ir.Stmt) Error!void {
        var st = st_in;
        if (st.kind == .comment) {
            if (std.mem.eql(u8, st.raw, ir.blank_line)) {
                if (!w.last_blank) try w.out.writeByte('\n');
                w.last_blank = true;
                return;
            }
            return w.comment(st.raw);
        }
        if (st.kind == .@"opaque") {
            if (std.mem.eql(u8, w.sourceOf(st), w.g.name)) return w.lineTail(st.raw, st.tail);
            w.report.add(.@"error", .untranslated, st.line, "no {s} rule understood this line; it is in the output only as a comment: {s}", .{
                w.sourceOf(st), std.mem.sliceTo(st.raw, '\n'),
            });
            return w.comment(try a.print("[sprack] untranslated {s}: {s}", .{ w.sourceOf(st), st.raw }));
        }
        const class = schema.info(st.kind).class;
        if (class == .control) {
            // Nothing left to say (its values moved elsewhere): no statement.
            var any = false;
            for (schema.info(st.kind).slots, 0..) |sl, i| {
                if (std.mem.eql(u8, sl.name, "package")) continue;
                switch (st.at(i)) {
                    .none => {},
                    .list => |l| any = any or l.len > 0,
                    .params => |ps| any = any or ps.len > 0,
                    else => any = true,
                }
            }
            if (!any) return;
        }
        w.ordinals[@backingInt(st.kind)] += 1;

        var mapped: ir.Stmt = undefined;
        if (st.kind == .model) {
            const m = w.unmapModel(a, st) catch |err| switch (err) {
                error.Skip => return,
                else => |e| return e,
            };
            mapped = m orelse return w.comment(try a.print("[sprack] not written: model '{s}'", .{st.get("name").atom}));
            st = &mapped;
        }

        if (!w.g.canWrite(st.kind)) {
            if (w.g.absentReason(st.kind) == null) {
                if (try ir.demoteToInstance(a, st)) |inst| {
                    if (w.g.canWrite(.instance)) {
                        w.ordinals[@backingInt(st.kind)] -= 1;
                        return w.leaf(a, &inst);
                    }
                }
            }
            return w.unsupported(a, st);
        }

        var best: ?*const grammar.Rule = null;
        var best_loss: usize = std.math.maxInt(usize);
        var best_renames: usize = 0;
        var why: []const u8 = "";
        for (w.g.rules) |*rule| {
            if (rule.kind != st.kind or rule.dir == .read) continue;
            var e = w.emitter(a, st);
            e.quiet = true;
            if (!try e.seq(rule.pat)) {
                if (why.len == 0) why = e.why;
                continue;
            }
            // Least lost first; among equals, the form that keeps the name.
            const loss = try e.lossCount();
            if (loss < best_loss or (loss == best_loss and e.renames < best_renames)) {
                best = rule;
                best_loss = loss;
                best_renames = e.renames;
                if (best_loss == 0 and best_renames == 0) break;
            }
        }
        const rule = best orelse {
            if (why.len > 0) {
                w.report.add(.@"error", .unsupported, st.line, "{s}: no {s} form of this statement can say {s}", .{ @tagName(st.kind), w.g.name, why });
            } else {
                w.report.add(.@"error", .invalid, st.line, "{s}: the values given do not fit any {s} form of this statement", .{ @tagName(st.kind), w.g.name });
            }
            return w.comment(try a.print("[sprack] not written: {s}", .{@tagName(st.kind)}));
        };
        var e = w.emitter(a, st);
        _ = try e.seq(rule.pat);
        try w.lineTail(e.buf.items, st.tail);
        if (rule.dir == .write and !w.g.canRead(st.kind)) {
            w.report.add(.info, .oneway, st.line, "{s}: written in a form the {s} grammar does not read back as a {s}", .{ @tagName(st.kind), w.g.name, @tagName(st.kind) });
        }
        if (class == .control and best_loss > 0) {
            // What one statement cannot hold, further statements may:
            // `.options timeint ...` next to `.options device ...`.
            var progress = true;
            while (progress) {
                progress = false;
                for (w.g.rules) |*more| {
                    if (more.kind != st.kind or more.dir == .read) continue;
                    var probe = w.emitter(a, st);
                    probe.quiet = true;
                    probe.hide = e.used;
                    if (!try probe.seq(more.pat) or probe.used & ~e.used == 0) continue;
                    var extra = w.emitter(a, st);
                    extra.hide = e.used;
                    _ = try extra.seq(more.pat);
                    try w.line(extra.buf.items);
                    e.used |= extra.used;
                    progress = true;
                }
            }
        }
        try e.reportLosses();
        if (e.foreign) {
            // `.dc X ...` sweeps a source in one dialect and a parameter or
            // the temperature in another, under the same spelling.
            for (schema.info(st.kind).slots, 0..) |sl, i| {
                if (sl.ty != .ref or st.at(i) != .atom) continue;
                if (w.instances.contains(st.at(i).atom)) continue;
                w.report.add(.@"error", .invalid, st.line, "{s}.{s} = {s} does not name a device in this netlist; if {s} means a parameter by it, {s} has to be told so in its own way", .{
                    @tagName(st.kind), sl.name, st.at(i).atom, w.sourceOf(st), w.g.name,
                });
            }
        }
        if (e.foreign and w.g.lex.ident_values and (st.kind == .resistor or st.kind == .capacitor)) {
            const master = st.get("master");
            const value = st.at(3);
            if (master == .atom and value == .none and !w.declared.contains(try std.ascii.allocLowerString(a, master.atom))) {
                w.report.add(.warning, .ambiguous, st.line, "'{s}' on {s} is a model name in {s}, but no model of that name is declared here; {s} will read it as a parameter", .{
                    master.atom, st.get("name").atom, w.sourceOf(st), w.g.name,
                });
            }
        }
        if (e.foreign and (st.kind == .include or st.kind == .lib or st.kind == .hdl)) {
            w.report.add(.warning, .caveat, st.line, "{s} is still {s} syntax; translate that file too (`sprack project` follows includes)", .{ try e.describe(st.get("path")), w.sourceOf(st) });
        }
    }

    /// Would `applyMoves` change anything? The list it copies can be large.
    fn anyMove(w: *const Writer, stmts: []const ir.Stmt) bool {
        for (w.g.moves) |mv| {
            var from = false;
            var to = false;
            for (stmts) |*s| {
                from = from or (s.kind == mv.from and s.at(mv.from_slot) != .none);
                to = to or (s.kind == mv.to and s.at(mv.to_slot) == .none);
            }
            if (from and to) return true;
        }
        return false;
    }

    /// Apply the grammar's `move` lines: values this dialect says on another
    /// statement are carried there before anything is written.
    fn applyMoves(w: *Writer, stmts: []const ir.Stmt) Allocator.Error![]const ir.Stmt {
        if (!w.anyMove(stmts)) return stmts;
        const list = try w.arena.dupe(ir.Stmt, stmts);
        for (w.g.moves) |mv| {
            for (list) |*src| {
                if (src.kind != mv.from or src.at(mv.from_slot) == .none) continue;
                var moved = false;
                for (list) |*dst| {
                    if (dst.kind != mv.to or dst.at(mv.to_slot) != .none) continue;
                    try dst.own(w.arena);
                    try dst.set(w.arena, mv.to_slot, src.at(mv.from_slot));
                    moved = true;
                }
                if (!moved) continue;
                try src.own(w.arena);
                try src.set(w.arena, mv.from_slot, .none);
            }
        }
        return list;
    }
};

fn collectDeclared(arena: Allocator, stmts: []const ir.Stmt, out: *std.StringHashMapUnmanaged(void)) Allocator.Error!void {
    for (stmts) |*s| {
        if ((s.kind == .model or s.kind == .subckt) and s.get("name") == .atom) try out.put(arena, try std.ascii.allocLowerString(arena, s.get("name").atom), {});
        try collectDeclared(arena, s.body, out);
    }
}

fn markUsed(stmts: []const ir.Stmt, used: *[schema.kind_count]bool) void {
    for (stmts) |*s| {
        used[@backingInt(s.kind)] = true;
        markUsed(s.body, used);
    }
}

/// Two names that differ only by case are one name in a case-folding dialect.
/// Each key is the spelling last seen. The tables hold every node and
/// instance name, so they live outside the arena and are freed when done.
const CaseMaps = struct {
    nodes: ir.CaselessSet = .empty,
    instances: ir.CaselessSet = .empty,
    definitions: ir.CaselessSet = .empty,

    fn deinit(m: *CaseMaps) void {
        m.nodes.deinit(ir.big);
        m.instances.deinit(ir.big);
        m.definitions.deinit(ir.big);
    }
};

/// Names that differ only by case collide in a dialect that ignores case.
/// Nodes, instances and definitions are separate name spaces: a source
/// `Vdd` on a node `vdd` is no collision. A subcircuit's ports, nodes and
/// instances are its own scope; definitions are shared by all scopes.
fn checkCase(stmts: []const ir.Stmt, seen: *CaseMaps, report: *ir.Report, target: []const u8) Allocator.Error!void {
    for (stmts) |*s| {
        const scoped = s.kind == .subckt;
        var inner: CaseMaps = .{ .definitions = seen.definitions };
        const maps = if (scoped) &inner else seen;
        defer if (scoped) {
            seen.definitions = inner.definitions;
            inner.nodes.deinit(ir.big);
            inner.instances.deinit(ir.big);
        };
        for (schema.info(s.kind).slots, 0..) |sl, i| {
            const map = switch (sl.ty) {
                .node => &maps.nodes,
                .name => if (schema.info(s.kind).class == .device) &maps.instances else &maps.definitions,
                .ident => &maps.definitions,
                else => continue,
            };
            // A model's type word is a keyword of the dialect, not a name.
            if (s.kind == .model and std.mem.eql(u8, sl.name, "type")) continue;
            const one = [1]Value{s.at(i)};
            const items: []const Value = switch (one[0]) {
                .atom => &one,
                .list => |l| l,
                else => &.{},
            };
            for (items) |v| {
                if (v != .atom) continue;
                const gop = try map.getOrPut(ir.big, v.atom);
                if (gop.found_existing and !std.mem.eql(u8, gop.key_ptr.*, v.atom)) {
                    report.add(.@"error", .invalid, s.line, "'{s}' and '{s}' are different names in the source but the same name in {s}, which ignores case", .{
                        gop.key_ptr.*, v.atom, target,
                    });
                    gop.key_ptr.* = v.atom;
                }
            }
        }
        try checkCase(s.body, maps, report, target);
    }
}

fn collectInstances(stmts: []const ir.Stmt, out: *ir.CaselessSet) Allocator.Error!void {
    for (stmts) |*s| {
        if (schema.info(s.kind).class == .device and s.get("name") == .atom) try out.put(ir.big, s.get("name").atom, {});
        try collectInstances(s.body, out);
    }
}

fn collectFuncs(arena: Allocator, stmts: []const ir.Stmt, out: *expr.Funcs) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .func and s.get("name") == .atom) try out.put(arena, try std.ascii.allocLowerString(arena, s.get("name").atom), {});
        try collectFuncs(arena, s.body, out);
    }
}

pub fn write(
    g: *const Grammar,
    arena: Allocator,
    out: *std.Io.Writer,
    nl: *const ir.Netlist,
    report: *ir.Report,
    caps: ?*const Caps,
    env: ?*const ir.Env,
) (Allocator.Error || std.Io.Writer.Error)!void {
    var w: Writer = .{
        .g = g,
        .arena = arena,
        .out = out,
        .report = report,
        .caps = caps,
        .source = nl.dialect,
        .scratch = .init(ir.big),
    };
    defer w.scratch.deinit();

    try collectDeclared(arena, nl.stmts, &w.declared);
    try collectFuncs(arena, nl.stmts, &w.funcs);
    defer w.instances.deinit(ir.big);
    try collectInstances(nl.stmts, &w.instances);
    if (env) |e| {
        var it = e.declared.keyIterator();
        while (it.next()) |k| try w.declared.put(arena, try std.ascii.allocLowerString(arena, k.*), {});
        var fi = e.funcs.keyIterator();
        while (fi.next()) |k| try w.funcs.put(arena, k.*, {});
    }
    if (!g.lex.case_sensitive) {
        var seen: CaseMaps = .{};
        defer seen.deinit();
        try checkCase(nl.stmts, &seen, report, g.name);
    }
    // An included file is not a netlist: it has no title of its own, must
    // not end the simulation, and leaves the boilerplate to the top file.
    if (g.lex.title and !nl.library) {
        try out.print("{s}{s}\n", .{ g.lex.title_prefix, if (nl.title.len > 0) nl.title else "untitled" });
    }
    for (g.header) |l| try w.line(l);
    if (!nl.library) {
        for (g.preamble) |l| try w.line(l);
        var used: [schema.kind_count]bool = if (env) |e| e.used else @splat(false);
        markUsed(nl.stmts, &used);
        for (g.needs) |n| {
            if (!used[@backingInt(n.kind)]) continue;
            for (n.lines) |l| try w.line(l);
        }
    }
    const stmts = try w.applyMoves(nl.stmts);
    for (stmts) |*s| {
        if (g.wrapOf(s.kind) == null) try w.stmt(s);
    }
    for (g.wraps) |*wr| {
        var any = false;
        for (stmts) |*s| {
            if (g.wrapOf(s.kind) != wr) continue;
            if (!any) try w.line(wr.open);
            any = true;
            try w.stmt(s);
        }
        if (any) try w.line(wr.close);
    }
    if (g.lex.end_marker.len > 0 and !nl.library) try w.line(g.lex.end_marker);
}
