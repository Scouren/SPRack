//! What a dialect assumes and the other must be told: a value one dialect
//! takes from another statement (`default`), a value it works out when
//! none is given (`omitted`), a statement it cannot run as it stands
//! (`invalid`), and a value the target says on another statement (`move`).
//! Each is a pass over the statements: statements in, statements or report
//! entries out.

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const expr = @import("expr");
const tables = @import("tables.zig");
const statement = @import("statement.zig");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Kind = schema.Kind;
const Value = ir.Value;
const takes = tables.takes;
const describeValue = tables.describeValue;
const Writer = statement.Writer;
const Error = Writer.Error;

/// A `move` onto the options, which hold for the whole netlist (HSPICE
/// caps the step of every `.tran` with one DELMAX): the first value
/// goes to the first options statement, a new one where the netlist
/// has none. A statement that says another value keeps it, for the
/// writer to refuse; one that says none is told what it now shares.
pub fn moveToOptions(w: *Writer, list_in: []ir.Stmt, mv: grammar.Move) Allocator.Error![]ir.Stmt {
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
    if (mv.oneway)
        w.report.add(
            .info,
            .oneway,
            said,
            "{s}.{s} is written as {s}.{s}, which reads back there",
            .{ @tagName(mv.from), from, @tagName(mv.to), to },
        );
    for (list) |*s| {
        if (s.kind != mv.from) continue;
        if (s.at(mv.from_slot) == .none) {
            var em = w.emitter(w.arena, s);
            w.report.add(.warning, .caveat, s.line, "{s}.{s} is not given: {s} says it " ++
                "once for the whole netlist ({s}.{s}), so the {s} another {s} gives holds " ++
                "here too", .{
                @tagName(mv.from), from, w.g.name, @tagName(mv.to), to, try em.describe(v), @tagName(mv.from),
            });
        } else if (s.at(mv.from_slot).eql(v)) {
            try s.own(w.arena);
            try s.set(w.arena, mv.from_slot, .none);
        }
    }
    return list;
}

