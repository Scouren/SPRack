//! One statement and what it holds: the kinds written another way first
//! (a control script where there is none, a native statement, an embedded
//! file, a command of another control language, a conditional block where
//! there are none), then a block by its grammar block or as a header and
//! its body; a statement without a body goes to `leaf.zig`.
//!
//! Contents:
//! - `pub fn stmt(w: *Writer, st: *const ir.Stmt) Error!void`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const leaf = @import("leaf.zig");
const emit = @import("emit.zig");
const spread = @import("spread.zig");
const output = @import("output.zig");
const unwritten = @import("unwritten.zig");
const bins = @import("bins.zig");
const instparams = @import("instparams.zig");
const plugins = @import("plugins.zig");
const variants = @import("variants.zig");
const expr = @import("expr");
const cond = @import("cond");
const statement = @import("statement.zig");
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Writer = statement.Writer;
const Error = Writer.Error;

/// A value of a block the target has a caveat on: the slot, the value and
/// the caveat's text.
const Caveat = struct { slot: []const u8, value: []const u8, why: []const u8 };

/// Write `st` and what it holds: the kinds written another way first,
/// then a block, then a statement without a body (`leaf.leaf`).
// tidy: allow(recursion) bounded by the nesting of blocks (ir.max_depth), a few calls a level
pub fn stmt(w: *Writer, st: *const ir.Stmt) Error!void {
    // `variants.split` writes its subcircuits, and `spread.spread` its
    // ending, through here.
    assert(!w.variant or st.kind == .subckt);
    assert(!w.ending or st.body.len == 0);
    // A statement that changes nothing in this dialect (`inert kind :
    // text`), with what it holds: left out, said once a kind.
    if (w.g.statementInert(st.kind)) |why| return inertStatement(w, st, why);
    if (st.kind == .model and st.body.len > 0) return bins.binnedModel(w, st);
    // A control script where there is none: its analyses and outputs
    // are the deck's own; its other commands are said one by one.
    if (st.kind == .script and !w.g.canWrite(.script) and for (st.body) |c| {
        if (c.kind != .simctl and c.kind != .comment) break true;
    } else false) return scriptAsDeck(w, st);
    if (st.kind == .native) return native(w, st);
    if (st.kind == .device and st.get("module") == .none) switch (try plugins.withModule(w, st)) {
        .keep => {},
        .done => return,
        .stmt => |d| return stmt(w, &d),
    };
    if (st.kind == .embed) if (w.g.rawOf(.embed)) |rb| {
        return embed(w, st, rb);
    } else if (try embedRefused(w, st)) return;
    // A command of one simulator's control language is no command of
    // another's: one with nothing to say there (run, quit) is left out,
    // any other is unsupported.
    if (st.kind == .simctl and w.othersCommand(st)) return foreignCommand(w, st);
    // A statement the target says only for an analysis: once for each.
    if (try spread.each(w, st)) return;
    if (try instparams.hoistParams(w, st)) |h| return stmt(w, &h);
    if (try compiledForm(w, st)) |c| return stmt(w, &c);
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
    // One of the subcircuits `split` writes: written as it is.
    const variant = w.variant;
    w.variant = false;
    if (st.kind == .subckt and !w.g.canWrite(.cond_if) and !variant and try split(w, st))
        return;
    if (st.kind == .cond_if and !w.g.canWrite(.cond_if)) return condBlock(w, st);
    // A block kind this dialect has only a rule for: the rule says the
    // header, the body follows it (Xyce `.sampling` ahead of its
    // analyses), or the rule is added to each statement of the body
    // (`spread`, HSPICE `monte=`).
    if (st.body.len > 0 and w.g.blockOf(st.kind) == null and w.g.canWrite(st.kind))
        return headerAndBody(w, st);
    for (w.g.blocks) |*b| {
        if (b.kind != st.kind) continue;
        // A kind that also has rules is a block only with a body
        // (Spectre's binned `model ... { }`).
        if (st.body.len == 0 and w.g.canWriteRule(st.kind)) break;
        return block(w, st, b);
    }
    if (w.g.onces.len > 0 and w.g.canWrite(st.kind)) try noteOnce(w, st);
    {
        defer _ = w.scratch.reset(.retain_capacity);
        try leaf.leaf(w, w.scratch.allocator(), st);
    }
    // A sweep this dialect writes as one line for the whole netlist
    // (`.step`): what it sweeps follows it.
    // Not where the sweep itself has no form: its statements were said
    // to be left out with it.
    if (schema.info(st.kind).class == .analysis and w.g.canWrite(st.kind))
        for (st.body) |*child| try stmt(w, child);
}

