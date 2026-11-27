//! Compiles a `.spgrammar` file into reader/writer tables.
//!
//! `compile` runs at run time only, for the built-in grammars (their text
//! is embedded in the binary) as for a grammar file given by path. A
//! mistake comes back as `error.BadGrammar` with `file:line: message` in
//! the `Diag`; `zig build` runs it on every file of `grammars/`, so a
//! mistake in a built-in grammar still stops the build.
//!
//! The module's surface is this file; what it names lives in:
//! `types.zig` (the rows), `tables.zig` (`Grammar`), `index.zig` (the read
//! index), `context.zig` (what the compiler shares), `parser.zig`
//! (patterns), and one file a family of directives: `lexer.zig`,
//! `sections.zig`, `rules.zig`, `models.zig`, `spellings.zig`, `facts.zig`,
//! `formulas.zig`, `cards.zig`, `netlist.zig`, `rewrite.zig`.
//!
//! Contents:
//! - `pub fn compile(gpa: Allocator, src: []const u8, file: []const u8, diag: *Diag) Error!Grammar`
//! - from `tables.zig`: `Grammar`
//! - from `context.zig`: `Diag`, `Error`
//! - from `index.zig`: `ReadIndex`, `mentions`
//! - from `types.zig`, the pattern: `Node`, `NodeTag`, `BagEntry`, `BagForm`,
//!   `Rule`, `Dir`, `Block`, `no_slot`, `wild_slot`
//! - from `types.zig`, the lexer: `LexCfg`, `Scale`, `OddScale`
//! - from `types.zig`, the directives: `Absent`, `Caveat`, `Check`, `Computes`,
//!   `Convert`, `Differs`, `Each`, `Edge`, `EnumMap`, `EnumPair`, `Fill`, `Implied`,
//!   `Inert`, `Means`, `Merge`, `ModelEntry`, `ModelKv`, `ModelParamTable`,
//!   `ModelSpelling`, `ModelWhen`, `Modules`, `Names`, `Respell`, `Move`, `Needs`, `NoFamily`,
//!   `NoParam`, `Once`,
//!   `Omitted`, `Own`, `ParamTable`, `Plugin`, `RawBlock`, `Require`,
//!   `Reserved`, `Rewrite`, `SignalForm`, `Spellings`, `Spread`, `Switch`,
//!   `Threshold`, `Topo`, `UniqueAnalysis`, `Wrap`, `paramsOpen`

const std = @import("std");
const schema = @import("schema");
const Allocator = std.mem.Allocator;
const cards = @import("cards.zig");
const context = @import("context.zig");
const facts = @import("facts.zig");
const formulas = @import("formulas.zig");
const index = @import("index.zig");
const lexer = @import("lexer.zig");
const models = @import("models.zig");
const netlist = @import("netlist.zig");
const parser = @import("parser.zig");
const rewrite = @import("rewrite.zig");
const rules = @import("rules.zig");
const sections = @import("sections.zig");
const spellings = @import("spellings.zig");
const tables = @import("tables.zig");
const types = @import("types.zig");
const C = context.C;
const Lines = context.Lines;
const splitHead = context.splitHead;
const anyWrites = index.anyWrites;
const markEndings = index.markEndings;
const readIndex = index.readIndex;
const parseLexer = lexer.parseLexer;
const Def = parser.Def;

pub const Grammar = tables.Grammar;
pub const Diag = context.Diag;
pub const Error = context.Error;
pub const ReadIndex = index.ReadIndex;
pub const mentions = index.mentions;
pub const Node = types.Node;
pub const NodeTag = types.NodeTag;
pub const BagEntry = types.BagEntry;
pub const BagForm = types.BagForm;
pub const Rule = types.Rule;
pub const Dir = types.Dir;
pub const Block = types.Block;
pub const no_slot = types.no_slot;
pub const wild_slot = types.wild_slot;
pub const LexCfg = types.LexCfg;
pub const Scale = types.Scale;
pub const OddScale = types.OddScale;
pub const Absent = types.Absent;
pub const Caveat = types.Caveat;
pub const Check = types.Check;
pub const Computes = types.Computes;
pub const Convert = types.Convert;
pub const Differs = types.Differs;
pub const Edge = types.Edge;
pub const EnumMap = types.EnumMap;
pub const EnumPair = types.EnumPair;
pub const Fill = types.Fill;
pub const Implied = types.Implied;
pub const Inert = types.Inert;
pub const Means = types.Means;
pub const Merge = types.Merge;
pub const ModelEntry = types.ModelEntry;
pub const ModelKv = types.ModelKv;
pub const ModelParamTable = types.ModelParamTable;
pub const ModelSpelling = types.ModelSpelling;
pub const ModelWhen = types.ModelWhen;
pub const Move = types.Move;
pub const Needs = types.Needs;
pub const Once = types.Once;
pub const Modules = types.Modules;
pub const Names = types.Names;
pub const Respell = types.Respell;
pub const NoFamily = types.NoFamily;
pub const NoParam = types.NoParam;
pub const Omitted = types.Omitted;
pub const Own = types.Own;
pub const ParamTable = types.ParamTable;
pub const Plugin = types.Plugin;
pub const RawBlock = types.RawBlock;
pub const Require = types.Require;
pub const Reserved = types.Reserved;
pub const Rewrite = types.Rewrite;
pub const SignalForm = types.SignalForm;
pub const Spellings = types.Spellings;
pub const Spread = types.Spread;
pub const Each = types.Each;
pub const Switch = types.Switch;
pub const Threshold = types.Threshold;
pub const Topo = types.Topo;
pub const UniqueAnalysis = types.UniqueAnalysis;
pub const Wrap = types.Wrap;
pub const paramsOpen = types.paramsOpen;

