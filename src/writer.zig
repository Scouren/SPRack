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

/// `3.3.0`: digits with more than one point.
fn malformedNumber(t: []const u8) bool {
    if (t.len == 0 or !std.ascii.isDigit(t[0])) return false;
    var dots: usize = 0;
    for (t) |c| {
        if (c == '.') dots += 1 else if (!std.ascii.isDigit(c)) return false;
    }
    return dots > 1;
}

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
    /// The dialect the statement was read in.
    source: []const u8 = "",
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
                const s = try e.exprText(canon);
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
                e.checkNumber(p);
                if (p.val == .none) {
                    w.writeAll(p.key) catch return error.OutOfMemory;
                } else w.print("{s}={s}", .{ p.key, try e.valueText(p.val, false) }) catch return error.OutOfMemory;
            },
        }
        return aw.written();
    }

    /// A canonical expression in this dialect's spelling, with what it
    /// cannot say (an error) and what it says differently (a caveat) reported.
    fn exprText(e: *Emit, canon: []const u8) Allocator.Error![]const u8 {
        var problems: std.ArrayList(expr.Problem) = .empty;
        const s = try expr.write(e.arena, e.g, canon, e.funcs, e.foreign, &problems);
        e.semantics(canon);
        if (!e.quiet) for (problems.items) |pb| {
            if (pb.kind == .form) {
                e.report.add(.info, .oneway, e.st.line, "expression '{s}': {s} has no {s}, so the choice is written {s}; it reads back in that form", .{
                    canon, e.g.name, if (std.mem.eql(u8, pb.text, "if")) "?: operator" else "if() function", if (std.mem.eql(u8, pb.text, "if")) "if(c, a, b)" else "c ? a : b",
                });
                continue;
            }
            const who = if (e.caps) |c| c.word(pb.text) else "";
            e.report.add(.@"error", .unsupported, e.st.line, "expression '{s}': {s} '{s}' has no spelling in {s}{s}{s}", .{
                canon,                                                @tagName(pb.kind), pb.text, e.g.name,
                if (who.len > 0) ". Dialects that have it: " else "", who,
            });
        };
        return s;
    }

    /// The items of a `[...]` vector, with the dialect's separator.
    fn vectorText(e: *Emit, v: Value) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (v.list, 0..) |it, i| {
            if (i > 0) try out.appendSlice(e.arena, e.g.lex.vector_sep);
            try out.appendSlice(e.arena, try e.valueText(it, false));
        }
        return out.items;
    }

    /// `version=3.3.0`: one simulator's lenient reading of a malformed
    /// number is no other's.
    fn checkNumber(e: *Emit, p: ir.Param) void {
        const raw: []const u8 = switch (p.val) {
            .atom => |x| x,
            .expr => |x| x,
            .str => |x| x,
            else => "",
        };
        if (e.foreign and !e.quiet and e.g.lex.strict_numbers and malformedNumber(raw)) {
            e.report.add(.@"error", .invalid, e.st.line, "{s}={s} is not a number; {s} does not read it", .{ p.key, raw, e.g.name });
        }
    }

    /// A function or operator that one side of a translation evaluates
    /// differently (`differs` in either grammar): a caveat, never silence.
    fn semantics(e: *Emit, canon: []const u8) void {
        if (e.quiet or !e.foreign) return;
        const src: ?*const Grammar = if (e.caps) |c| for (c.grammars) |*g| {
            if (std.mem.eql(u8, g.name, e.source)) break g;
        } else null else null;
        for ([_]?*const Grammar{ e.g, src }) |og| {
            const g = og orelse continue;
            for (g.differs) |d| {
                if (expr.uses(canon, d.canon)) e.report.add(.warning, .caveat, e.st.line, "expression '{s}': {s} in {s}: {s}", .{ canon, d.canon, g.name, d.text });
            }
        }
    }

    /// A value as shown in messages: no dialect delimiters around it.
    fn signalText(e: *Emit, canon: []const u8) Allocator.Error!?[]const u8 {
        var args: [3][]const u8 = undefined;
        const form, const n = reader.signalParts(canon, &args) orelse return null;
        for (e.g.signals) |sf| {
            if (!std.mem.eql(u8, sf.form, form)) continue;
            var out: std.ArrayList(u8) = .empty;
            var k: usize = 0;
            var i: usize = 0;
            while (i < sf.template.len) : (i += 1) {
                const c = sf.template[i];
                if (c != '%') {
                    try out.append(e.arena, c);
                    continue;
                }
                // `%2`: that name, not the next one.
                var at = k;
                if (i + 1 < sf.template.len and sf.template[i + 1] >= '1' and sf.template[i + 1] <= '3') {
                    at = sf.template[i + 1] - '1';
                    i += 1;
                }
                if (at < n) try out.appendSlice(e.arena, args[at]);
                k += 1;
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
                } else if (it == .expr) {
                    // `expr = "par('%')"` says how; where expressions have no
                    // delimiters nothing tells one from a node name.
                    const tmpl = for (e.g.signals) |sf| {
                        if (std.mem.eql(u8, sf.form, "expr")) break sf.template;
                    } else "";
                    if (tmpl.len == 0 and e.g.lex.bare_expr) {
                        e.why = try e.arena.print("the signal expression {s}", .{it.expr});
                        return null;
                    }
                    if (tmpl.len == 0) {
                        try out.appendSlice(e.arena, try e.valueText(it, false));
                    } else {
                        var problems: std.ArrayList(expr.Problem) = .empty;
                        const body = try expr.write(e.arena, e.g, it.expr, e.funcs, e.foreign, &problems);
                        if (problems.items.len > 0) {
                            e.why = try e.arena.print("the signal expression {s}", .{it.expr});
                            return null;
                        }
                        const pct = std.mem.indexOfScalar(u8, tmpl, '%').?;
                        try out.print(e.arena, "{s}{s}{s}", .{ tmpl[0..pct], body, tmpl[pct + 1 ..] });
                    }
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
            if (i + 1 < text.len and text[i + 1] == '+') {
                // `$+values`: how many items the list slot holds.
                var j = i + 2;
                while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) j += 1;
                const v = if (schema.slotIndex(e.st.kind, text[i + 2 .. j])) |si| e.st.at(si) else Value.none;
                try out.print(e.arena, "{d}", .{if (v == .list) v.list.len else 0});
                i = j;
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

    /// `#slot`: the list must have as many items as that slot says.
    fn counted(e: *Emit, n: Node, have: usize) Allocator.Error!bool {
        if (n.count == grammar.no_slot) return true;
        const c = e.st.at(n.count);
        if (c == .num and c.num.toFloat() == @as(f64, @floatFromInt(have))) return true;
        // No count given (a dialect that never says it): one item, as `dim?1` writes.
        if (c == .none and have == 1) return true;
        if (e.why.len == 0) e.why = try e.arena.print("{d} items where '{s}' says {s}", .{ have, e.slot(n.count).name, try e.describe(c) });
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
                    // A node made up for the instance (`tj?dt$name`) is news too.
                    const made = e.slot(n.slot).ty == .node and std.mem.indexOfScalar(u8, n.default, '$') != null;
                    if (!e.quiet and (e.slot(n.slot).ty == .value or made)) {
                        e.report.add(.warning, .synthesized, e.st.line, "{s}: {s} needs '{s}' but the source gave none; wrote {s}", .{
                            @tagName(e.st.kind), e.g.name, e.slot(n.slot).name, text,
                        });
                    }
                    return true;
                }
                if (n.count != grammar.no_slot and !try e.counted(n, if (e.st.at(n.slot) == .list) e.st.at(n.slot).list.len else 1)) return false;
                if (n.one and (e.st.at(n.slot) != .list or e.st.at(n.slot).list.len != 1)) {
                    if (e.why.len == 0) e.why = try e.arena.print("more than one '{s}'", .{e.slot(n.slot).name});
                    return false;
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
            .rep => {
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
            },
            .bag => {
                for (n.bag) |b| {
                    switch (b.form) {
                        .fixed => {
                            if (b.tag_slot != grammar.no_slot) {
                                const tv = e.st.at(b.tag_slot);
                                if (tv != .atom or !std.mem.eql(u8, tv.atom, b.tag_atom)) {
                                    if (tv == .atom) e.why = try e.arena.print("{s} = {s}", .{ e.slot(b.tag_slot).name, tv.atom });
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
                                    if (e.g.lex.bare_expr) try e.arena.print("[{s}]", .{try e.vectorText(p.val)}) else try e.vectorText(p.val)
                                else
                                    try e.valueText(p.val, false);
                                if (b.form == .call) {
                                    try e.tok(try e.arena.print("{s}({s})={s}", .{ b.key, p.key, vt }));
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
                                for (try e.valueText(p.val, false)) |c| if (c != ' ') try out.append(e.arena, c);
                            }
                            try out.append(e.arena, '}');
                            try e.tok(out.items);
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
                            const vt = if (b.form == .vector and e.val(b.slot) == .list)
                                try e.vectorText(e.val(b.slot))
                            else
                                (try e.slotText(b.slot, b.form == .quoted)) orelse continue;
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
                if (c.suffix.len > 0) {
                    const v = e.st.at(c.slot);
                    const t: []const u8 = switch (v) {
                        .str, .atom, .expr => |x| x,
                        else => "",
                    };
                    if (!std.ascii.endsWithIgnoreCase(t, c.suffix)) continue;
                }
                // Text carried verbatim may read differently on the other side.
                e.report.add(.warning, if (e.slot(c.slot).ty == .text) .ambiguous else .caveat, e.st.line, "{s}.{s}: {s}", .{ @tagName(e.st.kind), e.slot(c.slot).name, c.text });
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
    /// The statement being written names a file: one line, however long.
    nowrap: bool = false,
    /// Model name to its family, for rules that depend on it (`bjt[hicum2]`).
    // ponytail: models of this file only; one declared in another file of a project leaves its instances on the plain rules.
    families: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Model cards whose parameters were copied by name: one caveat per
    /// file, naming the first, not one per card (sky130 has thousands).
    copied: struct { n: usize = 0, name: []const u8 = "", family: []const u8 = "", source: []const u8 = "", line: u32 = 0 } = .{},

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
        if (text.len <= wrap_at or !can_wrap or w.nowrap or std.mem.indexOfScalar(u8, text, '\n') != null) {
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
        if (!same) {
            // A key given twice: SPICE keeps the last, Xyce rejects the card.
            var i: usize = ps.items.len;
            while (i > 0) {
                i -= 1;
                const k = ps.items[i].key;
                for (ps.items[i + 1 ..]) |later| if (std.ascii.eqlIgnoreCase(later.key, k)) {
                    w.report.add(.warning, .invalid, st.line, "model '{s}': '{s}' is given twice; the last value is kept", .{ st.get("name").atom, k });
                    _ = ps.orderedRemove(i);
                    break;
                };
            }
        }
        const th = try expr.thresholds(a, w.g, fam.atom, ps.items, true);
        if (th.changed and !th.no_half) w.report.add(.warning, .caveat, st.line, "model '{s}': the threshold and hysteresis are written as on and off levels; {s} moves smoothly between them where SPICE switches with hysteresis", .{ st.get("name").atom, w.g.name });
        if (th.changed) for (th.params) |p| if (p.val == .expr and isLevel(w.g, p.key)) {
            w.report.add(.info, .oneway, st.line, "model '{s}': levels computed from expressions read back as equal expressions of another shape", .{st.get("name").atom});
            break;
        };
        if (th.no_half) w.report.add(.@"error", .loss, st.line, "model '{s}': a switch with no hysteresis has no {s} form; its on and off levels would be equal", .{ st.get("name").atom, w.g.name });
        try out.set(a, schema.slotIndex(.model, "params").?, if (th.params.len > 0) .{ .params = th.params } else .none);
        if (!same and st.get("params") == .params) {
            if (w.copied.n == 0) w.copied = .{ .name = st.get("name").atom, .family = fam.atom, .source = w.sourceOf(st), .line = st.line };
            w.copied.n += 1;
        }
        return out;
    }

    /// The grammar of the dialect `st` was read in, when it is a built-in one.
    fn sourceGrammar(w: *const Writer, st: *const ir.Stmt) ?*const Grammar {
        const c = w.caps orelse return null;
        for (c.grammars) |*g| if (std.mem.eql(u8, g.name, w.sourceOf(st))) return g;
        return null;
    }

    /// A device's instance parameters against the target's `params` table:
    /// each is renamed to the target's spelling, and one the target's
    /// device does not take is a loss, not copied. Null: nothing changes.
    fn instParams(w: *Writer, a: Allocator, st: *const ir.Stmt) Allocator.Error!?ir.Stmt {
        const table = w.g.paramsOf(st.kind) orelse return null;
        if (std.mem.eql(u8, w.sourceOf(st), w.g.name)) return null;
        const idx = schema.slotIndex(st.kind, "params") orelse return null;
        const v = st.at(idx);
        if (v != .params) return null;
        const from = if (w.sourceGrammar(st)) |sg| sg.paramsOf(st.kind) else null;
        var em = w.emitter(a, st);
        var out: std.ArrayList(ir.Param) = .empty;
        var changed = false;
        for (v.params) |p| {
            const canon = if (from) |t| spellingCanon(t, p.key) orelse p.key else p.key;
            const entry = for (table) |*e| {
                if (std.ascii.eqlIgnoreCase(e.canon, canon)) break e;
            } else {
                const shown = if (p.val == .none) p.key else try a.print("{s}={s}", .{ p.key, try em.describe(p.val) });
                w.report.add(.@"error", .loss, st.line, "{s}: '{s}' has no spelling in {s}, whose {s} takes no such instance parameter", .{
                    @tagName(st.kind), shown, w.g.name, @tagName(st.kind),
                });
                changed = true;
                continue;
            };
            if (entry.positive and p.val == .num and p.val.num.toFloat() <= 0) {
                w.report.add(.@"error", .invalid, st.line, "{s}: {s}={s}: {s} refuses {s} of zero or less", .{
                    @tagName(st.kind), p.key, try em.describe(p.val), w.g.name, entry.canon,
                });
            }
            for (entry.spellings) |sp| {
                if (std.ascii.eqlIgnoreCase(sp, p.key)) break;
            } else {
                w.report.add(.info, .rename, st.line, "{s}: the instance parameter '{s}' is spelled '{s}' in {s}", .{ @tagName(st.kind), p.key, entry.spellings[0], w.g.name });
                try out.append(a, .{ .key = entry.spellings[0], .val = p.val });
                changed = true;
                continue;
            }
            try out.append(a, p);
        }
        if (!changed) return null;
        var copy = st.*;
        try copy.own(a);
        try copy.set(a, idx, if (out.items.len > 0) .{ .params = out.items } else .none);
        return copy;
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
            .source = w.sourceOf(st),
        };
    }

    fn unsupported(w: *Writer, a: Allocator, st: *const ir.Stmt) Error!void {
        const who = w.supporters(st.kind);
        const what = switch (schema.info(st.kind).class) {
            .analysis => "analysis",
            .device => "device",
            else => "statement",
        };
        const reason = w.g.absentReason(st.kind) orelse if (w.g.movedTo(st.kind)) |mv|
            try a.print("{s} says it as {s}.{s}, and this netlist has no {s}", .{
                w.g.name, @tagName(mv.to), schema.info(mv.to).slots[mv.to_slot].name, @tagName(mv.to),
            })
        else
            try a.print("{s}.spgrammar defines no rule for it", .{w.g.name});
        w.report.add(.@"error", .unsupported, st.line, "{s} '{s}' cannot be written for {s}: {s}. Dialects that define it: {s}", .{
            what, @tagName(st.kind), w.g.name, reason, if (who.len > 0) who else "none",
        });
        try w.comment(try a.print("[sprack] not written: {s} '{s}' has no {s} form", .{ what, @tagName(st.kind), w.g.name }));
    }

    fn stmt(w: *Writer, st: *const ir.Stmt) Error!void {
        if (st.kind == .model and st.body.len > 0) return w.binnedModel(st);
        // A block kind this dialect has only a rule for: the rule says the
        // header, the body follows it (Xyce `.sampling` ahead of its
        // analyses), or the rule is added to each statement of the body
        // (`spread`, HSPICE `monte=`).
        if (st.body.len > 0 and w.g.blockOf(st.kind) == null and w.g.canWrite(st.kind)) {
            if (w.g.isSpread(st.kind)) return w.spread(st);
            var head = st.*;
            head.body = &.{};
            try w.stmt(&head);
            for (st.body) |*child| try w.stmt(child);
            return;
        }
        for (w.g.blocks) |*b| {
            if (b.kind != st.kind) continue;
            // A kind that also has rules is a block only with a body
            // (Spectre's binned `model ... { }`).
            if (st.body.len == 0 and w.g.canWriteRule(st.kind)) break;
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
        {
            defer _ = w.scratch.reset(.retain_capacity);
            try w.leaf(w.scratch.allocator(), st);
        }
        // A sweep this dialect writes as one line for the whole netlist
        // (`.step`): what it sweeps follows it.
        if (schema.info(st.kind).class == .analysis) for (st.body) |*child| try w.stmt(child);
    }

    /// Where a step is one line that sweeps every analysis of the netlist, a
    /// step that sweeps only some of them cannot be said.
    fn checkSteps(w: *Writer, stmts: []const ir.Stmt) void {
        for (w.g.blocks) |b| if (b.kind == .step) return;
        var step: ?*const ir.Stmt = null;
        var outside = false;
        for (stmts) |*s| {
            if (s.kind != .step) {
                outside = outside or schema.info(s.kind).class == .analysis;
            } else if (step == null) step = s else outside = true;
        }
        const st = step orelse return;
        // HSPICE's .TEMP list in a deck with no analysis: nothing to repeat.
        if (st.body.len == 0 and !std.mem.eql(u8, w.sourceOf(st), w.g.name))
            w.report.add(.@"error", .invalid, st.line, "step: the netlist has no analysis for the {s} sweep to repeat", .{w.g.name});
        if (outside) w.report.add(.@"error", .invalid, st.line, "step: a {s} sweep applies to every analysis of the netlist; this one leaves some out", .{w.g.name});
    }

    /// What `stmt` writes for `st`, as text.
    fn capture(w: *Writer, st: *const ir.Stmt) Error![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(w.arena);
        const saved = w.out;
        w.out = &aw.writer;
        defer w.out = saved;
        try w.stmt(st);
        return aw.written();
    }

    /// `spread`: the block's own rule ends each statement of its body.
    fn spread(w: *Writer, st: *const ir.Stmt) Error!void {
        var head = st.*;
        head.body = &.{};
        const suffix = std.mem.trim(u8, try w.capture(&head), " \n");
        for (st.body) |*child| {
            if (schema.info(child.kind).class != .analysis) {
                try w.stmt(child);
                continue;
            }
            const text = std.mem.trimEnd(u8, try w.capture(child), "\n");
            try w.out.print("{s} {s}\n", .{ text, suffix });
        }
    }

    /// Model cards `nch.1`, `nch.2`, ... grouped under `nch` by
    /// `groupBins`: the block's header names the type, each bin is a line.
    fn binnedModel(w: *Writer, st: *const ir.Stmt) Error!void {
        const b = w.g.blockOf(.model).?;
        const a = w.arena;
        const ti = schema.slotIndex(.model, "type").?;
        const ni = schema.slotIndex(.model, "name").?;
        var bins: std.ArrayList(ir.Stmt) = .empty;
        var head = st.*;
        head.body = &.{};
        try head.own(a);
        for (st.body) |*child| {
            if (child.kind != .model) {
                try bins.append(a, child.*);
                continue;
            }
            const m = (w.unmapModel(a, child) catch |err| switch (err) {
                error.Skip => continue,
                else => |e| return e,
            }) orelse continue;
            var bin = m;
            try bin.own(a);
            if (head.at(ti) == .none) try head.set(a, ti, m.at(ti));
            const full = child.get("name").atom;
            const dot = std.mem.lastIndexOfScalar(u8, full, '.').?;
            try bin.set(a, ni, .{ .atom = try std.fmt.allocPrint(a, "{s}:", .{full[dot + 1 ..]}) });
            try bin.set(a, ti, .none);
            try bins.append(a, bin);
        }
        var e = w.emitter(a, &head);
        if (!try e.seq(b.open)) {
            w.report.add(.@"error", .invalid, st.line, "model: required values missing for the {s} form", .{w.g.name});
            return;
        }
        try w.lineTail(e.buf.items, st.tail);
        for (bins.items) |*bin| try w.stmt(bin);
        e.buf.clearRetainingCapacity();
        if (try e.seq(b.close)) try w.line(e.buf.items);
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
            // A region the source grammar keeps verbatim, and says why.
            if (w.caps) |c| for (c.grammars) |*sg| {
                if (!std.mem.eql(u8, sg.name, w.sourceOf(st))) continue;
                for (sg.raws) |rb| {
                    if (rb.reason.len == 0 or !std.mem.startsWith(u8, st.raw, rb.open)) continue;
                    w.report.add(.@"error", .unsupported, st.line, "'{s}' cannot be written for {s}: {s}", .{ std.mem.sliceTo(st.raw, '\n'), w.g.name, rb.reason });
                    return w.comment(try a.print("[sprack] not written: {s}", .{std.mem.sliceTo(st.raw, '\n')}));
                }
            };
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
        // A grammar loaded at run time, or JSON, can give a model or a
        // device no name; everything below names it in its messages.
        if ((class == .device or st.kind == .model) and st.get("name") != .atom) {
            w.report.add(.@"error", .invalid, st.line, "{s}: a statement without a name cannot be written", .{@tagName(st.kind)});
            return w.comment(try a.print("[sprack] not written: {s}", .{@tagName(st.kind)}));
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
        var checked: ir.Stmt = undefined;
        if (try w.instParams(a, st)) |c| {
            checked = c;
            st = &checked;
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
        const fam: []const u8 = if (st.get("master") == .atom) w.families.get(st.get("master").atom) orelse "" else "";
        // A model this file does not declare: the plain forms first, then
        // any form at all rather than none.
        for ([_]bool{ false, true }) |loose| {
            if (best != null or (loose and fam.len > 0)) break;
            for (w.g.rules) |*rule| {
                if (rule.kind != st.kind or rule.dir == .read) continue;
                if (rule.family.len > 0 and !std.mem.eql(u8, rule.family, fam) and !loose) {
                    if (why.len == 0 and fam.len > 0) why = try a.print("a model of family '{s}'", .{fam});
                    continue;
                }
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
        // ngspice reads .lib and .include before it joins continuation lines.
        w.nowrap = st.kind == .include or st.kind == .lib or st.kind == .hdl;
        defer w.nowrap = false;
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

    /// A grammar's `invalid` lines, for a netlist crossing into or out of
    /// that dialect: a value it leaves out (or gives as zero) means
    /// something else there.
    fn check(w: *Writer, g: *const Grammar, stmts: []const ir.Stmt) Allocator.Error!void {
        for (stmts) |*st| {
            try w.check(g, st.body);
            for (g.checks) |ck| {
                if (ck.kind != st.kind) continue;
                if (ck.when_slot != grammar.no_slot) {
                    const v = st.at(ck.when_slot);
                    if (v != .atom or !std.mem.eql(u8, v.atom, ck.when_atom)) continue;
                }
                const v = st.at(ck.slot);
                const zero = v == .num and v.num.toFloat() == 0;
                if (v != .none and !(ck.zero and zero)) continue;
                w.report.add(.@"error", .invalid, st.line, "{s}.{s} {s}: {s}", .{
                    @tagName(st.kind), schema.info(st.kind).slots[ck.slot].name, if (zero) "is 0" else "is not given", ck.text,
                });
            }
        }
    }

    /// Apply the grammar's `default` lines: a value a statement from another
    /// dialect leaves to that dialect's default (a SPICE pulse's rise time
    /// is the `.tran` step) is written out where this dialect needs it.
    /// Where the netlist has nothing to take it from, nothing is filled and
    /// the dialect's `invalid` line says why.
    fn fill(w: *Writer, stmts: []ir.Stmt, all: []const ir.Stmt) Allocator.Error![]ir.Stmt {
        var list: ?[]ir.Stmt = null;
        for (stmts, 0..) |*st, i| {
            var cur = st.*;
            var changed = false;
            if (st.body.len > 0) {
                const b = try w.fill(st.body, all);
                if (b.ptr != st.body.ptr) {
                    cur.body = b;
                    changed = true;
                }
            }
            for (w.g.fills) |f| {
                if (f.kind != st.kind or std.mem.eql(u8, w.sourceOf(st), w.g.name)) continue;
                if (f.when_slot != grammar.no_slot) {
                    const c = cur.at(f.when_slot);
                    if (c != .atom or !std.mem.eql(u8, c.atom, f.when_atom)) continue;
                }
                const v = cur.at(f.slot);
                const zero = v == .num and v.num.toFloat() == 0;
                if (v != .none and !(f.zero and zero)) continue;
                // A source dialect with a default of its own means that one.
                if (w.sourceGrammar(st)) |sg| if (sg.checksSlot(f.kind, f.slot)) continue;
                const from = firstValue(all, f.from, f.from_slot) orelse continue;
                try cur.own(w.arena);
                try cur.set(w.arena, f.slot, from);
                changed = true;
                const sl = schema.info(f.kind).slots;
                var em = w.emitter(w.arena, st);
                w.report.add(.warning, .synthesized, st.line, "{s}.{s} {s}: {s} means the {s}.{s} by that, and {s} needs it said; wrote {s}", .{
                    @tagName(f.kind), sl[f.slot].name,       if (zero) "is 0" else "is not given",
                    w.sourceOf(st),   @tagName(f.from),      schema.info(f.from).slots[f.from_slot].name,
                    w.g.name,         try em.describe(from),
                });
            }
            if (changed) {
                if (list == null) list = try w.arena.dupe(ir.Stmt, stmts);
                list.?[i] = cur;
            }
        }
        return list orelse stmts;
    }

    /// Apply the grammar's `move` lines: values this dialect says on another
    /// statement are carried there before anything is written.
    fn applyMoves(w: *Writer, stmts: []const ir.Stmt) Allocator.Error![]const ir.Stmt {
        if (!w.anyMove(stmts)) return stmts;
        const list = try w.arena.dupe(ir.Stmt, stmts);
        // One value may go to several kinds (`nodeset` onto every analysis),
        // so a source is emptied only after every move has seen it.
        var emptied: std.ArrayList(struct { *ir.Stmt, u8 }) = .empty;
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
                if (moved) try emptied.append(w.arena, .{ src, mv.from_slot });
            }
        }
        for (emptied.items) |em| {
            try em[0].own(w.arena);
            try em[0].set(w.arena, em[1], .none);
        }
        return list;
    }
};

/// The canonical name a dialect's `params` table gives a spelling.
fn spellingCanon(table: []const grammar.Spellings, key: []const u8) ?[]const u8 {
    for (table) |e| for (e.spellings) |sp| if (std.ascii.eqlIgnoreCase(sp, key)) return e.canon;
    return null;
}

/// The value of `slot` on the first statement of `kind` that has one.
fn firstValue(stmts: []const ir.Stmt, kind: Kind, slot: u8) ?Value {
    for (stmts) |*s| {
        if (s.kind == kind and s.at(slot) != .none) return s.at(slot);
        if (firstValue(s.body, kind, slot)) |v| return v;
    }
    return null;
}

/// `unique param`: a parameter defined twice in one scope. Each body
/// (subcircuit, library section, branch) is a scope of its own.
fn uniqueParams(stmts: []const ir.Stmt, report: *ir.Report, g: *const Grammar) Allocator.Error!void {
    var seen: ir.CaselessSet = .empty;
    defer seen.deinit(ir.big);
    for (stmts) |*s| {
        if (s.body.len > 0) try uniqueParams(s.body, report, g);
        if (s.kind != .param or s.get("params") != .params) continue;
        for (s.get("params").params) |p| {
            const gop = try seen.getOrPut(ir.big, p.key);
            if (gop.found_existing) report.add(.@"error", .invalid, s.line, "parameter '{s}' is defined twice in one scope; {s}", .{ p.key, g.unique_param });
        }
    }
}

/// `unique master`: a name that both a model (or its bins, `nch.1`) and a
/// subcircuit define, used by an instance.
fn uniqueMasters(stmts: []const ir.Stmt, report: *ir.Report, g: *const Grammar) Allocator.Error!void {
    var models: ir.CaselessSet = .empty;
    defer models.deinit(ir.big);
    var subckts: ir.CaselessSet = .empty;
    defer subckts.deinit(ir.big);
    var told: ir.CaselessSet = .empty;
    defer told.deinit(ir.big);
    try collectMasters(stmts, &models, &subckts);
    try clashes(stmts, &models, &subckts, &told, report, g);
}

fn collectMasters(stmts: []const ir.Stmt, models: *ir.CaselessSet, subckts: *ir.CaselessSet) Allocator.Error!void {
    for (stmts) |*s| {
        const n = s.get("name");
        if (n == .atom) {
            if (s.kind == .subckt) try subckts.put(ir.big, n.atom, {});
            if (s.kind == .model) {
                // `nch.1`, `nch.2`: bins of the model `nch`.
                var name = n.atom;
                if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
                    const tail = name[dot + 1 ..];
                    if (tail.len > 0 and for (tail) |c| {
                        if (!std.ascii.isDigit(c)) break false;
                    } else true) name = name[0..dot];
                }
                try models.put(ir.big, name, {});
            }
        }
        try collectMasters(s.body, models, subckts);
    }
}

fn clashes(stmts: []const ir.Stmt, models: *ir.CaselessSet, subckts: *ir.CaselessSet, told: *ir.CaselessSet, report: *ir.Report, g: *const Grammar) Allocator.Error!void {
    for (stmts) |*s| {
        try clashes(s.body, models, subckts, told, report, g);
        if (schema.info(s.kind).class != .device) continue;
        const m = s.get("master");
        if (m != .atom or !models.contains(m.atom) or !subckts.contains(m.atom)) continue;
        if ((try told.getOrPut(ir.big, m.atom)).found_existing) continue;
        report.add(.@"error", .invalid, s.line, "'{s}' names both a model and a subcircuit, and {s} uses it on {s}; {s}", .{ m.atom, @tagName(s.kind), s.get("name").atom, g.unique_master });
    }
}

/// `nch` of the model card `nch.12`, or null.
fn binBase(st: *const ir.Stmt) ?[]const u8 {
    if (st.kind != .model or st.get("name") != .atom) return null;
    return ir.binBase(st.get("name").atom);
}

/// For a dialect that writes binned models as one block (Spectre), the
/// model cards `nch.1`, `nch.2`, ... of a list become one model `nch`
/// whose body holds them, where the first of them stood.
fn groupBins(arena: Allocator, stmts: []const ir.Stmt) Allocator.Error![]const ir.Stmt {
    var groups: std.StringArrayHashMapUnmanaged(std.ArrayList(ir.Stmt)) = .empty;
    for (stmts) |*s| {
        const base = binBase(s) orelse continue;
        const gop = try groups.getOrPut(arena, base);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, s.*);
    }
    var any_body = false;
    for (stmts) |s| any_body = any_body or s.body.len > 0;
    if (groups.count() == 0 and !any_body) return stmts;
    var out: std.ArrayList(ir.Stmt) = .empty;
    var done: std.StringHashMapUnmanaged(void) = .empty;
    for (stmts) |*s| {
        if (binBase(s)) |base| {
            if ((try done.getOrPut(arena, base)).found_existing) continue;
            var parent = try ir.newStmt(arena, .model, s.line);
            try parent.set(arena, schema.slotIndex(.model, "name").?, .{ .atom = base });
            parent.body = groups.get(base).?.items;
            try out.append(arena, parent);
            continue;
        }
        var copy = s.*;
        if (s.body.len > 0) copy.body = @constCast(try groupBins(arena, s.body));
        try out.append(arena, copy);
    }
    return out.items;
}

fn collectDeclared(arena: Allocator, stmts: []const ir.Stmt, out: *std.StringHashMapUnmanaged(void)) Allocator.Error!void {
    for (stmts) |*s| {
        if ((s.kind == .model or s.kind == .subckt) and s.get("name") == .atom) try out.put(arena, try std.ascii.allocLowerString(arena, s.get("name").atom), {});
        try collectDeclared(arena, s.body, out);
    }
}

/// A switch on or off level named by one of the grammar's `threshold` lines.
fn isLevel(g: *const Grammar, key: []const u8) bool {
    for (g.thresholds) |t| if (std.ascii.eqlIgnoreCase(key, t.on) or std.ascii.eqlIgnoreCase(key, t.off)) return true;
    return false;
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

/// Is there a statement a `convert` line applies to? Copying a large
/// netlist's statement list to convert none of it costs its size again.
fn anyConverted(g: *const Grammar, stmts: []const ir.Stmt) bool {
    for (stmts) |*s| {
        for (g.converts) |cv| if (cv.kind == s.kind) return true;
        if (anyConverted(g, s.body)) return true;
    }
    return false;
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
    try ir.collectFamilies(arena, nl.stmts, &w.families);
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
        var fams: [schema.families.len]bool = if (env) |e| e.families else @splat(false);
        ir.markFamilies(nl.stmts, &fams);
        for (g.needs) |n| {
            if (n.family.len > 0) {
                const fi = for (schema.families, 0..) |f, i| {
                    if (std.mem.eql(u8, f.name, n.family)) break i;
                } else unreachable;
                if (!fams[fi]) continue;
            } else if (!used[@backingInt(n.kind)]) continue;
            for (n.lines) |l| try w.line(l);
        }
    }
    if (!std.mem.eql(u8, nl.dialect, g.name)) {
        if (g.unique_param.len > 0) try uniqueParams(nl.stmts, report, g);
        if (g.unique_master.len > 0) try uniqueMasters(nl.stmts, report, g);
    }
    const filled = if (g.fills.len > 0) try w.fill(nl.stmts, nl.stmts) else nl.stmts;
    if (!std.mem.eql(u8, nl.dialect, g.name)) {
        try w.check(g, filled);
        if (caps) |c| for (c.grammars) |*sg| {
            if (std.mem.eql(u8, sg.name, nl.dialect)) try w.check(sg, filled);
        };
    }
    const gathered = try ir.gatherSteps(arena, filled);
    if (g.canWrite(.step)) w.checkSteps(gathered);
    var stmts = try w.applyMoves(gathered);
    if (g.converts.len > 0 and anyConverted(g, stmts)) {
        const list = try arena.dupe(ir.Stmt, stmts);
        try expr.convert(arena, g, list, true);
        stmts = list;
    }
    if (g.blockOf(.model) != null) stmts = try groupBins(arena, stmts);
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
    const cp = w.copied;
    if (cp.n == 1) {
        report.add(.warning, .caveat, cp.line, "model '{s}' ({s}): {s} and {s} ship different implementations and versions of this model; parameters were copied as written, check them against {s}", .{
            cp.name, cp.family, cp.source, g.name, g.name,
        });
    } else if (cp.n > 1) {
        report.add(.warning, .caveat, cp.line, "model '{s}' ({s}) and {d} more model cards: {s} and {s} ship different implementations and versions of these models; parameters were copied as written, check them against {s}", .{
            cp.name, cp.family, cp.n - 1, cp.source, g.name, g.name,
        });
    }
}
