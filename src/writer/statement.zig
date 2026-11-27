//! Statement writer: what writing a netlist keeps from one statement to the
//! next (`Writer`: the names declared, the counts, the notes said once a
//! file) and what it asks of it.
//!
//! The writing itself is in the files beside this one: `blocks.zig` writes
//! one statement and what it holds, `leaf.zig` chooses the rule a statement
//! without a body is written by, `spread.zig` the sweeps over analyses,
//! `unwritten.zig` what the target cannot write, `output.zig` the lines and
//! comments, `notes.zig` what is said once a file. What a statement is
//! turned into before that: `cards.zig` (model cards), `bins.zig` (binned
//! ones), `instparams.zig`, `plugins.zig`, `variants.zig`, `defaults.zig`,
//! `rewrite.zig`. `driver.zig` owns the order of the passes and calls
//! `blocks.stmt` for each statement.
//!
//! Contents:
//! - `pub const Writer = struct`, with `pub const Hoisted = struct`,
//!   `pub const Error`, and the methods `pub fn sourceOf`, `pub fn familyOf`,
//!   `pub fn supporters`, `pub fn sourceGrammar`, `pub fn inertCommand`,
//!   `pub fn origin`, `pub fn pass`, `pub fn emitter`, `pub fn canWriteHere`
//! - `pub fn markUsed(stmts: []const ir.Stmt, used: *[schema.kind_count]bool) void`
//! - `pub fn needLine(arena: Allocator, l: []const u8, family: []const u8, env: ?*const ir.Env)
//!   Allocator.Error![]const u8`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const dialects = @import("dialects");
const expr = @import("expr");
const cond = @import("cond");
const facts = @import("facts.zig");
const emit = @import("emit.zig");
const Refs = @import("refs.zig").Refs;
const tables = @import("tables.zig");
const name_passes = @import("names.zig");
const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Kind = schema.Kind;
const Caps = emit.Caps;
const Emit = emit.Emit;
const reasonFor = emit.reasonFor;

// tidy: allow-fn(bool-heavy-struct) one a file, never in an array
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
    /// An annotation was written as a comment, which is said once a file.
    annotated: bool = false,
    /// The kinds left out as changing nothing here (`inert kind : text`),
    /// each said once a file.
    inert_said: [schema.kind_count]bool = @splat(false),
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

    /// The grammar of the dialect `st` was read in, when it is a built-in one.
    pub fn sourceGrammar(w: *const Writer, st: *const ir.Stmt) ?*const Grammar {
        const c = w.caps orelse return null;
        for (c.grammars) |*g| if (std.mem.eql(u8, g.name, w.sourceOf(st))) return g;
        return null;
    }

    /// Why command `cmd` of a `simctl` statement is left out here: the
    /// `inert` line of the dialect it was read in, with this dialect named
    /// where the line says `{to}`. A statement of no dialect this binary
    /// has a grammar for (one built from JSON or Python) is every
    /// built-in dialect's: the first that lists the command decides.
    pub fn inertCommand(
        w: *Writer,
        st: *const ir.Stmt,
        cmd: []const u8,
    ) Allocator.Error!?[]const u8 {
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

    /// A rule for the kind where the writer is (inside a block whose lines
    /// have rules of their own, those).
    pub fn canWriteHere(w: *const Writer, kind: Kind) bool {
        for (w.g.rules) |*r|
            if (r.kind == kind and r.dir != .read and w.g.ruleHere(r, w.within)) return true;
        return w.g.blockOf(kind) != null;
    }
};

/// The kinds of `stmts` and of what they hold, at any depth.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
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
