//! Statement writer: one canonical statement and the target's grammar → its
//! text on the output, with what the grammar has no place for reported.
//!
//! `Writer` holds what writing a netlist needs from one statement to the
//! next (the names declared, the counts, the notes said once a file).
//! `Writer.stmt` writes one statement and what it holds; `Writer.leaf`
//! chooses the rule a statement without a body is written by. What a
//! statement is turned into before that is in the files beside this one:
//! `cards.zig` (model cards), `bins.zig` (binned ones), `instparams.zig`,
//! `plugins.zig`, `variants.zig`, `defaults.zig`, `rewrite.zig`. `driver.zig` owns the
//! order of the passes and calls `Writer.stmt` for each statement.

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const dialects = @import("dialects");
const expr = @import("expr");
const alter = @import("alter");
const cond = @import("cond");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Kind = schema.Kind;

const instparams = @import("instparams.zig");
const variants = @import("variants.zig");
const cards = @import("cards.zig");
const bins = @import("bins.zig");
const facts = @import("facts.zig");
const plugins = @import("plugins.zig");
const emit = @import("emit.zig");
const Refs = @import("refs.zig").Refs;
const tables = @import("tables.zig");
const name_passes = @import("names.zig");
const rewrite = @import("rewrite.zig");
const Caps = emit.Caps;
const Emit = emit.Emit;
const reasonFor = emit.reasonFor;

