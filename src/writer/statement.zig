//! Statement writer: one canonical statement and the target's grammar → its
//! text on the output, with what the grammar has no place for reported.
//!
//! `Writer` holds what writing a netlist needs from one statement to the
//! next (the names declared, the counts, the notes said once a file); the
//! two drivers, `whole.zig` and `stream.zig`, own the order of the passes
//! and call `Writer.stmt` for each statement.

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const dialects = @import("dialects");
const lexer = @import("lexer");
const expr = @import("expr");
const alter = @import("alter");
const cond = @import("cond");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Kind = schema.Kind;
const Value = ir.Value;
pub const pzPorts = analysis_passes.pzPorts;
pub const foldMaxord = analysis_passes.foldMaxord;
pub const idleCeilings = analysis_passes.idleCeilings;
pub const defaultOptions = analysis_passes.defaultOptions;
pub const reportDefaults = analysis_passes.reportDefaults;
pub const sameDialect = analysis_passes.sameDialect;
pub const mentions = analysis_passes.mentions;
pub const anyConverted = analysis_passes.anyConverted;
pub const uniqueParams = name_passes.uniqueParams;
pub const uniqueParamsIn = name_passes.uniqueParamsIn;
pub const Analysis = name_passes.Analysis;
pub const collectAnalyses = name_passes.collectAnalyses;
pub const uniqueAnalyses = name_passes.uniqueAnalyses;
pub const collectReserved = name_passes.collectReserved;
pub const reservedRenames = name_passes.reservedRenames;
pub const renameParams = name_passes.renameParams;
pub const CaselessMap = name_passes.CaselessMap;
pub const masterRenames = name_passes.masterRenames;
pub const renamesOf = name_passes.renamesOf;
pub const collectMasters = name_passes.collectMasters;
pub const renameMasters = name_passes.renameMasters;
pub const uniqueMasters = name_passes.uniqueMasters;
pub const clashes = name_passes.clashes;
pub const collectDeclared = name_passes.collectDeclared;
pub const CaseMaps = name_passes.CaseMaps;
pub const checkCase = name_passes.checkCase;
pub const collectInstances = name_passes.collectInstances;
pub const collectFuncs = name_passes.collectFuncs;