/// The head words of the directives after the lexer section.
const Head = enum {
    preamble,
    header,
    needs,
    once,
    modules,
    names,
    respell,
    wrap,
    own,
    raw,
    block,
    rule,
    read,
    write,
    define,
    caveat,
    inert,
    rewrite,
    plugin,
    threshold,
    computes,
    edge,
    noparam,
    convert,
    invalid,
    default,
    omitted,
    libsections,
    variation,
    variant,
    unique,
    hoist,
    models,
    implied,
    @"enum",
    move,
    merge,
    signals,
    functions,
    variables,
    operators,
    params,
    modelparams,
    differs,
    means,
    @"switch",
    requires,
    reserved,
    spread,
    each,
    rerun,
    apart,
    no,
};

const tiny =
    \\dialect tiny
    \\lexer
    \\  case insensitive
    \\  comment line "*"
    \\  continue lead "+"
    \\  scale MEG=6 K=3 M=-3
    \\end
    \\rule resistor = name~"R" pos neg r {...params}
    \\rule tran = ".TRAN" step?'$stop/1000' stop [start?0 [maxstep]] [skip_dc:"UIC"=yes]
    \\rule ac = ".ac" (sweep:"dec" | sweep:"lin") points fstart fstop
    \\models
    \\  bsim4 n = nmos level=14 | nmos level=54
    \\  mos1 n = nmos level=1 | nmos !level
    \\  vbic npn = npn level=12 when nodes>=4 | npn level=11
    \\end
;

/// Turn the text of a `.spgrammar` file into a `Grammar`.
///
/// The grammar's tables are allocated from `gpa` and point into `src`, so
/// both must outlive it: pass an arena. A mistake returns
/// `error.BadGrammar` with `file:line: message` in `diag`; `file` names the
/// grammar in messages (empty: `<dialect>.spgrammar`).
pub fn compile(gpa: Allocator, src: []const u8, file: []const u8, diag: *Diag) Error!Grammar {
    var ctx: C = .{ .gpa = gpa, .diag = diag, .file = file };
    const c = &ctx;
    var lines: Lines = .{ .src = src };
    var g: Grammar = .{
        .name = "",
        .lex = .{},
        .preamble = &.{},
        .needs = &.{},
        .wraps = &.{},
        .raws = &.{},
        .blocks = &.{},
        .rules = &.{},
        .models = &.{},
        .caveats = &.{},
    };
    var defs: []const Def = &.{};
    var have_lexer = false;
    while (lines.next()) |line| {
        const head, const rest = splitHead(line);
        if (std.mem.eql(u8, head, "dialect")) {
            c.name = rest;
        } else if (std.mem.eql(u8, head, "lexer")) {
            g.lex = try parseLexer(c, &lines);
            c.comments = g.lex.line_comments;
            have_lexer = true;
        } else if (!have_lexer) {
            return c.fail(lines.no, "the lexer section must come before `{s}`", .{head});
        } else try directive(c, &g, &lines, &defs, head, rest);
    }
    if (std.mem.eql(u8, c.name, "?")) return c.fail(1, "missing `dialect <name>`", .{});
    g.name = c.name;
    g.rules = try markEndings(c, g.rules, g.spreads);
    // A device named by its module is a plugin's: the block says what to
    // tell who has none, and a block with no such rule says it to no one.
    if (anyWrites(g.rules, .device, schema.slot(.device, "module")) != (g.plugin != null))
        return c.fail(
            0,
            "a device rule that names the module (`module`) and a plugin block go together",
            .{},
        );
    g.read_index = try readIndex(c, g.rules, g.blocks, g.raws);
    // What a `modules` section writes: the instances and what they name.
    if (g.modules != null) for ([_]schema.Kind{ .subckt, .instance, .verilog, .ports }) |k| {
        g.read_index.writes |= ReadIndex.kindBit(k);
    };
    // The index lists every rule once in `all`.
    std.debug.assert(g.read_index.all.len == g.rules.len);
    return g;
}

