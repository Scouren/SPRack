//! One statement and what it holds: the kinds written another way first
//! (a control script where there is none, a native statement, an embedded
//! file, a command of another control language, a conditional block where
//! there are none), then a block by its grammar block or as a header and
//! its body; a statement without a body goes to `leaf.zig`.

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const leaf = @import("leaf.zig");
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
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Kind = schema.Kind;
const Writer = statement.Writer;
const Error = Writer.Error;

/// A statement only one dialect has: as its words there, an
/// `unsupported` with that grammar's reason anywhere else.
pub fn native(w: *Writer, st: *const ir.Stmt) Error!void {
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

pub fn stmt(w: *Writer, st: *const ir.Stmt) Error!void {
    if (st.kind == .model and st.body.len > 0) return bins.binnedModel(w, st);
    // A control script where there is none: its analyses and outputs
    // are the deck's own; its other commands are said one by one.
    if (st.kind == .script and !w.g.canWrite(.script) and for (st.body) |c| {
        if (c.kind != .simctl and c.kind != .comment) break true;
    } else false) {
        w.report.add(
            .info,
            .oneway,
            st.line,
            "script: {s} has no control script; the {s} script's analyses and outputs are " ++
                "written as the netlist's own, in order",
            .{ w.g.name, w.sourceOf(st) },
        );
        for (st.body) |*child| try stmt(w, child);
        return;
    }
    if (st.kind == .native) return native(w, st);
    if (st.kind == .device and st.get("module") == .none) switch (try plugins.withModule(w, st)) {
        .keep => {},
        .done => return,
        .stmt => |d| return stmt(w, &d),
    };
    if (st.kind == .embed) if (w.g.rawOf(.embed)) |rb| {
        // `embed "name" <<<FILE`, the text, `>>>FILE`.
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
        return;
    } else {
        // Elsewhere: this grammar's reason, or the embedding dialect's.
        var why: ?[]const u8 = w.g.absentReason(.embed);
        if (why == null)
            if (w.caps) |c|
                for (c.grammars) |*sg| if (sg.rawOf(.embed)) |rb| if (rb.reason.len > 0) {
                    why = rb.reason;
                };
        if (why) |reason| {
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
            return output.comment(
                w,
                try w.arena.print("[sprack] not written: the embedded file {s}", .{path}),
            );
        }
    };
    // A command of one simulator's control language is no command of
    // another's: one with nothing to say there (run, quit) is left out,
    // any other is unsupported.
    if (st.kind == .simctl and !std.mem.eql(u8, w.sourceOf(st), w.g.name)) {
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
    if (try instparams.hoistParams(w, st)) |h| return stmt(w, &h);
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
    if (st.kind == .subckt and !w.g.canWrite(.cond_if) and !variant)
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
            .variants => |v| return variants.split(w, st, &v),
        };
    if (st.kind == .cond_if and !w.g.canWrite(.cond_if)) {
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
    // A block kind this dialect has only a rule for: the rule says the
    // header, the body follows it (Xyce `.sampling` ahead of its
    // analyses), or the rule is added to each statement of the body
    // (`spread`, HSPICE `monte=`).
    if (st.body.len > 0 and w.g.blockOf(st.kind) == null and w.g.canWrite(st.kind)) {
        // Only a kind with lines of its own (a word starts its endings:
        // `.temp`) may be such a line; HSPICE's Monte Carlo has none.
        if (w.g.isSpread(st.kind) and
            !(st == w.sole and w.g.spreadWord(st.kind) != null and try spread.fits(w, st)))
            return spread.spread(w, st);
        var head = st.*;
        head.body = &.{};
        try stmt(w, &head);
        for (st.body) |*child| try stmt(w, child);
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
            // A word its open line has no spelling for (an HSPICE
            // element variation in Spectre): the block and what it
            // holds are not written, said once, with the target's
            // caveat on that value as the reason where it has one.
            for (schema.info(st.kind).slots, 0..) |sl, k| {
                const v = st.at(k);
                if (sl.ty != .atom or v != .atom) continue;
                const why = for (w.g.caveats) |c| {
                    if (c.kind == st.kind and c.slot == k and c.suffix.len > 0 and
                        std.ascii.endsWithIgnoreCase(
                            v.atom,
                            c.suffix,
                        )) break c.text;
                } else continue;
                const held = unwritten.bodyCount(st.body);
                w.report.add(.@"error", .unsupported, st.line, "{s} {s}={s} cannot be " ++
                    "written for {s}: {s}. The {d} statement{s} it holds {s} not written " ++
                    "either, and {s} in the output as comments", .{
                    @tagName(st.kind),              sl.name,                        v.atom, w.g.name, why, held,
                    if (held == 1)
                        ""
                    else
                        "s",
                    if (held == 1) "is" else "are", if (held == 1) "is" else "are",
                });
                try output.comment(
                    w,
                    try w.arena.print(
                        "[sprack] not written: {s} {s}={s}",
                        .{ @tagName(st.kind), sl.name, v.atom },
                    ),
                );
                try unwritten.bodyComments(w, w.arena, st.body);
                return;
            }
            w.report.add(
                .@"error",
                .invalid,
                st.line,
                "{s}: required values missing for the {s} form",
                .{ @tagName(st.kind), w.g.name },
            );
            return;
        }
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
        return;
    }
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