// ---- private ----

/// The lines of the grammar's `once` directives for `st`'s kind, kept
/// for the end of the file where its value of the directive's slot is new.
fn noteOnce(w: *Writer, st: *const ir.Stmt) Error!void {
    // `stmt` asks only where the grammar has a `once` and writes the kind.
    assert(w.g.onces.len > 0);
    for (w.g.onces, 0..) |o, which| {
        if (o.kind != st.kind) continue;
        const key = slotWord(st, o.slot, false) orelse continue;
        const fold = !w.g.lex.case_sensitive;
        const seen = for (w.onces.items) |l| {
            if (l.which == which and (if (fold)
                std.ascii.eqlIgnoreCase(l.key, key)
            else
                std.mem.eql(u8, l.key, key))) break true;
        } else false;
        if (seen) continue;
        var text: std.ArrayList(u8) = .empty;
        for (o.lines, 0..) |l, i| {
            if (i > 0) try text.append(w.perm, '\n');
            const empty = try fillOnce(w.perm, &text, l, st) orelse continue;
            const plain = try std.mem.replaceOwned(u8, w.arena, empty, ".stem", "");
            const said = try std.mem.replaceOwned(u8, w.arena, plain, "|", "' or '");
            const name = slotWord(st, 0, false) orelse "";
            w.report.add(.@"error", .invalid, st.line, "{s} '{s}': {s} writes a line for it " ++
                "from its '{s}', and it gives none", .{ @tagName(st.kind), name, w.g.name, said });
            break;
        } else try w.onces.append(w.perm, .{
            .which = which,
            .key = try w.perm.dupe(u8, key),
            .text = text.items,
        });
    }
}

/// `line` with each `{x}`, `{x.stem}` and `{x|y}` replaced by what `st`
/// holds (the grammar's compiler checked the names). Null when filled;
/// else the place `st` holds nothing for (`file.stem|module`).
fn fillOnce(
    a: std.mem.Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
    st: *const ir.Stmt,
) Error!?[]const u8 {
    var rest = line;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open, '}').?;
        try out.appendSlice(a, rest[0..open]);
        var names = std.mem.splitScalar(u8, rest[open + 1 .. close], '|');
        while (names.next()) |n| {
            const stem = std.mem.endsWith(u8, n, ".stem");
            const name = if (stem) n[0 .. n.len - ".stem".len] else n;
            const slot = schema.slotIndex(st.kind, name).?;
            if (slotWord(st, slot, stem)) |t| break try out.appendSlice(a, t);
        } else return rest[open + 1 .. close];
        rest = rest[close + 1 ..];
    }
    try out.appendSlice(a, rest);
    return null;
}

/// The word or path `st` holds in `slot`, or its stem: no directory, no
/// suffix. Null where it holds none.
fn slotWord(st: *const ir.Stmt, slot: u8, stem: bool) ?[]const u8 {
    const t = switch (st.at(slot)) {
        .atom, .str => |x| x,
        else => return null,
    };
    if (t.len == 0) return null;
    if (!stem) return t;
    const base = t[if (std.mem.lastIndexOfAny(u8, t, "/\\")) |i| i + 1 else 0..];
    return base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];
}

fn inertStatement(w: *Writer, st: *const ir.Stmt, why: []const u8) Error!void {
    const k = @backingInt(st.kind);
    if (w.inert_said[k]) return;
    w.inert_said[k] = true;
    w.report.add(.info, .loss, st.line, "{s}: not written: {s}", .{
        @tagName(st.kind), try emit.reasonFor(w.arena, why, w.g.name),
    });
}