// ---- private ----

/// One directive line after the lexer section, by its head word.
fn directive(
    c: *C,
    g: *Grammar,
    lines: *Lines,
    defs: *[]const Def,
    head: []const u8,
    rest: []const u8,
) Error!void {
    // `Lines.next` gives a line that starts with no blank: the head is a word.
    std.debug.assert(head.len > 0);
    const no = lines.no;
    const d = std.meta.stringToEnum(Head, head) orelse
        return c.fail(no, "unknown directive `{s}`", .{head});
    switch (d) {
        .preamble => try sections.preamble(c, g, lines, rest),
        .header => try sections.header(c, g, lines, rest),
        .needs => try sections.needs(c, g, lines, rest),
        .once => try sections.once(c, g, lines, rest),
        .modules => try sections.modules(c, g, lines),
        .names => try sections.names(c, g, lines),
        .wrap => try sections.wrap(c, g, no, rest),
        .own => try sections.own(c, g, no, rest),
        .raw => try sections.raw(c, g, no, rest),
        .block => try rules.block(c, g, lines, rest, defs.*),
        .rule, .read, .write => try rules.rule(c, g, no, head, rest, defs.*),
        .define => try rules.define(c, no, rest, defs),
        .caveat => try facts.caveat(c, g, no, rest),
        .inert => try facts.inert(c, g, no, rest),
        .implied => try facts.implied(c, g, no, rest),
        .@"enum" => try facts.enumMap(c, g, no, rest),
        .respell => try facts.respell(c, g, no, rest),
        .move => try facts.move(c, g, no, rest),
        .merge => try facts.merge(c, g, no, rest),
        .no => try facts.absent(c, g, no, rest),
        .invalid => try facts.invalid(c, g, no, rest),
        .default => try facts.default(c, g, no, rest),
        .convert => try formulas.convert(c, g, no, rest),
        .omitted => try formulas.omitted(c, g, no, rest),
        .threshold => try cards.threshold(c, g, no, rest),
        .computes => try cards.computes(c, g, no, rest),
        .edge => try cards.edge(c, g, no, rest),
        .noparam => try cards.noparam(c, g, no, rest),
        .libsections => try netlist.libsections(c, g, no, rest),
        .variation => try netlist.variation(c, g, no, rest),
        .variant => try netlist.variant(c, g, no, rest),
        .unique => try netlist.unique(c, g, no, rest),
        .hoist => try netlist.hoist(c, g, no, rest),
        .@"switch" => try netlist.switchTo(c, g, no, rest),
        .requires => try netlist.requires(c, g, no, rest),
        .reserved => try netlist.reserved(c, g, no, rest),
        .spread => try netlist.spread(c, g, no, rest),
        .rerun => try netlist.rerun(c, g, no, rest),
        .apart => try netlist.apart(c, g, no, rest),
        .each => try netlist.each(c, g, no, rest),
        .models => try models.models(c, g, lines),
        .signals => try spellings.signals(c, g, lines),
        .functions => try spellings.functions(c, g, lines),
        .variables => try spellings.variables(c, g, lines),
        .operators => try spellings.operators(c, g, lines),
        .params => try spellings.params(c, g, lines, rest),
        .modelparams => try spellings.modelparams(c, g, lines, rest),
        .differs => try spellings.differs(c, g, no, rest),
        .means => try spellings.means(c, g, no, rest),
        .rewrite => try rewrite.rewrite(c, g, lines, rest),
        .plugin => try rewrite.plugin(c, g, lines, rest),
    }
}

fn expectTiny(g: Grammar) !void {
    try std.testing.expectEqualStrings("tiny", g.name);
    try std.testing.expectEqual(3, g.rules.len);
    try std.testing.expectEqualStrings("meg", g.lex.scales[0].suffix);
    try std.testing.expectEqualStrings("r", g.rules[0].pat[0].prefix);
    try std.testing.expectEqualStrings(".tran", g.rules[1].pat[0].text);
    try std.testing.expectEqualStrings("$stop/1000", g.rules[1].pat[1].default);
    try std.testing.expectEqual(NodeTag.opt, g.rules[1].pat[3].tag);
    try std.testing.expectEqualStrings("yes", g.rules[1].pat[4].kids[0].atom);
    try std.testing.expectEqual(NodeTag.alt, g.rules[2].pat[1].tag);
    try std.testing.expectEqual(3, g.models.len);
    try std.testing.expect(g.models[1].spellings[1].kv[0].absent);
    try std.testing.expect(
        g.models[2].spellings[0].when[0].ge and g.models[2].spellings[0].when[0].isNodes(),
    );
    try std.testing.expectEqualStrings("4", g.models[2].spellings[0].when[0].val);
    try std.testing.expectEqual(0, g.models[2].spellings[1].when.len);
    try std.testing.expect(g.canWrite(.tran) and !g.canWrite(.noise));
}

