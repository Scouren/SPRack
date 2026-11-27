//! A statement without a body: the rule it is written by, chosen among
//! the forms of its kind by what each loses, and the report of what that
//! form does not carry back.
//!
//! Contents:
//! - `pub fn leaf(w: *Writer, a: Allocator, st_in: *const ir.Stmt) Error!void`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const output = @import("output.zig");
const unwritten = @import("unwritten.zig");
const cards = @import("cards.zig");
const selector = @import("selector.zig");
const instparams = @import("instparams.zig");
const variants = @import("variants.zig");
const rewrite = @import("rewrite.zig");
const cond = @import("cond");
const emit = @import("emit.zig");
const Emit = emit.Emit;
const statement = @import("statement.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Writer = statement.Writer;
const Error = Writer.Error;

/// The rule `choose` settled on, if any; the form it wrote for real when
/// that is the one chosen; and why the forms tried did not fit.
const Choice = struct { rule: ?*const grammar.Rule, written: ?Emit, why: []const u8 };

/// Write `st`, a statement without a body or one whose body follows it:
/// as text where it is a comment or kept as text, else by the rule of its
/// kind that loses least, with what that rule does not carry reported.
pub fn leaf(w: *Writer, a: Allocator, st_in: *const ir.Stmt) Error!void {
    // Set only while this function writes its own line.
    assert(!w.nowrap);
    var st = st_in;
    if (st.kind == .comment) return commentLine(w, st);
    if (st.kind == .annotation) return annotationLine(w, st);
    if (st.kind == .@"opaque") return opaqueLine(w, a, st);
    const class = schema.info(st.kind).class;
    // Nothing left to say (its values moved elsewhere): no statement.
    if (class == .control and !saysAnything(st)) return;
    // A grammar loaded at run time, or JSON, can give a model or a
    // device no name; everything below names it in its messages.
    if ((class == .device or st.kind == .model) and st.get("name") != .atom)
        return nameless(w, a, st);
    var chosen: ir.Stmt = undefined;
    if (st.kind == .instance and w.splits.items.len > 0 and st.get("master") == .atom and
        st.raw.ptr != cond.chosen.ptr)
    {
        const name = try variants.variantOf(w, a, st) orelse return output.comment(
            w,
            try a.print("[sprack] not written: instance '{s}'", .{st.get("name").atom}),
        );
        if (!std.ascii.eqlIgnoreCase(name, st.get("master").atom)) {
            chosen = st.*;
            try chosen.own(a);
            try chosen.set(a, schema.slot(.instance, "master"), .{ .atom = name });
            st = &chosen;
        }
    }
    if (w.g.rewrites.len > 0 and try rewritten(w, a, st)) return;
    w.ordinals[@backingInt(st.kind)] += 1;

    var mapped: ir.Stmt = undefined;
    if (st.kind == .model) {
        const m = cards.unmapModel(w, a, st) catch |err| switch (err) {
            error.Skip => return,
            else => |e| return e,
        };
        mapped = m orelse return output.comment(
            w,
            try a.print("[sprack] not written: model '{s}'", .{st.get("name").atom}),
        );
        st = &mapped;
    }
    var checked: ir.Stmt = undefined;
    if (try instparams.instParams(w, a, st)) |c| {
        checked = c;
        st = &checked;
    }

    if (!w.canWriteHere(st.kind)) return notHere(w, a, st);
    if (try selector.unchosen(w, a, st)) return;
    const choice = try choose(w, a, st);
    const rule = choice.rule orelse return noForm(w, a, st, choice.why);
    var e = choice.written orelse blk: {
        var again = w.emitter(a, st);
        _ = try again.seq(rule.pat);
        break :blk again;
    };
    // ngspice reads .lib and .include before it joins continuation lines.
    w.nowrap = st.kind == .include or st.kind == .lib or st.kind == .hdl;
    defer w.nowrap = false;
    // An options statement none of whose values crossed (ngspice's
    // `noacct` alone) says nothing: Xyce warns on a bare `.options timeint`.
    if (st.kind == .options and e.used == 0) return e.reportLosses();
    try output.lineTail(w, std.mem.trimEnd(u8, e.buf.items, "\n"), st.tail);
    readBack(w, st, rule, &e);
    if (class == .control) try moreStatements(w, a, st, &e);
    try e.reportLosses();
    if (e.foreign) {
        try unknownRefs(w, st);
        if (w.g.lex.ident_values and (st.kind == .resistor or st.kind == .capacitor))
            try modelOrParam(w, a, st);
        if (st.kind == .include or st.kind == .lib or st.kind == .hdl)
            try stillForeign(w, st, &e);
    }
}

// ---- private ----

/// A statement the target's grammar says with other statements (a
/// `rewrite` block): those are written in its place, with what the
/// rewrite reports. False: no rewrite applies, and the statement is
/// written as it is.
fn rewritten(w: *Writer, a: Allocator, st: *const ir.Stmt) Error!bool {
    var em = w.emitter(a, st);
    const parts = try rewrite.apply(a, st, .{
        .g = w.g,
        .sg = w.sourceGrammar(st) orelse rewrite.readIn(w.source, st),
        .em = &em,
        .source = w.sourceOf(st),
        .report = w.report,
        .clash_keys = &w.clash_keys,
        .nested = w.depth > 0,
    }) orelse return false;
    for (parts) |*part| try leaf(w, a, part);
    return true;
}

/// A comment, or one blank line where the source had any.
fn commentLine(w: *Writer, st: *const ir.Stmt) Error!void {
    if (std.mem.eql(u8, st.raw, ir.blank_line)) {
        if (!w.last_blank) try w.out.writeByte('\n');
        w.last_blank = true;
        return;
    }
    return output.comment(w, st.raw);
}

/// An annotation, whole on a line of its own: after the target's mark
/// (`*@`), or as a comment where the target has none, said once a file.
fn annotationLine(w: *Writer, st: *const ir.Stmt) Error!void {
    assert(st.kind == .annotation);
    const text = switch (st.get("text")) {
        .atom, .str, .expr => |t| t,
        else => "",
    };
    const mark = w.g.lex.annotation;
    if (mark.len > 0) {
        // Never wrapped: a tool reads the line whole.
        try w.out.print("{s}{s}{s}\n", .{ mark, if (text.len > 0) " " else "", text });
        w.last_blank = false;
        return;
    }
    if (!w.annotated) w.report.add(.warning, .loss, st.line, "annotation: {s} has no " ++
        "annotation lines; '{s}' is written as a comment, which reads back as one", .{
        w.g.name, text,
    });
    w.annotated = true;
    return output.comment(w, text);
}

/// A line no rule understood: as it was, where it is the target's own;
/// refused, where its own grammar keeps it verbatim and says why; else in
/// the output as a comment.
fn opaqueLine(w: *Writer, a: Allocator, st: *const ir.Stmt) Error!void {
    assert(st.kind == .@"opaque");
    if (std.mem.eql(u8, w.sourceOf(st), w.g.name)) {
        // A statement the grammar names as its own is understood.
        if (w.g.ownReason(st.raw) == null) {
            if (w.kept.n == 0) w.kept.line = st.line;
            w.kept.n += 1;
        }
        return output.lineTail(w, st.raw, st.tail);
    }
    // A region the source grammar keeps verbatim, and says why.
    if (w.caps) |c| for (c.grammars) |*sg| {
        if (!std.mem.eql(u8, sg.name, w.sourceOf(st))) continue;
        if (sg.ownReason(st.raw)) |why| return keptRefused(w, a, st, why);
        for (sg.raws) |rb| {
            if (rb.reason.len == 0 or !std.mem.startsWith(u8, st.raw, rb.open)) continue;
            return keptRefused(w, a, st, rb.reason);
        }
    };
    return untranslated(w, a, st);
}

/// A region its own grammar keeps verbatim, refused for `why`.
fn keptRefused(w: *Writer, a: Allocator, st: *const ir.Stmt, why: []const u8) Error!void {
    assert(st.kind == .@"opaque");
    const more = std.mem.count(u8, std.mem.trimEnd(u8, st.raw, "\n"), "\n");
    w.report.add(
        .@"error",
        .unsupported,
        st.line,
        "'{s}'{s} cannot be written for {s}: {s}",
        .{ std.mem.sliceTo(st.raw, '\n'), if (more == 0)
            ""
        else
            try a.print(" and the {d} line{s} after " ++
                "it", .{ more, if (more == 1) "" else "s" }), w.g.name, why },
    );
    return output.comment(
        w,
        try a.print("[sprack] not written: {s}", .{std.mem.sliceTo(st.raw, '\n')}),
    );
}

/// A line no rule of its dialect understood, in the output as a comment.
fn untranslated(w: *Writer, a: Allocator, st: *const ir.Stmt) Error!void {
    assert(st.kind == .@"opaque");
    const more = std.mem.count(u8, std.mem.trimEnd(u8, st.raw, "\n"), "\n");
    w.report.add(.@"error", .untranslated, st.line, "no {s} rule understood this " ++
        "line; it is in the output only as a comment: {s}{s}", .{
        w.sourceOf(st), std.mem.sliceTo(st.raw, '\n'),
        if (more == 0)
            ""
        else
            try a.print(" (and {d} more line{s} of it)", .{ more, if (more == 1)
                ""
            else
                "s" }),
    });
    return output.comment(
        w,
        try a.print("[sprack] untranslated {s}: {s}", .{ w.sourceOf(st), st.raw }),
    );
}

/// Does a control statement hold a value, its package aside?
fn saysAnything(st: *const ir.Stmt) bool {
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
    return any;
}

/// A model or a device without a name: not written.
fn nameless(w: *Writer, a: Allocator, st: *const ir.Stmt) Error!void {
    w.report.add(
        .@"error",
        .invalid,
        st.line,
        "{s}: a statement without a name cannot be written",
        .{@tagName(st.kind)},
    );
    return output.comment(w, try a.print("[sprack] not written: {s}", .{@tagName(st.kind)}));
}

/// A kind with no rule where the writer is: an instance of its model
/// where it can be one and the target has nothing to say against it,
/// else unsupported.
fn notHere(w: *Writer, a: Allocator, st: *const ir.Stmt) Error!void {
    assert(!w.canWriteHere(st.kind));
    if (w.g.absentReason(st.kind) == null) {
        if (try ir.demoteToInstance(a, st)) |inst| {
            if (w.g.canWrite(.instance)) {
                // Written as an instance of its model: with no card for
                // it in any file read, it reads back as a subcircuit's.
                if (st.get("master") == .atom and !std.mem.eql(
                    u8,
                    w.sourceOf(st),
                    w.g.name,
                )) try undeclaredModel(w, a, st);
                w.ordinals[@backingInt(st.kind)] -= 1;
                return leaf(w, a, &inst);
            }
        }
    }
    return unwritten.unsupported(w, a, st, "");
}

/// A device of another dialect written as an instance of its model: where
/// no file read declares the model, it reads back as a subcircuit's.
fn undeclaredModel(w: *Writer, a: Allocator, st: *const ir.Stmt) Error!void {
    const m = st.get("master").atom;
    const known = w.declared.contains(try std.ascii.allocLowerString(
        a,
        m,
    )) or w.families.contains(m);
    if (!known)
        w.report.add(.warning, .ambiguous, st.line, "{s} '{s}': its " ++
            "model '{s}' is declared in no file read; {s} tells a {s} " ++
            "from a subcircuit instance only by its model, so it " ++
            "reads back as an instance of '{s}'", .{
            @tagName(st.kind), st.get("name").atom, m, w.g.name, @tagName(st.kind), m,
        });
}

/// The rule `st` is written by: of the forms of its kind here, the one of
/// its model's family, else the one that loses least, among equals the one
/// that keeps the name. A model this file does not declare: the plain
/// forms first, then any form at all rather than none.
/// The first form tried is written for real, what it reports included:
/// most statements are said whole by it, and then it is the one written
/// (`written`). Where another form is chosen, what it reported is taken
/// back and that form written after.
fn choose(w: *Writer, a: Allocator, st: *const ir.Stmt) Error!Choice {
    var best: ?*const grammar.Rule = null;
    var best_loss: usize = std.math.maxInt(usize);
    var best_renames: usize = 0;
    var why: []const u8 = "";
    const fam: []const u8 = if (st.get("master") == .atom)
        w.familyOf(st.get("master").atom)
    else
        "";
    var written: ?Emit = null;
    const reported = w.report.items.items.len;
    var tried: usize = 0;
    const spreads = w.g.spreadWord(st.kind) != null;
    for ([_]bool{ false, true }) |loose| {
        if (best != null or (loose and fam.len > 0)) break;
        for (w.g.rulesOf(st.kind)) |ri| {
            const rule = &w.g.rules[ri];
            if (rule.dir == .read) continue;
            if (!w.g.ruleHere(rule, w.within)) continue;
            if (spreads and w.g.isEnding(rule) != w.ending) continue;
            if (rule.family.len > 0 and !std.mem.eql(u8, rule.family, fam) and !loose) {
                if (why.len == 0 and fam.len > 0)
                    why = try a.print("a model of family '{s}'", .{fam});
                continue;
            }
            var e = w.emitter(a, st);
            const first = tried == 0;
            tried += 1;
            e.quiet = !first;
            if (!try e.seq(rule.pat)) {
                if (first) w.report.items.shrinkRetainingCapacity(reported);
                if (why.len == 0) why = e.why;
                continue;
            }
            // The form of the model's own family, whatever a plain one keeps.
            if (rule.family.len > 0 and std.mem.eql(u8, rule.family, fam)) {
                best = rule;
                if (first) written = e;
                break;
            }
            // Least lost first; among equals, the form that keeps the name.
            const loss = try e.lossCount();
            if (loss < best_loss or (loss == best_loss and e.renames < best_renames)) {
                best = rule;
                best_loss = loss;
                best_renames = e.renames;
                if (best_loss == 0 and best_renames == 0) {
                    if (first) written = e;
                    break;
                }
            }
            if (first) w.report.items.shrinkRetainingCapacity(reported);
        }
    }
    // A form is written only once it is chosen.
    assert(written == null or best != null);
    return .{ .rule = best, .written = written, .why = why };
}

/// No form of the kind fits `st`: the `no kind slot` line of a value no
/// form takes (`.tf i(vm) vin` into HSPICE), not the first form's miss;
/// else `why` the forms did not fit.
fn noForm(w: *Writer, a: Allocator, st: *const ir.Stmt, why: []const u8) Error!void {
    // The kind has rules here; none of them fits.
    assert(w.canWriteHere(st.kind));
    for (0..schema.info(st.kind).slots.len) |i| {
        if (st.at(i) == .none) continue;
        const absent = w.g.slotAbsentReason(st.kind, @intCast(i)) orelse continue;
        w.report.add(
            .@"error",
            .unsupported,
            st.line,
            "{s}.{s}: {s}",
            .{ @tagName(st.kind), schema.info(st.kind).slots[i].name, absent },
        );
        return output.comment(w, try a.print("[sprack] not written: {s}", .{@tagName(st.kind)}));
    }
    if (why.len > 0) {
        w.report.add(
            .@"error",
            .unsupported,
            st.line,
            "{s}: no {s} form of this statement can say {s}",
            .{ @tagName(st.kind), w.g.name, why },
        );
    } else {
        w.report.add(
            .@"error",
            .invalid,
            st.line,
            "{s}: the values given do not fit any {s} form of this statement",
            .{ @tagName(st.kind), w.g.name },
        );
    }
    return output.comment(w, try a.print("[sprack] not written: {s}", .{@tagName(st.kind)}));
}

/// How `st`, written by `rule`, reads back: as another statement, or
/// without the slots left out on purpose.
fn readBack(w: *Writer, st: *const ir.Stmt, rule: *const grammar.Rule, e: *const Emit) void {
    // `choose` passes the rules that are only read by.
    assert(rule.dir != .read);
    if (rule.dir == .write and !w.g.canRead(st.kind)) {
        w.report.add(
            .info,
            .oneway,
            st.line,
            "{s}: written in a form the {s} grammar does not read back as a {s}",
            .{ @tagName(st.kind), w.g.name, @tagName(st.kind) },
        );
    } else if (e.dropped != 0 and (rule.dir != .write or w.g.canRead(st.kind))) {
        // Left out on purpose (`-slot`, its caveat says why): it reads
        // back without it.
        for (0..@min(schema.info(st.kind).slots.len, 64)) |i|
            if (e.dropped & (@as(u64, 1) << @intCast(i)) != 0) {
                w.report.add(
                    .info,
                    .loss,
                    st.line,
                    "{s}.{s} is not written, so it reads back without it",
                    .{ @tagName(st.kind), schema.info(st.kind).slots[i].name },
                );
            };
    }
}

/// What one statement cannot hold, further statements may: `.options
/// timeint ...` next to `.options device ...`. One that only says again
/// what an earlier one said (`reltol=reltol+`, `.options nonlin ...`) is
/// written once.
fn moreStatements(w: *Writer, a: Allocator, st: *const ir.Stmt, e: *Emit) Error!void {
    assert(schema.info(st.kind).class == .control);
    const said = try a.alloc(bool, w.g.rules.len);
    @memset(said, false);
    var used = e.used;
    var progress = true;
    while (progress) {
        progress = false;
        for (w.g.rules, said) |*more, *was| {
            if (more.kind != st.kind or more.dir == .read) continue;
            var probe = w.emitter(a, st);
            probe.quiet = true;
            probe.hide = used;
            if (!try probe.seq(more.pat)) continue;
            const fresh = probe.used & ~used != 0;
            if (!fresh and (probe.again == 0 or was.*)) continue;
            var extra = w.emitter(a, st);
            extra.hide = used;
            _ = try extra.seq(more.pat);
            try output.line(w, extra.buf.items);
            used |= extra.used;
            was.* = true;
            progress = progress or fresh;
        }
    }
    e.used = used;
}

/// `.dc X ...` sweeps a source in one dialect and a parameter or the
/// temperature in another, under the same spelling: a reference of a
/// statement of another dialect that names no device here.
fn unknownRefs(w: *Writer, st: *const ir.Stmt) Error!void {
    // Only a statement of another dialect is checked.
    assert(!std.mem.eql(u8, w.sourceOf(st), w.g.name));
    for (schema.info(st.kind).slots, 0..) |sl, i| {
        if (sl.ty != .ref or st.at(i) != .atom) continue;
        if (w.refs) |r| {
            if (r.found.contains(st.at(i).atom)) continue;
        } else if (w.instances.contains(st.at(i).atom)) continue;
        w.report.add(.@"error", .invalid, st.line, "{s}.{s} = {s} does not name a " ++
            "device in this netlist; if {s} means a parameter by it, {s} has to be " ++
            "told so in its own way", .{
            @tagName(st.kind), sl.name, st.at(i).atom, w.sourceOf(st), w.g.name,
        });
        // A device of the name may still come.
        if (w.refs) |r|
            try r.pending.append(
                w.perm,
                .{
                    .at = w.report.items.items.len - 1,
                    .name = try w.perm.dupe(u8, st.at(i).atom),
                },
            );
    }
}

/// A resistor or capacitor of another dialect whose value is a model name
/// no model here declares: the target reads it as a parameter.
fn modelOrParam(w: *Writer, a: Allocator, st: *const ir.Stmt) Error!void {
    const master = st.get("master");
    const value = st.at(3);
    if (master == .atom and value == .none and !w.declared.contains(
        try std.ascii.allocLowerString(a, master.atom),
    )) {
        w.report.add(.warning, .ambiguous, st.line, "'{s}' on {s} is a model name in " ++
            "{s}, but no model of that name is declared here; {s} will read it as a " ++
            "parameter", .{
            master.atom, st.get("name").atom, w.sourceOf(st), w.g.name,
        });
    }
}

/// A file an include of another dialect names is still in that dialect.
fn stillForeign(w: *Writer, st: *const ir.Stmt, e: *Emit) Error!void {
    w.report.add(
        .warning,
        .caveat,
        st.line,
        "{s} is still {s} syntax; translate that file too (`sprack project` follows " ++
            "includes)",
        .{ try e.describe(st.get("path")), w.sourceOf(st) },
    );
}