/// A statement only one dialect has: as its words there, an
/// `unsupported` with that grammar's reason anywhere else.
fn native(w: *Writer, st: *const ir.Stmt) Error!void {
    assert(st.kind == .native);
    const dialect = if (st.get("of") == .atom) st.get("of").atom else "";
    const word = if (st.get("word") == .atom) st.get("word").atom else "";
    var said: std.ArrayList(u8) = .empty;
    try said.appendSlice(w.arena, word);
    if (st.get("args") == .list) for (st.get("args").list) |v| switch (v) {
        .atom, .str, .expr => |x| try said.print(w.arena, " {s}", .{x}),
        else => {},
    };
    if (st.get("params") == .params) for (st.get("params").params) |p| switch (p.val) {
        .atom, .str, .expr => |x| try said.print(w.arena, " {s}={s}", .{ p.key, x }),
        .none => try said.print(w.arena, " {s}", .{p.key}),
        else => {
            var e = w.emitter(w.arena, st);
            try said.print(w.arena, " {s}={s}", .{ p.key, try e.describe(p.val) });
        },
    };
    if (std.mem.eql(u8, dialect, w.g.name)) return output.lineTail(w, said.items, st.tail);
    const sg: ?*const Grammar = if (w.caps) |c| for (c.grammars) |*g| {
        if (std.mem.eql(u8, g.name, dialect)) break g;
    } else null else null;
    const why = (if (sg) |g|
        g.ownReason(said.items)
    else
        null) orelse w.g.absentReason(.native) orelse "no other dialect has it";
    w.report.add(
        .@"error",
        .unsupported,
        st.line,
        "'{s}' is a {s} statement and cannot be written for {s}: {s}",
        .{ said.items, dialect, w.g.name, why },
    );
    try output.comment(w, try w.arena.print("[sprack] not written: {s}", .{said.items}));
}

/// A control script where there is none, holding more than commands:
/// what it holds is written as the netlist's own.
fn scriptAsDeck(w: *Writer, st: *const ir.Stmt) Error!void {
    w.report.add(
        .info,
        .oneway,
        st.line,
        "script: {s} has no control script; the {s} script's analyses and outputs are " ++
            "written as the netlist's own, in order",
        .{ w.g.name, w.sourceOf(st) },
    );
    for (st.body) |*child| try stmt(w, child);
}

/// `embed "name" <<<FILE`, the text, `>>>FILE`.
fn embed(w: *Writer, st: *const ir.Stmt, rb: *const grammar.RawBlock) Error!void {
    const path: []const u8 = switch (st.get("path")) {
        .str, .atom => |x| x,
        else => "",
    };
    const marker = if (std.mem.startsWith(u8, rb.close, ">>>")) rb.close[3..] else rb.close;
    try w.out.print("{s} \"{s}\" <<<{s}\n", .{ rb.open, path, marker });
    const text: []const u8 = switch (st.get("text")) {
        .atom, .str => |x| x,
        else => "",
    };
    try w.out.writeAll(text);
    if (text.len > 0 and text[text.len - 1] != '\n') try w.out.writeByte('\n');
    try w.out.print("{s}\n", .{rb.close});
    w.last_blank = false;
}

/// An embedded file where the target has no form for one: refused with
/// this grammar's reason, or the embedding dialect's. False: neither has
/// one, and it is written as any other statement.
fn embedRefused(w: *Writer, st: *const ir.Stmt) Error!bool {
    assert(st.kind == .embed);
    var why: ?[]const u8 = w.g.absentReason(.embed);
    if (why == null)
        if (w.caps) |c|
            for (c.grammars) |*sg| if (sg.rawOf(.embed)) |rb| if (rb.reason.len > 0) {
                why = rb.reason;
            };
    const reason = why orelse return false;
    const path: []const u8 = switch (st.get("path")) {
        .str, .atom => |x| x,
        else => "",
    };
    w.report.add(
        .@"error",
        .unsupported,
        st.line,
        "embed: the file '{s}' cannot be written for {s}: {s}",
        .{ path, w.g.name, reason },
    );
    try output.comment(
        w,
        try w.arena.print("[sprack] not written: the embedded file {s}", .{path}),
    );
    return true;
}