test "compile a small grammar" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try expectTiny(try compile(arena.allocator(), tiny, "tiny.spgrammar", &diag));
}

test "a broken grammar at run time names the file and line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { src: []const u8, msg: []const u8 }{
        .{
            .src = "dialect x\nlexer\nend\nrule nonsense = \"a\"\n",
            .msg = "x/bad.spgrammar:4: unknown kind 'nonsense'",
        },
        .{
            .src = "dialect x\nlexer\nend\n\nrule tran = \".tran\" bogus\n",
            .msg = "x/bad.spgrammar:5: unknown slot 'bogus' for kind 'tran'",
        },
        .{
            .src = "dialect x\nlexer\nend\nrule tran = \".tran\" [ stop\n",
            .msg = "x/bad.spgrammar:4: missing ']' in pattern",
        },
        .{
            .src = "dialect x\nlexer\n  case insensitive\n",
            .msg = "x/bad.spgrammar:3: lexer section is missing 'end'",
        },
        .{
            .src = "rule op = \".op\"\n",
            .msg = "x/bad.spgrammar:1: the lexer section must come before `rule`",
        },
        .{
            .src = "dialect x\nlexer\nend\nrequires dc-path maybe : why\n",
            .msg = "x/bad.spgrammar:4: requires is `requires " ++
                "dc-path|cutset|no-vloop|no-vlloop|no-lloop error|warning [analysis ...] : reason`",
        },
        .{
            .src = "dialect x\nlexer\nend\nnoparam bsim4 version : why\n",
            .msg = "x/bad.spgrammar:4: noparam needs a model family, a parameter and a severity",
        },
        .{
            .src = "dialect x\nlexer\nend\nmodelparams nosuch\nend\n",
            .msg = "x/bad.spgrammar:4: unknown model family 'nosuch'",
        },
        .{
            .src = "dialect x\nlexer\nend\nmodelparams resistor\n  narrow = narrow / 3\nend\n",
            .msg = "x/bad.spgrammar:5: a model parameter is halved or not: `name = spelling / 2`",
        },
        .{
            .src = "dialect x\nlexer\nend\nrequires dc-path error [op resistor] : why\n",
            .msg = "x/bad.spgrammar:4: requires: 'resistor' is not an analysis",
        },
        .{
            .src = "dialect x\nlexer\nend\nrewrite capacitor ic\n  keep neg={name}__ic\n",
            .msg = "x/bad.spgrammar:4: rewrite is missing 'end'",
        },
        .{
            .src = "dialect x\nlexer\nend\nrewrite capacitor q\n  become bsource i=ddt({q})\nend\n",
            .msg = "x/bad.spgrammar:6: a rewrite with `become` needs a `loss : text` line",
        },
        .{
            .src = "dialect x\nlexer\nend\nrewrite capacitor ic\n  add vsource dc={ic}\nend\n",
            .msg = "x/bad.spgrammar:5: a rewrite starts with keep or become, and goes on with add",
        },
        .{
            .src = "dialect x\nlexer\nend\nrule verilog = name nodes*@dirs=in master\n",
            .msg = "x/bad.spgrammar:4: a pattern that picks items " ++
                "(`slot*@sel=word`) is only written",
        },
        .{
            .src = "dialect x\nlexer\nend\nonce verilog master\n  .model {master} {bogus}\nend\n",
            .msg = "x/bad.spgrammar:4: unknown slot 'bogus' for kind 'verilog'",
        },
        .{
            .src = "dialect x\nlexer\nend\nrewrite capacitor ic\n  keep bogus={ic}\nend\n",
            .msg = "x/bad.spgrammar:5: unknown slot 'bogus' for kind 'capacitor'",
        },
    };
    for (cases) |cs| {
        var diag: Diag = .{};
        try std.testing.expectError(
            error.BadGrammar,
            compile(arena.allocator(), cs.src, "x/bad.spgrammar", &diag),
        );
        if (!std.mem.startsWith(u8, diag.msg, cs.msg)) {
            std.debug.print("got: {s}\nwant prefix: {s}\n", .{ diag.msg, cs.msg });
            return error.TestUnexpectedResult;
        }
    }
}