/// A grammar's `invalid` lines, for a netlist crossing into or out of
/// that dialect: a value it leaves out (or gives as zero) means
/// something else there. A slot `before`'s own line already says
/// something about (the source dialect's, checked after) is said once,
/// in the source's words.
pub fn check(
    w: *Writer,
    g: *const Grammar,
    stmts: []const ir.Stmt,
    before: ?*const Grammar,
) Allocator.Error!void {
    for (stmts) |*st| {
        try check(w, g, st.body, before);
        next: for (g.checks) |ck| {
            if (!fires(ck, st)) continue;
            if (before) |o| for (o.checks) |oc| {
                if (oc.slot == ck.slot and fires(oc, st)) continue :next;
            };
            const v = st.at(ck.slot);
            const zero = v == .num and v.num.toFloat() == 0;
            w.report.add(.@"error", .invalid, st.line, "{s}.{s} {s}: {s}", .{
                @tagName(st.kind), schema.info(st.kind).slots[ck.slot].name,
                if (zero)
                    "is 0"
                else
                    "is not given",
                ck.text,
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
pub fn fill(w: *Writer, stmts: []ir.Stmt, all: []const ir.Stmt) Allocator.Error![]ir.Stmt {
    var list: ?[]ir.Stmt = null;
    for (stmts, 0..) |*st, i| {
        var cur = st.*;
        var changed = false;
        if (st.body.len > 0) {
            const b = try fill(w, st.body, all);
            if (b.ptr != st.body.ptr) {
                cur.body = b;
                changed = true;
            }
        }
        const foreign = !std.mem.eql(u8, w.sourceOf(st), w.g.name);
        if (foreign and try omitted(w, w.sourceGrammar(st), st, &cur, all)) changed = true;
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
            w.report.add(.warning, .synthesized, st.line, "{s}.{s} {s}: {s} means the " ++
                "{s}.{s} by that, and {s} needs it said; wrote {s}", .{
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

/// Apply the grammar's `move` lines: values this dialect says on another
/// statement are carried there before anything is written.
pub fn applyMoves(w: *Writer, stmts: []const ir.Stmt) Allocator.Error![]const ir.Stmt {
    if (!anyMove(w, stmts)) return stmts;
    var list = try w.arena.dupe(ir.Stmt, stmts);
    // One value may go to several kinds (`nodeset` onto every analysis),
    // so a source is emptied only after every move has seen it.
    var emptied: std.ArrayList(struct { *ir.Stmt, u8 }) = .empty;
    for (w.g.moves) |mv| {
        if (mv.to == .options) {
            list = try moveToOptions(w, list, mv);
            continue;
        }
        // A value that acts on one analysis only, in a netlist without
        // it: nothing to act on, so not written, and nothing lost.
        const absent = actsOnNothing(w, mv, list);
        for (list) |*src| {
            if (src.kind != mv.from or src.at(mv.from_slot) == .none) continue;
            if (absent) {
                w.report.add(.info, .loss, src.line, "{s}.{s} = {s} is not written: {s} " ++
                    "says it on {s}.{s}, and this netlist has no {s} for it to act on", .{
                    @tagName(mv.from),                         schema.info(mv.from).slots[mv.from_slot].name,
                    try describeValue(
                        w.arena,
                        src.at(mv.from_slot),
                    ),
                    w.g.name,                                  @tagName(mv.to),
                    schema.info(mv.to).slots[mv.to_slot].name, @tagName(mv.to),
                });
                try emptied.append(w.arena, .{ src, mv.from_slot });
                continue;
            }
            var moved = false;
            for (list) |*dst| {
                if (dst.kind != mv.to or dst.at(mv.to_slot) != .none) continue;
                try dst.own(w.arena);
                try dst.set(w.arena, mv.to_slot, src.at(mv.from_slot));
                moved = true;
            }
            if (moved) try emptied.append(w.arena, .{ src, mv.from_slot });
            if (moved and mv.oneway)
                w.report.add(.info, .oneway, src.line, "{s}.{s} is written as {s}.{s}, " ++
                    "which reads back there", .{
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

/// The `omitted` lines of both dialects, for a statement crossing from
/// `sg`'s into this one: a value it leaves to `sg`'s default is written
/// out where this dialect means another by leaving it out (or says
/// nothing), and a zero this dialect reads as left out is written as
/// the line's `zero` value, or cannot be said.
pub fn omitted(
    w: *Writer,
    sg: ?*const Grammar,
    st: *const ir.Stmt,
    cur: *ir.Stmt,
    all: []const ir.Stmt,
) Allocator.Error!bool {
    var changed = false;
    const sl = schema.info(st.kind).slots;
    if (sg) |s| for (s.omitted) |*o| {
        if (omittedLine(s, st, o.slot) != o) continue;
        const v = st.at(o.slot);
        if (v != .none and !(o.zero and isZero(v))) continue;
        if (omittedLine(w.g, st, o.slot)) |t| {
            if (std.mem.eql(
                u8,
                t.text,
                o.text,
            ) and t.given == o.given and (v == .none or t.zero)) continue;
        }
        // Without the slot the formula holds for, the value plays no
        // part (no fall within the run). A target that cannot leave it
        // out (an `invalid` line) is given its own step, which changes
        // nothing before the stop (#75).
        if (o.given != grammar.no_slot and st.at(o.given) == .none) {
            if (!w.g.checksSlot(st.kind, o.slot)) continue;
            // A run with no step (Spectre's `tran stop=`): a hundredth of it.
            const step = firstValue(all, .tran, schema.slot(.tran, "step")) orelse
                try expr.arith(
                    w.arena,
                    .div,
                    firstValue(all, .tran, schema.slot(.tran, "stop")) orelse continue,
                    .{ .num = .init("100", 0) },
                );
            try cur.own(w.arena);
            try cur.set(w.arena, o.slot, step);
            changed = true;
            var em = w.emitter(w.arena, st);
            w.report.add(.warning, .synthesized, st.line, "{s}.{s} is not given: without " ++
                "{s}.{s} {s} means it plays no part within the run, and {s} needs it " ++
                "said; wrote {s}, which changes nothing before the stop", .{
                @tagName(st.kind), sl[o.slot].name, @tagName(st.kind), sl[o.given].name, s.name, w.g.name, try em.describe(step),
            });
            continue;
        }
        const what = try omittedPhrase(w.arena, o);
        var missing: ?Kind = null;
        const val = (try omittedValue(w, s, st, o, all, &missing, 0)) orelse {
            if (missing) |k|
                w.report.add(.@"error", .invalid, st.line, "{s}.{s} {s}: {s} means {s} by " ++
                    "that and {s} does not, and this netlist has no {s} to take it from", .{
                    @tagName(st.kind), sl[o.slot].name,
                    if (v != .none)
                        "is 0"
                    else
                        "is not given",
                    s.name,            what,
                    w.g.name,          @tagName(k),
                });
            continue;
        };
        try cur.own(w.arena);
        try cur.set(w.arena, o.slot, val);
        changed = true;
        var em = w.emitter(w.arena, st);
        w.report.add(.warning, .synthesized, st.line, "{s}.{s} {s}: {s} means {s} by " ++
            "that, and {s} needs it said; wrote {s}", .{
            @tagName(st.kind), sl[o.slot].name,
            if (v != .none)
                "is 0"
            else
                "is not given",
            s.name,            what,
            w.g.name,          try em.describe(val),
        });
    };
    for (w.g.omitted) |*t| {
        if (omittedLine(w.g, st, t.slot) != t) continue;
        const v = cur.at(t.slot);
        const theirs = if (sg) |s| omittedLine(s, st, t.slot) else null;
        if (t.zero and isZero(v) and !(theirs != null and theirs.?.zero)) {
            const what = try omittedPhrase(w.arena, t);
            if (t.zero_as.len == 0) {
                w.report.add(.@"error", .invalid, st.line, "{s}.{s} is 0: {s} reads a 0 " ++
                    "there as not given and takes {s} for it; a 0 cannot be said", .{
                    @tagName(st.kind), sl[t.slot].name, w.g.name, what,
                });
                continue;
            }
            const tiny: Value = if (lexer.parseNumber(w.arena, &w.g.lex, t.zero_as)) |n|
                .{ .num = n }
            else
                .{ .expr = t.zero_as };
            try cur.own(w.arena);
            try cur.set(w.arena, t.slot, tiny);
            changed = true;
            var em = w.emitter(w.arena, st);
            w.report.add(.warning, .synthesized, st.line, "{s}.{s} is 0: {s} reads a 0 " ++
                "there as not given and would take {s}; wrote {s}, which it takes as given", .{
                @tagName(st.kind), sl[t.slot].name, w.g.name, what, try em.describe(tiny),
            });
        } else if (v == .none and theirs == null and
            !(sg != null and sg.?.checksSlot(st.kind, t.slot)))
        {
            // Nothing is assumed of a dialect that does not say.
            w.report.add(.warning, .ambiguous, st.line, "{s}.{s} is not given: {s} takes " ++
                "its own default for it, and what {s} takes is not measured; written as " ++
                "it was", .{
                @tagName(st.kind), sl[t.slot].name, w.g.name, w.sourceOf(st),
            });
        }
    }
    return changed;
}

/// What the `omitted` line `o` of `sg` gives for `st`. Null where the
/// netlist has no statement of a kind it counts from (`missing` names
/// it) or the statement no value for a slot it counts from.
pub fn omittedValue(
    w: *Writer,
    sg: *const Grammar,
    st: *const ir.Stmt,
    o: *const grammar.Omitted,
    all: []const ir.Stmt,
    missing: *?Kind,
    depth: u8,
) Allocator.Error!?Value {
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
            stack[n] = if (v != .none and !(its != null and its.?.zero and isZero(v)))
                v
            else if (its != null and depth < 4)
                (try omittedValue(w, sg, st, its.?, all, missing, depth + 1)) orelse return null
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

/// Whether an `invalid` line holds for this statement.
pub fn fires(ck: grammar.Check, st: *const ir.Stmt) bool {
    if (ck.kind != st.kind) return false;
    if (ck.when_slot != grammar.no_slot) {
        const v = st.at(ck.when_slot);
        if (v != .atom or !std.mem.eql(u8, v.atom, ck.when_atom)) return false;
    }
    const v = st.at(ck.slot);
    const zero = v == .num and v.num.toFloat() == 0;
    return v == .none or (ck.zero and zero);
}

/// Would `applyMoves` change anything? The list it copies can be large.
/// An option this dialect says on one analysis only (`move
/// options.method -> tran.method`), in a netlist with none of that
/// analysis: it acts on nothing.
pub fn actsOnNothing(w: *const Writer, mv: grammar.Move, stmts: []const ir.Stmt) bool {
    if (mv.from != .options or schema.info(mv.to).class != .analysis) return false;
    for (w.g.moves) |o|
        if (o.from == mv.from and o.from_slot == mv.from_slot and ir.countStmts(
            stmts,
            o.to,
        ) > 0) return false;
    return true;
}

pub fn anyMove(w: *const Writer, stmts: []const ir.Stmt) bool {
    for (w.g.moves) |mv| {
        var from = false;
        // An options statement is made where there is none; an
        // analysis that is not there takes nothing, which is said.
        var to = mv.to == .options or actsOnNothing(w, mv, stmts);
        for (stmts) |*s| {
            from = from or (s.kind == mv.from and s.at(mv.from_slot) != .none);
            to = to or (s.kind == mv.to and s.at(mv.to_slot) == .none);
        }
        if (from and to) return true;
    }
    return false;
}

/// An `omitted` formula in a report's words: "the tran.step", "td1 plus
/// the tran.step", any other as the grammar writes it.
pub fn omittedPhrase(arena: Allocator, o: *const grammar.Omitted) Allocator.Error![]const u8 {
    const t = o.terms;
    const sl = schema.info(o.kind).slots;
    if (t.len == 1 and t[0] == .first)
        return std.fmt.allocPrint(
            arena,
            "the {s}.{s}",
            .{
                @tagName(t[0].first.kind),
                schema.info(t[0].first.kind).slots[t[0].first.slot].name,
            },
        );
    if (t.len == 3 and t[0] == .slot and t[1] == .first and t[2].op == .add)
        return std.fmt.allocPrint(
            arena,
            "{s} plus the {s}.{s}",
            .{
                sl[t[0].slot].name,
                @tagName(t[1].first.kind),
                schema.info(t[1].first.kind).slots[t[1].first.slot].name,
            },
        );
    return o.text;
}

/// The dialect's `omitted` line for `slot` of a statement like `st`.
pub fn omittedLine(g: *const Grammar, st: *const ir.Stmt, slot: usize) ?*const grammar.Omitted {
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

/// The value of `slot` on the first statement of `kind` that has one.
pub fn firstValue(stmts: []const ir.Stmt, kind: Kind, slot: u8) ?Value {
    for (stmts) |*s| {
        if (s.kind == kind and s.at(slot) != .none) return s.at(slot);
        if (firstValue(s.body, kind, slot)) |v| return v;
    }
    return null;
}

pub fn isZero(v: Value) bool {
    return v == .num and v.num.toFloat() == 0;
}