/// A command of another simulator's control language: left out where it
/// has nothing to say, unsupported otherwise.
fn foreignCommand(w: *Writer, st: *const ir.Stmt) Error!void {
    assert(st.kind == .simctl);
    const cmd = if (st.get("cmd") == .atom) st.get("cmd").atom else "";
    const args: []const u8 = switch (st.get("args")) {
        .atom, .str, .expr => |x| x,
        else => "",
    };
    const said = try w.arena.print("{s}{s}{s}", .{ cmd, if (args.len > 0)
        " "
    else
        "", args });
    // The dialect the command is of says which of its commands
    // have nothing to say outside it (`inert simctl run ...`).
    if (try w.inertCommand(st, cmd)) |why| {
        w.report.add(
            .info,
            .loss,
            st.line,
            "simctl: '{s}' is not written: {s}",
            .{ said, why },
        );
        return;
    }
    if (w.g.absentReason(.simctl)) |why| {
        w.report.add(
            .@"error",
            .unsupported,
            st.line,
            "simctl: '{s}' is a command of {s}'s control language and cannot be " ++
                "written for {s}: {s}",
            .{ said, w.sourceOf(st), w.g.name, why },
        );
    } else w.report.add(.@"error", .unsupported, st.line, "simctl: '{s}' is a command " ++
        "of {s}'s control language; {s} has no form for it (post-processing stays " ++
        "with {s})", .{ said, w.sourceOf(st), w.g.name, w.sourceOf(st) });
    return output.comment(w, try w.arena.print("[sprack] not written: {s}", .{said}));
}

/// A subcircuit whose own parameters decide its conditional blocks, where
/// the target has none: written once for each branch. False: it is not,
/// and `w.unsplit` says why where there is a reason.
fn split(w: *Writer, st: *const ir.Stmt) Error!bool {
    assert(st.kind == .subckt);
    switch (try cond.split(
        w.arena,
        st,
        expr.choiceForm(w.g),
        &w.declared,
        try variants.knownSplits(w, w.arena),
    )) {
        .none => {},
        .refused => |why| w.unsplit = why,
        .clash => |name| w.unsplit = try std.fmt.allocPrint(
            w.arena,
            "'{s}', the name one of them would take, is already declared",
            .{name},
        ),
        .variants => |v| {
            try variants.split(w, st, &v);
            return true;
        },
    }
    return false;
}

/// A conditional block where the target has none: its statements once,
/// where every branch holds the same ones, else unsupported.
fn condBlock(w: *Writer, st: *const ir.Stmt) Error!void {
    assert(st.kind == .cond_if);
    var also: []const u8 = "";
    if (expr.choiceForm(w.g)) |form| switch (try cond.merge(w.arena, st, form)) {
        .merged => |stmts| {
            w.report.add(
                .info,
                .oneway,
                st.line,
                "cond_if: {s} has no conditional blocks; every branch holds the same " ++
                    "statements, so they are written once, each value that differs as " ++
                    "a choice between the branches' values by their conditions; it " ++
                    "reads back as those statements, not as a block",
                .{w.g.name},
            );
            for (stmts) |*s| try stmt(w, s);
            return;
        },
        .refused => |why| also = try std.fmt.allocPrint(
            w.arena,
            ", and this block is not the same statements with other values in every " ++
                "branch: {s}",
            .{why},
        ),
    };
    if (w.unsplit.len > 0)
        also = try std.fmt.allocPrint(
            w.arena,
            "{s}; nor is its subcircuit written once for each branch: {s}",
            .{ also, w.unsplit },
        );
    return unwritten.unsupported(w, w.arena, st, also);
}

/// A block kind the target has only a rule for: the rule as the header and
/// the body after it, or the rule as the end of each statement of the body.
fn headerAndBody(w: *Writer, st: *const ir.Stmt) Error!void {
    // Only a kind with lines of its own (a word starts its endings:
    // `.temp`) may be such a line; HSPICE's Monte Carlo has none.
    if (w.g.isSpread(st.kind) and
        !(st == w.sole and w.g.spreadWord(st.kind) != null and try spread.fits(w, st)))
        return spread.spread(w, st);
    var head = st.*;
    head.body = &.{};
    try stmt(w, &head);
    for (st.body) |*child| try stmt(w, child);
}

