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
const stats = @import("stats.zig");
const alter = @import("alter.zig");
const cond = @import("cond.zig");
const topology = @import("topology.zig");

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

    const Save = struct { len: usize, used: u64, dropped: u64, tight: bool };

    fn save(e: *const Emit) Save {
        return .{ .len = e.buf.items.len, .used = e.used, .dropped = e.dropped, .tight = e.tight };
    }

    fn restore(e: *Emit, s: Save) void {
        e.buf.shrinkRetainingCapacity(s.len);
        e.used = s.used;
        e.dropped = s.dropped;
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
        return e.given(idx) and !e.isImplied(idx);
    }

    /// `bound`, or holding what this dialect assumes: left out where the
    /// pattern can leave it out, written where a later value needs its
    /// place (`exp(0 1 0 2n)`).
    fn given(e: *const Emit, idx: u8) bool {
        if (idx >= schema.info(e.st.kind).slots.len) return false;
        if (idx < 64 and e.hide & (@as(u64, 1) << @intCast(idx)) != 0) return false;
        if (e.foreign and e.private(idx)) return false;
        return e.present(idx);
    }

    /// The slot holds exactly what this dialect assumes when nothing is
    /// said, so there is no need to say it.
    fn isImplied(e: *const Emit, idx: u8) bool {
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
    /// A function the target lacks, said by what the source means by it
    /// (`means`), one note a rewrite.
    fn meant(e: *Emit, canon_in: []const u8) Allocator.Error![]const u8 {
        const sg = e.sourceGrammar() orelse return canon_in;
        var canon = canon_in;
        for (sg.means) |*m| {
            if (m.kind != null and m.kind.? != e.st.kind) continue;
            // A line for this kind wins over the general one.
            const specific = m.kind != null or for (sg.means) |o| {
                if (o.kind != null and o.kind.? == e.st.kind and std.mem.eql(u8, o.canon, m.canon)) break false;
            } else true;
            if (!specific) continue;
            if (spellingsOf(e.g.functions, m.canon) != null or !expr.uses(canon, m.canon)) continue;
            var n: usize = 0;
            const out = try expr.applyMeans(e.arena, canon, m, &n);
            if (n == 0) continue;
            if (!e.quiet) e.report.add(.info, .oneway, e.st.line, "expression '{s}': {s} has no {s}; written as what {s} means by it, {s}; it reads back in that form", .{
                canon_in, e.g.name, m.canon, sg.name, m.body,
            });
            canon = out;
        }
        return canon;
    }

    fn exprText(e: *Emit, canon_in: []const u8) Allocator.Error![]const u8 {
        var problems: std.ArrayList(expr.Problem) = .empty;
        const canon = if (e.foreign) try e.meant(canon_in) else canon_in;
        const s = try expr.write(e.arena, e.g, canon, e.funcs, e.foreign, &problems);
        // What the source's functions mean differently, as it wrote them,
        // but for those written as what they mean (`means`).
        e.semantics(canon_in, canon);
        if (!e.quiet) for (problems.items) |pb| {
            if (pb.kind == .form) {
                e.report.add(.info, .oneway, e.st.line, "expression '{s}': {s} has no {s}, so the choice is written {s}; it reads back in that form", .{
                    canon, e.g.name, if (std.mem.eql(u8, pb.text, "if")) "?: operator" else "if() function", if (std.mem.eql(u8, pb.text, "if")) "if(c, a, b)" else "c ? a : b",
                });
                continue;
            }
            if (pb.kind == .shadowed) {
                e.report.add(.@"error", .invalid, e.st.line, "expression '{s}': the parameter '{s}' is a variable of {s} under that name, which takes the word for the variable; give the parameter another name", .{ canon, pb.text, e.g.name });
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
    /// `written`: `canon` as it is written, functions the target lacks said
    /// by what they mean; a function gone from it is not a caveat, and
    /// one the meaning brought in is the meaning's, not the source's.
    fn semantics(e: *Emit, canon: []const u8, written: []const u8) void {
        if (e.quiet or !e.foreign) return;
        for ([_]?*const Grammar{ e.g, e.sourceGrammar() }) |og| {
            const g = og orelse continue;
            for (g.differs) |d| {
                if (expr.uses(canon, d.canon) and expr.uses(written, d.canon)) {
                    e.report.add(.warning, .caveat, e.st.line, "expression '{s}': {s} in {s}: {s}", .{ canon, d.canon, g.name, d.text });
                }
            }
        }
    }

    /// The built-in grammar the statement was read with, if any.
    fn sourceGrammar(e: *const Emit) ?*const Grammar {
        const c = e.caps orelse return null;
        for (c.grammars) |*g| if (std.mem.eql(u8, g.name, e.source)) return g;
        return null;
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
                // `bdf=gear`: a spelling that reads back as another value.
                for (em.pairs) |pr| if (std.mem.eql(u8, pr.spelling, sp)) {
                    if (!std.mem.eql(u8, pr.canon, v.atom) and !e.quiet) e.report.add(.info, .oneway, e.st.line, "{s}.{s} = {s} is written as {s}, which reads back as {s}", .{ @tagName(e.st.kind), sl.name, v.atom, sp, pr.canon });
                    break;
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
            .drop => if (e.present(n.slot)) {
                e.mark(n.slot);
                if (n.slot < 64) e.dropped |= @as(u64, 1) << @intCast(n.slot);
            },
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
                if (!e.given(n.slot)) {
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
                for (n.bag, 0..) |b, bi| {
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
                        .pair => {
                            if (!e.bound(b.slot) or e.isUsed(b.slot)) continue;
                            const first = (try e.slotText(b.slot, true)) orelse continue;
                            const v2 = e.val(b.slot2);
                            const ground = v2 == .atom and std.mem.eql(u8, v2.atom, "0");
                            if (e.bound(b.slot2) and !ground) {
                                const second = (try e.slotText(b.slot2, true)) orelse continue;
                                // No blank: the reader takes the vector as one word.
                                const sep = std.mem.trim(u8, e.g.lex.vector_sep, " ");
                                try e.tok(try e.arena.print("{s}=[{s}{s}{s}]", .{ b.key, first, if (sep.len > 0) sep else " ", second }));
                            } else try e.tok(try e.arena.print("{s}={s}", .{ b.key, first }));
                            e.mark(b.slot);
                            if (e.present(b.slot2)) e.mark(b.slot2);
                        },
                        .plain, .quoted, .vector => {
                            if (b.required and !e.bound(b.slot)) {
                                if (e.why.len == 0) e.why = try e.arena.print("a statement without '{s}'", .{e.slot(b.slot).name});
                                return false;
                            }
                            if (!e.bound(b.slot) and b.default.len > 0 and e.foreign) {
                                // What the source's simulator assumes and this one does not.
                                const raw = try e.expandDefault(b.default);
                                const made: Value = if (lexer.parseNumber(e.arena, &e.g.lex, raw)) |num| .{ .num = num } else .{ .expr = raw };
                                // Not a ceiling that would be dropped had the source given it.
                                if (idleCeiling(e.st, b.slot, made)) continue;
                                const text = try e.valueText(made, false);
                                try e.tok(try e.arena.print("{s}={s}", .{ b.key, text }));
                                if (!e.quiet) e.report.add(.warning, .synthesized, e.st.line, "{s}: {s} needs '{s}' to behave as {s} does without it; wrote {s}", .{
                                    @tagName(e.st.kind), e.g.name, e.slot(b.slot).name, e.source, text,
                                });
                                continue;
                            }
                            // An earlier line of this statement wrote the slot.
                            const before = b.also and b.slot < 64 and e.hide & (@as(u64, 1) << @intCast(b.slot)) != 0;
                            if (b.also and e.foreign) {
                                // Only after another key wrote it, for another dialect's statement.
                                if (!before and !(e.bound(b.slot) and e.isUsed(b.slot))) continue;
                            } else if (!e.bound(b.slot) or e.isUsed(b.slot)) {
                                continue;
                            } else if (b.also) {
                                // In its own dialect, only where this key read it: on a
                                // line that says again what an earlier line said.
                                const owned = for (n.bag) |o| {
                                    if (!o.also and o.slot == b.slot and (o.form == .plain or o.form == .quoted or o.form == .vector)) break true;
                                } else false;
                                if (owned) continue;
                            }
                            // Two slots this dialect spells with one key
                            // (`gmin=gmin gmin=gmindc`): one value is said; two are a loss.
                            const twin = for (n.bag[0..bi]) |o| {
                                if (o.form == .plain and !o.also and o.slot != b.slot and e.isUsed(o.slot) and std.mem.eql(u8, o.key, b.key)) break o.slot;
                            } else null;
                            if (twin) |t| {
                                if (!e.val(t).eql(e.val(b.slot)) and !e.quiet) e.report.add(.@"error", .loss, e.st.line, "{s}: {s} = {s} and {s} = {s} are both '{s}' in {s}; the first is written", .{
                                    @tagName(e.st.kind),           e.slot(t).name, try e.describe(e.val(t)), e.slot(b.slot).name,
                                    try e.describe(e.val(b.slot)), b.key,          e.g.name,
                                });
                                e.mark(b.slot);
                                continue;
                            }
                            // `gmin=gmindc` after `gmin=gmin`: read back, the key fills the other slot.
                            for (n.bag[0..bi]) |o| if (o.form == .plain and !o.also and o.slot != b.slot and std.mem.eql(u8, o.key, b.key)) {
                                if (!e.quiet) e.report.add(.info, .oneway, e.st.line, "{s}.{s} is written as '{s}', which reads back as {s}.{s}", .{ @tagName(e.st.kind), e.slot(b.slot).name, b.key, @tagName(e.st.kind), e.slot(o.slot).name });
                                break;
                            };
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
                            e.again += @intFromBool(before);
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

    /// Why the source dialect's parameter changes no result (`inert`), if it does not.
    fn inert(e: *const Emit, key: []const u8) ?[]const u8 {
        const sg = e.sourceGrammar() orelse return null;
        for (sg.inerts) |in| if (in.kind == e.st.kind and std.ascii.eqlIgnoreCase(in.key, key)) return in.text;
        return null;
    }

    fn lossCount(e: *Emit) Allocator.Error!usize {
        var n: usize = e.lost_flags;
        for (0..schema.info(e.st.kind).slots.len) |i| n += @intFromBool(try e.lost(@intCast(i)));
        return n;
    }

    fn reportLosses(e: *Emit) Allocator.Error!void {
        // The target's caveats on writing it, the source's on reading it.
        const src: []const grammar.Caveat = if (e.sourceGrammar()) |sg| sg.caveats else &.{};
        for ([_][]const grammar.Caveat{ e.g.caveats, src }, [_]bool{ false, true }) |cs, read| for (cs) |c| {
            if (c.read == read and e.foreign and c.kind == e.st.kind and e.isUsed(c.slot)) {
                if (c.suffix.len > 0) {
                    const v = e.st.at(c.slot);
                    const t: []const u8 = switch (v) {
                        .str, .atom, .expr => |x| x,
                        else => "",
                    };
                    if (!std.ascii.endsWithIgnoreCase(t, c.suffix)) continue;
                }
                // Text carried verbatim is the source's syntax, not the
                // target's: an error (a measure's spec that ngspice refuses).
                if (e.slot(c.slot).ty == .text) {
                    e.report.add(.@"error", .invalid, e.st.line, "{s}.{s}: {s}; it is {s} text, written as it was", .{ @tagName(e.st.kind), e.slot(c.slot).name, c.text, e.source });
                } else e.report.add(.warning, .caveat, e.st.line, "{s}.{s}: {s}", .{ @tagName(e.st.kind), e.slot(c.slot).name, c.text });
            }
        };
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
                    if (e.inert(p.key)) |why| {
                        e.report.add(.info, .cosmetic, e.st.line, "{s}: '{s}' is not written: {s}", .{ @tagName(e.st.kind), try e.describe(.{ .params = &.{p} }), why });
                        continue;
                    }
                    e.report.add(.@"error", .loss, e.st.line, "{s}: '{s}' has no spelling in {s}", .{
                        @tagName(e.st.kind), try e.describe(.{ .params = &.{p} }), e.g.name,
                    });
                }
                continue;
            }
            const why = e.g.slotAbsentReason(e.st.kind, idx);
            e.report.add(.@"error", .loss, e.st.line, "{s}.{s} = {s} has no spelling in {s}{s}{s}", .{
                @tagName(e.st.kind), e.slot(idx).name, try e.describe(v), e.g.name, if (why != null) ": " else "", why orelse "",
            });
        }
    }
};

const Writer = struct {
    g: *const Grammar,
    arena: Allocator,
    /// What outlives the statement being written (`arena` is the same
    /// unless the netlist is written as a stream).
    perm: Allocator,
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
    /// Writing the ending a `spread` kind adds to each analysis (`sweep
    /// ...`): only its ending rules are tried, and elsewhere only the others.
    ending: bool = false,
    /// The one analysis of the netlist, when it has one: a spread step
    /// around it may be the kind's own line (HSPICE `.temp 0 27`).
    sole: ?*const ir.Stmt = null,
    /// Model name to its family, for rules that depend on it (`bjt[hicum2]`):
    /// the models of this file, then those of the project's other files.
    families: std.StringHashMapUnmanaged([]const u8) = .empty,
    env: ?*const ir.Env = null,
    /// Model cards whose parameters were copied by name: one caveat per
    /// file, naming the first, not one per card (sky130 has thousands).
    copied: struct { n: usize = 0, name: []const u8 = "", family: []const u8 = "", source: []const u8 = "", line: u32 = 0 } = .{},
    /// Written as a stream, the instances that references name (`Refs`).
    refs: ?*Refs = null,
    /// Model parameters not written with a warning (`noparam ... warning`),
    /// per rule: one report per file, naming the first card (sky130 has a
    /// version on every bin). An error is reported card by card.
    refused: std.AutoArrayHashMapUnmanaged(*const grammar.NoParam, struct { n: usize, name: []const u8, line: u32 }) = .empty,
    /// Subcircuits whose inner parameters went to the header (`hoist
    /// param`), and those whose stayed inside because their dialect is not
    /// measured: one entry a file each, naming the first (a PDK has hundreds).
    hoisted: Hoisted = .{},
    unhoisted: Hoisted = .{},
    /// The subcircuits written once for each branch of a conditional block
    /// (`cond.split`), or that would be but for a name: this netlist's and
    /// the environment's, for their instances.
    splits: std.ArrayList(struct { name: []const u8, split: cond.Split }) = .empty,
    /// Why the subcircuit being written is not one of them.
    unsplit: []const u8 = "",
    /// The first instance that gives parameters to a subcircuit of another
    /// file, where the target has no conditional blocks (`foreignNote`).
    foreign_inst: ?struct { line: u32, name: []const u8, master: []const u8 } = null,
    /// Lines no rule understood, written back as they were in their own
    /// dialect: one note a file (`keptNote`).
    kept: struct { n: usize = 0, line: u32 = 0 } = .{},
    /// The nodes the netlist's `.ic` statements set (`capacitorParts`).
    ic_nodes: ir.CaselessSet = .empty,
    /// How many subcircuits the statement being written is inside.
    depth: u32 = 0,
    /// The terminals of the instances of each model (`collectTerminals`).
    terminals: TerminalMap = .empty,

    const Hoisted = struct { n: usize = 0, name: []const u8 = "", source: []const u8 = "", line: u32 = 0 };

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

    fn familyOf(w: *const Writer, model: []const u8) []const u8 {
        if (w.families.get(model)) |f| return f;
        return if (w.env) |e| e.family_of.get(model) orelse "" else "";
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
            // No model cards at all here (CDL): the grammar's reason, not a gap in its table.
            if (w.g.absentReason(.model)) |why| {
                w.report.add(.@"error", .unsupported, st.line, "model '{s}' cannot be written for {s}: {s}. Dialects that define the family: {s}", .{
                    st.get("name").atom, w.g.name, why, if (who.len > 0) who else "none",
                });
                return null;
            }
            w.report.add(.@"error", .unsupported, st.line, "model '{s}': {s}.spgrammar has no spelling for model family '{s}{s}{s}'. Defined by: {s}", .{
                st.get("name").atom,              w.g.name, fam.atom, if (pol.len > 0) " " else "", pol,
                if (who.len > 0) who else "none",
            });
            return null;
        };
        const sp = try w.chooseSpelling(a, st, entry, fam.atom);
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
        const selectors = ps.items.len;
        if (st.get("params") == .params) for (st.get("params").params) |p| {
            // A parameter the level says (`version=107` as `level=107`).
            const said = !same and for (sp.when) |c| {
                if (!c.isNodes() and std.ascii.eqlIgnoreCase(c.key, p.key)) break true;
            } else false;
            if (said) {
                w.report.add(.info, .oneway, st.line, "model '{s}': {s}={s} is said by the {s} {s} spelling and is not written: {s} has no such parameter; it reads back without it", .{
                    st.get("name").atom, p.key, try expr.canonText(a, p.val), w.g.name, try spellingText(a, sp), w.g.name,
                });
                continue;
            }
            try ps.append(a, p);
        };
        if (!same) {
            try w.cardParams(a, st, fam.atom, &ps, selectors);
            // A key given twice: SPICE keeps the last, Xyce rejects the card.
            // But a key that names the model here (`level=103`) stays, and
            // the card's own parameter of that name (PSP's LEVEL) goes.
            var i: usize = ps.items.len;
            while (i > 0) {
                i -= 1;
                const k = ps.items[i].key;
                for (ps.items[i + 1 ..], i + 1..) |later, j| if (std.ascii.eqlIgnoreCase(later.key, k)) {
                    if (i < selectors) {
                        w.report.add(.warning, .loss, st.line, "model '{s}': its own '{s}' is not written: in {s} that parameter names the model", .{ st.get("name").atom, later.key, w.g.name });
                        _ = ps.orderedRemove(j);
                    } else {
                        w.report.add(.warning, .invalid, st.line, "model '{s}': '{s}' is given twice; the last value is kept", .{ st.get("name").atom, k });
                        _ = ps.orderedRemove(i);
                    }
                    break;
                };
            }
            // Parameters this dialect's module for the family refuses.
            for (w.g.noparams) |*np| {
                if (!std.mem.eql(u8, np.family, fam.atom)) continue;
                var j: usize = 0;
                while (j < ps.items.len) : (j += 1) {
                    const p = ps.items[j];
                    if (!std.ascii.eqlIgnoreCase(p.key, np.key)) continue;
                    if (np.value.len > 0 and (p.val != .num or p.val.num.toFloat() != (std.fmt.parseFloat(f64, np.value) catch unreachable))) continue;
                    const name = st.get("name").atom;
                    if (np.err) {
                        w.report.add(.@"error", .loss, st.line, "model '{s}': {s} not written: {s}", .{ name, p.key, np.text });
                    } else {
                        const r = try w.refused.getOrPut(w.perm, np);
                        if (r.found_existing) r.value_ptr.n += 1 else r.value_ptr.* = .{ .n = 1, .name = try w.perm.dupe(u8, name), .line = st.line };
                    }
                    _ = ps.orderedRemove(j);
                    break;
                }
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
            if (w.copied.n == 0) w.copied = .{ .name = try w.perm.dupe(u8, st.get("name").atom), .family = fam.atom, .source = w.sourceOf(st), .line = st.line };
            w.copied.n += 1;
        }
        return out;
    }

    /// The spelling of the family `entry` a card is written with: the first
    /// whose `when` conditions hold, on the card's own parameters or on the
    /// terminals of the instances that name it. A condition that cannot be
    /// told, or instances of more than one count, is said.
    fn chooseSpelling(w: *Writer, a: Allocator, st: *const ir.Stmt, entry: *const grammar.ModelEntry, fam: []const u8) Allocator.Error!grammar.ModelSpelling {
        const name = st.get("name").atom;
        const ps: []const ir.Param = if (st.get("params") == .params) st.get("params").params else &.{};
        const used = w.terminals.get(name);
        var unknown: ?[]const u8 = null;
        var mixed = false;
        for (entry.spellings) |sp| {
            const holds = for (sp.when) |c| {
                const want = std.fmt.parseFloat(f64, c.val) catch unreachable;
                if (c.isNodes()) {
                    const t = used orelse {
                        unknown = unknown orelse "no instance in this file names it";
                        break false;
                    };
                    if (t.min < @as(u32, @intFromFloat(want)) and t.max >= @as(u32, @intFromFloat(want))) mixed = true;
                    if (@as(f64, @floatFromInt(t.min)) < want) break false;
                    continue;
                }
                const v = for (ps) |p| {
                    if (std.ascii.eqlIgnoreCase(p.key, c.key)) break p.val;
                } else {
                    unknown = unknown orelse try a.print("it gives no {s}", .{c.key});
                    break false;
                };
                if (v != .num) {
                    unknown = unknown orelse try a.print("its {s} is not a number", .{c.key});
                    break false;
                }
                if (v.num.toFloat() != want) {
                    unknown = unknown orelse try a.print("{s}={s} is none of the values the spellings name", .{ c.key, try expr.canonText(a, v) });
                    break false;
                }
            } else true;
            if (!holds) continue;
            if (std.mem.eql(u8, w.sourceOf(st), w.g.name)) return sp;
            if (mixed) w.report.add(.warning, .ambiguous, st.line, "model '{s}' ({s}): instances with {d} and with {d} terminals name it, and {s} has a model of its own for each; it is written as {s}", .{
                name, fam, used.?.min, used.?.max, w.g.name, try spellingText(a, sp),
            }) else if (unknown) |why| if (sp.when.len == 0) w.report.add(.warning, .caveat, st.line, "model '{s}' ({s}): {s} writes another model by its conditions, and {s}; it is written as {s}", .{
                name, fam, w.g.name, why, try spellingText(a, sp),
            });
            return sp;
        }
        return entry.spellings[0];
    }

    /// The parameters of a model card, `ps` from `own` on, against the
    /// `modelparams` tables of the two dialects for the family, when both
    /// have one: each gets the target's spelling and number. One the
    /// source's model does not take by the name written is not written, and
    /// neither are those the target has one parameter for when they differ.
    fn cardParams(w: *Writer, a: Allocator, st: *const ir.Stmt, family: []const u8, ps: *std.ArrayList(ir.Param), own: usize) Allocator.Error!void {
        const to = w.g.modelParamsOf(family) orelse return;
        const only = w.g.modelParamsOnly(family);
        const sg = w.sourceGrammar(st) orelse return;
        // A card the target refuses by one value (a diode's level=3) is
        // another model there: its other names are not checked against
        // this one's.
        const other_model = for (w.g.noparams) |np| {
            if (!np.err or np.value.len == 0 or !std.mem.eql(u8, np.family, family)) continue;
            const want = std.fmt.parseFloat(f64, np.value) catch continue;
            for (ps.items[own..]) |p| {
                if (std.ascii.eqlIgnoreCase(p.key, np.key) and p.val == .num and p.val.num.toFloat() == want) break;
            } else continue;
            break true;
        } else false;
        if (other_model) return;
        // A source with no table: every name as it is written, against a
        // table that lists all the target's card takes.
        const from = sg.modelParamsOf(family) orelse if (only) &.{} else return;
        const name = st.get("name").atom;
        var em = w.emitter(a, st);
        // Canonical names and values; `wrote` is the key each was written by.
        // `as_is`: the source's table does not list it, so it is copied.
        const Canon = struct { p: ir.Param, wrote: []const u8, as_is: bool = false, done: bool = false };
        var cs: std.ArrayList(Canon) = .empty;
        for (ps.items[own..]) |p| {
            var halves: std.ArrayList(ir.Param) = .empty;
            var taken = false;
            for (from) |*e| {
                for (e.spellings) |sp| {
                    if (std.ascii.eqlIgnoreCase(sp, p.key)) break;
                } else continue;
                taken = true;
                // A number at an exponent a scale suffix can spell (500n).
                const half: Value = if (!e.halved) p.val else if (p.val == .num) try expr.arith(a, .mul, p.val, .{ .num = .init("5", -1) }) else try expr.halve(a, p.val);
                const c: ir.Param = .{ .key = e.canon, .val = half };
                try cs.append(a, .{ .p = c, .wrote = if (e.halved) e.canon else p.key });
                if (e.halved) try halves.append(a, c);
            }
            if (halves.items.len > 0) w.report.add(.info, .rename, st.line, "model '{s}': {s} of {s} is {s}, each half its value", .{
                name, try em.describe(.{ .params = &.{p} }), sg.name, try em.describe(.{ .params = halves.items }),
            });
            if (taken) continue;
            if (spellingsOf(from, p.key)) |e| {
                w.report.add(.warning, .loss, st.line, "model '{s}': {s} not written: the {s} model of {s} does not take it; that parameter is '{s}' there", .{ name, p.key, family, sg.name, e.spellings[0] });
                continue;
            }
            try cs.append(a, .{ .p = p, .wrote = p.key, .as_is = true });
        }
        ps.shrinkRetainingCapacity(own);
        for (cs.items, 0..) |*c, i| {
            if (c.done) continue;
            const e = (if (c.as_is) null else spellingsOf(to, c.p.key)) orelse {
                // A name the target's card does not take: not written. One
                // a `noparam` line names is left to that line.
                const named = for (w.g.noparams) |np| {
                    if (std.mem.eql(u8, np.family, family) and (std.ascii.eqlIgnoreCase(np.key, c.p.key) or std.ascii.eqlIgnoreCase(np.key, c.wrote))) break true;
                } else false;
                // A card's level picks the simulator's model, in every dialect.
                const level = std.ascii.eqlIgnoreCase(c.p.key, "level");
                if (only and !named and !level and (if (c.as_is) spellingCanon(to, c.p.key) == null else true)) {
                    var takes_list: std.ArrayList(u8) = .empty;
                    for (to, 0..) |t, k| {
                        const dup = for (to[0..k]) |u| {
                            if (std.ascii.eqlIgnoreCase(u.spellings[0], t.spellings[0])) break true;
                        } else false;
                        if (!dup) try takes_list.print(a, "{s}{s}", .{ if (takes_list.items.len > 0) ", " else "", t.spellings[0] });
                    }
                    w.report.add(.@"error", .loss, st.line, "model '{s}': {s} not written: the {s} card of {s} takes no such parameter; it takes {s}", .{
                        name, try em.describe(.{ .params = &.{.{ .key = c.wrote, .val = c.p.val }} }), family, w.g.name, takes_list.items,
                    });
                    continue;
                }
                // Under the name it was written by: the canonical one may
                // mean something else to a target that does not list it,
                // unless a `noparam` line of the target names it.
                const refused = for (w.g.noparams) |np| {
                    if (std.mem.eql(u8, np.family, family) and std.ascii.eqlIgnoreCase(np.key, c.p.key)) break true;
                } else false;
                try ps.append(a, .{ .key = if (refused) c.p.key else c.wrote, .val = c.p.val });
                continue;
            };
            if (!e.halved) {
                if (!std.ascii.eqlIgnoreCase(e.spellings[0], c.wrote)) w.report.add(.info, .rename, st.line, "model '{s}': the parameter '{s}' is spelled '{s}' in {s}", .{ name, c.wrote, e.spellings[0], w.g.name });
                try ps.append(a, .{ .key = if (std.ascii.eqlIgnoreCase(e.spellings[0], c.wrote)) c.wrote else e.spellings[0], .val = c.p.val });
                continue;
            }
            // One parameter here for every canonical name of this spelling:
            // they must agree, one left out being 0.
            var value: ?Value = null;
            var same = true;
            var names: std.ArrayList(u8) = .empty;
            var shown: std.ArrayList(ir.Param) = .empty;
            for (to) |*t| {
                if (!t.halved or !std.mem.eql(u8, t.spellings[0], e.spellings[0])) continue;
                try names.print(a, "{s}{s}", .{ if (names.items.len > 0) " and " else "", t.canon });
                var v: Value = .{ .num = .init("0", 0) };
                // The last of a name, as the simulators take a card.
                for (cs.items[i..]) |*o| if (!o.as_is and std.ascii.eqlIgnoreCase(o.p.key, t.canon)) {
                    v = o.p.val;
                    o.done = true;
                    try shown.append(a, .{ .key = o.wrote, .val = v });
                };
                if (value) |first| same = same and v.eql(first) else value = v;
            }
            const was = try em.describe(.{ .params = shown.items });
            if (same) {
                const twice: ir.Param = .{ .key = e.spellings[0], .val = try expr.arith(a, .mul, value.?, .{ .num = .init("2", 0) }) };
                const now = try em.describe(.{ .params = &.{twice} });
                if (!std.mem.eql(u8, was, now)) w.report.add(.info, .rename, st.line, "model '{s}': {s} is written {s}, twice the value: {s} has the one parameter for {s}", .{ name, was, now, w.g.name, names.items });
                try ps.append(a, twice);
                continue;
            }
            var why: std.ArrayList(u8) = .empty;
            if (w.g.computesText(family, e.canon)) |t| try why.print(a, ": {s} computes {s}", .{ w.g.name, t });
            if (sg.computesText(family, e.canon)) |t| try why.print(a, "; {s} computes {s}", .{ sg.name, t });
            w.report.add(.@"error", .loss, st.line, "model '{s}': {s} not written: {s} has the one parameter '{s}' for {s}, and they are not equal here (one left out is 0){s}", .{
                name, was, w.g.name, e.spellings[0], names.items, why.items,
            });
        }
    }

    /// After the last statement: an instance whose subcircuit may be
    /// written once for each branch in its own file, said once.
    fn foreignNote(w: *Writer) void {
        const x = w.foreign_inst orelse return;
        w.report.add(.warning, .ambiguous, x.line, "instance '{s}' gives parameters to subcircuit '{s}', which is not in this file; {s} has no conditional blocks, so a subcircuit that holds one is written once for each branch, and which one this instance names can only be told with the library: translate the two together (`sprack project`, or a PDK)", .{
            x.name, x.master, w.g.name,
        });
    }

    /// After the last statement: the lines written back as text, said once.
    fn keptNote(w: *Writer) void {
        if (w.kept.n == 0) return;
        w.report.add(.info, .oneway, w.kept.line, "{d} statement{s} no {s} rule understood {s} written back as {s}, from this line on; {s} itself may refuse {s}, and they read back as text (`sprack audit` counts them)", .{
            w.kept.n, if (w.kept.n == 1) "" else "s", w.g.name, if (w.kept.n == 1) "is" else "are", if (w.kept.n == 1) "it was" else "they were", w.g.name, if (w.kept.n == 1) "it" else "them",
        });
    }

    /// After the last statement: what `refused` gathered, one entry a rule.
    /// A loss, so that the cards reading back without the parameter is explained.
    fn refusals(w: *Writer) void {
        for (w.refused.keys(), w.refused.values()) |np, r| {
            if (r.n == 1) {
                w.report.add(.warning, .loss, r.line, "model '{s}': {s} not written: {s}", .{ r.name, np.key, np.text });
            } else {
                w.report.add(.warning, .loss, r.line, "model '{s}' and {d} more card{s} in this file: {s} not written: {s}", .{ r.name, r.n - 1, if (r.n == 2) "" else "s", np.key, np.text });
            }
        }
        var buf: [48]u8 = undefined;
        const hs = w.hoisted;
        if (hs.n > 0) w.report.add(.info, .oneway, hs.line, "subckt '{s}'{s}: the parameters defined inside are written on the header, which reads back there; {s} gives an instance's value to that instance alone only for a parameter of the header", .{
            hs.name, if (hs.n > 1) std.fmt.bufPrint(&buf, " and {d} more in this file", .{hs.n - 1}) catch unreachable else "", w.g.name,
        });
        const us = w.unhoisted;
        if (us.n > 0) w.report.add(.warning, .ambiguous, us.line, "subckt '{s}'{s}: the parameters defined inside are written as they were; {s} gives an instance's value to that instance alone only for a parameter of the header, and what {s} does with one defined inside is not measured", .{
            us.name, if (us.n > 1) std.fmt.bufPrint(&buf, " and {d} more in this file", .{us.n - 1}) catch unreachable else "", w.g.name, us.source,
        });
    }

    /// A parameter statement of a dialect the grammar's `hoist param` lists.
    fn hoists(w: *const Writer, st: *const ir.Stmt) bool {
        if (st.kind != .param or st.get("params") != .params) return false;
        for (w.g.hoist_param) |d| {
            if (std.mem.eql(u8, d, w.sourceOf(st))) return true;
        }
        return false;
    }

    /// `hoist param`: subcircuit `st` with the parameter statements of its
    /// body on its header, the only place an instance sets one for itself
    /// alone here. A later value of a name replaces an earlier one, the
    /// header's too, as the listed dialects take it (docs/verification.md
    /// 4.14). Null: nothing moves.
    fn hoistParams(w: *Writer, st: *const ir.Stmt) Allocator.Error!?ir.Stmt {
        if (st.kind != .subckt or w.g.hoist_param.len == 0) return null;
        var any = false;
        var unmeasured: ?[]const u8 = null;
        for (st.body) |*c| {
            if (w.hoists(c)) any = true else if (c.kind == .param and !std.mem.eql(u8, w.sourceOf(c), w.g.name)) unmeasured = w.sourceOf(c);
        }
        const h = if (any) &w.hoisted else &w.unhoisted;
        if (any or unmeasured != null) {
            if (h.n == 0) h.* = .{ .name = if (st.get("name") == .atom) try w.perm.dupe(u8, st.get("name").atom) else "", .source = unmeasured orelse "", .line = st.line };
            h.n += 1;
        }
        if (!any) return null;
        const a = w.arena;
        const pi = schema.slotIndex(.subckt, "params").?;
        var ps: std.ArrayList(ir.Param) = .empty;
        if (st.at(pi) == .params) try ps.appendSlice(a, st.at(pi).params);
        var body: std.ArrayList(ir.Stmt) = try .initCapacity(a, st.body.len);
        for (st.body) |*c| {
            if (!w.hoists(c)) {
                body.appendAssumeCapacity(c.*);
                continue;
            }
            next: for (c.get("params").params) |p| {
                for (ps.items) |*q| if (std.ascii.eqlIgnoreCase(q.key, p.key)) {
                    q.val = p.val;
                    continue :next;
                };
                try ps.append(a, p);
            }
            if (c.tail.len > 0) body.appendAssumeCapacity(.{ .kind = .comment, .raw = c.tail, .line = c.line });
        }
        var out = st.*;
        try out.own(a);
        try out.set(a, pi, .{ .params = ps.items });
        out.body = body.items;
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
        if (std.mem.eql(u8, w.sourceOf(st), w.g.name)) return null;
        const idx = schema.slotIndex(st.kind, "params") orelse return null;
        const v = st.at(idx);
        if (v != .params) return null;
        const from = if (w.sourceGrammar(st)) |sg| sg.paramsOf(st.kind) else null;
        // Without a table here, the source's own spellings still go back to canonical names.
        const open: []const grammar.Spellings = &.{.{ .canon = "...", .spellings = &.{"..."} }};
        const table = w.g.paramsOf(st.kind) orelse if (from != null) open else return null;
        var em = w.emitter(a, st);
        var out: std.ArrayList(ir.Param) = .empty;
        // The spellings parameters of other names were written under.
        var renamed: std.ArrayList([]const u8) = .empty;
        var changed = false;
        for (v.params) |p| {
            const canon = if (from) |t| spellingCanon(t, p.key) orelse p.key else p.key;
            const entry = for (table) |*e| {
                if (std.ascii.eqlIgnoreCase(e.canon, canon)) break e;
            } else {
                // `same ...`: the table renames; what it does not list passes as written.
                // In the canonical spelling, when the source's table had its own.
                if (grammar.paramsOpen(table)) {
                    try out.append(a, .{ .key = if (std.ascii.eqlIgnoreCase(canon, p.key)) p.key else canon, .val = p.val });
                    if (!std.ascii.eqlIgnoreCase(canon, p.key)) {
                        w.report.add(.info, .rename, st.line, "{s}: the instance parameter '{s}' is spelled '{s}' in {s}", .{ @tagName(st.kind), p.key, canon, w.g.name });
                        changed = true;
                    }
                    continue;
                }
                const shown = if (p.val == .none) p.key else try a.print("{s}={s}", .{ p.key, try em.describe(p.val) });
                if (em.inert(p.key)) |why| {
                    // A loss all the same: the statement reads back without it.
                    w.report.add(.info, .loss, st.line, "{s}: '{s}' is not written: {s}", .{ @tagName(st.kind), shown, why });
                } else w.report.add(.@"error", .loss, st.line, "{s}: '{s}' has no spelling in {s}, whose {s} takes no such instance parameter", .{
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
            const same = for (entry.spellings) |sp| {
                if (std.ascii.eqlIgnoreCase(sp, p.key)) break true;
            } else false;
            const key = if (same) p.key else entry.spellings[0];
            // Two parameters this dialect says with one name (a capacitor's
            // `scale` and `m` in Xyce): their product has no place here.
            const clash = if (same) for (renamed.items) |k| {
                if (std.ascii.eqlIgnoreCase(k, key)) break true;
            } else false else for (out.items) |o| {
                if (std.ascii.eqlIgnoreCase(o.key, key)) break true;
            } else false;
            if (clash) {
                w.report.add(.@"error", .loss, st.line, "{s}: '{s}={s}' is '{s}' in {s}, which the instance gives as well", .{ @tagName(st.kind), p.key, try em.describe(p.val), key, w.g.name });
                changed = true;
                continue;
            }
            if (!same) {
                w.report.add(.info, .rename, st.line, "{s}: the instance parameter '{s}' is spelled '{s}' in {s}", .{ @tagName(st.kind), p.key, key, w.g.name });
                try renamed.append(a, key);
                changed = true;
            }
            try out.append(a, .{ .key = key, .val = p.val });
        }
        if (!changed) return null;
        var copy = st.*;
        try copy.own(a);
        try copy.set(a, idx, if (out.items.len > 0) .{ .params = out.items } else .none);
        return copy;
    }

    /// A capacitor's `ic=` or `q=` where the target's capacitor takes
    /// neither and other devices of the target say it, as measured in
    /// ngspice 45 and VACASK (docs/verification.md 4.16):
    ///  - `ic`: the capacitor to a node of its own, `<name>__ic`, and from
    ///    there to its second node a DC source of the initial voltage. With
    ///    UIC the capacitor starts at 0 and the pair at `ic`; at an
    ///    operating point and in AC the source is the short it adds.
    ///  - `q`: a behavioural source whose current is `ddt` of the charge,
    ///    times `m`.
    /// False: the capacitor is written as it is.
    fn capacitorParts(w: *Writer, a: Allocator, st: *const ir.Stmt) Error!bool {
        const sg = w.sourceGrammar(st) orelse readIn(w.source, st);
        const parts = capParts(w.g, sg, st);
        if (!parts.any()) return false;
        const from = if (sg) |s| s.paramsOf(.capacitor) else null;
        const name = st.get("name").atom;
        var em = w.emitter(a, st);
        var rest: std.ArrayList(ir.Param) = .empty;
        var m: ?Value = null;
        for (st.get("params").params) |p| {
            const canon = if (from) |t| spellingCanon(t, p.key) orelse p.key else p.key;
            if (parts.q != null and std.ascii.eqlIgnoreCase(canon, "q")) continue;
            if (parts.ic != null and std.ascii.eqlIgnoreCase(canon, "ic")) continue;
            if (parts.q != null and std.ascii.eqlIgnoreCase(canon, "m")) {
                m = p.val;
                continue;
            }
            try rest.append(a, p);
        }
        if (parts.q) |q| {
            // Whatever else the capacitor gives has no place on the source.
            if (st.get("c") != .none) w.report.add(.@"error", .loss, st.line, "capacitor '{s}': 'c={s}' has no place on the behavioural source a capacitor given by its charge is written as for {s}", .{ name, try em.describe(st.get("c")), w.g.name });
            if (st.get("master") != .none) w.report.add(.@"error", .loss, st.line, "capacitor '{s}': the model '{s}' has no place on the behavioural source a capacitor given by its charge is written as for {s}", .{ name, try em.describe(st.get("master")), w.g.name });
            for (rest.items) |p| {
                const shown = if (p.val == .none) p.key else try a.print("{s}={s}", .{ p.key, try em.describe(p.val) });
                w.report.add(.@"error", .loss, st.line, "capacitor '{s}': '{s}' has no place on the behavioural source a capacitor given by its charge is written as for {s}", .{ name, shown, w.g.name });
            }
            const charge = try expr.canonText(a, q);
            const current = if (m) |mv| blk: {
                const mt = try expr.canonText(a, mv);
                break :blk if (mv == .expr) try a.print("({s})*ddt({s})", .{ mt, charge }) else try a.print("{s}*ddt({s})", .{ mt, charge });
            } else try a.print("ddt({s})", .{charge});
            var b = try ir.newStmt(a, .bsource, st.line);
            b.dialect = st.dialect;
            b.tail = st.tail;
            try b.set(a, schema.slotIndex(.bsource, "name").?, st.get("name"));
            try b.set(a, schema.slotIndex(.bsource, "pos").?, st.get("pos"));
            try b.set(a, schema.slotIndex(.bsource, "neg").?, st.get("neg"));
            try b.set(a, schema.slotIndex(.bsource, "i").?, .{ .expr = current });
            w.report.add(.info, .oneway, st.line, "capacitor '{s}': {s}'s capacitor takes no charge (q=); it is written as a behavioural source whose current is {s}, which reads back as that source", .{ name, w.g.name, current });
            try w.leaf(a, &b);
            return true;
        }
        const ic = parts.ic.?;
        const pos, const neg = .{ st.get("pos"), st.get("neg") };
        // ngspice lets the capacitor's ic win over an .ic on one of its
        // nodes; the source in series adds the two.
        for ([_]Value{ pos, neg }) |n| {
            if (n != .atom) continue;
            const hit = if (w.depth == 0) w.ic_nodes.contains(n.atom) else blk: {
                var it = w.ic_nodes.keyIterator();
                while (it.next()) |k| {
                    const dot = std.mem.lastIndexOfScalar(u8, k.*, '.') orelse continue;
                    if (std.ascii.eqlIgnoreCase(k.*[dot + 1 ..], n.atom)) break :blk true;
                }
                break :blk false;
            };
            if (hit) w.report.add(.@"error", .invalid, st.line, "capacitor '{s}': ic={s}, and an .ic sets node {s} too; {s} takes the capacitor's, and the source in series that says it for {s} adds the two", .{
                name, try em.describe(ic), n.atom, w.sourceOf(st), w.g.name,
            });
        }
        const node: Value = .{ .atom = try a.print("{s}__ic", .{name}) };
        var cap = st.*;
        try cap.own(a);
        try cap.set(a, schema.slotIndex(.capacitor, "neg").?, node);
        try cap.set(a, schema.slotIndex(.capacitor, "params").?, if (rest.items.len > 0) .{ .params = rest.items } else .none);
        var v = try ir.newStmt(a, .vsource, st.line);
        v.dialect = st.dialect;
        try v.set(a, schema.slotIndex(.vsource, "name").?, .{ .atom = try a.print("V{s}__ic", .{name}) });
        try v.set(a, schema.slotIndex(.vsource, "pos").?, node);
        try v.set(a, schema.slotIndex(.vsource, "neg").?, neg);
        try v.set(a, schema.slotIndex(.vsource, "dc").?, ic);
        w.report.add(.info, .oneway, st.line, "capacitor '{s}': {s}'s capacitor takes no initial voltage (ic={s}); it is written to node {s}, with a DC source of {s} from there to {s}, which reads back as the two", .{
            name, w.g.name, try em.describe(ic), node.atom, try em.describe(ic), try em.describe(neg),
        });
        try w.leaf(a, &cap);
        try w.leaf(a, &v);
        return true;
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

    /// `also`: what more there is to the reason, as the end of its sentence.
    /// The statements a block holds, at any depth, comments aside.
    fn bodyCount(stmts: []const ir.Stmt) usize {
        var n: usize = 0;
        for (stmts) |*s| {
            if (s.kind != .comment) n += 1;
            n += bodyCount(s.body);
        }
        return n;
    }

    /// The statements of a block not written, each as a comment.
    fn bodyComments(w: *Writer, a: Allocator, stmts: []const ir.Stmt) Error!void {
        for (stmts) |*s| {
            if (s.kind == .comment) continue;
            if (s.kind == .@"opaque") {
                var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, s.raw, "\n"), '\n');
                while (it.next()) |l| try w.comment(try a.print("[sprack] not written: {s}", .{l}));
            } else {
                const name = s.get("name");
                try w.comment(try a.print("[sprack] not written: {s}{s}{s}", .{ @tagName(s.kind), if (name == .atom) " " else "", if (name == .atom) name.atom else "" }));
            }
            try w.bodyComments(a, s.body);
        }
    }

    fn unsupported(w: *Writer, a: Allocator, st: *const ir.Stmt, also: []const u8) Error!void {
        const held = bodyCount(st.body);
        const after = if (held == 0) "" else try a.print(". The {d} statement{s} it holds {s} not written either, and {s} in the output as comments", .{
            held, if (held == 1) "" else "s", if (held == 1) "is" else "are", if (held == 1) "is" else "are",
        });
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
        w.report.add(.@"error", .unsupported, st.line, "{s} '{s}' cannot be written for {s}: {s}{s}. Dialects that define it: {s}{s}", .{
            what, @tagName(st.kind), w.g.name, reason, also, if (who.len > 0) who else "none", after,
        });
        try w.comment(try a.print("[sprack] not written: {s} '{s}' has no {s} form", .{ what, @tagName(st.kind), w.g.name }));
        try w.bodyComments(a, st.body);
    }

    fn stmt(w: *Writer, st: *const ir.Stmt) Error!void {
        if (st.kind == .model and st.body.len > 0) return w.binnedModel(st);
        if (try w.hoistParams(st)) |h| return w.stmt(&h);
        // A conditional block where there are none, but a choice inside an
        // expression: the same statements in every branch are written once,
        // their values as choices (`cond.zig`).
        // What is left in a subcircuit, when its own parameters decide the
        // conditions: the subcircuit once for each branch (`split`).
        const outer = w.unsplit;
        defer w.unsplit = outer;
        const outer_depth = w.depth;
        defer w.depth = outer_depth;
        if (st.kind == .subckt) {
            w.unsplit = "";
            w.depth += 1;
        }
        if (st.kind == .subckt and !w.g.canWrite(.cond_if)) switch (try cond.split(w.arena, st, expr.choiceForm(w.g), &w.declared)) {
            .none => {},
            .refused => |why| w.unsplit = why,
            .clash => |name| w.unsplit = try std.fmt.allocPrint(w.arena, "'{s}', the name one of them would take, is already declared", .{name}),
            .variants => |v| return w.split(st, &v),
        };
        if (st.kind == .cond_if and !w.g.canWrite(.cond_if)) {
            var also: []const u8 = "";
            if (expr.choiceForm(w.g)) |form| switch (try cond.merge(w.arena, st, form)) {
                .merged => |stmts| {
                    w.report.add(.info, .oneway, st.line, "cond_if: {s} has no conditional blocks; every branch holds the same statements, so they are written once, each value that differs as a choice between the branches' values by their conditions; it reads back as those statements, not as a block", .{w.g.name});
                    for (stmts) |*s| try w.stmt(s);
                    return;
                },
                .refused => |why| also = try std.fmt.allocPrint(w.arena, ", and this block is not the same statements with other values in every branch: {s}", .{why}),
            };
            if (w.unsplit.len > 0) also = try std.fmt.allocPrint(w.arena, "{s}; nor is its subcircuit written once for each branch: {s}", .{ also, w.unsplit });
            return w.unsupported(w.arena, st, also);
        }
        // A block kind this dialect has only a rule for: the rule says the
        // header, the body follows it (Xyce `.sampling` ahead of its
        // analyses), or the rule is added to each statement of the body
        // (`spread`, HSPICE `monte=`).
        if (st.body.len > 0 and w.g.blockOf(st.kind) == null and w.g.canWrite(st.kind)) {
            if (w.g.isSpread(st.kind) and !(st == w.sole and try w.fits(st))) return w.spread(st);
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

    /// The subcircuit `st` once for each of `v`, a comment above each
    /// saying where it is the one.
    fn split(w: *Writer, st: *const ir.Stmt, v: *const cond.Variants) Error!void {
        const name = st.get("name").atom;
        var listed: std.ArrayList(u8) = .empty;
        for (v.list, 0..) |x, i| try listed.print(w.arena, "{s}'{s}' where {s}", .{ if (i > 0) ", " else "", x.name, x.cond });
        w.report.add(.info, .oneway, v.line, "subckt '{s}': {s} has no conditional blocks, so the subcircuit is written once for each branch of the {s} {d}: {s}; an instance is written with the one its parameters select; it reads back as {d} subcircuits", .{
            name, w.g.name, if (v.more) "blocks from line" else "block at line", v.line, listed.items, v.list.len,
        });
        // A statement outside the blocks is in every one of them: what it
        // reports is said once.
        var said: std.StringHashMapUnmanaged(void) = .empty;
        var new: std.ArrayList([]const u8) = .empty;
        for (v.list) |x| {
            try w.comment(try std.fmt.allocPrint(w.arena, "[sprack] '{s}' where {s}", .{ name, x.cond }));
            var one = st.*;
            try one.own(w.arena);
            try one.set(w.arena, schema.slotIndex(.subckt, "name").?, .{ .atom = x.name });
            one.body = x.body;
            const from = w.report.items.items.len;
            try w.stmt(&one);
            var kept = from;
            for (w.report.items.items[from..]) |d| {
                const key = try std.fmt.allocPrint(w.arena, "{d} {s} {s}", .{ d.line, @tagName(d.code), d.msg });
                if (said.contains(key)) continue;
                try new.append(w.arena, key);
                w.report.items.items[kept] = d;
                kept += 1;
            }
            w.report.items.shrinkRetainingCapacity(kept);
            for (new.items) |key| try said.put(w.arena, key, {});
            new.clearRetainingCapacity();
        }
    }

    /// The first instance that gives parameters to a subcircuit no file
    /// read declares.
    fn foreignInstance(w: *Writer, stmts: []const ir.Stmt) Allocator.Error!?*const ir.Stmt {
        for (stmts) |*s| {
            if (s.kind == .instance and s.get("master") == .atom and s.get("params") == .params and s.get("name") == .atom) {
                if (!w.declared.contains(try std.ascii.allocLowerString(w.arena, s.get("master").atom))) return s;
            }
            if (try w.foreignInstance(s.body)) |x| return x;
        }
        return null;
    }

    /// Notes every subcircuit of `stmts` that is written as several.
    fn noteSplits(w: *Writer, stmts: []const ir.Stmt) Allocator.Error!void {
        for (stmts) |*s| {
            if (s.kind == .subckt) {
                const sp = try cond.split(w.perm, s, expr.choiceForm(w.g), &w.declared);
                if (sp == .variants or sp == .clash) try w.splits.append(w.perm, .{ .name = s.get("name").atom, .split = sp });
            }
            try w.noteSplits(s.body);
        }
    }

    /// The subcircuit name an instance is written with: of a subcircuit
    /// written as several, the one its parameters select. Null, reported,
    /// when that cannot be told.
    fn variantOf(w: *Writer, a: Allocator, st: *const ir.Stmt) Allocator.Error!?[]const u8 {
        const master = st.get("master").atom;
        var name: ?[]const u8 = null;
        for (w.splits.items) |*sp| {
            if (!std.ascii.eqlIgnoreCase(sp.name, master)) continue;
            var stop: []const u8 = "";
            const pick = switch (sp.split) {
                .variants => |*v| try cond.choose(a, v, if (st.get("params") == .params) st.get("params").params else &.{}, &stop) orelse {
                    w.report.add(.@"error", .unsupported, st.line, "instance '{s}': subcircuit '{s}' is written once for each branch of its conditional block, and which of them this instance is depends on parameter '{s}', which is not a number here", .{ st.get("name").atom, master, stop });
                    return null;
                },
                .clash => |taken| {
                    w.report.add(.@"error", .unsupported, st.line, "instance '{s}': subcircuit '{s}' holds a conditional block, which {s} has not, and is not written once for each branch: '{s}', the name one of them would take, is already declared", .{ st.get("name").atom, master, w.g.name, taken });
                    return null;
                },
                else => unreachable,
            };
            if (name) |other| if (!std.mem.eql(u8, other, pick)) {
                w.report.add(.@"error", .unsupported, st.line, "instance '{s}': subcircuit '{s}' is declared more than once, and this instance is '{s}' by one declaration, '{s}' by another", .{ st.get("name").atom, master, other, pick });
                return null;
            };
            name = pick;
        }
        return name orelse master;
    }

    /// Where a step is one line that sweeps every analysis of the netlist, a
    /// step that sweeps only some of them cannot be said.
    fn checkSteps(w: *Writer, stmts: []const ir.Stmt) void {
        for (w.g.blocks) |b| if (b.kind == .step) return;
        var step: ?*const ir.Stmt = null;
        var outside = false;
        for (stmts) |*s| {
            if (s.kind == .alter) continue;
            if (s.kind != .step) {
                outside = outside or schema.info(s.kind).class == .analysis;
            } else if (step == null) step = s else outside = true;
        }
        const st = step orelse return;
        // HSPICE's .TEMP list in a deck with no analysis: nothing to repeat.
        if (st.body.len == 0 and !std.mem.eql(u8, w.sourceOf(st), w.g.name))
            w.report.add(.@"error", .invalid, st.line, "step: the netlist has no analysis for the {s} sweep to repeat", .{w.g.name});
        if (outside and !w.g.isSpread(.step)) w.report.add(.@"error", .invalid, st.line, "step: a {s} sweep applies to every analysis of the netlist; this one leaves some out", .{w.g.name});
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
        w.ending = true;
        const captured = w.capture(&head);
        w.ending = false;
        const suffix = std.mem.trim(u8, try captured, " \n");
        for (st.body) |*child| {
            if (schema.info(child.kind).class != .analysis) {
                try w.stmt(child);
                continue;
            }
            const text = std.mem.trimEnd(u8, try w.capture(child), "\n");
            try w.out.print("{s} {s}\n", .{ text, suffix });
        }
    }

    /// Does one of the kind's own rules (not an ending) say `st` whole?
    fn fits(w: *Writer, st: *const ir.Stmt) Error!bool {
        var head = st.*;
        head.body = &.{};
        for (w.g.rules) |*rule| {
            if (rule.kind != st.kind or rule.dir == .read or w.g.isEnding(rule)) continue;
            var e = w.emitter(w.arena, &head);
            e.quiet = true;
            if (try e.seq(rule.pat) and try e.lossCount() == 0) return true;
        }
        return false;
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
            if (std.mem.eql(u8, w.sourceOf(st), w.g.name)) {
                if (w.kept.n == 0) w.kept.line = st.line;
                w.kept.n += 1;
                return w.lineTail(st.raw, st.tail);
            }
            // A region the source grammar keeps verbatim, and says why.
            if (w.caps) |c| for (c.grammars) |*sg| {
                if (!std.mem.eql(u8, sg.name, w.sourceOf(st))) continue;
                for (sg.raws) |rb| {
                    if (rb.reason.len == 0 or !std.mem.startsWith(u8, st.raw, rb.open)) continue;
                    const more = std.mem.count(u8, std.mem.trimEnd(u8, st.raw, "\n"), "\n");
                    w.report.add(.@"error", .unsupported, st.line, "'{s}'{s} cannot be written for {s}: {s}", .{ std.mem.sliceTo(st.raw, '\n'), if (more == 0) "" else try a.print(" and the {d} line{s} after it", .{ more, if (more == 1) "" else "s" }), w.g.name, rb.reason });
                    return w.comment(try a.print("[sprack] not written: {s}", .{std.mem.sliceTo(st.raw, '\n')}));
                }
            };
            const more = std.mem.count(u8, std.mem.trimEnd(u8, st.raw, "\n"), "\n");
            w.report.add(.@"error", .untranslated, st.line, "no {s} rule understood this line; it is in the output only as a comment: {s}{s}", .{
                w.sourceOf(st), std.mem.sliceTo(st.raw, '\n'), if (more == 0) "" else try a.print(" (and {d} more line{s} of it)", .{ more, if (more == 1) "" else "s" }),
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
        var chosen: ir.Stmt = undefined;
        if (st.kind == .instance and w.splits.items.len > 0 and st.get("master") == .atom) {
            const name = try w.variantOf(a, st) orelse return w.comment(try a.print("[sprack] not written: instance '{s}'", .{st.get("name").atom}));
            if (!std.ascii.eqlIgnoreCase(name, st.get("master").atom)) {
                chosen = st.*;
                try chosen.own(a);
                try chosen.set(a, schema.slotIndex(.instance, "master").?, .{ .atom = name });
                st = &chosen;
            }
        }
        if (st.kind == .capacitor and try w.capacitorParts(a, st)) return;
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
                        // Written as an instance of its model: with no card for
                        // it in any file read, it reads back as a subcircuit's.
                        if (st.get("master") == .atom and !std.mem.eql(u8, w.sourceOf(st), w.g.name)) {
                            const m = st.get("master").atom;
                            const known = w.declared.contains(try std.ascii.allocLowerString(a, m)) or w.families.contains(m);
                            if (!known) w.report.add(.warning, .ambiguous, st.line, "{s} '{s}': its model '{s}' is declared in no file read; {s} tells a {s} from a subcircuit instance only by its model, so it reads back as an instance of '{s}'", .{
                                @tagName(st.kind), st.get("name").atom, m, w.g.name, @tagName(st.kind), m,
                            });
                        }
                        w.ordinals[@backingInt(st.kind)] -= 1;
                        return w.leaf(a, &inst);
                    }
                }
            }
            return w.unsupported(a, st, "");
        }

        var best: ?*const grammar.Rule = null;
        var best_loss: usize = std.math.maxInt(usize);
        var best_renames: usize = 0;
        var why: []const u8 = "";
        const fam: []const u8 = if (st.get("master") == .atom) w.familyOf(st.get("master").atom) else "";
        // A model this file does not declare: the plain forms first, then
        // any form at all rather than none.
        for ([_]bool{ false, true }) |loose| {
            if (best != null or (loose and fam.len > 0)) break;
            for (w.g.rules) |*rule| {
                if (rule.kind != st.kind or rule.dir == .read) continue;
                if (w.g.spreadWord(st.kind) != null and w.g.isEnding(rule) != w.ending) continue;
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
                // The form of the model's own family, whatever a plain one keeps.
                if (rule.family.len > 0 and std.mem.eql(u8, rule.family, fam)) {
                    best = rule;
                    break;
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
        try w.lineTail(std.mem.trimEnd(u8, e.buf.items, "\n"), st.tail);
        if (rule.dir == .write and !w.g.canRead(st.kind)) {
            w.report.add(.info, .oneway, st.line, "{s}: written in a form the {s} grammar does not read back as a {s}", .{ @tagName(st.kind), w.g.name, @tagName(st.kind) });
        } else if (e.dropped != 0) {
            // Left out on purpose (`-slot`, its caveat says why): it reads
            // back without it.
            for (0..@min(schema.info(st.kind).slots.len, 64)) |i| if (e.dropped & (@as(u64, 1) << @intCast(i)) != 0) {
                w.report.add(.info, .loss, st.line, "{s}.{s} is not written, so it reads back without it", .{ @tagName(st.kind), schema.info(st.kind).slots[i].name });
            };
        }
        if (class == .control) {
            // What one statement cannot hold, further statements may:
            // `.options timeint ...` next to `.options device ...`. One that
            // only says again what an earlier one said (`reltol=reltol+`,
            // `.options nonlin ...`) is written once.
            const said = try a.alloc(bool, w.g.rules.len);
            @memset(said, false);
            var progress = true;
            while (progress) {
                progress = false;
                for (w.g.rules, said) |*more, *was| {
                    if (more.kind != st.kind or more.dir == .read) continue;
                    var probe = w.emitter(a, st);
                    probe.quiet = true;
                    probe.hide = e.used;
                    if (!try probe.seq(more.pat)) continue;
                    const fresh = probe.used & ~e.used != 0;
                    if (!fresh and (probe.again == 0 or was.*)) continue;
                    var extra = w.emitter(a, st);
                    extra.hide = e.used;
                    _ = try extra.seq(more.pat);
                    try w.line(extra.buf.items);
                    e.used |= extra.used;
                    was.* = true;
                    progress = progress or fresh;
                }
            }
        }
        try e.reportLosses();
        if (e.foreign) {
            // `.dc X ...` sweeps a source in one dialect and a parameter or
            // the temperature in another, under the same spelling.
            for (schema.info(st.kind).slots, 0..) |sl, i| {
                if (sl.ty != .ref or st.at(i) != .atom) continue;
                if (w.refs) |r| {
                    if (r.found.contains(st.at(i).atom)) continue;
                } else if (w.instances.contains(st.at(i).atom)) continue;
                w.report.add(.@"error", .invalid, st.line, "{s}.{s} = {s} does not name a device in this netlist; if {s} means a parameter by it, {s} has to be told so in its own way", .{
                    @tagName(st.kind), sl.name, st.at(i).atom, w.sourceOf(st), w.g.name,
                });
                // A device of the name may still come.
                if (w.refs) |r| try r.pending.append(w.perm, .{ .at = w.report.items.items.len - 1, .name = try w.perm.dupe(u8, st.at(i).atom) });
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
            // An options statement is made where there is none.
            var to = mv.to == .options;
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

    /// Apply the grammar's `default` lines and both dialects' `omitted`
    /// lines: a value a statement from another dialect leaves to that
    /// dialect's default (a SPICE pulse's rise time is the `.tran` step) is
    /// written out where this dialect needs it. Where the netlist has
    /// nothing to take a `default` from, nothing is filled and the dialect's
    /// `invalid` line says why.
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
            const foreign = !std.mem.eql(u8, w.sourceOf(st), w.g.name);
            if (foreign and try w.omitted(w.sourceGrammar(st), st, &cur, all)) changed = true;
            for (w.g.fills) |f| {
                if (f.kind != st.kind or !foreign) continue;
                if (f.when_slot != grammar.no_slot) {
                    const c = cur.at(f.when_slot);
                    if (c != .atom or !std.mem.eql(u8, c.atom, f.when_atom)) continue;
                }
                const v = cur.at(f.slot);
                if (v != .none and !(f.zero and isZero(v))) continue;
                // A source dialect with a default of its own means that one.
                if (w.sourceGrammar(st)) |sg| if (sg.checksSlot(f.kind, f.slot)) continue;
                const sl = schema.info(f.kind).slots;
                const from = firstValue(all, f.from, f.from_slot) orelse continue;
                try cur.own(w.arena);
                try cur.set(w.arena, f.slot, from);
                changed = true;
                var em = w.emitter(w.arena, st);
                w.report.add(.warning, .synthesized, st.line, "{s}.{s} {s}: {s} means the {s}.{s} by that, and {s} needs it said; wrote {s}", .{
                    @tagName(f.kind),                           sl[f.slot].name,
                    if (v != .none) "is 0" else "is not given", w.sourceOf(st),
                    @tagName(f.from),                           schema.info(f.from).slots[f.from_slot].name,
                    w.g.name,                                   try em.describe(from),
                });
            }
            if (changed) {
                if (list == null) list = try w.arena.dupe(ir.Stmt, stmts);
                list.?[i] = cur;
            }
        }
        return list orelse stmts;
    }

    /// The `omitted` lines of both dialects, for a statement crossing from
    /// `sg`'s into this one: a value it leaves to `sg`'s default is written
    /// out where this dialect means another by leaving it out (or says
    /// nothing), and a zero this dialect reads as left out is written as
    /// the line's `zero` value, or cannot be said.
    fn omitted(w: *Writer, sg: ?*const Grammar, st: *const ir.Stmt, cur: *ir.Stmt, all: []const ir.Stmt) Allocator.Error!bool {
        var changed = false;
        const sl = schema.info(st.kind).slots;
        if (sg) |s| for (s.omitted) |*o| {
            if (omittedLine(s, st, o.slot) != o) continue;
            const v = st.at(o.slot);
            if (v != .none and !(o.zero and isZero(v))) continue;
            if (omittedLine(w.g, st, o.slot)) |t| {
                if (std.mem.eql(u8, t.text, o.text) and t.given == o.given and (v == .none or t.zero)) continue;
            }
            // Without the slot the formula holds for, the value plays no part.
            if (o.given != grammar.no_slot and st.at(o.given) == .none) continue;
            const what = try omittedPhrase(w.arena, o);
            var missing: ?Kind = null;
            const val = (try w.omittedValue(s, st, o, all, &missing, 0)) orelse {
                if (missing) |k| w.report.add(.@"error", .invalid, st.line, "{s}.{s} {s}: {s} means {s} by that and {s} does not, and this netlist has no {s} to take it from", .{
                    @tagName(st.kind), sl[o.slot].name, if (v != .none) "is 0" else "is not given", s.name, what, w.g.name, @tagName(k),
                });
                continue;
            };
            try cur.own(w.arena);
            try cur.set(w.arena, o.slot, val);
            changed = true;
            var em = w.emitter(w.arena, st);
            w.report.add(.warning, .synthesized, st.line, "{s}.{s} {s}: {s} means {s} by that, and {s} needs it said; wrote {s}", .{
                @tagName(st.kind), sl[o.slot].name, if (v != .none) "is 0" else "is not given", s.name, what, w.g.name, try em.describe(val),
            });
        };
        for (w.g.omitted) |*t| {
            if (omittedLine(w.g, st, t.slot) != t) continue;
            const v = cur.at(t.slot);
            const theirs = if (sg) |s| omittedLine(s, st, t.slot) else null;
            if (t.zero and isZero(v) and !(theirs != null and theirs.?.zero)) {
                const what = try omittedPhrase(w.arena, t);
                if (t.zero_as.len == 0) {
                    w.report.add(.@"error", .invalid, st.line, "{s}.{s} is 0: {s} reads a 0 there as not given and takes {s} for it; a 0 cannot be said", .{
                        @tagName(st.kind), sl[t.slot].name, w.g.name, what,
                    });
                    continue;
                }
                const tiny: Value = if (lexer.parseNumber(w.arena, &w.g.lex, t.zero_as)) |n| .{ .num = n } else .{ .expr = t.zero_as };
                try cur.own(w.arena);
                try cur.set(w.arena, t.slot, tiny);
                changed = true;
                var em = w.emitter(w.arena, st);
                w.report.add(.warning, .synthesized, st.line, "{s}.{s} is 0: {s} reads a 0 there as not given and would take {s}; wrote {s}, which it takes as given", .{
                    @tagName(st.kind), sl[t.slot].name, w.g.name, what, try em.describe(tiny),
                });
            } else if (v == .none and theirs == null and !(sg != null and sg.?.checksSlot(st.kind, t.slot))) {
                // Nothing is assumed of a dialect that does not say.
                w.report.add(.warning, .ambiguous, st.line, "{s}.{s} is not given: {s} takes its own default for it, and what {s} takes is not measured; written as it was", .{
                    @tagName(st.kind), sl[t.slot].name, w.g.name, w.sourceOf(st),
                });
            }
        }
        return changed;
    }

    /// What the `omitted` line `o` of `sg` gives for `st`. Null where the
    /// netlist has no statement of a kind it counts from (`missing` names
    /// it) or the statement no value for a slot it counts from.
    fn omittedValue(w: *Writer, sg: *const Grammar, st: *const ir.Stmt, o: *const grammar.Omitted, all: []const ir.Stmt, missing: *?Kind, depth: u8) Allocator.Error!?Value {
        var stack: [3]Value = undefined;
        var n: usize = 0;
        for (o.terms) |t| switch (t) {
            .num => |digits| {
                stack[n] = .{ .num = .init(digits, 0) };
                n += 1;
            },
            .first => |f| {
                stack[n] = firstValue(all, f.kind, f.slot) orelse {
                    missing.* = f.kind;
                    return null;
                };
                n += 1;
            },
            .slot => |slot| {
                const v = st.at(slot);
                const its = omittedLine(sg, st, slot);
                // Left out as well: what the dialect means by that.
                stack[n] = if (v != .none and !(its != null and its.?.zero and isZero(v))) v else if (its != null and depth < 4)
                    (try w.omittedValue(sg, st, its.?, all, missing, depth + 1)) orelse return null
                else
                    return null;
                n += 1;
            },
            .op => |op| {
                n -= 1;
                stack[n - 1] = try expr.arith(w.arena, switch (op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                }, stack[n - 1], stack[n]);
            },
        };
        return stack[0];
    }

    /// Apply the grammar's `move` lines: values this dialect says on another
    /// statement are carried there before anything is written.
    fn applyMoves(w: *Writer, stmts: []const ir.Stmt) Allocator.Error![]const ir.Stmt {
        if (!w.anyMove(stmts)) return stmts;
        var list = try w.arena.dupe(ir.Stmt, stmts);
        // One value may go to several kinds (`nodeset` onto every analysis),
        // so a source is emptied only after every move has seen it.
        var emptied: std.ArrayList(struct { *ir.Stmt, u8 }) = .empty;
        for (w.g.moves) |mv| {
            if (mv.to == .options) {
                list = try w.moveToOptions(list, mv);
                continue;
            }
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
                if (moved and mv.oneway) w.report.add(.info, .oneway, src.line, "{s}.{s} is written as {s}.{s}, which reads back there", .{
                    @tagName(mv.from), schema.info(mv.from).slots[mv.from_slot].name, @tagName(mv.to), schema.info(mv.to).slots[mv.to_slot].name,
                });
            }
        }
        for (emptied.items) |em| {
            try em[0].own(w.arena);
            try em[0].set(w.arena, em[1], .none);
        }
        return list;
    }

    /// A `move` onto the options, which hold for the whole netlist (HSPICE
    /// caps the step of every `.tran` with one DELMAX): the first value
    /// goes to the first options statement, a new one where the netlist
    /// has none. A statement that says another value keeps it, for the
    /// writer to refuse; one that says none is told what it now shares.
    fn moveToOptions(w: *Writer, list_in: []ir.Stmt, mv: grammar.Move) Allocator.Error![]ir.Stmt {
        var list = list_in;
        const first = for (list, 0..) |*s, i| {
            if (s.kind == mv.from and s.at(mv.from_slot) != .none) break i;
        } else return list;
        const v = list[first].at(mv.from_slot);
        const said = list[first].line;
        const at = for (list, 0..) |*s, i| {
            if (s.kind == .options) break i;
        } else blk: {
            const grown = try w.arena.alloc(ir.Stmt, list.len + 1);
            @memcpy(grown[0..first], list[0..first]);
            grown[first] = try ir.newStmt(w.arena, .options, said);
            @memcpy(grown[first + 1 ..], list[first..]);
            list = grown;
            break :blk first;
        };
        if (list[at].at(mv.to_slot) != .none) return list;
        try list[at].own(w.arena);
        try list[at].set(w.arena, mv.to_slot, v);
        const from = schema.info(mv.from).slots[mv.from_slot].name;
        const to = schema.info(mv.to).slots[mv.to_slot].name;
        if (mv.oneway) w.report.add(.info, .oneway, said, "{s}.{s} is written as {s}.{s}, which reads back there", .{ @tagName(mv.from), from, @tagName(mv.to), to });
        for (list) |*s| {
            if (s.kind != mv.from) continue;
            if (s.at(mv.from_slot) == .none) {
                var em = w.emitter(w.arena, s);
                w.report.add(.warning, .caveat, s.line, "{s}.{s} is not given: {s} says it once for the whole netlist ({s}.{s}), so the {s} another {s} gives holds here too", .{
                    @tagName(mv.from), from, w.g.name, @tagName(mv.to), to, try em.describe(v), @tagName(mv.from),
                });
            } else if (s.at(mv.from_slot).eql(v)) {
                try s.own(w.arena);
                try s.set(w.arena, mv.from_slot, .none);
            }
        }
        return list;
    }
};

/// The canonical name a dialect's `params` table gives a spelling.
/// The entry of a spellings table for a canonical name.
fn spellingsOf(table: []const grammar.Spellings, canon: []const u8) ?*const grammar.Spellings {
    for (table) |*e| if (std.ascii.eqlIgnoreCase(e.canon, canon)) return e;
    return null;
}

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

fn isZero(v: Value) bool {
    return v == .num and v.num.toFloat() == 0;
}

/// The dialect's `omitted` line for `slot` of a statement like `st`.
fn omittedLine(g: *const Grammar, st: *const ir.Stmt, slot: usize) ?*const grammar.Omitted {
    for (g.omitted) |*o| {
        if (o.kind != st.kind or o.slot != slot) continue;
        if (o.when_slot != grammar.no_slot) {
            const c = st.at(o.when_slot);
            if (c != .atom or !std.mem.eql(u8, c.atom, o.when_atom)) continue;
        }
        return o;
    }
    return null;
}

/// An `omitted` formula in a report's words: "the tran.step", "td1 plus
/// the tran.step", any other as the grammar writes it.
fn omittedPhrase(arena: Allocator, o: *const grammar.Omitted) Allocator.Error![]const u8 {
    const t = o.terms;
    const sl = schema.info(o.kind).slots;
    if (t.len == 1 and t[0] == .first)
        return std.fmt.allocPrint(arena, "the {s}.{s}", .{ @tagName(t[0].first.kind), schema.info(t[0].first.kind).slots[t[0].first.slot].name });
    if (t.len == 3 and t[0] == .slot and t[1] == .first and t[2].op == .add)
        return std.fmt.allocPrint(arena, "{s} plus the {s}.{s}", .{ sl[t[0].slot].name, @tagName(t[1].first.kind), schema.info(t[1].first.kind).slots[t[1].first.slot].name });
    return o.text;
}

/// `unique param`: a parameter defined twice in one scope. Each body
/// (subcircuit, library section, branch) is a scope of its own.
fn uniqueParams(stmts: []const ir.Stmt, report: *ir.Report, g: *const Grammar) Allocator.Error!void {
    var seen: ir.CaselessSet = .empty;
    defer seen.deinit(ir.big);
    try uniqueParamsIn(stmts, &seen, null, report, g);
}

/// `seen`: the names the scope defined before `stmts`; with `keep`, each
/// new one is kept, as `stmts` go away before the scope ends.
fn uniqueParamsIn(stmts: []const ir.Stmt, seen: *ir.CaselessSet, keep: ?ir.Keep, report: *ir.Report, g: *const Grammar) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.body.len > 0) try uniqueParams(s.body, report, g);
        if (s.kind != .param or s.get("params") != .params) continue;
        for (s.get("params").params) |p| {
            // The variation of the parameter before it, not a parameter.
            if (stats.devLotKey(p.key) != null) continue;
            const gop = try seen.getOrPut(ir.big, p.key);
            if (gop.found_existing) report.add(.@"error", .invalid, s.line, "parameter '{s}' is defined twice in one scope; {s}", .{ p.key, g.unique_param }) else if (keep) |k| {
                gop.key_ptr.* = try k.text(p.key);
            }
        }
    }
}

const Analysis = struct { kind: ir.Kind, line: u32 };

/// `unique analysis`: the statements of `stmts` that count as an analysis
/// in `g`, outside subcircuits, in the order written.
fn collectAnalyses(a: Allocator, g: *const Grammar, stmts: []const ir.Stmt, found: *std.ArrayList(Analysis)) Allocator.Error!void {
    const u = g.unique_analysis orelse return;
    for (stmts) |*s| {
        if (s.kind == .subckt) continue;
        if (std.mem.indexOfScalar(ir.Kind, u.kinds, s.kind) != null) try found.append(a, .{ .kind = s.kind, .line = s.line });
        try collectAnalyses(a, g, s.body, found);
    }
}

/// `unique analysis`: more analyses than the simulator loads in one netlist
/// are an error on each; two it loads, running one, a caveat on the other.
/// The lines are the entries': a message is the same for a netlist built
/// in Python, whose statements have other lines.
fn uniqueAnalyses(a: Allocator, g: *const Grammar, found: []const Analysis, report: *ir.Report) Allocator.Error!void {
    const u = g.unique_analysis orelse return;
    if (found.len < 2) return;
    var besides: usize = 0;
    for (found) |f| besides += @intFromBool(f.kind == u.beside);
    if (found.len == 2 and besides > 0) {
        // Two of the kind are the same analysis twice: nothing is left out.
        if (besides == 2) return;
        const op: usize = @intFromBool(found[1].kind == u.beside);
        report.add(.warning, .caveat, found[op].line, "{s} beside {s}; {s}", .{ @tagName(found[op].kind), @tagName(found[op ^ 1].kind), u.reason });
        return;
    }
    var names: std.ArrayList(u8) = .empty;
    for (found, 0..) |f, i| try names.print(a, "{s}{s}", .{ if (i == 0) "" else ", ", @tagName(f.kind) });
    for (found) |f| report.add(.@"error", .invalid, f.line, "{s}: one of {d} analyses in this netlist ({s}); {s}", .{ @tagName(f.kind), found.len, names.items, u.reason });
}

/// The parameter names `stmts` define that start with a name the dialect
/// keeps for itself (`reserved`): those `reservedRenames` renames, and the
/// names a new one could clash with. With `src`, a name not in it is copied.
pub fn collectReserved(arena: Allocator, g: *const Grammar, stmts: []const ir.Stmt, out: *ir.CaselessSet, src: ?[]const u8) Allocator.Error!void {
    if (g.reserved.len == 0) return;
    for (stmts) |*s| {
        try collectReserved(arena, g, s.body, out, src);
        if ((s.kind != .param and s.kind != .subckt) or s.get("params") != .params) continue;
        for (s.get("params").params) |p| for (g.reserved) |r| for (r.names) |n| {
            if (std.ascii.startsWithIgnoreCase(p.key, n)) try ir.putName(out, arena, src, p.key);
        };
    }
}

/// `reserved`: each parameter `defined` (here or in another file of the
/// project) under a name the dialect keeps for itself, to the name it is
/// written under: `vt__p`, or `vt__p2` and so on when that is taken. Every
/// file of a project gets the same map. A name that is a variable in every
/// dialect (`time`) is left: in an expression the word is the variable.
fn reservedRenames(arena: Allocator, g: *const Grammar, defined: *const ir.CaselessSet, env: ?*const ir.Env) Allocator.Error!CaselessMap {
    var out: CaselessMap = .empty;
    for (g.reserved) |r| for (r.names) |n| {
        // `time` is the variable in every expression; a variable this
        // dialect takes before a parameter of its name (`shadowed`) is not.
        if (schema.isVariable(n) and !r.shadowed) continue;
        if (!defined.contains(n) and !(if (env) |e| e.params.contains(n) else false)) continue;
        var name = try std.fmt.allocPrint(arena, "{s}__p", .{n});
        var i: usize = 2;
        while (defined.contains(name) or (if (env) |e| e.params.contains(name) else false)) : (i += 1) {
            name = try std.fmt.allocPrint(arena, "{s}__p{d}", .{ n, i });
        }
        try out.put(arena, n, name);
    };
    return out;
}

/// The parameters `renames` names under their new names: where they are
/// defined (`.param`, a subcircuit's header), given to a subcircuit, and
/// used in an expression. Each is reported once.
fn renameParams(w: *Writer, stmts: []ir.Stmt, renames: *const CaselessMap, told: *ir.CaselessSet) Allocator.Error![]ir.Stmt {
    var list: ?[]ir.Stmt = null;
    for (stmts, 0..) |*st, i| {
        var cur = st.*;
        var changed = false;
        if (st.body.len > 0) {
            const b = try renameParams(w, st.body, renames, told);
            if (b.ptr != st.body.ptr) {
                cur.body = b;
                changed = true;
            }
        }
        var hit: std.ArrayList([]const u8) = .empty;
        const keys = st.kind == .param or st.kind == .subckt or st.kind == .instance;
        for (schema.info(st.kind).slots, 0..) |sl, si| {
            // Slots that name a parameter: a function's arguments, what a
            // sweep sweeps, a data table's columns, what an alter sets.
            const words = (st.kind == .func and std.mem.eql(u8, sl.name, "args")) or
                ((st.kind == .dc or st.kind == .step) and (std.mem.eql(u8, sl.name, "param") or std.mem.eql(u8, sl.name, "param2"))) or
                (st.kind == .data and std.mem.eql(u8, sl.name, "cols")) or
                (st.kind == .alter and (std.mem.eql(u8, sl.name, "param") or std.mem.eql(u8, sl.name, "keys")));
            const v = try renamedValue(w.arena, st.at(@intCast(si)), renames, keys, words, &hit) orelse continue;
            if (!changed or cur.body.ptr != st.body.ptr) try cur.own(w.arena);
            try cur.set(w.arena, @intCast(si), v);
            changed = true;
        }
        for (hit.items) |old| {
            const gop = try told.getOrPut(w.perm, old);
            if (gop.found_existing) continue;
            gop.key_ptr.* = try w.perm.dupe(u8, old);
            const why = why: for (w.g.reserved) |r| {
                for (r.names) |n| if (std.ascii.eqlIgnoreCase(n, old)) break :why r.reason;
            } else "";
            w.report.add(.info, .rename, st.line, "parameter '{s}' is written as '{s}', where it is defined and wherever it is used: {s}", .{ old, renames.get(old).?, why });
        }
        if (changed) {
            if (list == null) list = try w.arena.dupe(ir.Stmt, stmts);
            list.?[i] = cur;
        }
    }
    return list orelse stmts;
}

/// `v` for `renameParams`, or null when nothing in it is renamed. `keys`:
/// the keys of a parameter list are parameters; `words`: so are bare words.
fn renamedValue(arena: Allocator, v: Value, renames: *const CaselessMap, keys: bool, words: bool, hit: *std.ArrayList([]const u8)) Allocator.Error!?Value {
    switch (v) {
        .expr => |e| {
            const t = try expr.rename(arena, e, renames, hit);
            return if (t.ptr == e.ptr) null else .{ .expr = t };
        },
        .atom => |a| {
            const to = renames.get(a) orelse return null;
            if (!words) return null;
            try hit.append(arena, a);
            return .{ .atom = to };
        },
        .list => |l| {
            var out: ?[]Value = null;
            for (l, 0..) |x, i| if (try renamedValue(arena, x, renames, keys, words, hit)) |n| {
                if (out == null) out = try arena.dupe(Value, l);
                out.?[i] = n;
            };
            return if (out) |o| .{ .list = o } else null;
        },
        .params => |ps| {
            var out: ?[]ir.Param = null;
            for (ps, 0..) |p, i| {
                var n = p;
                if (keys) if (renames.get(p.key)) |to| {
                    try hit.append(arena, p.key);
                    n.key = to;
                };
                if (try renamedValue(arena, p.val, renames, false, false, hit)) |val| n.val = val;
                if (n.key.ptr == p.key.ptr and n.val.eql(p.val)) continue;
                if (out == null) out = try arena.dupe(ir.Param, ps);
                out.?[i] = n;
            }
            return if (out) |o| .{ .params = o } else null;
        },
        else => return null,
    }
}

/// A map from names, ignoring case.
const CaselessMap = std.HashMapUnmanaged([]const u8, []const u8, ir.Caseless, std.hash_map.default_max_load_percentage);

/// `unique master`: names both a model (or its bins, `nch.1`) and a
/// subcircuit define, here or in another file of the project, each to the
/// name its model is written under: `nch__m`, or `nch__m2` and so on when
/// that is taken. Every file of a project gets the same map.
pub fn masterRenames(arena: Allocator, stmts: []const ir.Stmt, env: ?*const ir.Env) Allocator.Error!CaselessMap {
    var models: ir.CaselessSet = .empty;
    var subckts: ir.CaselessSet = .empty;
    try collectMasters(arena, stmts, &models, &subckts, null);
    return renamesOf(arena, &models, &subckts, env);
}

/// `masterRenames` for the models and subcircuits `collectMasters` found.
fn renamesOf(arena: Allocator, models_in: *const ir.CaselessSet, subckts_in: *const ir.CaselessSet, env: ?*const ir.Env) Allocator.Error!CaselessMap {
    var models = try models_in.clone(arena);
    var subckts = try subckts_in.clone(arena);
    var taken: ir.CaselessSet = .empty;
    if (env) |e| {
        var it = e.models.keyIterator();
        while (it.next()) |k| try models.put(arena, ir.binBase(k.*) orelse k.*, {});
        var si = e.subckts.keyIterator();
        while (si.next()) |k| try subckts.put(arena, k.*, {});
        var di = e.declared.keyIterator();
        while (di.next()) |k| try taken.put(arena, k.*, {});
    }
    var out: CaselessMap = .empty;
    var it = models.keyIterator();
    while (it.next()) |k| {
        try taken.put(arena, k.*, {});
        if (!subckts.contains(k.*)) continue;
        var name = try std.fmt.allocPrint(arena, "{s}__m", .{k.*});
        var n: usize = 2;
        while (taken.contains(name) or subckts.contains(name) or models.contains(name)) : (n += 1) {
            name = try std.fmt.allocPrint(arena, "{s}__m{d}", .{ k.*, n });
        }
        try out.put(arena, k.*, name);
    }
    return out;
}

/// With `src`, a name not in it is copied (the statements go away).
fn collectMasters(arena: Allocator, stmts: []const ir.Stmt, models: *ir.CaselessSet, subckts: *ir.CaselessSet, src: ?[]const u8) Allocator.Error!void {
    for (stmts) |*s| {
        const n = s.get("name");
        if (n == .atom) {
            if (s.kind == .subckt) try ir.putName(subckts, arena, src, n.atom);
            // `nch.1`, `nch.2`: bins of the model `nch`.
            if (s.kind == .model) try ir.putName(models, arena, src, ir.binBase(n.atom) orelse n.atom);
        }
        try collectMasters(arena, s.body, models, subckts, src);
    }
}

/// The model cards `renames` names, and the devices that use them as a
/// model (by their SPICE letter), under their new names; subcircuit
/// instances keep theirs. Each name is reported once.
fn renameMasters(w: *Writer, stmts: []ir.Stmt, renames: *const CaselessMap, told: *ir.CaselessSet) Allocator.Error![]ir.Stmt {
    var list: ?[]ir.Stmt = null;
    for (stmts, 0..) |*st, i| {
        var cur = st.*;
        var changed = false;
        if (st.body.len > 0) {
            const b = try renameMasters(w, st.body, renames, told);
            if (b.ptr != st.body.ptr) {
                cur.body = b;
                changed = true;
            }
        }
        const class = schema.info(st.kind).class;
        const slot: ?u8 = if (st.kind == .model) schema.slotIndex(.model, "name") else if (class == .device and st.kind != .instance) schema.slotIndex(st.kind, "master") else null;
        if (slot) |si| if (cur.at(si) == .atom) {
            const old = cur.at(si).atom;
            const base = if (st.kind == .model) ir.binBase(old) orelse old else old;
            if (renames.get(base)) |new| {
                try cur.own(w.arena);
                try cur.set(w.arena, si, .{ .atom = try std.mem.concat(w.arena, u8, &.{ new, old[base.len..] }) });
                changed = true;
                const gop = try told.getOrPut(w.perm, base);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try w.perm.dupe(u8, base);
                    w.report.add(.info, .rename, st.line, "'{s}' names both a model and a subcircuit: the model is written as '{s}', and so is every device that uses it as a model; {s}", .{ base, new, w.g.unique_master });
                }
            }
        };
        if (changed) {
            if (list == null) list = try w.arena.dupe(ir.Stmt, stmts);
            list.?[i] = cur;
        }
    }
    return list orelse stmts;
}

/// A device still using a name both a model and a subcircuit define after
/// `renameMasters` (one it could not reach): an error.
fn uniqueMasters(arena: Allocator, stmts: []const ir.Stmt, env: ?*const ir.Env, report: *ir.Report, g: *const Grammar) Allocator.Error!void {
    var models: ir.CaselessSet = .empty;
    var subckts: ir.CaselessSet = .empty;
    var told: ir.CaselessSet = .empty;
    try collectMasters(arena, stmts, &models, &subckts, null);
    if (env) |e| {
        var it = e.models.keyIterator();
        while (it.next()) |k| try models.put(arena, ir.binBase(k.*) orelse k.*, {});
        var si = e.subckts.keyIterator();
        while (si.next()) |k| try subckts.put(arena, k.*, {});
    }
    try clashes(arena, stmts, &models, &subckts, &told, report, g);
}

fn clashes(arena: Allocator, stmts: []const ir.Stmt, models: *ir.CaselessSet, subckts: *ir.CaselessSet, told: *ir.CaselessSet, report: *ir.Report, g: *const Grammar) Allocator.Error!void {
    for (stmts) |*s| {
        try clashes(arena, s.body, models, subckts, told, report, g);
        if (schema.info(s.kind).class != .device or s.kind == .instance) continue;
        const m = s.get("master");
        if (m != .atom or !models.contains(m.atom) or !subckts.contains(m.atom)) continue;
        const gop = try told.getOrPut(arena, m.atom);
        if (gop.found_existing) continue;
        gop.key_ptr.* = try arena.dupe(u8, m.atom);
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

/// Does a `params` table take the canonical parameter `canon`?
fn takes(table: []const grammar.Spellings, canon: []const u8) bool {
    if (grammar.paramsOpen(table)) return true;
    for (table) |e| if (std.ascii.eqlIgnoreCase(e.canon, canon)) return true;
    return false;
}

/// A capacitor's initial voltage or charge where the target's capacitor
/// takes neither (VACASK), and other devices of the target say it
/// (`Writer.capacitorParts`). Empty: written as a capacitor.
const CapParts = struct {
    ic: ?Value = null,
    q: ?Value = null,

    fn any(c: CapParts) bool {
        return c.ic != null or c.q != null;
    }
};

/// `sg`: the dialect the statement was read in.
fn capParts(g: *const Grammar, sg: ?*const Grammar, st: *const ir.Stmt) CapParts {
    if (st.kind != .capacitor) return .{};
    if (sg) |s| if (s == g or std.mem.eql(u8, s.name, g.name)) return .{};
    const table = g.paramsOf(.capacitor) orelse return .{};
    const v = st.get("params");
    if (v != .params) return .{};
    const from = if (sg) |s| s.paramsOf(.capacitor) else null;
    var out: CapParts = .{};
    for (v.params) |p| {
        const canon = if (from) |t| spellingCanon(t, p.key) orelse p.key else p.key;
        if (std.ascii.eqlIgnoreCase(canon, "q") and !takes(table, "q") and g.canWrite(.bsource) and spellingsOf(g.functions, "ddt") != null) out.q = p.val;
        if (std.ascii.eqlIgnoreCase(canon, "ic") and !takes(table, "ic") and g.canWrite(.vsource)) out.ic = p.val;
    }
    // A charge has no initial voltage of its own to put in series: that
    // stays the loss it was.
    if (out.q != null) out.ic = null;
    return out;
}

/// The grammar a statement was read in: its own tag, else the netlist's.
fn readIn(dialect: []const u8, st: *const ir.Stmt) ?*const Grammar {
    return sprack.find(if (st.dialect != 0) sprack.dialectName(st.dialect) else dialect);
}

/// The kinds a capacitor is written as where `capParts` applies: a
/// voltage source or a behavioural one, whose boilerplate (`needs`) the
/// netlist then needs.
fn markCapParts(g: *const Grammar, dialect: []const u8, stmts: []const ir.Stmt, used: *[schema.kind_count]bool) void {
    for (stmts) |*s| {
        const c = capParts(g, readIn(dialect, s), s);
        if (c.ic != null) used[@backingInt(Kind.vsource)] = true;
        if (c.q != null) used[@backingInt(Kind.bsource)] = true;
        markCapParts(g, dialect, s.body, used);
    }
}

/// The nodes an `.ic` statement sets, anywhere in `stmts`.
fn collectIcNodes(a: Allocator, stmts: []const ir.Stmt, out: *ir.CaselessSet, src: ?[]const u8) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .ic and s.get("values") == .params) {
            for (s.get("values").params) |p| try ir.putName(out, a, src, p.key);
        }
        try collectIcNodes(a, s.body, out, src);
    }
}

/// The fewest and the most terminals of the instances that name a model.
pub const Terminals = struct { min: u32, max: u32 };
pub const TerminalMap = std.HashMapUnmanaged([]const u8, Terminals, ir.Caseless, std.hash_map.default_max_load_percentage);

/// How many terminals a device statement connects.
fn terminalCount(st: *const ir.Stmt) u32 {
    var n: u32 = 0;
    for (schema.info(st.kind).slots, 0..) |sl, i| {
        if (sl.ty != .node) continue;
        switch (st.at(i)) {
            .list => |l| n += @intCast(l.len),
            .none => {},
            else => n += 1,
        }
    }
    return n;
}

/// A spelling as the grammar's models table gives it, without its conditions.
fn spellingText(a: Allocator, sp: grammar.ModelSpelling) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, sp.type);
    for (sp.kv) |kv| if (!kv.absent) try out.print(a, " {s}={s}", .{ kv.key, kv.val });
    return out.items;
}

/// For every model an instance of `stmts` names, the fewest and the most
/// terminals of those instances (`when nodes>=n`).
fn collectTerminals(a: Allocator, stmts: []const ir.Stmt, out: *TerminalMap, src: ?[]const u8) Allocator.Error!void {
    for (stmts) |*s| {
        if (schema.info(s.kind).class == .device) if (schema.slotIndex(s.kind, "master")) |mi| if (s.at(mi) == .atom) {
            const n = terminalCount(s);
            const gop = try out.getOrPut(a, s.at(mi).atom);
            if (gop.found_existing) {
                gop.value_ptr.min = @min(gop.value_ptr.min, n);
                gop.value_ptr.max = @max(gop.value_ptr.max, n);
            } else {
                if (src) |t| gop.key_ptr.* = try ir.keepText(a, t, s.at(mi).atom);
                gop.value_ptr.* = .{ .min = n, .max = n };
            }
        };
        try collectTerminals(a, s.body, out, src);
    }
}

/// Two names that differ only by case are one name in a case-folding dialect.
/// Each key is the spelling last seen. The tables hold every node and
/// instance name, so they live outside the arena and are freed when done.
const CaseMaps = struct {
    nodes: ir.CaselessSet = .empty,
    instances: ir.CaselessSet = .empty,
    definitions: ir.CaselessSet = .empty,
    params: ir.CaselessSet = .empty,

    fn deinit(m: *CaseMaps) void {
        m.nodes.deinit(ir.big);
        m.instances.deinit(ir.big);
        m.definitions.deinit(ir.big);
        m.params.deinit(ir.big);
    }
};

/// Names that differ only by case collide in a dialect that ignores case.
/// Nodes, instances, definitions and parameters are separate name spaces
/// (`schema.Space`): a source `Vdd` on a node `vdd` is no collision. A
/// subcircuit's ports, nodes and instances are its own scope; definitions
/// and parameters are shared by all scopes.
/// With `keep`, names are kept: the statements go away first.
fn checkCase(stmts: []const ir.Stmt, seen: *CaseMaps, report: *ir.Report, target: []const u8, keep: ?ir.Keep) Allocator.Error!void {
    for (stmts) |*s| {
        const scoped = s.kind == .subckt;
        var inner: CaseMaps = .{ .definitions = seen.definitions, .params = seen.params };
        const maps = if (scoped) &inner else seen;
        defer if (scoped) {
            seen.definitions = inner.definitions;
            seen.params = inner.params;
            inner.nodes.deinit(ir.big);
            inner.instances.deinit(ir.big);
        };
        for (schema.info(s.kind).slots, 0..) |sl, i| {
            const map = switch (sl.ty) {
                .node, .name, .ident => switch (sl.space orelse continue) {
                    .node => &maps.nodes,
                    .instance => &maps.instances,
                    .definition => &maps.definitions,
                    .param => &maps.params,
                },
                else => continue,
            };
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
                    gop.key_ptr.* = if (keep) |k| try k.text(v.atom) else v.atom;
                } else if (!gop.found_existing) if (keep) |k| {
                    gop.key_ptr.* = try k.text(v.atom);
                };
            }
        }
        try checkCase(s.body, maps, report, target, keep);
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

fn mentions(nodes: []const Node, slot: u8) bool {
    for (nodes) |n| {
        if (n.slot == slot or mentions(n.kids, slot)) return true;
        for (n.bag) |b| if (b.slot == slot or b.slot2 == slot) return true;
    }
    return false;
}

const PzForm = struct { writes: bool = false, by_src: bool = false, by_sig: bool = false };

/// Whether `g` writes a pole-zero analysis, and does with a source for the
/// input and a signal for the output.
fn pzForm(g: *const Grammar) PzForm {
    const src_i = schema.slotIndex(.pz, "src").?;
    const out_i = schema.slotIndex(.pz, "out").?;
    var f: PzForm = .{};
    for (g.rules) |r| if (r.kind == .pz and r.dir != .read) {
        f.writes = true;
        f.by_src = f.by_src or mentions(r.pat, src_i);
        f.by_sig = f.by_sig or mentions(r.pat, out_i);
    };
    return f;
}

/// A pole-zero analysis names its input either as a source (HSPICE `.pz
/// v(out) vin`, Spectre's iprobe=) or as a node pair with `vol` or `cur`
/// (SPICE), and its output either as a signal (HSPICE) or as a node pair
/// (SPICE, Spectre). Each half is put in the form `g` writes. A source's
/// nodes are the input pair, `vol` for a voltage source and `cur` for a
/// current source; a node pair is the one source of that kind across it.
/// A signal-form dialect (HSPICE) takes the poles and zeros of the first
/// node of v(a,b) only: measured, docs/verification.md.
fn pzPorts(arena: Allocator, w: *const Writer, stmts: []const ir.Stmt, report: *ir.Report) Allocator.Error![]const ir.Stmt {
    const g = w.g;
    const src_i = schema.slotIndex(.pz, "src").?;
    const out_i = schema.slotIndex(.pz, "out").?;
    const ip_i = schema.slotIndex(.pz, "in_pos").?;
    const in_i = schema.slotIndex(.pz, "in_neg").?;
    const op_i = schema.slotIndex(.pz, "out_pos").?;
    const on_i = schema.slotIndex(.pz, "out_neg").?;
    const tr_i = schema.slotIndex(.pz, "transfer").?;
    const fi_i = schema.slotIndex(.pz, "find").?;
    const form = pzForm(g);
    if (!form.writes) return stmts;
    const by_src, const by_sig = .{ form.by_src, form.by_sig };
    var list: ?[]ir.Stmt = null;
    for (stmts, 0..) |*st, k| {
        if (st.kind != .pz) continue;
        const has_src = st.at(src_i) == .atom;
        const has_sig = st.at(out_i) != .none;
        const in_nodes = st.at(ip_i) == .atom and st.at(in_i) == .atom and st.at(tr_i) == .atom;
        const out_nodes = st.at(op_i) == .atom and st.at(on_i) == .atom;
        const move_in = (has_src and !by_src) or (!has_src and by_src and in_nodes);
        const move_out = (has_sig and !by_sig) or (!has_sig and by_sig and out_nodes);
        if (!move_in and !move_out) continue;

        // The source for a node pair, or the node pair of a source.
        var dev: ?*const ir.Stmt = null;
        if (move_in and has_src) {
            const name = st.at(src_i).atom;
            dev = for (stmts) |*d| {
                if ((d.kind == .vsource or d.kind == .isource) and d.get("name") == .atom and std.ascii.eqlIgnoreCase(d.get("name").atom, name)) break d;
            } else {
                report.add(.@"error", .unsupported, st.line, "pz: {s} names the input by its nodes, and no voltage or current source '{s}' is in this file to take them from", .{ g.name, name });
                continue;
            };
        } else if (move_in) {
            const p, const n = .{ st.at(ip_i).atom, st.at(in_i).atom };
            const tr = st.at(tr_i).atom;
            const want: schema.Kind = if (std.ascii.eqlIgnoreCase(tr, "cur")) .isource else .vsource;
            var hits: usize = 0;
            for (stmts) |*d| {
                if (d.kind != want or d.get("name") != .atom or d.get("pos") != .atom or d.get("neg") != .atom) continue;
                const dp, const dn = .{ d.get("pos").atom, d.get("neg").atom };
                const fwd = std.ascii.eqlIgnoreCase(dp, p) and std.ascii.eqlIgnoreCase(dn, n);
                const rev = std.ascii.eqlIgnoreCase(dp, n) and std.ascii.eqlIgnoreCase(dn, p);
                if (!fwd and !rev) continue;
                hits += 1;
                dev = d;
            }
            if (hits != 1) {
                report.add(.@"error", .unsupported, st.line, "pz: {s} names the input by its source, and {s} {s} sources connect nodes {s} and {s} ({s} input); it takes exactly one", .{
                    g.name, if (hits == 0) "no" else "several", if (want == .vsource) "voltage" else "current", p, n, tr,
                });
                continue;
            }
        }
        var args: [3][]const u8 = undefined;
        var n_args: usize = 0;
        var out_text: []const u8 = "";
        if (move_out and has_sig) {
            const text: ?[]const u8 = switch (st.at(out_i)) {
                .expr, .atom, .str => |x| x,
                else => null,
            };
            out_text = text orelse "";
            const sform, n_args = (if (text) |t| reader.signalParts(t, &args) else null) orelse .{ "", 0 };
            if (!(std.mem.eql(u8, sform, "v") or std.mem.eql(u8, sform, "vdiff")) or n_args == 0) {
                report.add(.@"error", .unsupported, st.line, "pz: {s} names the output by its nodes; the output here is not a node voltage", .{g.name});
                continue;
            }
        } else if (move_out and !std.mem.eql(u8, st.at(on_i).atom, "0")) {
            report.add(.@"error", .unsupported, st.line, "pz: {s} takes the poles and zeros of v({s}) alone for v({s},{s}), so the differential output has no {s} form", .{
                g.name, st.at(op_i).atom, st.at(op_i).atom, st.at(on_i).atom, g.name,
            });
            continue;
        }
        if (n_args == 2 and !std.mem.eql(u8, args[1], "0")) if (w.sourceGrammar(st)) |sg| if (pzForm(sg).by_sig) {
            report.add(.warning, .caveat, st.line, "pz: {s} took the poles and zeros of v({s}) alone for v({s},{s}); {s} finds those of the difference", .{
                sg.name, args[0], args[0], args[1], g.name,
            });
        };

        const l = list orelse blk: {
            list = try arena.dupe(ir.Stmt, stmts);
            break :blk list.?;
        };
        const p = &l[k];
        try p.own(arena);
        if (move_in and has_src) {
            const d = dev.?;
            try p.set(arena, ip_i, d.get("pos"));
            try p.set(arena, in_i, d.get("neg"));
            try p.set(arena, tr_i, .{ .atom = if (d.kind == .vsource) "vol" else "cur" });
            try p.set(arena, fi_i, .{ .atom = "pz" });
            try p.set(arena, src_i, .none);
            report.add(.info, .oneway, st.line, "pz: the input is source {s}'s nodes, as {s} names it", .{ d.get("name").atom, g.name });
        } else if (move_in) {
            const d = dev.?;
            const find = st.at(fi_i);
            if (find == .atom and !std.ascii.eqlIgnoreCase(find.atom, "pz")) {
                report.add(.warning, .caveat, st.line, "pz: {s} finds both poles and zeros; only the {s} were asked for", .{
                    g.name, if (std.ascii.eqlIgnoreCase(find.atom, "pol")) "poles" else "zeros",
                });
            }
            if (std.ascii.eqlIgnoreCase(d.get("pos").atom, st.at(in_i).atom) and !std.ascii.eqlIgnoreCase(d.get("pos").atom, st.at(ip_i).atom)) {
                report.add(.info, .oneway, st.line, "pz: source {s} is connected from {s} to {s}, the reverse of the input pair; the transfer function changes sign, its poles and zeros do not", .{
                    d.get("name").atom, d.get("pos").atom, d.get("neg").atom,
                });
            }
            try p.set(arena, src_i, d.get("name"));
            inline for (.{ ip_i, in_i, tr_i, fi_i }) |i| try p.set(arena, i, .none);
            report.add(.info, .oneway, st.line, "pz: the input nodes {s} {s} are source {s}, as {s} names it", .{ st.at(ip_i).atom, st.at(in_i).atom, d.get("name").atom, g.name });
        }
        if (move_out and has_sig) {
            try p.set(arena, op_i, .{ .atom = args[0] });
            try p.set(arena, on_i, .{ .atom = if (n_args > 1) args[1] else "0" });
            try p.set(arena, out_i, .none);
            report.add(.info, .oneway, st.line, "pz: the output {s} is the node pair {s} {s}, as {s} names it", .{ out_text, args[0], if (n_args > 1) args[1] else "0", g.name });
        } else if (move_out) {
            const pos, const neg = .{ st.at(op_i).atom, st.at(on_i).atom };
            const sig = if (std.mem.eql(u8, neg, "0")) try std.fmt.allocPrint(arena, "v({s})", .{pos}) else try std.fmt.allocPrint(arena, "v({s},{s})", .{ pos, neg });
            try p.set(arena, out_i, .{ .atom = sig });
            try p.set(arena, op_i, .none);
            try p.set(arena, on_i, .none);
            report.add(.info, .oneway, st.line, "pz: the output nodes {s} {s} are the signal {s}, as {s} names it", .{ pos, neg, sig, g.name });
        }
    }
    return list orelse stmts;
}

/// `v` in `slot` of `st` is a `.tran` step ceiling at or above the stop
/// time, which limits nothing.
fn idleCeiling(st: *const ir.Stmt, slot: usize, v: Value) bool {
    if (st.kind != .tran or slot != schema.slotIndex(.tran, "maxstep").?) return false;
    return v == .num and st.get("stop") == .num and !(v.num.toFloat() < st.get("stop").num.toFloat());
}

/// A `.tran` step ceiling at or above the stop time limits nothing, and in
/// HSPICE a fourth number above the stop is a second segment: not written.
fn idleCeilings(arena: Allocator, stmts: []const ir.Stmt, report: *ir.Report) Allocator.Error![]const ir.Stmt {
    const mi = schema.slotIndex(.tran, "maxstep").?;
    var list: ?[]ir.Stmt = null;
    for (stmts, 0..) |*st, k| {
        if (!idleCeiling(st, mi, st.at(mi))) continue;
        const l = list orelse blk: {
            list = try arena.dupe(ir.Stmt, stmts);
            break :blk list.?;
        };
        try l[k].own(arena);
        try l[k].set(arena, mi, .none);
        report.add(.info, .oneway, st.line, "tran.maxstep at or above the stop time limits nothing and is not written; it reads back without one", .{});
    }
    return list orelse stmts;
}

/// An option's value in a netlist of dialect `sg`: the one it sets, else
/// the one `sg` assumes (`implied options tnom = 25`; `$temp` is another
/// option's value).
fn optionValue(arena: Allocator, sg: *const Grammar, stmts: []const ir.Stmt, slot: u8, depth: u8) ?Value {
    if (topValue(stmts, slot)) |v| return v;
    return impliedValue(arena, sg, sg, stmts, slot, depth);
}

/// An option the netlist itself sets: not one in a body (an `.alter`
/// changes it for its own run only).
fn topValue(stmts: []const ir.Stmt, slot: u8) ?Value {
    for (stmts) |*s| if (s.kind == .options and s.at(slot) != .none) return s.at(slot);
    return null;
}

/// What `g` assumes for an option, with a `$other` read in the netlist of `sg`.
fn impliedValue(arena: Allocator, g: *const Grammar, sg: *const Grammar, stmts: []const ir.Stmt, slot: u8, depth: u8) ?Value {
    const text = g.impliedOf(.options, slot) orelse return null;
    if (text.len > 1 and text[0] == '$') {
        const other = schema.slotIndex(.options, text[1..]) orelse return null;
        return if (depth < 4) optionValue(arena, sg, stmts, @intCast(other), depth + 1) else null;
    }
    const n = lexer.parseNumber(arena, &g.lex, text) orelse return .{ .atom = text };
    return .{ .num = n };
}

/// The options the netlist's own dialect assumes and `g` does not (HSPICE's
/// TNOM of 25 against ngspice's 27), as one statement to write at the top;
/// null when there are none. An option set anywhere in the netlist is left
/// to that statement.
// ponytail: an option set only in an included file is not seen here; pass it via ir.Env if that matters.
pub fn defaultOptions(arena: Allocator, g: *const Grammar, nl: *const ir.Netlist) Allocator.Error!?ir.Stmt {
    if (nl.library or std.mem.eql(u8, nl.dialect, g.name) or !g.canWrite(.options)) return null;
    const sg = sprack.find(nl.dialect) orelse return null;
    var st = try ir.newStmt(arena, .options, 0);
    var any = false;
    for (sg.implied) |im| {
        if (im.kind != .options or topValue(nl.stmts, im.slot) != null) continue;
        const want = optionValue(arena, sg, nl.stmts, im.slot, 0) orelse continue;
        if (impliedValue(arena, g, sg, nl.stmts, im.slot, 0)) |have| if (have.eql(want)) continue;
        try st.set(arena, im.slot, want);
        any = true;
    }
    return if (any) st else null;
}

/// Whether `nl` is written back in its own dialect: read in `g`, or built
/// (Python, JSON) from statements read in `g` (`Stmt.dialect`) and others
/// that name no dialect, such as a subcircuit built around them.
fn sameDialect(nl: *const ir.Netlist, g: *const grammar.Grammar) bool {
    if (std.mem.eql(u8, nl.dialect, g.name)) return true;
    var tagged = false;
    return allFrom(nl.stmts, g.name, &tagged) and tagged;
}

fn allFrom(stmts: []const ir.Stmt, name: []const u8, tagged: *bool) bool {
    for (stmts) |*s| {
        if (s.dialect != 0) {
            if (!std.ascii.eqlIgnoreCase(sprack.dialectName(s.dialect), name)) return false;
            tagged.* = true;
        }
        if (!allFrom(s.body, name, tagged)) return false;
    }
    return true;
}

pub fn write(
    g: *const Grammar,
    arena: Allocator,
    out: *std.Io.Writer,
    nl_in: *const ir.Netlist,
    report: *ir.Report,
    caps: ?*const Caps,
    project_env: ?*const ir.Env,
) (Allocator.Error || std.Io.Writer.Error)!void {
    const env = project_env orelse nl_in.env;
    var w: Writer = .{
        .g = g,
        .arena = arena,
        .perm = arena,
        .out = out,
        .report = report,
        .caps = caps,
        .source = nl_in.dialect,
        .scratch = .init(ir.big),
    };
    defer w.scratch.deinit();
    var nl_own = nl_in.*;
    const nl = &nl_own;

    try collectDeclared(arena, nl.stmts, &w.declared);
    try ir.collectFamilies(arena, nl.stmts, &w.families, null);
    w.env = env;
    try collectFuncs(arena, nl.stmts, &w.funcs);
    defer w.instances.deinit(ir.big);
    try collectInstances(nl.stmts, &w.instances);
    try collectIcNodes(arena, nl.stmts, &w.ic_nodes, null);
    try collectTerminals(arena, nl.stmts, &w.terminals, null);
    if (env) |e| {
        var it = e.declared.keyIterator();
        while (it.next()) |k| try w.declared.put(arena, try std.ascii.allocLowerString(arena, k.*), {});
        var fi = e.funcs.keyIterator();
        while (fi.next()) |k| try w.funcs.put(arena, k.*, {});
    }
    // A case-sensitive target told to fold case (`header folded`) merges
    // names the way a case-insensitive one does.
    const fold_header = g.header_folded.len > 0 and (nl.folds_case or
        if (sprack.find(nl.dialect)) |sg| !sg.lex.case_sensitive else false);
    if (!g.lex.case_sensitive or fold_header) {
        var seen: CaseMaps = .{};
        defer seen.deinit();
        try checkCase(nl.stmts, &seen, report, g.name, null);
    }
    // An included file is not a netlist: it has no title of its own, must
    // not end the simulation, and leaves the boilerplate to the top file.
    if (g.lex.title and !nl.library) {
        try out.print("{s}{s}\n", .{ g.lex.title_prefix, if (nl.title.len > 0) nl.title else "untitled" });
    }
    for (if (fold_header) g.header_folded else g.header) |l| try w.line(l);
    if (!nl.library) {
        var used: [schema.kind_count]bool = if (env) |e| e.used else @splat(false);
        markUsed(nl.stmts, &used);
        markCapParts(g, nl.dialect, nl.stmts, &used);
        const said = if (g.preamble_unless) |k| used[@backingInt(k)] else false;
        if (!said) for (g.preamble) |l| try w.line(l);
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
        var found: std.ArrayList(Analysis) = .empty;
        try collectAnalyses(arena, g, nl.stmts, &found);
        try uniqueAnalyses(arena, g, found.items, report);
        if (g.unique_param.len > 0) try uniqueParams(nl.stmts, report, g);
        if (g.unique_master.len > 0) {
            var renames = try masterRenames(arena, nl.stmts, env);
            // A renamed model is declared under the name it is written as.
            var ri = renames.valueIterator();
            while (ri.next()) |v| try w.declared.put(arena, try std.ascii.allocLowerString(arena, v.*), {});
            if (renames.count() > 0) {
                var told: ir.CaselessSet = .empty;
                nl_own.stmts = try renameMasters(&w, nl.stmts, &renames, &told);
            }
            try uniqueMasters(arena, nl.stmts, env, report, g);
        }
        if (g.reserved.len > 0) {
            var defined: ir.CaselessSet = .empty;
            try collectReserved(arena, g, nl.stmts, &defined, null);
            const renames = try reservedRenames(arena, g, &defined, env);
            if (renames.count() > 0) {
                var told: ir.CaselessSet = .empty;
                nl_own.stmts = try renameParams(&w, nl.stmts, &renames, &told);
            }
        }
    }
    if (!sameDialect(nl, g)) try topology.check(ir.big, arena, nl, g, report);
    const filled = try w.fill(nl.stmts, nl.stmts);
    if (!std.mem.eql(u8, nl.dialect, g.name)) {
        try w.check(g, filled);
        if (caps) |c| for (c.grammars) |*sg| {
            if (std.mem.eql(u8, sg.name, nl.dialect)) try w.check(sg, filled);
        };
    }
    var gathered = try ir.gatherSteps(arena, filled);
    if (g.canWrite(.step)) w.checkSteps(gathered);
    // Before the alters are laid out, so a run that changes no temperature
    // is at the source's.
    if (try defaultOptions(arena, g, nl)) |d| {
        var names: std.ArrayList(u8) = .empty;
        for (schema.info(.options).slots, 0..) |sl, i| if (d.at(i) != .none) {
            try names.print(arena, "{s}{s}", .{ if (names.items.len > 0) ", " else "", sl.name });
        };
        report.add(.warning, .caveat, 0, "options: {s} assumes other defaults for {s} than {s} does; they are written out", .{ nl.dialect, names.items, g.name });
        const list = try arena.alloc(ir.Stmt, gathered.len + 1);
        list[0] = d;
        @memcpy(list[1..], gathered);
        gathered = list;
    }
    var stmts = try w.applyMoves(try alter.prepare(arena, g, gathered, report));
    if (g.converts.len > 0 and anyConverted(g, stmts)) {
        const list = try arena.dupe(ir.Stmt, stmts);
        try expr.convert(arena, g, list, true);
        stmts = list;
    }
    if (g.blockOf(.model) != null) stmts = try groupBins(arena, stmts);
    stmts = try stats.prepare(arena, g, nl.dialect, stmts, report);
    stmts = try pzPorts(arena, &w, stmts, report);
    stmts = try idleCeilings(arena, stmts, report);
    var n_analyses: usize = 0;
    for (stmts) |*s| if (schema.info(s.kind).class == .analysis and s.kind != .alter) {
        n_analyses += 1;
        w.sole = s;
    };
    if (n_analyses != 1) w.sole = null;
    if (!g.canWrite(.cond_if) and env == null and !std.mem.eql(u8, nl.dialect, g.name)) {
        if (try w.foreignInstance(stmts)) |x| w.foreign_inst = .{ .line = x.line, .name = x.get("name").atom, .master = x.get("master").atom };
    }
    if (!g.canWrite(.cond_if)) {
        try w.noteSplits(stmts);
        // ponytail: each file of a project works the environment's out again; once a project if a PDK has thousands.
        if (env) |e| try w.noteSplits(e.conditional.items);
    }
    for (stmts) |*s| {
        if (g.wrapOf(s.kind) == null) try w.stmt(s);
    }
    for (g.wraps) |*wr| {
        // A control block runs in order (VACASK), so settings come before
        // every analysis: SPICE applies them wherever they stand.
        var any = false;
        for ([_]bool{ false, true }) |analyses| for (stmts) |*s| {
            if (g.wrapOf(s.kind) != wr or (schema.info(s.kind).class == .analysis) != analyses) continue;
            if (!any) try w.line(wr.open);
            any = true;
            try w.stmt(s);
        };
        if (any) try w.line(wr.close);
    }
    if (g.lex.end_marker.len > 0 and !nl.library) try w.line(g.lex.end_marker);
    w.refusals();
    w.keptNote();
    w.foreignNote();
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
    if (report.lost) return error.OutOfMemory;
}

// ------------------------------------------------------------- streaming

/// The references a netlist read as a stream makes (`.dc X`, `F1 a b X`):
/// every name in a reference slot, gathered before writing, and those of
/// them a device has been met with so far.
pub const Refs = struct {
    wanted: ir.CaselessSet = .empty,
    found: ir.CaselessSet = .empty,
    /// Entries saying a name is no device, made before such a device came.
    pending: std.ArrayList(struct { at: usize, name: []const u8 }) = .empty,

    /// Every name in a reference slot of `stmts`.
    pub fn want(r: *Refs, k: ir.Keep, stmts: []const ir.Stmt) Allocator.Error!void {
        for (stmts) |*s| {
            for (schema.info(s.kind).slots, 0..) |sl, i| {
                if (sl.ty == .ref and s.at(i) == .atom) try ir.putName(&r.wanted, k.perm, k.src, s.at(i).atom);
            }
            try r.want(k, s.body);
        }
    }

    /// The devices of `stmts` whose names are wanted.
    fn add(r: *Refs, k: ir.Keep, stmts: []const ir.Stmt) Allocator.Error!void {
        if (r.wanted.count() == 0) return;
        for (stmts) |*s| {
            if (schema.info(s.kind).class == .device and s.get("name") == .atom and r.wanted.contains(s.get("name").atom))
                try ir.putName(&r.found, k.perm, k.src, s.get("name").atom);
            try r.add(k, s.body);
        }
    }

    /// Withdraw the entries a device met later answers.
    fn settle(r: *Refs, report: *ir.Report) void {
        var drop = r.pending.items;
        var n: usize = 0;
        var j: usize = 0;
        for (report.items.items, 0..) |d, i| {
            if (j < drop.len and drop[j].at == i) {
                defer j += 1;
                if (r.found.contains(drop[j].name)) continue;
            }
            report.items.items[n] = d;
            n += 1;
        }
        report.items.shrinkRetainingCapacity(n);
        drop = &.{};
    }
};

/// What writing needs to know of the whole netlist before its first
/// statement, when the statements come one at a time (`stream.zig`
/// gathers it in a pass of its own). Names are in `perm` or the source.
pub const Survey = struct {
    title: []const u8 = "",
    dialect: []const u8,
    library: bool = false,
    folds_case: bool = false,
    declared: std.StringHashMapUnmanaged(void) = .empty,
    families: std.StringHashMapUnmanaged([]const u8) = .empty,
    funcs: expr.Funcs = .empty,
    used: [schema.kind_count]bool = @splat(false),
    fams: [schema.families.len]bool = @splat(false),
    models: ir.CaselessSet = .empty,
    subckts: ir.CaselessSet = .empty,
    /// One statement per `default` source the target's grammar names,
    /// holding the first value of it in the netlist.
    fill_from: std.ArrayList(ir.Stmt) = .empty,
    /// The top-level option statements, as a netlist read whole has them.
    options: []ir.Stmt = &.{},
    /// The subcircuits an instance names before their definitions come.
    early: std.ArrayList(ir.Stmt) = .empty,
    /// Top-level analyses.
    analyses: usize = 0,
    /// `collectAnalyses`.
    counted: std.ArrayList(Analysis) = .empty,
    /// Two names differing only by case may be in it: the check runs.
    check_case: bool = true,
    facts: topology.Facts = .{},
    globals: std.ArrayList([]const u8) = .empty,
    refs: Refs = .{},
    /// `collectReserved`.
    reserved: ir.CaselessSet = .empty,
    /// `collectIcNodes`.
    ic_nodes: ir.CaselessSet = .empty,
    /// `collectTerminals`.
    terminals: TerminalMap = .empty,

    /// Learn what `stmts`, the next top-level statements, hold.
    /// Keeps the value of `slot` on the netlist's first statement of `kind`
    /// that has one, for `fill`.
    fn takeFirst(sv: *Survey, k: ir.Keep, stmts: []const ir.Stmt, kind: Kind, slot: u8) Allocator.Error!void {
        for (sv.fill_from.items) |*s| {
            if (s.kind == kind and s.at(slot) != .none) return;
        }
        const v = firstValue(stmts, kind, slot) orelse return;
        var st = try ir.newStmt(k.perm, kind, 0);
        try st.set(k.perm, slot, try ir.cloneValue(k, v));
        try sv.fill_from.append(k.perm, st);
    }

    /// `gf`: the grammar the netlist is read with.
    pub fn add(sv: *Survey, g: *const Grammar, gf: *const Grammar, k: ir.Keep, stmts: []const ir.Stmt) Allocator.Error!void {
        const a = k.perm;
        try collectDeclared(a, stmts, &sv.declared);
        try ir.collectFamilies(a, stmts, &sv.families, k.src);
        try collectFuncs(a, stmts, &sv.funcs);
        markUsed(stmts, &sv.used);
        markCapParts(g, sv.dialect, stmts, &sv.used);
        try collectIcNodes(a, stmts, &sv.ic_nodes, k.src);
        ir.markFamilies(stmts, &sv.fams);
        try collectMasters(a, stmts, &sv.models, &sv.subckts, k.src);
        try collectTerminals(a, stmts, &sv.terminals, k.src);
        try collectReserved(a, g, stmts, &sv.reserved, k.src);
        for (g.fills) |f| try sv.takeFirst(k, stmts, f.from, f.from_slot);
        for (gf.omitted) |o| for (o.terms) |t| {
            if (t == .first) try sv.takeFirst(k, stmts, t.first.kind, t.first.slot);
        };
        for (stmts) |*s| {
            if (schema.info(s.kind).class == .analysis and s.kind != .alter) sv.analyses += 1;
        }
        try collectAnalyses(a, g, stmts, &sv.counted);
        sv.facts.add(stmts);
        try sv.addGlobals(k, stmts);
        try sv.refs.want(k, stmts);
    }

    fn addGlobals(sv: *Survey, k: ir.Keep, stmts: []const ir.Stmt) Allocator.Error!void {
        for (stmts) |*s| {
            if (s.kind == .global and s.get("nodes") == .list) {
                for (s.get("nodes").list) |v| if (v == .atom) try sv.globals.append(k.perm, try k.text(v.atom));
            }
            try sv.addGlobals(k, s.body);
        }
    }
};

/// A netlist written as it is read: `group` is given the top-level
/// statements a few at a time, as the reader makes them, and each pass of
/// `write` runs on them before the next come. What the passes need of the
/// whole netlist is in the `Survey`; constructs whose passes need the
/// statements themselves are written whole instead (`stream.zig` says
/// which). Report entries come in pass order once `stream.zig` sorts them.
pub const Stream = struct {
    w: Writer,
    nl: ir.Netlist,
    keep: ir.Keep,
    foreign: bool,
    case: bool = false,
    seen: CaseMaps = .{},
    params: ir.CaselessSet = .empty,
    renames: CaselessMap = .empty,
    told: ir.CaselessSet = .empty,
    /// `reservedRenames`, and those of them reported.
    param_renames: CaselessMap = .empty,
    param_told: ir.CaselessSet = .empty,
    models: ir.CaselessSet = .empty,
    subckts: ir.CaselessSet = .empty,
    clashed: ir.CaselessSet = .empty,
    topo: ?topology.Stream = null,
    fill_from: []const ir.Stmt = &.{},
    source: ?*const Grammar = null,
    analyses: usize = 0,
    wrapped: std.ArrayList(ir.Stmt) = .empty,
    refs: Refs = .{},
    lower: ?stats.Stream = null,
    /// How many `dev/gauss=` are random functions now (`stats.asFunctions`).
    functions: usize = 0,

    /// Everything before the first statement: title, header, boilerplate
    /// and the options the source's dialect assumes. In place: the writer
    /// points into it.
    pub fn begin(s: *Stream, g: *const Grammar, k: ir.Keep, out: *std.Io.Writer, sv: *Survey, report: *ir.Report, caps: ?*const Caps, env: ?*const ir.Env) Writer.Error!void {
        const perm = k.perm;
        s.* = .{
            .w = .{ .g = g, .arena = perm, .perm = perm, .out = out, .report = report, .caps = caps, .source = sv.dialect, .scratch = .init(ir.big) },
            .nl = .{ .title = sv.title, .dialect = sv.dialect, .library = sv.library, .folds_case = sv.folds_case },
            .keep = k,
            .foreign = !std.mem.eql(u8, sv.dialect, g.name),
            .fill_from = sv.fill_from.items,
            .analyses = sv.analyses,
            .refs = sv.refs,
            .lower = stats.Stream.init(k, g, report),
        };
        errdefer s.deinit();
        const w = &s.w;
        w.refs = &s.refs;
        const nl = &s.nl;
        w.declared = sv.declared;
        w.families = sv.families;
        w.env = env;
        w.funcs = sv.funcs;
        w.ic_nodes = sv.ic_nodes;
        w.terminals = sv.terminals;
        if (env) |e| {
            var it = e.declared.keyIterator();
            while (it.next()) |n| try w.declared.put(perm, try std.ascii.allocLowerString(perm, n.*), {});
            var fi = e.funcs.keyIterator();
            while (fi.next()) |n| try w.funcs.put(perm, n.*, {});
        }
        // The netlist's own make it be written whole (`stream.zig`).
        if (env) |e| if (!g.canWrite(.cond_if)) try w.noteSplits(e.conditional.items);
        const fold_header = g.header_folded.len > 0 and (nl.folds_case or
            if (sprack.find(nl.dialect)) |sg| !sg.lex.case_sensitive else false);
        s.case = (!g.lex.case_sensitive or fold_header) and sv.check_case;
        if (g.lex.title and !nl.library) {
            try out.print("{s}{s}\n", .{ g.lex.title_prefix, if (nl.title.len > 0) nl.title else "untitled" });
        }
        for (if (fold_header) g.header_folded else g.header) |l| try w.line(l);
        if (!nl.library) {
            var used: [schema.kind_count]bool = if (env) |e| e.used else @splat(false);
            for (&used, sv.used) |*u, x| u.* = u.* or x;
            const said = if (g.preamble_unless) |pk| used[@backingInt(pk)] else false;
            if (!said) for (g.preamble) |l| try w.line(l);
            var fams: [schema.families.len]bool = if (env) |e| e.families else @splat(false);
            for (&fams, sv.fams) |*f, x| f.* = f.* or x;
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
        if (s.foreign and g.unique_master.len > 0) {
            s.renames = try renamesOf(perm, &sv.models, &sv.subckts, env);
            // A renamed model is declared under the name it is written as.
            var ri = s.renames.valueIterator();
            while (ri.next()) |v| try w.declared.put(perm, try std.ascii.allocLowerString(perm, v.*), {});
            // What `uniqueMasters` finds after the renames.
            var it = sv.models.keyIterator();
            while (it.next()) |m| try s.models.put(perm, s.renames.get(m.*) orelse m.*, {});
            try s.subckts.ensureUnusedCapacity(perm, sv.subckts.count());
            var si = sv.subckts.keyIterator();
            while (si.next()) |n| try s.subckts.put(perm, n.*, {});
            if (env) |e| {
                var mi = e.models.keyIterator();
                while (mi.next()) |m| try s.models.put(perm, ir.binBase(m.*) orelse m.*, {});
                var ei = e.subckts.keyIterator();
                while (ei.next()) |n| try s.subckts.put(perm, n.*, {});
            }
        }
        if (s.foreign) {
            report.phase = ir.Phase.params;
            try uniqueAnalyses(perm, g, sv.counted.items, report);
            s.param_renames = try reservedRenames(perm, g, &sv.reserved, env);
        }
        if (!std.mem.eql(u8, nl.dialect, g.name))
            s.topo = try topology.Stream.init(ir.big, perm, g, report, k.src, nl.library, sv.facts, sv.globals.items, sv.early.items);
        if (caps) |c| for (c.grammars) |*sg| {
            if (std.mem.eql(u8, sg.name, nl.dialect)) s.source = sg;
        };
        var opts = nl.*;
        opts.stmts = sv.options;
        report.phase = ir.Phase.options;
        if (try defaultOptions(perm, g, &opts)) |d| {
            var names: std.ArrayList(u8) = .empty;
            for (schema.info(.options).slots, 0..) |sl, i| if (d.at(i) != .none) {
                try names.print(perm, "{s}{s}", .{ if (names.items.len > 0) ", " else "", sl.name });
            };
            report.add(.warning, .caveat, 0, "options: {s} assumes other defaults for {s} than {s} does; they are written out", .{ nl.dialect, names.items, g.name });
            const one = try perm.dupe(ir.Stmt, &.{d});
            try s.tail(one);
        }
    }

    /// The next top-level statements, read and resolved; made in `arena`,
    /// which may be freed once this returns.
    pub fn group(s: *Stream, arena: Allocator, stmts_in: []ir.Stmt) Writer.Error!void {
        const w = &s.w;
        const g = w.g;
        const report = w.report;
        w.arena = arena;
        defer w.arena = s.keep.perm;
        var stmts = stmts_in;
        if (s.foreign and w.foreign_inst == null and !g.canWrite(.cond_if) and w.env == null) {
            if (try w.foreignInstance(stmts)) |x| w.foreign_inst = .{ .line = x.line, .name = try s.keep.text(x.get("name").atom), .master = try s.keep.text(x.get("master").atom) };
        }
        try s.refs.add(s.keep, stmts);
        report.phase = ir.Phase.case;
        if (s.case) try checkCase(stmts, &s.seen, report, g.name, s.keep);
        if (s.foreign) {
            report.phase = ir.Phase.params;
            if (g.unique_param.len > 0) try uniqueParamsIn(stmts, &s.params, s.keep, report, g);
            if (g.unique_master.len > 0) {
                report.phase = ir.Phase.renames;
                if (s.renames.count() > 0) stmts = try renameMasters(w, stmts, &s.renames, &s.told);
                report.phase = ir.Phase.masters;
                try clashes(s.keep.perm, stmts, &s.models, &s.subckts, &s.clashed, report, g);
            }
            if (s.param_renames.count() > 0) stmts = try renameParams(w, stmts, &s.param_renames, &s.param_told);
        }
        report.phase = ir.Phase.topology;
        if (s.topo) |*t| try t.group(stmts);
        report.phase = ir.Phase.fill;
        const filled = try w.fill(stmts, s.fill_from);
        if (s.foreign) {
            report.phase = ir.Phase.checks;
            try w.check(g, filled);
            report.phase = ir.Phase.checks_source;
            if (s.source) |sg| try w.check(sg, filled);
        }
        try s.tail(filled);
    }

    /// The passes after the options are laid out, and the writing itself.
    fn tail(s: *Stream, in: []const ir.Stmt) Writer.Error!void {
        const w = &s.w;
        const g = w.g;
        const a = w.arena;
        var stmts = in;
        if (g.converts.len > 0 and anyConverted(g, stmts)) {
            const list = try a.dupe(ir.Stmt, stmts);
            try expr.convert(a, g, list, true);
            stmts = list;
        }
        if (g.blockOf(.model) != null) stmts = try groupBins(a, stmts);
        // `stats.prepare`, but for the statistics blocks it folds, and
        // `pzPorts`: what those would change makes the netlist be written
        // whole (`stream.zig`).
        w.report.phase = ir.Phase.devlot;
        if (stats.devLots(g, s.nl.dialect) and stats.usesDevLot(stmts)) stmts = try stats.devLot(a, stmts, w.report, &s.functions);
        w.report.phase = ir.Phase.stats;
        stats.checkReserved(g, stmts, w.report);
        if (s.lower) |*l| stmts = try l.group(a, stmts);
        try s.last(stmts);
    }

    /// The last pass and the writing itself.
    fn last(s: *Stream, in: []const ir.Stmt) Writer.Error!void {
        const w = &s.w;
        const g = w.g;
        w.report.phase = ir.Phase.ceilings;
        const stmts = try idleCeilings(w.arena, in, w.report);
        w.report.phase = ir.Phase.write;
        for (stmts) |*st| {
            if (g.wrapOf(st.kind) != null) {
                try s.wrapped.append(s.keep.perm, try ir.cloneStmt(s.keep, st));
                continue;
            }
            s.sole(st);
            try w.stmt(st);
        }
    }

    fn sole(s: *Stream, st: *const ir.Stmt) void {
        if (s.analyses == 1 and schema.info(st.kind).class == .analysis and st.kind != .alter) s.w.sole = st;
    }

    /// Everything after the last statement. `rescan` gives the topology
    /// check every group again when the top level has islands:
    /// `rescan.run(topology.Stream.cross, *topology.Stream)`.
    pub fn end(s: *Stream, rescan: anytype) Writer.Error!void {
        const w = &s.w;
        const g = w.g;
        const report = w.report;
        report.phase = ir.Phase.stats;
        stats.asFunctions(g, s.functions, report);
        if (s.lower) |*l| try s.last(try l.end(w.arena));
        report.phase = ir.Phase.write;
        for (g.wraps) |*wr| {
            // A control block runs in order (VACASK), so settings come before
            // every analysis: SPICE applies them wherever they stand.
            var any = false;
            for ([_]bool{ false, true }) |analyses| for (s.wrapped.items) |*st| {
                if (g.wrapOf(st.kind) != wr or (schema.info(st.kind).class == .analysis) != analyses) continue;
                if (!any) try w.line(wr.open);
                any = true;
                s.sole(st);
                try w.stmt(st);
            };
            if (any) try w.line(wr.close);
        }
        if (g.lex.end_marker.len > 0 and !s.nl.library) try w.line(g.lex.end_marker);
        report.phase = ir.Phase.caveat;
        w.refusals();
        w.keptNote();
        w.foreignNote();
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
        if (s.topo) |*t| {
            report.phase = ir.Phase.topology;
            if (try t.islands()) try rescan.run(topology.Stream.cross, t);
            try t.end();
        }
        s.refs.settle(report);
    }

    /// The tables outside the arena: after `end`, or an error after `begin`
    /// (which frees them itself when it fails).
    pub fn deinit(s: *Stream) void {
        if (s.topo) |*t| t.deinit();
        s.params.deinit(ir.big);
        s.seen.deinit();
        s.w.scratch.deinit();
    }
};