pub const Writer = struct {
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
    /// The block whose body is being written, where the grammar has rules
    /// for lines inside it (`rule tran@script`).
    within: ?Kind = null,
    /// The one analysis of the netlist, when it has one: a spread step
    /// around it may be the kind's own line (HSPICE `.temp 0 27`).
    sole: ?*const ir.Stmt = null,
    /// Model name to its family, for rules that depend on it (`bjt[hicum2]`):
    /// the models of this file, then those of the project's other files.
    families: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Model name to the Verilog-A module its card names (a type no table
    /// lists), for a dialect that names the module on the instance.
    modules: std.StringHashMapUnmanaged([]const u8) = .empty,
    plugins_said: std.StringHashMapUnmanaged(void) = .empty,
    env: ?*const ir.Env = null,
    /// Model cards whose parameters were copied by name: one caveat per
    /// file, naming the first, not one per card (sky130 has thousands).
    copied: struct { n: usize = 0, name: []const u8 = "", family: []const u8 =
        "",
    source: []const u8 = "", line: u32 = 0 } = .{},
    /// Written as a stream, the instances that references name (`Refs`).
    refs: ?*Refs = null,
    /// Model parameters not written with a warning (`noparam ... warning`),
    /// per rule: one report per file, naming the first card (sky130 has a
    /// version on every bin). An error is reported card by card.
    refused: std.AutoArrayHashMapUnmanaged(
        *const grammar.NoParam,
        struct { n: usize, name: []const u8, line: u32 },
    ) = .empty,
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
    /// The next subcircuit is one of those `split` writes.
    variant: bool = false,
    /// The first instance that gives parameters to a subcircuit of another
    /// file, where the target has no conditional blocks (`foreignNote`).
    foreign_inst: ?struct { line: u32, name: []const u8, master: []const u8 } = null,
    /// Lines no rule understood, written back as they were in their own
    /// dialect: one note a file (`keptNote`).
    kept: struct { n: usize = 0, line: u32 = 0 } = .{},
    /// The keys the grammar's `clash` lines watch (`collectClashKeys`).
    clash_keys: ir.CaselessSet = .empty,
    /// How many subcircuits the statement being written is inside.
    depth: u32 = 0,
    /// The terminals of the instances of each model (`collectTerminals`).
    terminals: facts.TerminalMap = .empty,

    pub const Hoisted = struct { n: usize = 0, name: []const u8 = "", source: []const u8 =
        "",
        line: u32 = 0 };

    pub const Error = Allocator.Error || std.Io.Writer.Error;

    const wrap_at = 100;

    pub fn breakLine(w: *Writer) Error!void {
        const cfg = &w.g.lex;
        if (cfg.cont_lead.len > 0) {
            try w.out.print("\n{s} ", .{cfg.cont_lead});
        } else try w.out.print(" {s}\n    ", .{cfg.cont_trail});
    }

    /// Write one statement. A long one is broken at a blank, outside any
    /// quotes and brackets, with the dialect's continuation mark.
    pub fn line(w: *Writer, text: []const u8) Error!void {
        w.last_blank = false;
        const cfg = &w.g.lex;
        const can_wrap = cfg.cont_lead.len > 0 or cfg.cont_trail.len > 0;
        if (text.len <= wrap_at or !can_wrap or w.nowrap or std.mem.indexOfScalar(
            u8,
            text,
            '\n',
        ) != null) {
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

    pub fn comment(w: *Writer, text: []const u8) Error!void {
        const marker = if (w.g.lex.line_comments.len > 0) w.g.lex.line_comments[0] else "*";
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| {
            if (l.len == 0)
                try w.out.print("{s}\n", .{marker})
            else
                try w.out.print("{s} {s}\n", .{ marker, l });
        }
        w.last_blank = false;
    }

    /// A statement and the comment that trailed it in the source.
    pub fn lineTail(w: *Writer, text: []const u8, tail: []const u8) Error!void {
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
    pub fn sourceOf(w: *const Writer, st: *const ir.Stmt) []const u8 {
        return if (st.dialect != 0) dialects.nameOf(st.dialect) else w.source;
    }

    pub fn familyOf(w: *const Writer, model: []const u8) []const u8 {
        if (w.families.get(model)) |f| return f;
        return if (w.env) |e| e.family_of.get(model) orelse "" else "";
    }

    pub fn supporters(w: *Writer, kind: Kind) []const u8 {
        const c = w.caps orelse return "";
        return c.kinds[@backingInt(kind)];
    }

    /// After the last statement: an instance whose subcircuit may be
    /// written once for each branch in its own file, said once.
    pub fn foreignNote(w: *Writer) void {
        const x = w.foreign_inst orelse return;
        w.report.add(.warning, .ambiguous, x.line, "instance '{s}' gives parameters to " ++
            "subcircuit '{s}', which is not in this file; {s} has no conditional blocks, so a " ++
            "subcircuit that holds one is written once for each branch, and which one this " ++
            "instance names can only be told with the library: translate the two together " ++
            "(`sprack project`, or a PDK)", .{
            x.name, x.master, w.g.name,
        });
    }

    /// After the last statement: the model cards whose parameters were
    /// copied by name, said once, naming the first.
    pub fn copiedNote(w: *Writer) void {
        const cp = w.copied;
        const g = w.g;
        if (cp.n == 1) {
            w.report.add(.warning, .caveat, cp.line, "model '{s}' ({s}): {s} and {s} ship " ++
                "different implementations and versions of this model; parameters were copied " ++
                "as written, check them against {s}", .{
                cp.name, cp.family, cp.source, g.name, g.name,
            });
        } else if (cp.n > 1) {
            w.report.add(.warning, .caveat, cp.line, "model '{s}' ({s}) and {d} more model " ++
                "cards: {s} and {s} ship different implementations and versions of these " ++
                "models; parameters were copied as written, check them against {s}", .{
                cp.name, cp.family, cp.n - 1, cp.source, g.name, g.name,
            });
        }
    }

    /// After the last statement: the lines written back as text, said once.
    pub fn keptNote(w: *Writer) void {
        if (w.kept.n == 0) return;
        w.report.add(.info, .oneway, w.kept.line, "{d} statement{s} no {s} rule understood " ++
            "{s} written back as {s}, from this line on; {s} itself may refuse {s}, and they " ++
            "read back as text (`sprack audit` counts them)", .{
            w.kept.n,
            if (w.kept.n == 1)
                ""
            else
                "s",
            w.g.name,
            if (w.kept.n == 1) "is" else "are",
            if (w.kept.n == 1) "it was" else "they were",
            w.g.name,
            if (w.kept.n == 1) "it" else "them",
        });
    }

    /// After the last statement: what `refused` gathered, one entry a rule.
    /// A loss, so that the cards reading back without the parameter is explained.
    pub fn refusals(w: *Writer) void {
        for (w.refused.keys(), w.refused.values()) |np, r| {
            if (r.n == 1) {
                w.report.add(
                    .warning,
                    .loss,
                    r.line,
                    "model '{s}': {s} not written: {s}",
                    .{ r.name, np.key, np.text },
                );
            } else {
                w.report.add(
                    .warning,
                    .loss,
                    r.line,
                    "model '{s}' and {d} more card{s} in this file: {s} not written: {s}",
                    .{ r.name, r.n - 1, if (r.n == 2) "" else "s", np.key, np.text },
                );
            }
        }
        var buf: [48]u8 = undefined;
        const hs = w.hoisted;
        if (hs.n > 0)
            w.report.add(.info, .oneway, hs.line, "subckt '{s}'{s}: the parameters defined " ++
                "inside are written on the header, which reads back there; {s} gives an " ++
                "instance's value to that instance alone only for a parameter of the header", .{
                hs.name,
                if (hs.n > 1)
                    std.fmt.bufPrint(
                        &buf,
                        " and {d} more in this file",
                        .{hs.n - 1},
                    ) catch unreachable
                else
                    "",
                w.g.name,
            });
        const us = w.unhoisted;
        if (us.n > 0)
            w.report.add(.warning, .ambiguous, us.line, "subckt '{s}'{s}: the parameters " ++
                "defined inside are written as they were; {s} gives an instance's value to " ++
                "that instance alone only for a parameter of the header, and what {s} does " ++
                "with one defined inside is not measured", .{
                us.name,
                if (us.n > 1)
                    std.fmt.bufPrint(
                        &buf,
                        " and {d} more in this file",
                        .{us.n - 1},
                    ) catch unreachable
                else
                    "",
                w.g.name,
                us.source,
            });
    }

    /// The grammar of the dialect `st` was read in, when it is a built-in one.
    pub fn sourceGrammar(w: *const Writer, st: *const ir.Stmt) ?*const Grammar {
        const c = w.caps orelse return null;
        for (c.grammars) |*g| if (std.mem.eql(u8, g.name, w.sourceOf(st))) return g;
        return null;
    }

    /// A statement the target's grammar says with other statements (a
    /// `rewrite` block): those are written in its place, with what the
    /// rewrite reports. False: no rewrite applies, and the statement is
    /// written as it is.
    pub fn rewritten(w: *Writer, a: Allocator, st: *const ir.Stmt) Error!bool {
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
        for (parts) |*part| try w.leaf(a, part);
        return true;
    }

    /// Why command `cmd` of a `simctl` statement is left out here: the
    /// `inert` line of the dialect it was read in, with this dialect named
    /// where the line says `{to}`. A statement of no dialect this binary
    /// has a grammar for (one built from JSON or Python) is every
    /// built-in dialect's: the first that lists the command decides.
    pub fn inertCommand(w: *Writer, st: *const ir.Stmt, cmd: []const u8) Allocator.Error!?[]const u8 {
        const why = if (w.sourceGrammar(st)) |sg|
            sg.inertReason(st.kind, cmd)
        else for (if (w.caps) |c| c.grammars else &.{}) |*g| {
            if (g.inertReason(st.kind, cmd)) |text| break text;
        } else null;
        const text = why orelse return null;
        return try reasonFor(w.arena, text, w.g.name);
    }

    /// Where the statements being written come from (`tables.Origin`).
    pub fn origin(w: *const Writer) tables.Origin {
        return .{ .source = w.source, .grammars = if (w.caps) |c| c.grammars else &.{} };
    }

    /// What the name passes take of the writer (`names.Pass`).
    pub fn pass(w: *const Writer) name_passes.Pass {
        return .{ .arena = w.arena, .perm = w.perm, .g = w.g, .report = w.report };
    }

    pub fn emitter(w: *Writer, a: Allocator, st: *const ir.Stmt) Emit {
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
    pub fn bodyCount(stmts: []const ir.Stmt) usize {
        var n: usize = 0;
        for (stmts) |*s| {
            if (s.kind != .comment) n += 1;
            n += bodyCount(s.body);
        }
        return n;
    }

    /// The statements of a block not written, each as a comment.
    pub fn bodyComments(w: *Writer, a: Allocator, stmts: []const ir.Stmt) Error!void {
        for (stmts) |*s| {
            if (s.kind == .comment) continue;
            if (s.kind == .@"opaque") {
                var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, s.raw, "\n"), '\n');
                while (it.next()) |l| try w.comment(try a.print("[sprack] not written: {s}", .{l}));
            } else {
                if (s.kind == .simctl) {
                    const args: []const u8 = switch (s.get("args")) {
                        .atom, .str, .expr => |x| x,
                        else => "",
                    };
                    try w.comment(
                        try a.print("[sprack] not written: {s}{s}{s}", .{ if (s.get("cmd") == .atom)
                            s.get("cmd").atom
                        else
                            "", if (args.len > 0) " " else "", args }),
                    );
                    continue;
                }
                const name = s.get("name");
                try w.comment(
                    try a.print(
                        "[sprack] not written: {s}{s}{s}",
                        .{ @tagName(s.kind), if (name == .atom)
                            " "
                        else
                            "", if (name == .atom) name.atom else "" },
                    ),
                );
            }
            try w.bodyComments(a, s.body);
        }
    }

    pub fn unsupported(w: *Writer, a: Allocator, st: *const ir.Stmt, also: []const u8) Error!void {
        const held = bodyCount(st.body);
        const after = if (held == 0)
            ""
        else
            try a.print(". The {d} statement{s} it holds {s} not written either, and {s} in " ++
                "the output as comments", .{
                held,
                if (held == 1)
                    ""
                else
                    "s",
                if (held == 1) "is" else "are",
                if (held == 1) "is" else "are",
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
        w.report.add(.@"error", .unsupported, st.line, "{s} '{s}' cannot be written for {s}: " ++
            "{s}{s}. Dialects that define it: {s}{s}", .{
            what,  @tagName(st.kind), w.g.name, reason, also,
            if (who.len > 0)
                who
            else
                "none",
            after,
        });
        try w.comment(
            try a.print(
                "[sprack] not written: {s} '{s}' has no {s} form",
                .{ what, @tagName(st.kind), w.g.name },
            ),
        );
        try w.bodyComments(a, st.body);
    }

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
        if (std.mem.eql(u8, dialect, w.g.name)) return w.lineTail(said.items, st.tail);
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
        try w.comment(try w.arena.print("[sprack] not written: {s}", .{said.items}));
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
            for (st.body) |*child| try w.stmt(child);
            return;
        }
        if (st.kind == .native) return w.native(st);
        if (st.kind == .device and st.get("module") == .none) switch (try plugins.withModule(w, st)) {
            .keep => {},
            .done => return,
            .stmt => |d| return w.stmt(&d),
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
                return w.comment(
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
            return w.comment(try w.arena.print("[sprack] not written: {s}", .{said}));
        }
        if (try instparams.hoistParams(w, st)) |h| return w.stmt(&h);
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
                    for (stmts) |*s| try w.stmt(s);
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
            return w.unsupported(w.arena, st, also);
        }
        // A block kind this dialect has only a rule for: the rule says the
        // header, the body follows it (Xyce `.sampling` ahead of its
        // analyses), or the rule is added to each statement of the body
        // (`spread`, HSPICE `monte=`).
        if (st.body.len > 0 and w.g.blockOf(st.kind) == null and w.g.canWrite(st.kind)) {
            // Only a kind with lines of its own (a word starts its endings:
            // `.temp`) may be such a line; HSPICE's Monte Carlo has none.
            if (w.g.isSpread(st.kind) and
                !(st == w.sole and w.g.spreadWord(st.kind) != null and try w.fits(st)))
                return w.spread(st);
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
                    const held = bodyCount(st.body);
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
                    try w.comment(
                        try w.arena.print(
                            "[sprack] not written: {s} {s}={s}",
                            .{ @tagName(st.kind), sl.name, v.atom },
                        ),
                    );
                    try w.bodyComments(w.arena, st.body);
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
            try w.lineTail(e.buf.items, st.tail);
            for (b.inner) |pat| {
                if (!e.anyBound(pat)) continue;
                e.buf.clearRetainingCapacity();
                if (try e.seq(pat)) try w.line(e.buf.items);
            }
            {
                const was = w.within;
                w.within = st.kind;
                defer w.within = was;
                for (st.body) |*child| try w.stmt(child);
            }
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
        // Not where the sweep itself has no form: its statements were said
        // to be left out with it.
        if (schema.info(st.kind).class == .analysis and w.g.canWrite(st.kind))
            for (st.body) |*child| try w.stmt(child);
    }

    /// Where a step is one line that sweeps every analysis of the netlist, a
    /// step that sweeps only some of them cannot be said.
    pub fn checkSteps(w: *Writer, stmts: []const ir.Stmt) void {
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
            w.report.add(
                .@"error",
                .invalid,
                st.line,
                "step: the netlist has no analysis for the {s} sweep to repeat",
                .{w.g.name},
            );
        if (outside and !w.g.isSpread(.step))
            w.report.add(
                .@"error",
                .invalid,
                st.line,
                "step: a {s} sweep applies to every analysis of the netlist; this one leaves " ++
                    "some out",
                .{w.g.name},
            );
    }

    /// What `stmt` writes for `st`, as text.
    pub fn capture(w: *Writer, st: *const ir.Stmt) Error![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(w.arena);
        const saved = w.out;
        w.out = &aw.writer;
        defer w.out = saved;
        try w.stmt(st);
        return aw.written();
    }

    /// `spread`: the block's own rule ends each statement of its body.
    pub fn spread(w: *Writer, st: *const ir.Stmt) Error!void {
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

    /// A rule for the kind where the writer is (inside a block whose lines
    /// have rules of their own, those).
    pub fn canWriteHere(w: *const Writer, kind: Kind) bool {
        for (w.g.rules) |*r|
            if (r.kind == kind and r.dir != .read and w.g.ruleHere(r, w.within)) return true;
        return w.g.blockOf(kind) != null;
    }

    /// Does one of the kind's own rules (not an ending) say `st` whole?
    pub fn fits(w: *Writer, st: *const ir.Stmt) Error!bool {
        var head = st.*;
        head.body = &.{};
        for (w.g.rules) |*rule| {
            if (rule.kind != st.kind or rule.dir == .read or w.g.isEnding(rule)) continue;
            if (!w.g.ruleHere(rule, w.within)) continue;
            var e = w.emitter(w.arena, &head);
            e.quiet = true;
            if (try e.seq(rule.pat) and try e.lossCount() == 0) return true;
        }
        return false;
    }

    pub fn leaf(w: *Writer, a: Allocator, st_in: *const ir.Stmt) Error!void {
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
                // A statement the grammar names as its own is understood.
                if (w.g.ownReason(st.raw) == null) {
                    if (w.kept.n == 0) w.kept.line = st.line;
                    w.kept.n += 1;
                }
                return w.lineTail(st.raw, st.tail);
            }
            // A region the source grammar keeps verbatim, and says why.
            if (w.caps) |c| for (c.grammars) |*sg| {
                if (!std.mem.eql(u8, sg.name, w.sourceOf(st))) continue;
                if (sg.ownReason(st.raw)) |why| {
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
                    return w.comment(
                        try a.print("[sprack] not written: {s}", .{std.mem.sliceTo(st.raw, '\n')}),
                    );
                }
                for (sg.raws) |rb| {
                    if (rb.reason.len == 0 or !std.mem.startsWith(u8, st.raw, rb.open)) continue;
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
                                "it", .{ more, if (more == 1) "" else "s" }), w.g.name, rb.reason },
                    );
                    return w.comment(
                        try a.print("[sprack] not written: {s}", .{std.mem.sliceTo(st.raw, '\n')}),
                    );
                }
            };
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
            return w.comment(
                try a.print("[sprack] untranslated {s}: {s}", .{ w.sourceOf(st), st.raw }),
            );
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
            w.report.add(
                .@"error",
                .invalid,
                st.line,
                "{s}: a statement without a name cannot be written",
                .{@tagName(st.kind)},
            );
            return w.comment(try a.print("[sprack] not written: {s}", .{@tagName(st.kind)}));
        }
        var chosen: ir.Stmt = undefined;
        if (st.kind == .instance and w.splits.items.len > 0 and st.get("master") == .atom and
            st.raw.ptr != cond.chosen.ptr)
        {
            const name = try variants.variantOf(w, a, st) orelse return w.comment(
                try a.print("[sprack] not written: instance '{s}'", .{st.get("name").atom}),
            );
            if (!std.ascii.eqlIgnoreCase(name, st.get("master").atom)) {
                chosen = st.*;
                try chosen.own(a);
                try chosen.set(a, schema.slot(.instance, "master"), .{ .atom = name });
                st = &chosen;
            }
        }
        if (w.g.rewrites.len > 0 and try w.rewritten(a, st)) return;
        w.ordinals[@backingInt(st.kind)] += 1;

        var mapped: ir.Stmt = undefined;
        if (st.kind == .model) {
            const m = cards.unmapModel(w, a, st) catch |err| switch (err) {
                error.Skip => return,
                else => |e| return e,
            };
            mapped = m orelse return w.comment(
                try a.print("[sprack] not written: model '{s}'", .{st.get("name").atom}),
            );
            st = &mapped;
        }
        var checked: ir.Stmt = undefined;
        if (try instparams.instParams(w, a, st)) |c| {
            checked = c;
            st = &checked;
        }

        if (!w.canWriteHere(st.kind)) {
            if (w.g.absentReason(st.kind) == null) {
                if (try ir.demoteToInstance(a, st)) |inst| {
                    if (w.g.canWrite(.instance)) {
                        // Written as an instance of its model: with no card for
                        // it in any file read, it reads back as a subcircuit's.
                        if (st.get("master") == .atom and !std.mem.eql(
                            u8,
                            w.sourceOf(st),
                            w.g.name,
                        )) {
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
        const fam: []const u8 = if (st.get("master") == .atom)
            w.familyOf(st.get("master").atom)
        else
            "";
        // A model this file does not declare: the plain forms first, then
        // any form at all rather than none.
        // The first form tried is written for real, what it reports
        // included: most statements are said whole by it, and then it is
        // the one written (`written`). Where another form is chosen, what
        // it reported is taken back and that form written after the loop.
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
        const rule = best orelse {
            // A value no form takes, whose `no kind slot` line says why
            // (`.tf i(vm) vin` into HSPICE): that, not the first form's miss.
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
                return w.comment(try a.print("[sprack] not written: {s}", .{@tagName(st.kind)}));
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
            return w.comment(try a.print("[sprack] not written: {s}", .{@tagName(st.kind)}));
        };
        var e = written orelse blk: {
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
        try w.lineTail(std.mem.trimEnd(u8, e.buf.items, "\n"), st.tail);
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
        if (e.foreign and w.g.lex.ident_values and (st.kind == .resistor or st.kind == .capacitor)) {
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
        if (e.foreign and (st.kind == .include or st.kind == .lib or st.kind == .hdl)) {
            w.report.add(
                .warning,
                .caveat,
                st.line,
                "{s} is still {s} syntax; translate that file too (`sprack project` follows " ++
                    "includes)",
                .{ try e.describe(st.get("path")), w.sourceOf(st) },
            );
        }
    }
};

pub fn markUsed(stmts: []const ir.Stmt, used: *[schema.kind_count]bool) void {
    for (stmts) |*s| {
        used[@backingInt(s.kind)] = true;
        markUsed(s.body, used);
    }
}

/// A `needs` line with `{file}`: the file given for the family.
pub fn needLine(
    arena: Allocator,
    l: []const u8,
    family: []const u8,
    env: ?*const ir.Env,
) Allocator.Error![]const u8 {
    const at = std.mem.indexOf(u8, l, "{file}") orelse return l;
    const given: []const [2][]const u8 = if (env) |e| e.provided else &.{};
    const file = for (given) |p| {
        if (std.ascii.eqlIgnoreCase(p[0], family)) break p[1];
    } else return l;
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ l[0..at], file, l[at + 6 ..] });
}