/// A block by the grammar's block for its kind: the open line, the inner
/// lines, the body, the close line.
fn block(w: *Writer, st: *const ir.Stmt, b: *const grammar.Block) Error!void {
    assert(b.kind == st.kind);
    w.ordinals[@backingInt(st.kind)] += 1;
    var e = w.emitter(w.arena, st);
    if (!try e.seq(b.open)) return openRefused(w, st);
    try output.lineTail(w, e.buf.items, st.tail);
    for (b.inner) |pat| {
        if (!e.anyBound(pat)) continue;
        e.buf.clearRetainingCapacity();
        if (try e.seq(pat)) try output.line(w, e.buf.items);
    }
    {
        const was = w.within;
        w.within = st.kind;
        defer w.within = was;
        for (st.body) |*child| try stmt(w, child);
    }
    e.buf.clearRetainingCapacity();
    if (try e.seq(b.close)) try output.line(w, e.buf.items);
    try e.reportLosses();
}

/// A block whose open line cannot be written. A word it has no spelling
/// for (an HSPICE element variation in Spectre): the block and what it
/// holds are not written, said once, with the target's caveat on that
/// value as the reason where it has one.
fn openRefused(w: *Writer, st: *const ir.Stmt) Error!void {
    if (caveatOn(w, st)) |c| return caveatRefused(w, st, c);
    w.report.add(
        .@"error",
        .invalid,
        st.line,
        "{s}: required values missing for the {s} form",
        .{ @tagName(st.kind), w.g.name },
    );
}

/// `st` with a value the target loads only in another form (`caveat hdl
/// path=*.va -> *.osdi`) given that form's suffix, and the caveat said;
/// null where no such caveat holds. Read back, the value stays as written.
fn compiledForm(w: *Writer, st: *const ir.Stmt) Error!?ir.Stmt {
    if (std.mem.eql(u8, w.sourceOf(st), w.g.name)) return null;
    for (w.g.caveats) |c| {
        if (c.becomes.len == 0 or c.kind != st.kind) continue;
        const v = st.at(c.slot);
        const was: []const u8 = switch (v) {
            .str, .atom => |x| x,
            else => continue,
        };
        if (!std.ascii.endsWithIgnoreCase(was, c.suffix)) continue;
        const now = try w.arena.print("{s}{s}", .{ was[0 .. was.len - c.suffix.len], c.becomes });
        // The grammar's compiler refuses a form that ends as the one it replaces.
        assert(!std.ascii.endsWithIgnoreCase(now, c.suffix));
        var out = st.*;
        try out.own(w.arena);
        try out.set(w.arena, c.slot, if (v == .str) .{ .str = now } else .{ .atom = now });
        w.report.add(.warning, .caveat, st.line, "{s}.{s}: '{s}' is written as '{s}': {s}", .{
            @tagName(st.kind), schema.info(st.kind).slots[c.slot].name, was, now, c.text,
        });
        return out;
    }
    return null;
}

/// The first value of `st` the target has a caveat on, and the caveat.
fn caveatOn(w: *const Writer, st: *const ir.Stmt) ?Caveat {
    for (schema.info(st.kind).slots, 0..) |sl, k| {
        const v = st.at(k);
        if (sl.ty != .atom or v != .atom) continue;
        for (w.g.caveats) |c| {
            if (c.kind == st.kind and c.slot == k and c.suffix.len > 0 and
                std.ascii.endsWithIgnoreCase(v.atom, c.suffix))
                return .{ .slot = sl.name, .value = v.atom, .why = c.text };
        }
    }
    return null;
}

/// The block `st` is not written: the target's caveat on one of its values
/// says why.
fn caveatRefused(w: *Writer, st: *const ir.Stmt, c: Caveat) Error!void {
    // The value ends with the caveat's suffix, which is not empty.
    assert(c.value.len > 0);
    const slot = c.slot;
    const value = c.value;
    const why = c.why;
    const held = unwritten.bodyCount(st.body);
    w.report.add(.@"error", .unsupported, st.line, "{s} {s}={s} cannot be " ++
        "written for {s}: {s}. The {d} statement{s} it holds {s} not written " ++
        "either, and {s} in the output as comments", .{
        @tagName(st.kind),          slot,                           value,
        w.g.name,                   why,                            held,
        if (held == 1) "" else "s", if (held == 1) "is" else "are", if (held == 1) "is" else "are",
    });
    try output.comment(
        w,
        try w.arena.print(
            "[sprack] not written: {s} {s}={s}",
            .{ @tagName(st.kind), slot, value },
        ),
    );
    try unwritten.bodyComments(w, w.arena, st.body);
}