const emit = @import("emit.zig");
const Refs = @import("refs.zig").Refs;
const tables = @import("tables.zig");
const analysis_passes = @import("analyses.zig");
const name_passes = @import("names.zig");
const rewrite = @import("rewrite.zig");
pub const Caps = emit.Caps;
pub const Emit = emit.Emit;
pub const reasonFor = emit.reasonFor;
pub const spellingsOf = tables.spellingsOf;
pub const spellingCanon = tables.spellingCanon;
pub const takes = tables.takes;
pub const idleCeiling = tables.idleCeiling;
pub const describeValue = tables.describeValue;

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
    terminals: TerminalMap = .empty,

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

    pub fn unmapModel(w: *Writer, a: Allocator, st: *const ir.Stmt) (Error || error{Skip})!?ir.Stmt {
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
                    if (sg.ownModelReason(ty)) |why| {
                        w.report.add(
                            .@"error",
                            .unsupported,
                            st.line,
                            "model '{s}' of type '{s}' cannot be written for {s}: {s}",
                            .{ st.get("name").atom, ty, w.g.name, why },
                        );
                        try w.comment(
                            try a.print(
                                "[sprack] not written: model '{s}' ({s})",
                                .{ st.get("name").atom, ty },
                            ),
                        );
                        return error.Skip;
                    }
                    for (sg.models) |*m| for (m.spellings) |*sp| {
                        if (std.ascii.eqlIgnoreCase(sp.type, ty)) builtin = true;
                    };
                };
                if (builtin) {
                    w.report.add(.@"error", .unsupported, st.line, "model '{s}': type '{s}' " ++
                        "with these parameters is not in the {s} models table, so its {s} " ++
                        "name is unknown; written as it was", .{
                        st.get("name").atom, ty, w.sourceOf(st), w.g.name,
                    });
                } else if (w.needsPlugin(ty)) {
                    w.report.add(
                        .@"error",
                        .unsupported,
                        st.line,
                        "model '{s}' is of the Verilog-A module '{s}': {s} takes it only from " ++
                            "a plugin of the module; build one with buildxyceplugin and name " ++
                            "it with --provide {s}=FILE",
                        .{ st.get("name").atom, ty, w.g.name, ty },
                    );
                } else if (w.namesModule() and st.get("params") == .params) {
                    // Xyce finds a card's device by type and level, and a
                    // plugin is level 1: IHP's `mosvar level=1000` card is
                    // "no valid model card" for its Y line, and the same
                    // card without it gives ngspice's current (#52).
                    w.report.add(
                        .warning,
                        .caveat,
                        st.line,
                        "model '{s}' is of the Verilog-A module '{s}': {s} must load the same " ++
                            "module",
                        .{ st.get("name").atom, ty, w.g.name },
                    );
                    const ps = st.get("params").params;
                    for (ps, 0..) |p, i| if (std.ascii.eqlIgnoreCase(p.key, "level")) {
                        w.report.add(
                            .warning,
                            .loss,
                            st.line,
                            "model '{s}': level not written: {s} takes a plugin's card only " ++
                                "at the plugin's own level, so the module runs at its default " ++
                                "level",
                            .{ st.get("name").atom, w.g.name },
                        );
                        var out = st.*;
                        try out.own(a);
                        const rest = try std.mem.concat(a, ir.Param, &.{ ps[0..i], ps[i + 1 ..] });
                        try out.set(a, schema.slot(.model, "params"), if (rest.len > 0)
                            .{ .params = rest }
                        else
                            .none);
                        return out;
                    };
                } else if (w.g.absentReason(.device)) |why| {
                    w.report.add(
                        .@"error",
                        .unsupported,
                        st.line,
                        "model '{s}' is of the Verilog-A module '{s}': {s}",
                        .{ st.get("name").atom, ty, why },
                    );
                } else {
                    w.report.add(
                        .warning,
                        .caveat,
                        st.line,
                        "model '{s}' is of the Verilog-A module '{s}': {s} must load the same " ++
                            "module",
                        .{ st.get("name").atom, ty, w.g.name },
                    );
                }
            }
            return st.*;
        }
        if (std.mem.eql(u8, fam.atom, ir.unlisted_builtin)) {
            var plain = st.*;
            try plain.own(a);
            try plain.set(a, schema.slot(.model, "family"), .none);
            if (!same)
                w.report.add(.@"error", .unsupported, st.line, "model '{s}': '{s}' is a " ++
                    "built-in {s} model type that the {s} models table does not list, so its " ++
                    "{s} name is unknown; written as it was", .{
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
                    if (w.g.canWrite(k) and schema.slotOf(k, "master") == null) {
                        w.report.add(
                            .info,
                            .cosmetic,
                            st.line,
                            "model '{s}' only names a built-in {s}; {s} needs no such line",
                            .{ st.get("name").atom, fam.atom, w.g.name },
                        );
                        return error.Skip;
                    }
                }
            }
            const who = if (w.caps) |c| c.family(fam.atom, pol) else "";
            // No model cards at all here (CDL): the grammar's reason, not a gap in its table.
            if (w.g.absentReason(.model)) |why| {
                w.report.add(.@"error", .unsupported, st.line, "model '{s}' cannot be written " ++
                    "for {s}: {s}. Dialects that define the family: {s}", .{
                    st.get("name").atom, w.g.name, why, if (who.len > 0) who else "none",
                });
                return null;
            }
            if (w.g.noFamilyReason(fam.atom)) |why| {
                w.report.add(.@"error", .unsupported, st.line, "model '{s}' ({s}{s}{s}) " ++
                    "cannot be written for {s}: {s}. Defined by: {s}", .{
                    st.get("name").atom, fam.atom,
                    if (pol.len > 0)
                        " "
                    else
                        "",
                    pol,                 w.g.name,
                    why,                 if (who.len > 0) who else "none",
                });
                return null;
            }
            w.report.add(.@"error", .unsupported, st.line, "model '{s}': {s}.spgrammar has no " ++
                "spelling for model family '{s}{s}{s}'. Defined by: {s}", .{
                st.get("name").atom, w.g.name,                         fam.atom,
                if (pol.len > 0)
                    " "
                else
                    "",
                pol,                 if (who.len > 0) who else "none",
            });
            return null;
        };
        if (entry.provided) {
            const file = w.providedFile(fam.atom) orelse {
                w.report.add(.@"error", .unsupported, st.line, "model '{s}' ({s}): {s} has no " ++
                    "built-in {s}; it runs one as a compiled module given to the translation: " ++
                    "--provide {s}=FILE", .{
                    st.get("name").atom, fam.atom, w.g.name, fam.atom, fam.atom,
                });
                return null;
            };
            if (w.plugins_said.get(fam.atom) == null) {
                // Kept for the file: w.arena is the statement's when streamed.
                try w.plugins_said.put(w.perm, try w.perm.dupe(u8, fam.atom), {});
                w.report.add(
                    .warning,
                    .caveat,
                    st.line,
                    "model '{s}' ({s}): written for the module {s} given to the translation; " ++
                        "{s} has no built-in one",
                    .{ st.get("name").atom, fam.atom, file, w.g.name },
                );
            }
        }
        const sp = try w.chooseSpelling(a, st, entry, fam.atom);
        var out = try ir.newStmt(a, .model, st.line);
        out.tail = st.tail;
        out.mask = st.mask;
        out.bound = st.bound;
        try out.own(a);
        try out.set(a, schema.slot(.model, "type"), .{ .atom = sp.type });
        try out.set(a, schema.slot(.model, "family"), .none);
        try out.set(a, schema.slot(.model, "polarity"), .none);
        var ps: std.ArrayList(ir.Param) = .empty;
        for (sp.kv) |kv| {
            if (kv.absent or kv.min) continue;
            const v: Value = if (lexer.parseNumber(a, &w.g.lex, kv.val)) |n|
                .{ .num = n }
            else
                .{ .atom = kv.val };
            try ps.append(a, .{ .key = kv.key, .val = v });
        }
        const selectors = ps.items.len;
        if (st.get("params") == .params) for (st.get("params").params) |p| {
            // A parameter the level says (`version=107` as `level=107`).
            const said = !same and for (sp.when) |c| {
                if (!c.isNodes() and std.ascii.eqlIgnoreCase(c.key, p.key)) break true;
            } else false;
            if (said) {
                w.report.add(.info, .oneway, st.line, "model '{s}': {s}={s} is said by the " ++
                    "{s} {s} spelling and is not written: {s} has no such parameter; it reads " ++
                    "back without it", .{
                    st.get("name").atom, p.key,
                    try expr.canonText(
                        a,
                        p.val,
                    ),
                    w.g.name,            try spellingText(a, sp),
                    w.g.name,
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
                for (ps.items[i + 1 ..], i + 1..) |later, j|
                    if (std.ascii.eqlIgnoreCase(later.key, k)) {
                        if (i < selectors) {
                            w.report.add(
                                .warning,
                                .loss,
                                st.line,
                                "model '{s}': its own '{s}' is not written: in {s} that " ++
                                    "parameter names the model",
                                .{ st.get("name").atom, later.key, w.g.name },
                            );
                            _ = ps.orderedRemove(j);
                        } else {
                            w.report.add(
                                .warning,
                                .invalid,
                                st.line,
                                "model '{s}': '{s}' is given twice; the last value is kept",
                                .{ st.get("name").atom, k },
                            );
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
                        w.report.add(
                            .@"error",
                            .loss,
                            st.line,
                            "model '{s}': {s} not written: {s}",
                            .{ name, p.key, np.text },
                        );
                    } else {
                        const r = try w.refused.getOrPut(w.perm, np);
                        if (r.found_existing)
                            r.value_ptr.n += 1
                        else
                            r.value_ptr.* = .{
                                .n = 1,
                                .name = try w.perm.dupe(u8, name),
                                .line = st.line,
                            };
                    }
                    _ = ps.orderedRemove(j);
                    break;
                }
            }
        }
        const th = try expr.thresholds(a, w.g, fam.atom, ps.items, true);
        if (th.changed and !th.no_half)
            w.report.add(
                .warning,
                .caveat,
                st.line,
                "model '{s}': the threshold and hysteresis are written as on and off levels; " ++
                    "{s} moves smoothly between them where SPICE switches with hysteresis",
                .{ st.get("name").atom, w.g.name },
            );
        if (th.changed) for (th.params) |p| if (p.val == .expr and isLevel(w.g, p.key)) {
            w.report.add(
                .info,
                .oneway,
                st.line,
                "model '{s}': levels computed from expressions read back as equal expressions " ++
                    "of another shape",
                .{st.get("name").atom},
            );
            break;
        };
        if (th.no_half)
            w.report.add(
                .@"error",
                .loss,
                st.line,
                "model '{s}': a switch with no hysteresis has no {s} form; its on and off " ++
                    "levels would be equal",
                .{ st.get("name").atom, w.g.name },
            );
        try out.set(a, schema.slot(.model, "params"), if (th.params.len > 0)
            .{ .params = th.params }
        else
            .none);
        if (!same and st.get("params") == .params) {
            if (w.copied.n == 0)
                w.copied = .{
                    .name = try w.perm.dupe(u8, st.get("name").atom),
                    .family = fam.atom,
                    .source = w.sourceOf(st),
                    .line = st.line,
                };
            w.copied.n += 1;
        }
        return out;
    }

    /// The spelling of the family `entry` a card is written with: the first
    /// whose `when` conditions hold, on the card's own parameters or on the
    /// terminals of the instances that name it. A condition that cannot be
    /// told, or instances of more than one count, is said.
    pub fn chooseSpelling(
        w: *Writer,
        a: Allocator,
        st: *const ir.Stmt,
        entry: *const grammar.ModelEntry,
        fam: []const u8,
    ) Allocator.Error!grammar.ModelSpelling {
        const name = st.get("name").atom;
        const ps: []const ir.Param = if (st.get("params") == .params)
            st.get("params").params
        else
            &.{};
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
                    if (t.min < @as(
                        u32,
                        @intFromFloat(want),
                    ) and t.max >= @as(u32, @intFromFloat(want))) mixed = true;
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
                    unknown = unknown orelse try a.print(
                        "{s}={s} is none of the values the spellings name",
                        .{ c.key, try expr.canonText(a, v) },
                    );
                    break false;
                }
            } else true;
            if (!holds) continue;
            if (std.mem.eql(u8, w.sourceOf(st), w.g.name)) return sp;
            if (mixed)
                w.report.add(.warning, .ambiguous, st.line, "model '{s}' ({s}): instances " ++
                    "with {d} and with {d} terminals name it, and {s} has a model of its own " ++
                    "for each; it is written as {s}", .{
                    name, fam, used.?.min, used.?.max, w.g.name, try spellingText(a, sp),
                })
            else if (unknown) |why|
                if (sp.when.len == 0)
                    w.report.add(.warning, .caveat, st.line, "model '{s}' ({s}): {s} writes " ++
                        "another model by its conditions, and {s}; it is written as {s}", .{
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
    pub fn cardParams(
        w: *Writer,
        a: Allocator,
        st: *const ir.Stmt,
        family: []const u8,
        ps: *std.ArrayList(ir.Param),
        own: usize,
    ) Allocator.Error!void {
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
                if (std.ascii.eqlIgnoreCase(
                    p.key,
                    np.key,
                ) and p.val == .num and p.val.num.toFloat() == want) break;
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
        const Canon = struct { p: ir.Param, wrote: []const u8, as_is: bool = false, done: bool =
            false };
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
                const half: Value = if (!e.halved)
                    p.val
                else if (p.val == .num)
                    try expr.arith(a, .mul, p.val, .{ .num = .init("5", -1) })
                else
                    try expr.halve(a, p.val);
                const c: ir.Param = .{ .key = e.canon, .val = half };
                try cs.append(a, .{ .p = c, .wrote = if (e.halved) e.canon else p.key });
                if (e.halved) try halves.append(a, c);
            }
            if (halves.items.len > 0)
                w.report.add(.info, .rename, st.line, "model '{s}': {s} of {s} is {s}, each " ++
                    "half its value", .{
                    name, try em.describe(.{ .params = &.{p} }), sg.name, try em.describe(.{ .params = halves.items }),
                });
            if (taken) continue;
            if (spellingsOf(from, p.key)) |e| {
                w.report.add(
                    .warning,
                    .loss,
                    st.line,
                    "model '{s}': {s} not written: the {s} model of {s} does not take it; " ++
                        "that parameter is '{s}' there",
                    .{ name, p.key, family, sg.name, e.spellings[0] },
                );
                continue;
            }
            try cs.append(a, .{ .p = p, .wrote = p.key, .as_is = true });
        }
        ps.shrinkRetainingCapacity(own);
        // A corner where one of the two computes something else, once a card.
        if (sg != w.g) for (cs.items) |c| {
            if (c.as_is) continue;
            const text = w.g.edgeText(
                family,
                c.p.key,
            ) orelse sg.edgeText(family, c.p.key) orelse continue;
            w.report.add(
                .warning,
                .caveat,
                st.line,
                "model '{s}': {s}: {s}",
                .{ name, c.p.key, text },
            );
            break;
        };
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
                        if (!dup)
                            try takes_list.print(a, "{s}{s}", .{ if (takes_list.items.len > 0)
                                ", "
                            else
                                "", t.spellings[0] });
                    }
                    w.report.add(.@"error", .loss, st.line, "model '{s}': {s} not written: " ++
                        "the {s} card of {s} takes no such parameter; it takes {s}", .{
                        name,
                        try em.describe(
                            .{ .params = &.{.{ .key = c.wrote, .val = c.p.val }} },
                        ),
                        family,
                        w.g.name,
                        takes_list.items,
                    });
                    continue;
                }
                // Under the name it was written by: the canonical one may
                // mean something else to a target that does not list it,
                // unless a `noparam` line of the target names it.
                const refused = for (w.g.noparams) |np| {
                    if (std.mem.eql(
                        u8,
                        np.family,
                        family,
                    ) and std.ascii.eqlIgnoreCase(np.key, c.p.key)) break true;
                } else false;
                try ps.append(a, .{ .key = if (refused) c.p.key else c.wrote, .val = c.p.val });
                continue;
            };
            if (!e.halved) {
                if (!std.ascii.eqlIgnoreCase(e.spellings[0], c.wrote))
                    w.report.add(
                        .info,
                        .rename,
                        st.line,
                        "model '{s}': the parameter '{s}' is spelled '{s}' in {s}",
                        .{ name, c.wrote, e.spellings[0], w.g.name },
                    );
                try ps.append(a, .{ .key = if (std.ascii.eqlIgnoreCase(e.spellings[0], c.wrote))
                    c.wrote
                else
                    e.spellings[0], .val = c.p.val });
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
                try names.print(a, "{s}{s}", .{ if (names.items.len > 0)
                    " and "
                else
                    "", t.canon });
                var v: Value = .{ .num = .init("0", 0) };
                // The last of a name, as the simulators take a card.
                for (cs.items[i..]) |*o|
                    if (!o.as_is and std.ascii.eqlIgnoreCase(o.p.key, t.canon)) {
                        v = o.p.val;
                        o.done = true;
                        try shown.append(a, .{ .key = o.wrote, .val = v });
                    };
                if (value) |first| same = same and v.eql(first) else value = v;
            }
            const was = try em.describe(.{ .params = shown.items });
            if (same) {
                const twice: ir.Param = .{
                    .key = e.spellings[0],
                    .val = try expr.arith(a, .mul, value.?, .{ .num = .init("2", 0) }),
                };
                const now = try em.describe(.{ .params = &.{twice} });
                if (!std.mem.eql(u8, was, now))
                    w.report.add(
                        .info,
                        .rename,
                        st.line,
                        "model '{s}': {s} is written {s}, twice the value: {s} has the one " ++
                            "parameter for {s}",
                        .{ name, was, now, w.g.name, names.items },
                    );
                try ps.append(a, twice);
                continue;
            }
            var why: std.ArrayList(u8) = .empty;
            if (w.g.computesText(family, e.canon)) |t|
                try why.print(a, ": {s} computes {s}", .{ w.g.name, t });
            if (sg.computesText(family, e.canon)) |t|
                try why.print(a, "; {s} computes {s}", .{ sg.name, t });
            w.report.add(.@"error", .loss, st.line, "model '{s}': {s} not written: {s} has " ++
                "the one parameter '{s}' for {s}, and they are not equal here (one left out " ++
                "is 0){s}", .{
                name, was, w.g.name, e.spellings[0], names.items, why.items,
            });
        }
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

    /// A parameter statement of a dialect the grammar's `hoist param` lists.
    pub fn hoists(w: *const Writer, st: *const ir.Stmt) bool {
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
    pub fn hoistParams(w: *Writer, st: *const ir.Stmt) Allocator.Error!?ir.Stmt {
        if (st.kind != .subckt or w.g.hoist_param.len == 0) return null;
        var any = false;
        var unmeasured: ?[]const u8 = null;
        for (st.body) |*c| {
            if (w.hoists(c))
                any = true
            else if (c.kind == .param and !std.mem.eql(u8, w.sourceOf(c), w.g.name))
                unmeasured = w.sourceOf(c);
        }
        const h = if (any) &w.hoisted else &w.unhoisted;
        if (any or unmeasured != null) {
            if (h.n == 0)
                h.* = .{ .name = if (st.get("name") == .atom)
                    try w.perm.dupe(u8, st.get("name").atom)
                else
                    "", .source = unmeasured orelse "", .line = st.line };
            h.n += 1;
        }
        if (!any) return null;
        const a = w.arena;
        const pi = schema.slot(.subckt, "params");
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
            if (c.tail.len > 0)
                body.appendAssumeCapacity(.{ .kind = .comment, .raw = c.tail, .line = c.line });
        }
        var out = st.*;
        try out.own(a);
        try out.set(a, pi, .{ .params = ps.items });
        out.body = body.items;
        return out;
    }

    /// The grammar of the dialect `st` was read in, when it is a built-in one.
    pub fn sourceGrammar(w: *const Writer, st: *const ir.Stmt) ?*const Grammar {
        const c = w.caps orelse return null;
        for (c.grammars) |*g| if (std.mem.eql(u8, g.name, w.sourceOf(st))) return g;
        return null;
    }

    /// A device's instance parameters against the target's `params` table:
    /// each is renamed to the target's spelling, and one the target's
    /// device does not take is a loss, not copied. Null: nothing changes.
    pub fn instParams(w: *Writer, a: Allocator, st: *const ir.Stmt) Allocator.Error!?ir.Stmt {
        if (std.mem.eql(u8, w.sourceOf(st), w.g.name)) return null;
        const idx = schema.slotOf(st.kind, "params") orelse return null;
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
                    try out.append(a, .{ .key = if (std.ascii.eqlIgnoreCase(canon, p.key))
                        p.key
                    else
                        canon, .val = p.val });
                    if (!std.ascii.eqlIgnoreCase(canon, p.key)) {
                        w.report.add(
                            .info,
                            .rename,
                            st.line,
                            "{s}: the instance parameter '{s}' is spelled '{s}' in {s}",
                            .{ @tagName(st.kind), p.key, canon, w.g.name },
                        );
                        changed = true;
                    }
                    continue;
                }
                const shown = if (p.val == .none)
                    p.key
                else
                    try a.print("{s}={s}", .{ p.key, try em.describe(p.val) });
                if (try em.inert(p.key)) |why| {
                    // A loss all the same: the statement reads back without it.
                    w.report.add(
                        .info,
                        .loss,
                        st.line,
                        "{s}: '{s}' is not written: {s}",
                        .{ @tagName(st.kind), shown, why },
                    );
                } else w.report.add(.@"error", .loss, st.line, "{s}: '{s}' has no spelling in " ++
                    "{s}, whose {s} takes no such {s}", .{
                    @tagName(st.kind), shown, w.g.name, @tagName(st.kind),
                    if (schema.info(st.kind).class == .device)
                        "instance parameter"
                    else
                        "parameter",
                });
                changed = true;
                continue;
            };
            if (entry.positive and p.val == .num and p.val.num.toFloat() <= 0) {
                w.report.add(.@"error", .invalid, st.line, "{s}: {s}={s}: {s} refuses {s} of " ++
                    "zero or less", .{
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
                w.report.add(
                    .@"error",
                    .loss,
                    st.line,
                    "{s}: '{s}={s}' is '{s}' in {s}, which the instance gives as well",
                    .{ @tagName(st.kind), p.key, try em.describe(p.val), key, w.g.name },
                );
                changed = true;
                continue;
            }
            if (!same) {
                w.report.add(
                    .info,
                    .rename,
                    st.line,
                    "{s}: the instance parameter '{s}' is spelled '{s}' in {s}",
                    .{ @tagName(st.kind), p.key, key, w.g.name },
                );
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

    /// A Verilog-A instance where the target names the module on it (Xyce
    /// `Y<module>`): the module of its model card, if the target has a
    /// plugin of it (`ir.Env.provided`); else an error that says how to get
    /// one. Null: written as it is.
    /// The file given to the translation under this name (`--provide`).
    pub fn providedFile(w: *const Writer, name: []const u8) ?[]const u8 {
        const given: []const [2][]const u8 = if (w.env) |e| e.provided else &.{};
        for (given) |p| if (std.ascii.eqlIgnoreCase(p[0], name)) return p[1];
        return null;
    }

    /// Does this dialect name the module on the instance (a plugin's), and
    /// has no plugin of this one been named?
    pub fn needsPlugin(w: *const Writer, module: []const u8) bool {
        if (!w.namesModule()) return false;
        const plugins: []const [2][]const u8 = if (w.env) |e| e.provided else &.{};
        for (plugins) |p| if (std.ascii.eqlIgnoreCase(p[0], module)) return false;
        return true;
    }

    pub const WithModule = union(enum) { keep, done, stmt: ir.Stmt };

    /// Does this dialect name the Verilog-A module on the instance (Xyce `Y<module>`)?
    pub fn namesModule(w: *const Writer) bool {
        const mi = schema.slot(.device, "module");
        for (w.g.rules) |*r|
            if (r.kind == .device and r.dir != .read and mentions(r.pat, mi)) return true;
        return false;
    }

    pub fn withModule(w: *Writer, st: *const ir.Stmt) Error!WithModule {
        const mi = schema.slot(.device, "module");
        if (!w.namesModule()) return .keep;
        const master = if (st.get("master") == .atom) st.get("master").atom else return .keep;
        const module = w.modules.get(master) orelse (if (w.env) |e|
            e.modules.get(master)
        else
            null) orelse return .keep;
        const plugins: []const [2][]const u8 = if (w.env) |e| e.provided else &.{};
        const file = for (plugins) |p| {
            if (std.ascii.eqlIgnoreCase(p[0], module)) break p[1];
        } else {
            w.report.add(
                .@"error",
                .unsupported,
                st.line,
                "device: {s} instantiates the Verilog-A module '{s}' only through a plugin of " ++
                    "it: build one with buildxyceplugin and name it with --provide {s}=FILE",
                .{ w.g.name, module, module },
            );
            try w.comment(
                try w.arena.print("[sprack] not written: {s}", .{if (st.get("name") == .atom)
                    st.get("name").atom
                else
                    "device"}),
            );
            return .done;
        };
        if (w.plugins_said.get(module) == null) {
            try w.plugins_said.put(w.perm, try w.perm.dupe(u8, module), {});
            w.report.add(
                .warning,
                .caveat,
                st.line,
                "device: the Verilog-A module '{s}' is the plugin {s}: run {s} with -plugin {s}",
                .{ module, file, w.g.name, file },
            );
        }
        var d = st.*;
        try d.own(w.arena);
        try d.set(w.arena, mi, .{ .atom = module });
        // A plugin has no m: Xyce's ADMS templates have no $mfactor
        // (FIXME_MFACTOR), Xyce 7.10 refuses `Yr3_cmc ... m=2`, and neither
        // a subcircuit's m nor IHP's own `mult` (r3_cmc.va:327, only its
        // mismatch) changes the current of IHP's rsil (#52). At 1 it is the
        // same device.
        const pi = schema.slot(.device, "params");
        if (d.at(pi) == .params)
            for (d.at(pi).params, 0..) |p, i| if (std.ascii.eqlIgnoreCase(p.key, "m")) {
                if (p.val != .num or p.val.num.toFloat() != 1) {
                    var em = w.emitter(w.arena, st);
                    w.report.add(
                        .@"error",
                        .loss,
                        st.line,
                        "device: 'm={s}' not written: a {s} plugin has no device multiplier " ++
                            "($mfactor), so the module '{s}' is simulated as one device",
                        .{ try em.describe(p.val), w.g.name, module },
                    );
                }
                const ps = d.at(pi).params;
                const rest = try std.mem.concat(w.arena, ir.Param, &.{ ps[0..i], ps[i + 1 ..] });
                try d.set(w.arena, pi, if (rest.len > 0) .{ .params = rest } else .none);
                break;
            };
        return .{ .stmt = d };
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
        if (st.kind == .model and st.body.len > 0) return w.binnedModel(st);
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
        if (st.kind == .device and st.get("module") == .none) switch (try w.withModule(st)) {
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
        // One of the subcircuits `split` writes: written as it is.
        const variant = w.variant;
        w.variant = false;
        if (st.kind == .subckt and !w.g.canWrite(.cond_if) and !variant)
            switch (try cond.split(
                w.arena,
                st,
                expr.choiceForm(w.g),
                &w.declared,
                try w.knownSplits(w.arena),
            )) {
                .none => {},
                .refused => |why| w.unsplit = why,
                .clash => |name| w.unsplit = try std.fmt.allocPrint(
                    w.arena,
                    "'{s}', the name one of them would take, is already declared",
                    .{name},
                ),
                .variants => |v| return w.split(st, &v),
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

    /// The subcircuit `st` once for each of `v`, a comment above each
    /// saying where it is the one.
    pub fn split(w: *Writer, st: *const ir.Stmt, v: *const cond.Variants) Error!void {
        const name = st.get("name").atom;
        var listed: std.ArrayList(u8) = .empty;
        for (v.list, 0..) |x, i|
            try listed.print(w.arena, "{s}'{s}' where {s}", .{ if (i > 0)
                ", "
            else
                "", x.name, x.cond });
        w.report.add(.info, .oneway, v.line, "subckt '{s}': {s} has no conditional blocks, so " ++
            "the subcircuit is written once for each branch of the {s} {d}: {s}; an instance " ++
            "is written with the one its parameters select; it reads back as {d} subcircuits", .{
            name,       w.g.name,
            if (v.more)
                "blocks from line"
            else
                "block at line",
            v.line,     listed.items,
            v.list.len,
        });
        // A statement outside the blocks is in every one of them: what it
        // reports is said once.
        var said: std.StringHashMapUnmanaged(void) = .empty;
        var new: std.ArrayList([]const u8) = .empty;
        for (v.list) |x| {
            try w.comment(
                try std.fmt.allocPrint(w.arena, "[sprack] '{s}' where {s}", .{ name, x.cond }),
            );
            var one = st.*;
            try one.own(w.arena);
            try one.set(w.arena, schema.slot(.subckt, "name"), .{ .atom = x.name });
            one.body = x.body;
            const from = w.report.items.items.len;
            w.variant = true;
            try w.stmt(&one);
            var kept = from;
            for (w.report.items.items[from..]) |d| {
                const key = try std.fmt.allocPrint(
                    w.arena,
                    "{d} {s} {s}",
                    .{ d.line, @tagName(d.code), d.msg },
                );
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
    pub fn foreignInstance(w: *Writer, stmts: []const ir.Stmt) Allocator.Error!?*const ir.Stmt {
        for (stmts) |*s| {
            if (s.kind == .instance and s.get("master") == .atom and s.get("params") == .params and
                s.get("name") == .atom)
            {
                if (!w.declared.contains(
                    try std.ascii.allocLowerString(w.arena, s.get("master").atom),
                )) return s;
            }
            if (try w.foreignInstance(s.body)) |x| return x;
        }
        return null;
    }

    /// The subcircuits noted so far as written once for each branch.
    pub fn knownSplits(w: *Writer, a: Allocator) Allocator.Error![]const cond.Known {
        var out: std.ArrayList(cond.Known) = .empty;
        for (w.splits.items) |*sp|
            if (sp.split == .variants)
                try out.append(a, .{ .name = sp.name, .variants = &sp.split.variants });
        return out.items;
    }

    /// Notes every subcircuit of `stmts` that is written as several. A
    /// subcircuit that holds an instance of one, decided by its own
    /// parameters, is one too: noted once the other is (`cond.passDown`).
    /// Returns how many were noted.
    pub fn noteSplits(w: *Writer, stmts: []const ir.Stmt) Allocator.Error!usize {
        var n: usize = 0;
        for (stmts) |*s| {
            if (s.kind == .subckt and s.get("name") == .atom) noted: {
                for (w.splits.items) |sp|
                    if (std.ascii.eqlIgnoreCase(sp.name, s.get("name").atom)) break :noted;
                const sp = try cond.split(
                    w.perm,
                    s,
                    expr.choiceForm(w.g),
                    &w.declared,
                    try w.knownSplits(w.perm),
                );
                if (sp == .variants or sp == .clash) {
                    try w.splits.append(w.perm, .{ .name = s.get("name").atom, .split = sp });
                    n += 1;
                }
            }
            n += try w.noteSplits(s.body);
        }
        return n;
    }

    /// `noteSplits` until no more are noted: a subcircuit is noted after
    /// the ones it holds instances of, at any depth.
    pub fn noteAllSplits(w: *Writer, stmts: []const ir.Stmt, env: ?*const ir.Env) Allocator.Error!void {
        var rounds: usize = 0;
        while (rounds < cond.max_variants) : (rounds += 1) {
            var n = try w.noteSplits(stmts);
            if (env) |e| n += try w.noteSplits(e.conditional.items);
            if (n == 0) break;
        }
    }

    /// The subcircuit name an instance is written with: of a subcircuit
    /// written as several, the one its parameters select. Null, reported,
    /// when that cannot be told.
    pub fn variantOf(w: *Writer, a: Allocator, st: *const ir.Stmt) Allocator.Error!?[]const u8 {
        const master = st.get("master").atom;
        var name: ?[]const u8 = null;
        for (w.splits.items) |*sp| {
            if (!std.ascii.eqlIgnoreCase(sp.name, master)) continue;
            var stop: []const u8 = "";
            const pick = switch (sp.split) {
                .variants => |*v| try cond.choose(a, v, if (st.get("params") == .params)
                    st.get("params").params
                else
                    &.{}, &stop) orelse {
                    w.report.add(
                        .@"error",
                        .unsupported,
                        st.line,
                        "instance '{s}': subcircuit '{s}' is written once for each branch of " ++
                            "its conditional block, and which of them this instance is " ++
                            "depends on parameter '{s}', which is not a number here",
                        .{ st.get("name").atom, master, stop },
                    );
                    return null;
                },
                .clash => |taken| {
                    w.report.add(
                        .@"error",
                        .unsupported,
                        st.line,
                        "instance '{s}': subcircuit '{s}' holds a conditional block, which " ++
                            "{s} has not, and is not written once for each branch: '{s}', the " ++
                            "name one of them would take, is already declared",
                        .{ st.get("name").atom, master, w.g.name, taken },
                    );
                    return null;
                },
                else => unreachable,
            };
            if (name) |other| if (!std.mem.eql(u8, other, pick)) {
                w.report.add(
                    .@"error",
                    .unsupported,
                    st.line,
                    "instance '{s}': subcircuit '{s}' is declared more than once, and this " ++
                        "instance is '{s}' by one declaration, '{s}' by another",
                    .{ st.get("name").atom, master, other, pick },
                );
                return null;
            };
            name = pick;
        }
        return name orelse master;
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

    /// Model cards `nch.1`, `nch.2`, ... grouped under `nch` by
    /// `groupBins`: the block's header names the type, each bin is a line.
    pub fn binnedModel(w: *Writer, st: *const ir.Stmt) Error!void {
        const b = w.g.blockOf(.model).?;
        const a = w.arena;
        const ti = schema.slot(.model, "type");
        const ni = schema.slot(.model, "name");
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
            w.report.add(
                .@"error",
                .invalid,
                st.line,
                "model: required values missing for the {s} form",
                .{w.g.name},
            );
            return;
        }
        try w.lineTail(e.buf.items, st.tail);
        for (bins.items) |*bin| try w.stmt(bin);
        e.buf.clearRetainingCapacity();
        if (try e.seq(b.close)) try w.line(e.buf.items);
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
            const name = try w.variantOf(a, st) orelse return w.comment(
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
            const m = w.unmapModel(a, st) catch |err| switch (err) {
                error.Skip => return,
                else => |e| return e,
            };
            mapped = m orelse return w.comment(
                try a.print("[sprack] not written: model '{s}'", .{st.get("name").atom}),
            );
            st = &mapped;
        }
        var checked: ir.Stmt = undefined;
        if (try w.instParams(a, st)) |c| {
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
            var to = mv.to == .options or w.actsOnNothing(mv, stmts);
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
            try w.check(g, st.body, before);
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
            const val = (try w.omittedValue(s, st, o, all, &missing, 0)) orelse {
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
    pub fn applyMoves(w: *Writer, stmts: []const ir.Stmt) Allocator.Error![]const ir.Stmt {
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
            // A value that acts on one analysis only, in a netlist without
            // it: nothing to act on, so not written, and nothing lost.
            const absent = w.actsOnNothing(mv, list);
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
};

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

/// `nch` of the model card `nch.12`, or null.
pub fn binBase(st: *const ir.Stmt) ?[]const u8 {
    if (st.kind != .model or st.get("name") != .atom) return null;
    return ir.binBase(st.get("name").atom);
}

/// For a dialect that writes binned models as one block (Spectre), the
/// model cards `nch.1`, `nch.2`, ... of a list become one model `nch`
/// whose body holds them, where the first of them stood.
pub fn groupBins(arena: Allocator, stmts: []const ir.Stmt) Allocator.Error![]const ir.Stmt {
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
            try parent.set(arena, schema.slot(.model, "name"), .{ .atom = base });
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

/// A switch on or off level named by one of the grammar's `threshold` lines.
pub fn isLevel(g: *const Grammar, key: []const u8) bool {
    for (g.thresholds) |t|
        if (std.ascii.eqlIgnoreCase(key, t.on) or std.ascii.eqlIgnoreCase(key, t.off)) return true;
    return false;
}

pub fn markUsed(stmts: []const ir.Stmt, used: *[schema.kind_count]bool) void {
    for (stmts) |*s| {
        used[@backingInt(s.kind)] = true;
        markUsed(s.body, used);
    }
}

/// The fewest and the most terminals of the instances that name a model.
pub const Terminals = struct { min: u32, max: u32 };
pub const TerminalMap = std.HashMapUnmanaged(
    []const u8,
    Terminals,
    ir.Caseless,
    std.hash_map.default_max_load_percentage,
);

/// How many terminals a device statement connects.
pub fn terminalCount(st: *const ir.Stmt) u32 {
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
pub fn spellingText(a: Allocator, sp: grammar.ModelSpelling) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, sp.type);
    for (sp.kv) |kv| if (!kv.absent) try out.print(a, " {s}={s}", .{ kv.key, kv.val });
    return out.items;
}

/// For every model an instance of `stmts` names, the fewest and the most
/// terminals of those instances (`when nodes>=n`).
pub fn collectTerminals(
    a: Allocator,
    stmts: []const ir.Stmt,
    out: *TerminalMap,
    src: ?[]const u8,
) Allocator.Error!void {
    for (stmts) |*s| {
        if (schema.info(s.kind).class == .device)
            if (schema.slotOf(s.kind, "master")) |mi| if (s.at(mi) == .atom) {
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

pub fn collectModules(
    arena: Allocator,
    stmts: []const ir.Stmt,
    out: *std.StringHashMapUnmanaged([]const u8),
) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .model and s.get("family") == .none and s.get("type") == .atom and
            s.get("name") == .atom)
            try out.put(arena, s.get("name").atom, s.get("type").atom);
        try collectModules(arena, s.body, out);
    }
}
