//! Emitter: one statement and one pattern of the target's grammar → the
//! statement's text, with what the pattern has no place for counted and
//! reported. `Caps` says which other dialects could have written it.
//!
//! Contents:
//! - `pub const Caps = struct`
//! - `pub const Emit = struct`
//! - `pub fn reasonFor(arena: Allocator, text: []const u8, to: []const u8) Allocator.Error![]const u8`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const expr = @import("expr");
const reader = @import("reader");
const tables = @import("tables.zig");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Node = grammar.Node;
const Value = ir.Value;
const spellingsOf = tables.spellingsOf;
const idleCeiling = tables.idleCeiling;

/// A grammar's reason with `{to}` in it replaced by the dialect being
/// written; the text itself where it has no such place.
pub fn reasonFor(arena: Allocator, text: []const u8, to: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, text, "{to}") == null) return text;
    return std.mem.replaceOwned(u8, arena, text, "{to}", to);
}

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
            if (std.mem.eql(u8, f.family, fam) and std.mem.eql(u8, f.polarity, pol))
                return f.dialects;
        }
        return "";
    }
};

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

    pub fn valueText(e: *Emit, v: Value, quoted: bool) Allocator.Error![]const u8 {
        const cfg = &e.g.lex;
        // The values a device line is made of need no writer: a name is its
        // own text, and a number or an expression is at most one copy.
        switch (v) {
            .none => return "",
            .atom => |s| return if (quoted) std.mem.concat(e.arena, u8, &.{ "\"", s, "\"" }) else s,
            .num => |n| if (n.exp10 == 0) return n.digits(),
            .expr => |canon| {
                const s = try e.exprText(canon);
                // A bracketed vector a SPICE reader kept as text
                // (`hblin=[1, -1]`) is written as it was, not as arithmetic.
                if (s.len >= 2 and s[0] == '[' and s[s.len - 1] == ']') return s;
                if (cfg.bare_expr) {
                    const needs_parens = std.mem.indexOfAny(u8, s, " \t") != null;
                    return if (needs_parens) std.mem.concat(e.arena, u8, &.{ "(", s, ")" }) else s;
                }
                if (cfg.expr_delims.len == 0) return s;
                return std.mem.concat(
                    e.arena,
                    u8,
                    &.{ cfg.expr_delims[0][0], s, cfg.expr_delims[0][1] },
                );
            },
            .str => |s| return std.mem.concat(e.arena, u8, &.{ "\"", s, "\"" }),
            .list, .params => {},
        }
        var aw: std.Io.Writer.Allocating = .init(e.arena);
        const w = &aw.writer;
        switch (v) {
            .none, .atom, .expr, .str => unreachable,
            .num => |n| lexer.renderNumber(w, cfg, n) catch return error.OutOfMemory,
            .list => |items| for (items, 0..) |it, i| {
                if (i > 0) w.writeByte(' ') catch return error.OutOfMemory;
                w.writeAll(try e.valueText(it, false)) catch return error.OutOfMemory;
            },
            .params => |ps| for (ps, 0..) |p, i| {
                if (i > 0) w.writeByte(' ') catch return error.OutOfMemory;
                e.checkNumber(p);
                if (p.val == .none) {
                    w.writeAll(p.key) catch return error.OutOfMemory;
                } else w.print("{s}={s}", .{ p.key, try e.valueText(p.val, false) }) catch
                    return error.OutOfMemory;
            },
        }
        return aw.written();
    }

    /// A canonical expression in this dialect's spelling, with what it
    /// cannot say (an error) and what it says differently (a caveat) reported.
    /// A function the target lacks, said by what the source means by it
    /// (`means`), one note a rewrite.
    pub fn meant(e: *Emit, canon_in: []const u8) Allocator.Error![]const u8 {
        const sg = e.sourceGrammar() orelse return canon_in;
        var canon = canon_in;
        for (sg.means) |*m| {
            if (m.kind != null and m.kind.? != e.st.kind) continue;
            // A line for this kind wins over the general one.
            const specific = m.kind != null or for (sg.means) |o| {
                if (o.kind != null and o.kind.? == e.st.kind and std.mem.eql(u8, o.canon, m.canon))
                    break false;
            } else true;
            if (!specific) continue;
            if (spellingsOf(e.g.functions, m.canon) != null or !expr.uses(canon, m.canon)) continue;
            var n: usize = 0;
            const out = try expr.applyMeans(e.arena, canon, m, &n);
            if (n == 0) continue;
            if (!e.quiet)
                e.report.add(.info, .oneway, e.st.line, "expression '{s}': {s} has no {s}; " ++
                    "written as what {s} means by it, {s}; it reads back in that form", .{
                    canon_in, e.g.name, m.canon, sg.name, m.body,
                });
            canon = out;
        }
        return canon;
    }

    pub fn exprText(e: *Emit, canon_in: []const u8) Allocator.Error![]const u8 {
        var problems: std.ArrayList(expr.Problem) = .empty;
        const canon = if (e.foreign) try e.meant(canon_in) else canon_in;
        const s = try expr.write(e.arena, e.g, canon, e.funcs, e.foreign, &problems);
        // What the source's functions mean differently, as it wrote them,
        // but for those written as what they mean (`means`).
        e.semantics(canon_in, canon);
        if (!e.quiet) for (problems.items) |pb| {
            if (pb.kind == .form) {
                e.report.add(.info, .oneway, e.st.line, "expression '{s}': {s} has no {s}, so " ++
                    "the choice is written {s}; it reads back in that form", .{
                    canon,                                                              e.g.name,
                    if (std.mem.eql(u8, pb.text, "if"))
                        "?: operator"
                    else
                        "if() function",
                    if (std.mem.eql(u8, pb.text, "if")) "if(c, a, b)" else "c ? a : b",
                });
                continue;
            }
            if (pb.kind == .shadowed) {
                e.report.add(
                    .@"error",
                    .invalid,
                    e.st.line,
                    "expression '{s}': the parameter '{s}' is a variable of {s} under that " ++
                        "name, which takes the word for the variable; give the parameter " ++
                        "another name",
                    .{ canon, pb.text, e.g.name },
                );
                continue;
            }
            const who = if (e.caps) |c| c.word(pb.text) else "";
            e.report.add(.@"error", .unsupported, e.st.line, "expression '{s}': {s} '{s}' has " ++
                "no spelling in {s}{s}{s}", .{
                canon,                                                @tagName(pb.kind), pb.text, e.g.name,
                if (who.len > 0) ". Dialects that have it: " else "", who,
            });
        };
        return s;
    }

    /// The items of a `[...]` vector, with the dialect's separator.
    pub fn vectorText(e: *Emit, v: Value) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (v.list, 0..) |it, i| {
            if (i > 0) try out.appendSlice(e.arena, e.g.lex.vector_sep);
            try out.appendSlice(e.arena, try e.valueText(it, false));
        }
        return out.items;
    }

    /// `version=3.3.0`: one simulator's lenient reading of a malformed
    /// number is no other's.
    pub fn checkNumber(e: *Emit, p: ir.Param) void {
        const raw: []const u8 = switch (p.val) {
            .atom => |x| x,
            .expr => |x| x,
            .str => |x| x,
            else => "",
        };
        if (e.foreign and !e.quiet and e.g.lex.strict_numbers and malformedNumber(raw)) {
            e.report.add(
                .@"error",
                .invalid,
                e.st.line,
                "{s}={s} is not a number; {s} does not read it",
                .{ p.key, raw, e.g.name },
            );
        }
    }

    /// A function or operator that one side of a translation evaluates
    /// differently (`differs` in either grammar): a caveat, never silence.
    /// `written`: `canon` as it is written, functions the target lacks said
    /// by what they mean; a function gone from it is not a caveat, and
    /// one the meaning brought in is the meaning's, not the source's.
    pub fn semantics(e: *Emit, canon: []const u8, written: []const u8) void {
        if (e.quiet or !e.foreign) return;
        for ([_]?*const Grammar{ e.g, e.sourceGrammar() }) |og| {
            const g = og orelse continue;
            for (g.differs) |d| {
                if (expr.uses(canon, d.canon) and expr.uses(written, d.canon)) {
                    e.report.add(
                        .warning,
                        .caveat,
                        e.st.line,
                        "expression '{s}': {s} in {s}: {s}",
                        .{ canon, d.canon, g.name, d.text },
                    );
                }
            }
        }
    }

    /// The built-in grammar the statement was read with, if any.
    pub fn sourceGrammar(e: *const Emit) ?*const Grammar {
        const c = e.caps orelse return null;
        for (c.grammars) |*g| if (std.mem.eql(u8, g.name, e.source)) return g;
        return null;
    }

    /// A value as shown in messages: no dialect delimiters around it.
    pub fn signalText(e: *Emit, canon: []const u8) Allocator.Error!?[]const u8 {
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
                if (i + 1 < sf.template.len and sf.template[i + 1] >= '1' and
                    sf.template[i + 1] <= '3')
                {
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
    pub fn slotText(e: *Emit, idx: u8, quoted: bool) Allocator.Error!?[]const u8 {
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
                    if (!std.mem.eql(u8, pr.canon, v.atom) and !e.quiet)
                        e.report.add(
                            .info,
                            .oneway,
                            e.st.line,
                            "{s}.{s} = {s} is written as {s}, which reads back as {s}",
                            .{ @tagName(e.st.kind), sl.name, v.atom, sp, pr.canon },
                        );
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
                        const body = try expr.write(
                            e.arena,
                            e.g,
                            it.expr,
                            e.funcs,
                            e.foreign,
                            &problems,
                        );
                        if (problems.items.len > 0) {
                            e.why = try e.arena.print("the signal expression {s}", .{it.expr});
                            return null;
                        }
                        const pct = std.mem.indexOfScalar(u8, tmpl, '%').?;
                        try out.print(
                            e.arena,
                            "{s}{s}{s}",
                            .{ tmpl[0..pct], body, tmpl[pct + 1 ..] },
                        );
                    }
                } else try out.appendSlice(e.arena, try e.valueText(it, false));
            }
            return out.items;
        }
        return try e.valueText(v, quoted);
    }

    pub fn describe(e: *Emit, v: Value) Allocator.Error![]const u8 {
        return switch (v) {
            .expr => |s| s,
            .params => |ps| blk: {
                var out: std.ArrayList(u8) = .empty;
                for (ps, 0..) |p, i| {
                    if (i > 0) try out.append(e.arena, ' ');
                    if (p.val == .none)
                        try out.appendSlice(e.arena, p.key)
                    else
                        try out.print(e.arena, "{s}={s}", .{ p.key, try e.describe(p.val) });
                }
                break :blk out.items;
            },
            else => e.valueText(v, false),
        };
    }

    /// Default text may refer to other slots (`$stop`) and to the ordinal of
    /// this statement among its kind (`$#`).
    pub fn expandDefault(e: *Emit, text: []const u8) Allocator.Error![]const u8 {
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
                while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_'))
                    j += 1;
                const v = if (schema.slotIndex(e.st.kind, text[i + 2 .. j])) |si|
                    e.st.at(si)
                else
                    Value.none;
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
                    .num => |n| if (n.exp10 == 0)
                        n.digits()
                    else
                        try e.arena.print("{s}e{d}", .{ n.digits(), n.exp10 }),
                    else => try e.valueText(v, false),
                };
                try out.appendSlice(e.arena, raw);
            } else try out.appendSlice(e.arena, text[i..j]);
            i = j;
        }
        return out.toOwnedSlice(e.arena);
    }

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
            },
            .cap => {
                if (n.slot == grammar.wild_slot) {
                    try e.tok(try e.expandDefault(n.default));
                    return true;
                }
                if (!e.given(n.slot)) {
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
                // A module's letter (Xyce `Y<module>`) is part of the form,
                // not a new name.
                if (n.prefix.len > 0 and !std.mem.eql(u8, e.slot(n.slot).name, "name")) {
                    text = try e.arena.print(
                        "{c}{s}{s}",
                        .{ std.ascii.toUpper(n.prefix[0]), n.prefix[1..], text },
                    );
                } else if (n.prefix.len > 0 and !std.ascii.startsWithIgnoreCase(text, n.prefix)) {
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
                                    if (tv == .atom)
                                        e.why = try e.arena.print(
                                            "{s} = {s}",
                                            .{ e.slot(b.tag_slot).name, tv.atom },
                                        );
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
                                    if (e.g.lex.bare_expr)
                                        try e.arena.print("[{s}]", .{try e.vectorText(p.val)})
                                    else
                                        try e.vectorText(p.val)
                                else
                                    try e.valueText(p.val, false);
                                if (b.form == .call) {
                                    try e.tok(
                                        try e.arena.print("{s}({s})={s}", .{ b.key, p.key, vt }),
                                    );
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
                                for (try e.valueText(p.val, false)) |c|
                                    if (c != ' ') try out.append(e.arena, c);
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
                                try e.tok(
                                    try e.arena.print(
                                        "{s}=[{s}{s}{s}]",
                                        .{ b.key, first, if (sep.len > 0) sep else " ", second },
                                    ),
                                );
                            } else try e.tok(try e.arena.print("{s}={s}", .{ b.key, first }));
                            e.mark(b.slot);
                            if (e.present(b.slot2)) e.mark(b.slot2);
                        },
                        .plain, .quoted, .vector => {
                            if (b.required and !e.bound(b.slot)) {
                                if (e.why.len == 0)
                                    e.why = try e.arena.print(
                                        "a statement without '{s}'",
                                        .{e.slot(b.slot).name},
                                    );
                                return false;
                            }
                            if (!e.bound(b.slot) and b.default.len > 0 and e.foreign) {
                                // What the source's simulator assumes and this one does not.
                                const raw = try e.expandDefault(b.default);
                                const made: Value = if (lexer.parseNumber(
                                    e.arena,
                                    &e.g.lex,
                                    raw,
                                )) |num| .{ .num = num } else .{ .expr = raw };
                                // Not a ceiling that would be dropped had the source given it.
                                if (idleCeiling(e.st, b.slot, made)) continue;
                                const text = try e.valueText(made, false);
                                try e.tok(try e.arena.print("{s}={s}", .{ b.key, text }));
                                if (!e.quiet)
                                    e.report.add(
                                        .warning,
                                        .synthesized,
                                        e.st.line,
                                        "{s}: {s} needs '{s}' to behave as {s} does without " ++
                                            "it; wrote {s}",
                                        .{
                                            @tagName(e.st.kind), e.g.name, e.slot(b.slot).name, e.source, text,
                                        },
                                    );
                                continue;
                            }
                            // An earlier line of this statement wrote the slot.
                            const before = b.also and b.slot < 64 and e.hide & (@as(
                                u64,
                                1,
                            ) << @intCast(b.slot)) != 0;
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
                                if (o.form == .plain and !o.also and o.slot != b.slot and
                                    e.isUsed(o.slot) and std.mem.eql(
                                    u8,
                                    o.key,
                                    b.key,
                                )) break o.slot;
                            } else null;
                            if (twin) |t| {
                                if (!e.val(t).eql(e.val(b.slot)) and !e.quiet)
                                    e.report.add(.@"error", .loss, e.st.line, "{s}: {s} = {s} " ++
                                        "and {s} = {s} are both '{s}' in {s}; the first is " ++
                                        "written", .{
                                        @tagName(e.st.kind),           e.slot(t).name, try e.describe(e.val(t)), e.slot(b.slot).name,
                                        try e.describe(e.val(b.slot)), b.key,          e.g.name,
                                    });
                                e.mark(b.slot);
                                continue;
                            }
                            // `gmin=gmindc` after `gmin=gmin`: read back, the key fills the other slot.
                            for (n.bag[0..bi]) |o|
                                if (o.form == .plain and !o.also and o.slot != b.slot and
                                    std.mem.eql(
                                        u8,
                                        o.key,
                                        b.key,
                                    ))
                                {
                                    if (!e.quiet)
                                        e.report.add(
                                            .info,
                                            .oneway,
                                            e.st.line,
                                            "{s}.{s} is written as '{s}', which reads back as " ++
                                                "{s}.{s}",
                                            .{
                                                @tagName(e.st.kind),
                                                e.slot(b.slot).name,
                                                b.key,
                                                @tagName(e.st.kind),
                                                e.slot(o.slot).name,
                                            },
                                        );
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
                            else if (b.suffix.len > 0)
                                try e.arena.print(
                                    "\"{s}{s}\"",
                                    .{ (try e.slotText(b.slot, false)) orelse continue, b.suffix },
                                )
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

    pub fn lost(e: *Emit, idx: u8) Allocator.Error!bool {
        if (!e.present(idx) or e.isUsed(idx)) return false;
        // The heading alone carries nothing a foreign dialect needs.
        if (e.foreign and std.mem.eql(u8, e.slot(idx).name, "package")) return false;
        // What this dialect assumes anyway need not be said.
        return !e.isImplied(idx);
    }

    /// Why the source dialect's parameter changes no result (`inert`), if it does not.
    /// Why the source dialect's `key` of this statement changes no result
    /// (its `inert` line), with `{to}` in it the dialect being written.
    pub fn inert(e: *const Emit, key: []const u8) Allocator.Error!?[]const u8 {
        const sg = e.sourceGrammar() orelse return null;
        const text = sg.inertReason(e.st.kind, key) orelse return null;
        return try reasonFor(e.arena, text, e.g.name);
    }

    pub fn lossCount(e: *Emit) Allocator.Error!usize {
        var n: usize = e.lost_flags;
        for (0..schema.info(e.st.kind).slots.len) |i| n += @intFromBool(try e.lost(@intCast(i)));
        return n;
    }

    pub fn reportLosses(e: *Emit) Allocator.Error!void {
        // The target's caveats on writing it, the source's on reading it.
        const src: []const grammar.Caveat = if (e.sourceGrammar()) |sg| sg.caveats else &.{};
        for ([_][]const grammar.Caveat{ e.g.caveats, src }, [_]bool{ false, true }) |cs, read|
            for (cs) |c| {
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
                        e.report.add(
                            .@"error",
                            .invalid,
                            e.st.line,
                            "{s}.{s}: {s}; it is {s} text, written as it was",
                            .{ @tagName(e.st.kind), e.slot(c.slot).name, c.text, e.source },
                        );
                    } else e.report.add(.warning, .caveat, e.st.line, "{s}.{s}: {s}", .{ @tagName(e.st.kind), e.slot(c.slot).name, c.text });
                }
            };
        if (e.lost_flags > 0) {
            for (e.st.values()) |v| {
                if (v != .params) continue;
                for (v.params) |p| {
                    if (p.val == .none)
                        e.report.add(
                            .@"error",
                            .loss,
                            e.st.line,
                            "{s}: the flag '{s}' has no spelling in {s}",
                            .{ @tagName(e.st.kind), p.key, e.g.name },
                        );
                }
            }
        }
        for (0..schema.info(e.st.kind).slots.len) |i| {
            const v = e.st.at(i);
            const idx: u8 = @intCast(i);
            if (!try e.lost(idx)) continue;
            const label = schema.info(e.st.kind).class == .analysis and e.slot(idx).ty == .name;
            if (label) {
                e.report.add(
                    .info,
                    .cosmetic,
                    e.st.line,
                    "{s}: {s} does not name its analyses; the label '{s}' is not written",
                    .{ @tagName(e.st.kind), e.g.name, try e.describe(v) },
                );
                continue;
            }
            if (e.slot(idx).ty == .params and v == .params) {
                // One entry per parameter: each is a separate thing the target cannot say.
                for (v.params) |p| {
                    if (try e.inert(p.key)) |why| {
                        e.report.add(
                            .info,
                            .loss,
                            e.st.line,
                            "{s}: '{s}' is not written: {s}",
                            .{ @tagName(e.st.kind), try e.describe(.{ .params = &.{p} }), why },
                        );
                        continue;
                    }
                    e.report.add(.@"error", .loss, e.st.line, "{s}: '{s}' has no spelling in " ++
                        "{s}", .{
                        @tagName(e.st.kind), try e.describe(.{ .params = &.{p} }), e.g.name,
                    });
                }
                continue;
            }
            const why = e.g.slotAbsentReason(e.st.kind, idx);
            e.report.add(.@"error", .loss, e.st.line, "{s}.{s} = {s} has no spelling in " ++
                "{s}{s}{s}", .{
                @tagName(e.st.kind), e.slot(idx).name, try e.describe(v), e.g.name,
                if (why != null)
                    ": "
                else
                    "",
                why orelse "",
            });
        }
    }
};
