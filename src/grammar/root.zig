//! Compiles a `.spgrammar` file into reader/writer tables.
//!
//! `compile` runs at run time only, for the built-in grammars (their text
//! is embedded in the binary) as for a grammar file given by path. A
//! mistake comes back as `error.BadGrammar` with `file:line: message` in
//! the `Diag`; `zig build` runs it on every file of `grammars/`, so a
//! mistake in a built-in grammar still stops the build.
//!
//! Contents:
//! - `pub const Diag`
//! - `pub const Error`
//! - `pub const ReadIndex`
//! - `pub const mentions`
//! - `pub const Grammar`
//! - `pub const Absent`
//! - `pub const BagEntry`
//! - `pub const BagForm`
//! - `pub const Block`
//! - `pub const Caveat`
//! - `pub const Check`
//! - `pub const Computes`
//! - `pub const Convert`
//! - `pub const Differs`
//! - `pub const Dir`
//! - `pub const Edge`
//! - `pub const EnumMap`
//! - `pub const EnumPair`
//! - `pub const Fill`
//! - `pub const Implied`
//! - `pub const Inert`
//! - `pub const LexCfg`
//! - `pub const Means`
//! - `pub const Merge`
//! - `pub const ModelEntry`
//! - `pub const ModelKv`
//! - `pub const ModelParamTable`
//! - `pub const ModelSpelling`
//! - `pub const ModelWhen`
//! - `pub const Move`
//! - `pub const Needs`
//! - `pub const NoFamily`
//! - `pub const NoParam`
//! - `pub const Node`
//! - `pub const NodeTag`
//! - `pub const OddScale`
//! - `pub const Omitted`
//! - `pub const Own`
//! - `pub const ParamTable`
//! - `pub const Plugin`
//! - `pub const RawBlock`
//! - `pub const Require`
//! - `pub const Reserved`
//! - `pub const Rewrite`
//! - `pub const Rule`
//! - `pub const Scale`
//! - `pub const SignalForm`
//! - `pub const Spellings`
//! - `pub const Spread`
//! - `pub const Switch`
//! - `pub const Threshold`
//! - `pub const Topo`
//! - `pub const UniqueAnalysis`
//! - `pub const Wrap`
//! - `pub const no_slot`
//! - `pub const paramsOpen`
//! - `pub const wild_slot`
//! - `pub fn compile(gpa: Allocator, src: []const u8, file: []const u8, diag: *Diag) Error!Grammar`

const std = @import("std");
const schema = @import("schema");
const Kind = schema.Kind;
const Allocator = std.mem.Allocator;
const context = @import("context.zig");
const index = @import("index.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const rewrite = @import("rewrite.zig");
const spellings = @import("spellings.zig");
const tables = @import("tables.zig");
const types = @import("types.zig");
const C = context.C;
const Lines = context.Lines;
const args = context.args;
const condition = context.condition;
const dotted = context.dotted;
const kindOf = context.kindOf;
const kindSlot = context.kindSlot;
const literalLines = context.literalLines;
const parseDecimal = context.parseDecimal;
const slotNamed = context.slotNamed;
const splitHead = context.splitHead;
const anyWrites = index.anyWrites;
const markEndings = index.markEndings;
const readIndex = index.readIndex;
const parseLexer = lexer.parseLexer;
const Def = parser.Def;
const pattern = parser.pattern;
const pluginBlock = rewrite.pluginBlock;
const rewriteBlock = rewrite.rewriteBlock;
const parseModels = spellings.parseModels;
const parseSignals = spellings.parseSignals;
const parseSpellings = spellings.parseSpellings;

pub const Diag = context.Diag;

pub const Error = context.Error;

pub const ReadIndex = index.ReadIndex;

pub const mentions = index.mentions;

pub const Grammar = tables.Grammar;

pub const Absent = types.Absent;

pub const BagEntry = types.BagEntry;

pub const BagForm = types.BagForm;

pub const Block = types.Block;

pub const Caveat = types.Caveat;

pub const Check = types.Check;

pub const Computes = types.Computes;

pub const Convert = types.Convert;

pub const Differs = types.Differs;

pub const Dir = types.Dir;

pub const Edge = types.Edge;

pub const EnumMap = types.EnumMap;

pub const EnumPair = types.EnumPair;

pub const Fill = types.Fill;

pub const Implied = types.Implied;

pub const Inert = types.Inert;

pub const LexCfg = types.LexCfg;

pub const Means = types.Means;

pub const Merge = types.Merge;

pub const ModelEntry = types.ModelEntry;

pub const ModelKv = types.ModelKv;

pub const ModelParamTable = types.ModelParamTable;

pub const ModelSpelling = types.ModelSpelling;

pub const ModelWhen = types.ModelWhen;

pub const Move = types.Move;

pub const Needs = types.Needs;

pub const NoFamily = types.NoFamily;

pub const NoParam = types.NoParam;

pub const Node = types.Node;

pub const NodeTag = types.NodeTag;

pub const OddScale = types.OddScale;

pub const Omitted = types.Omitted;

pub const Own = types.Own;

pub const ParamTable = types.ParamTable;

pub const Plugin = types.Plugin;

pub const RawBlock = types.RawBlock;

pub const Require = types.Require;

pub const Reserved = types.Reserved;

pub const Rewrite = types.Rewrite;

pub const Rule = types.Rule;

pub const Scale = types.Scale;

pub const SignalForm = types.SignalForm;

pub const Spellings = types.Spellings;

pub const Spread = types.Spread;

pub const Switch = types.Switch;

pub const Threshold = types.Threshold;

pub const Topo = types.Topo;

pub const UniqueAnalysis = types.UniqueAnalysis;

pub const Wrap = types.Wrap;

pub const no_slot = types.no_slot;

pub const paramsOpen = types.paramsOpen;

pub const wild_slot = types.wild_slot;

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
    var lex: LexCfg = .{};
    var have_lexer = false;
    var preamble: []const []const u8 = &.{};
    var preamble_unless: ?Kind = null;
    var header: []const []const u8 = &.{};
    var header_folded: []const []const u8 = &.{};
    var needs: []const Needs = &.{};
    var wraps: []const Wrap = &.{};
    var raws: []const RawBlock = &.{};
    var owns: []const Own = &.{};
    var no_families: []const NoFamily = &.{};
    var blocks: []const Block = &.{};
    var rules: []const Rule = &.{};
    var models: []const ModelEntry = &.{};
    var caveats: []const Caveat = &.{};
    var implied: []const Implied = &.{};
    var enums: []const EnumMap = &.{};
    var moves: []const Move = &.{};
    var merges: []const Merge = &.{};
    var defs: []const Def = &.{};
    var signals: []const SignalForm = &.{};
    var functions: []const Spellings = &.{};
    var variables: []const Spellings = &.{};
    var operators: []const Spellings = &.{};
    var absent: []const Absent = &.{};
    var converts: []const Convert = &.{};
    var checks: []const Check = &.{};
    var differs: []const Differs = &.{};
    var means: []const Means = &.{};
    var thresholds: []const Threshold = &.{};
    var params: []const ParamTable = &.{};
    var modelparams: []const ModelParamTable = &.{};
    var fills: []const Fill = &.{};
    var omitted: []const Omitted = &.{};
    var unique_param: []const u8 = "";
    var variation_inline = false;
    var unique_master: []const u8 = "";
    var libsections_opened: []const u8 = "";
    var unique_analysis: ?UniqueAnalysis = null;
    var hoist_param: []const []const u8 = &.{};
    var spreads: []const Spread = &.{};
    var reruns: []const Kind = &.{};
    var reserved: []const Reserved = &.{};
    var requires: []const Require = &.{};
    var switches: []const Switch = &.{};
    var noparams: []const NoParam = &.{};
    var computes: []const Computes = &.{};
    var edges: []const Edge = &.{};
    var inerts: []const Inert = &.{};
    var rewrites: []const Rewrite = &.{};
    var plugin: ?Plugin = null;

    while (lines.next()) |line| {
        const head, const rest = splitHead(line);
        const fold = !lex.case_sensitive;
        const no = lines.no;
        if (std.mem.eql(u8, head, "dialect")) {
            c.name = rest;
        } else if (std.mem.eql(u8, head, "lexer")) {
            lex = try parseLexer(c, &lines);
            have_lexer = true;
        } else if (!have_lexer) {
            return c.fail(no, "the lexer section must come before `{s}`", .{head});
        } else if (std.mem.eql(u8, head, "preamble")) {
            if (std.mem.startsWith(u8, rest, "unless "))
                preamble_unless = try kindOf(c, no, rest["unless ".len..]);
            preamble = try literalLines(c, &lines);
        } else if (std.mem.eql(u8, head, "header")) {
            if (std.mem.eql(u8, rest, "folded")) {
                header_folded = try literalLines(c, &lines);
            } else if (rest.len > 0) {
                return c.fail(no, "`header {s}`: only `header folded` takes a word", .{rest});
            } else header = try literalLines(c, &lines);
        } else if (std.mem.eql(u8, head, "needs")) {
            if (schema.kindFromName(rest) == null and schema.familyKind(rest) != null) {
                needs = try c.add(
                    Needs,
                    needs,
                    .{ .kind = .model, .family = rest, .lines = try literalLines(c, &lines) },
                );
            } else {
                const kind = try kindOf(c, no, rest);
                needs = try c.add(
                    Needs,
                    needs,
                    .{ .kind = kind, .lines = try literalLines(c, &lines) },
                );
            }
        } else if (std.mem.eql(u8, head, "wrap")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "wrap is `wrap \"open\" \"close\" : kind ...`",
                .{},
            );
            const lits = try args(c, no, rest[0..colon]);
            if (lits.len != 2)
                return c.fail(no, "wrap needs an opening and a closing literal", .{});
            var kinds: []const Kind = &.{};
            for (try args(c, no, rest[colon + 3 ..])) |k|
                kinds = try c.add(Kind, kinds, try kindOf(c, no, k));
            wraps = try c.add(Wrap, wraps, .{
                .open = try c.foldIf(fold, lits[0]),
                .close = try c.foldIf(fold, lits[1]),
                .kinds = kinds,
            });
        } else if (std.mem.eql(u8, head, "own")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "own is `own \"word\"... : reason`",
                .{},
            );
            var words = try args(c, no, rest[0..colon]);
            const model = words.len > 1 and std.mem.eql(
                u8,
                words[0],
                "model",
            ) and !std.mem.startsWith(u8, rest, "\"");
            if (model) words = words[1..];
            if (words.len == 0) return c.fail(no, "own needs a word", .{});
            for (words) |wd|
                owns = try c.add(
                    Own,
                    owns,
                    .{
                        .word = try c.foldIf(fold, wd),
                        .reason = rest[colon + 3 ..],
                        .model = model,
                    },
                );
        } else if (std.mem.eql(u8, head, "raw")) {
            const colon = std.mem.indexOf(u8, rest, " : ");
            var lits = try args(c, no, if (colon) |k| rest[0..k] else rest);
            var as_kind: ?Kind = null;
            if (lits.len == 4 and std.mem.eql(u8, lits[2], "as")) {
                as_kind = try kindOf(c, no, lits[3]);
                lits = lits[0..2];
            }
            if (lits.len != 2)
                return c.fail(no, "raw is `raw \"open\" \"close\" [as kind] [: reason]`", .{});
            raws = try c.add(RawBlock, raws, .{
                .open = try c.foldIf(fold, lits[0]),
                .close = try c.foldIf(fold, lits[1]),
                .reason = if (colon) |k| rest[k + 3 ..] else "",
                .kind = as_kind,
            });
        } else if (std.mem.eql(u8, head, "block")) {
            const kind = try kindOf(c, no, rest);
            var open: []const Node = &.{};
            var close: []const Node = &.{};
            var inner: []const []const Node = &.{};
            var closed = false;
            while (true) {
                const bl = lines.next() orelse return c.fail(
                    lines.no,
                    "block is missing 'end'",
                    .{},
                );
                if (std.mem.eql(u8, bl, "end")) break;
                if (std.mem.eql(u8, bl, "closed")) {
                    closed = true;
                    continue;
                }
                const bh, const br = splitHead(bl);
                const pat = try pattern(c, lines.no, kind, fold, br, defs);
                if (std.mem.eql(u8, bh, "open")) {
                    open = pat;
                } else if (std.mem.eql(u8, bh, "close")) {
                    close = pat;
                } else if (std.mem.eql(u8, bh, "inner")) {
                    inner = try c.add([]const Node, inner, pat);
                } else return c.fail(lines.no, "expected open, inner, close, closed or end", .{});
            }
            if (open.len == 0 or close.len == 0)
                return c.fail(lines.no, "block needs both open and close", .{});
            if (closed and close[0].tag != .lit)
                return c.fail(lines.no, "a closed block's close starts with a word", .{});
            blocks = try c.add(
                Block,
                blocks,
                .{ .kind = kind, .open = open, .inner = inner, .close = close, .closed = closed },
            );
        } else if (std.mem.eql(u8, head, "rule") or std.mem.eql(u8, head, "read") or
            std.mem.eql(u8, head, "write"))
        {
            const eq = std.mem.indexOf(u8, rest, " = ") orelse return c.fail(
                no,
                "expected `{s} kind = pattern`",
                .{head},
            );
            var kname = std.mem.trim(u8, rest[0..eq], " \t");
            var within: ?Kind = null;
            if (std.mem.indexOfScalar(u8, kname, '@')) |at| {
                within = try kindOf(c, no, kname[at + 1 ..]);
                kname = kname[0..at];
            }
            var family: []const u8 = "";
            if (std.mem.indexOfScalar(u8, kname, '[')) |b| {
                if (kname[kname.len - 1] != ']') return c.fail(no, "expected `kind[family]`", .{});
                family = kname[b + 1 .. kname.len - 1];
                kname = kname[0..b];
            }
            const kind = try kindOf(c, no, kname);
            if (family.len > 0) {
                if (schema.familyKind(family) == null)
                    return c.fail(no, "unknown model family '{s}'", .{family});
                if (schema.slotOf(kind, "master") == null)
                    return c.fail(
                        no,
                        "'{s}' names no model, so it cannot depend on a family",
                        .{kname},
                    );
            }
            const dir: Dir = if (head[0] == 'r' and head[1] == 'u')
                .both
            else if (head[0] == 'r') .read else .write;
            rules = try c.add(Rule, rules, .{
                .kind = kind,
                .dir = dir,
                .pat = try pattern(c, no, kind, fold, rest[eq + 3 ..], defs),
                .family = family,
                .within = within,
            });
        } else if (std.mem.eql(u8, head, "define")) {
            const eq = std.mem.indexOf(u8, rest, " = ") orelse return c.fail(
                no,
                "expected `define name = pattern`",
                .{},
            );
            const dname = std.mem.trim(u8, rest[0..eq], " \t");
            for (defs) |d|
                if (std.mem.eql(u8, d.name, dname))
                    return c.fail(no, "`{s}` is already defined", .{dname});
            defs = try c.add(Def, defs, .{ .name = dname, .text = rest[eq + 3 ..] });
        } else if (std.mem.eql(u8, head, "caveat")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "caveat is `caveat kind slot : text`",
                .{},
            );
            const all = try args(c, no, rest[0..colon]);
            const read = all.len > 0 and std.mem.eql(u8, all[0], "read");
            const ks = all[@intFromBool(read)..];
            if (ks.len != 2) return c.fail(no, "caveat needs a kind and a slot", .{});
            const star = std.mem.indexOf(u8, ks[1], "=*");
            const kind, const slot = try kindSlot(c, no, ks[0], if (star) |k|
                ks[1][0..k]
            else
                ks[1]);
            caveats = try c.add(
                Caveat,
                caveats,
                .{ .kind = kind, .slot = slot, .text = rest[colon + 3 ..], .suffix = if (star) |k|
                    ks[1][k + 2 ..]
                else
                    "", .read = read },
            );
        } else if (std.mem.eql(u8, head, "inert")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "inert is `inert kind key : text`",
                .{},
            );
            const e = try args(c, no, rest[0..colon]);
            if (e.len < 2) return c.fail(no, "inert needs a kind and a parameter", .{});
            const kind = try kindOf(c, no, e[0]);
            for (e[1..]) |key| {
                inerts = try c.add(
                    Inert,
                    inerts,
                    .{ .kind = kind, .key = key, .text = rest[colon + 3 ..] },
                );
            }
        } else if (std.mem.eql(u8, head, "rewrite")) {
            const rule = try rewriteBlock(c, &lines, rest);
            // The keys every clash line watches are held in one table.
            for (rewrites) |other| {
                const a = other.clash orelse continue;
                const b = rule.clash orelse continue;
                if (a.kind != b.kind or a.slot != b.slot)
                    return c.fail(no, "every clash line of a grammar names one kind.slot", .{});
            }
            rewrites = try c.add(Rewrite, rewrites, rule);
        } else if (std.mem.eql(u8, head, "plugin")) {
            if (plugin != null) return c.fail(no, "a grammar has one plugin block", .{});
            plugin = try pluginBlock(c, &lines, rest);
        } else if (std.mem.eql(u8, head, "threshold")) {
            const e = try args(c, no, rest);
            if (e.len != 7 or !std.mem.eql(u8, e[1], ":") or !std.mem.eql(u8, e[4], "="))
                return c.fail(no, "threshold is `threshold family : on off = mid half`", .{});
            if (schema.familyKind(e[0]) == null)
                return c.fail(no, "unknown model family '{s}'", .{e[0]});
            thresholds = try c.add(
                Threshold,
                thresholds,
                .{ .family = e[0], .on = e[2], .off = e[3], .mid = e[5], .half = e[6] },
            );
        } else if (std.mem.eql(u8, head, "computes")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "computes is `computes family key... : formula`",
                .{},
            );
            const e = try args(c, no, rest[0..colon]);
            if (e.len < 2) return c.fail(no, "computes needs a model family and a parameter", .{});
            if (schema.familyKind(e[0]) == null)
                return c.fail(no, "unknown model family '{s}'", .{e[0]});
            computes = try c.add(
                Computes,
                computes,
                .{ .family = e[0], .keys = e[1..], .text = rest[colon + 3 ..] },
            );
        } else if (std.mem.eql(u8, head, "edge")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "edge is `edge family key : text`",
                .{},
            );
            const e = try args(c, no, rest[0..colon]);
            if (e.len != 2) return c.fail(no, "edge needs a model family and a parameter", .{});
            if (schema.familyKind(e[0]) == null)
                return c.fail(no, "unknown model family '{s}'", .{e[0]});
            edges = try c.add(
                Edge,
                edges,
                .{ .family = e[0], .key = e[1], .text = rest[colon + 3 ..] },
            );
        } else if (std.mem.eql(u8, head, "noparam")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "noparam is `noparam family key[=value] warning|error : text`",
                .{},
            );
            const e = try args(c, no, rest[0..colon]);
            if (e.len != 3)
                return c.fail(no, "noparam needs a model family, a parameter and a severity", .{});
            if (!(std.mem.eql(u8, e[2], "error") or std.mem.eql(u8, e[2], "warning")))
                return c.fail(no, "noparam severity is warning or error, not '{s}'", .{e[2]});
            if (schema.familyKind(e[0]) == null)
                return c.fail(no, "unknown model family '{s}'", .{e[0]});
            const eq = std.mem.indexOfScalar(u8, e[1], '=') orelse e[1].len;
            if (eq < e[1].len)
                _ = std.fmt.parseFloat(f64, e[1][eq + 1 ..]) catch return c.fail(
                    no,
                    "noparam takes a plain number after '='",
                    .{},
                );
            noparams = try c.add(NoParam, noparams, .{
                .family = e[0],
                .key = e[1][0..eq],
                .value = if (eq < e[1].len) e[1][eq + 1 ..] else "",
                .err = std.mem.eql(u8, e[2], "error"),
                .text = rest[colon + 3 ..],
            });
        } else if (std.mem.eql(u8, head, "convert")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "convert is `convert kind [slot=atom] : a = b [op c]`",
                .{},
            );
            const ks = try args(c, no, rest[0..colon]);
            if (ks.len < 1 or ks.len > 2)
                return c.fail(no, "convert needs a kind and at most one condition", .{});
            const kind = try kindOf(c, no, ks[0]);
            var cv: Convert = .{ .kind = kind, .dst = 0, .src = 0 };
            var eq: ?[2]u8 = null;
            if (ks.len == 2) {
                if (std.mem.indexOf(u8, ks[1], "==")) |at| {
                    eq = .{
                        try slotNamed(c, no, kind, ks[1][0..at]),
                        try slotNamed(c, no, kind, ks[1][at + 2 ..]),
                    };
                } else cv.when_slot, cv.when_atom = try condition(c, no, kind, ks[1]);
            }
            const e = try args(c, no, rest[colon + 3 ..]);
            if (e.len < 3 or !std.mem.eql(u8, e[1], "="))
                return c.fail(no, "expected `a = b [op c]` after ':'", .{});
            cv.dst = try slotNamed(c, no, kind, e[0]);
            if (eq) |pair| {
                const inner = if (e.len == 3 and e[2].len > 2 and e[2][0] == '[' and
                    e[2][e[2].len - 1] == ']')
                    e[2][1 .. e[2].len - 1]
                else
                    "";
                if (inner.len == 0 or !std.mem.eql(
                    u8,
                    inner,
                    ks[1][0..std.mem.indexOf(u8, ks[1], "==").?],
                ))
                    return c.fail(no, "with `a==b` the conversion is `l = [a]`", .{});
                if (!schema.info(kind).slots[cv.dst].list)
                    return c.fail(no, "`l = [a]` needs a list slot", .{});
                cv.op = .wrap;
                cv.src = pair[0];
                cv.when_eq = pair[1];
            } else if (e.len == 3) {
                cv.src = try slotNamed(c, no, kind, e[2]);
            } else if (e.len == 5 and std.mem.eql(u8, e[2], "1") and std.mem.eql(u8, e[3], "/")) {
                cv.op = .recip;
                cv.src = try slotNamed(c, no, kind, e[4]);
                if (cv.src != cv.dst)
                    return c.fail(no, "`a = 1 / b` needs a and b to be the same slot", .{});
            } else if (e.len == 5 and e[3].len == 1 and
                std.mem.indexOfScalar(u8, "-+*/", e[3][0]) != null)
            {
                cv.op = switch (e[3][0]) {
                    '-' => .sub,
                    '+' => .add,
                    '*' => .mul,
                    else => .div,
                };
                cv.src = try slotNamed(c, no, kind, e[2]);
                if (cv.src != cv.dst)
                    return c.fail(no, "`a = b - c` needs a and b to be the same slot", .{});
                if (schema.slotIndex(kind, e[4])) |si| {
                    cv.arg_slot = si;
                } else {
                    _ = try parseDecimal(c, no, e[4]);
                    cv.arg_num = e[4];
                }
            } else return c.fail(no, "expected `a = b`, `a = a - c`, `a = a + c`, `a = a * " ++
                "c`, `a = a / c` or `a = 1 / a`", .{});
            converts = try c.add(Convert, converts, cv);
        } else if (std.mem.eql(u8, head, "invalid")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "invalid is `invalid kind slot[=0] [slot=atom] : text`",
                .{},
            );
            const ks = try args(c, no, rest[0..colon]);
            if (ks.len < 2 or ks.len > 3)
                return c.fail(no, "invalid needs a kind, a slot and at most one condition", .{});
            const kind = try kindOf(c, no, ks[0]);
            const zero = std.mem.endsWith(u8, ks[1], "=0");
            const sname = if (zero) ks[1][0 .. ks[1].len - 2] else ks[1];
            var ck: Check = .{
                .kind = kind,
                .slot = try slotNamed(c, no, kind, sname),
                .zero = zero,
                .text = rest[colon + 3 ..],
            };
            if (ks.len == 3) ck.when_slot, ck.when_atom = try condition(c, no, kind, ks[2]);
            checks = try c.add(Check, checks, ck);
        } else if (std.mem.eql(u8, head, "default")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "default is `default kind slot[=0] [slot=atom] : kind.slot`",
                .{},
            );
            const ks = try args(c, no, rest[0..colon]);
            if (ks.len < 2 or ks.len > 3)
                return c.fail(no, "default needs a kind, a slot and at most one condition", .{});
            const kind = try kindOf(c, no, ks[0]);
            const zero = std.mem.endsWith(u8, ks[1], "=0");
            const sname = if (zero) ks[1][0 .. ks[1].len - 2] else ks[1];
            const to = try args(c, no, rest[colon + 3 ..]);
            if (to.len != 1) return c.fail(no, "default takes one `kind.slot`", .{});
            const fk, const fs = try dotted(c, no, to[0]);
            var f: Fill = .{
                .kind = kind,
                .slot = try slotNamed(c, no, kind, sname),
                .zero = zero,
                .from = fk,
                .from_slot = fs,
            };
            if (ks.len == 3) f.when_slot, f.when_atom = try condition(c, no, kind, ks[2]);
            fills = try c.add(Fill, fills, f);
        } else if (std.mem.eql(u8, head, "omitted")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "omitted is `omitted kind slot[=0] [slot=atom] : formula [given slot] [zero " ++
                    "value]`",
                .{},
            );
            const ks = try args(c, no, rest[0..colon]);
            if (ks.len < 2 or ks.len > 3)
                return c.fail(no, "omitted needs a kind, a slot and at most one condition", .{});
            const kind = try kindOf(c, no, ks[0]);
            const zero = std.mem.endsWith(u8, ks[1], "=0");
            var text = std.mem.trim(u8, rest[colon + 3 ..], " \t");
            var o: Omitted = .{ .kind = kind, .slot = try slotNamed(c, no, kind, if (zero)
                ks[1][0 .. ks[1].len - 2]
            else
                ks[1]), .zero = zero, .text = "", .terms = &.{} };
            if (ks.len == 3) o.when_slot, o.when_atom = try condition(c, no, kind, ks[2]);
            if (std.mem.lastIndexOf(u8, text, " zero ")) |at| {
                if (!zero) return c.fail(no, "`zero value` needs the slot written `slot=0`", .{});
                o.zero_as = std.mem.trim(u8, text[at + 6 ..], " \t");
                text = std.mem.trim(u8, text[0..at], " \t");
            }
            if (std.mem.lastIndexOf(u8, text, " given ")) |at| {
                o.given = try slotNamed(c, no, kind, std.mem.trim(u8, text[at + 7 ..], " \t"));
                text = std.mem.trim(u8, text[0..at], " \t");
            }
            o.text = text;
            const f = try args(c, no, text);
            // Read left to right, so two operators need the first in
            // parentheses: `a`, `a + b`, `(a - b) / c`.
            if (f.len != 1 and f.len != 3 and f.len != 5)
                return c.fail(no, "an omitted formula is `a`, `a + b` or `(a - b) / c`", .{});
            for (f, 0..) |tok, i| {
                var t = tok;
                if (f.len == 5 and i == 0 and t[0] == '(') t = t[1..];
                if (f.len == 5 and i == 2 and t[t.len - 1] == ')') t = t[0 .. t.len - 1];
                if (f.len == 5 and (i == 0 or i == 2) and t.len == tok.len)
                    return c.fail(
                        no,
                        "an omitted formula with two operators is `(a - b) / c`",
                        .{},
                    );
                const term: Omitted.Term = if (i % 2 == 1)
                    .{ .op = if (t.len != 1)
                        return c.fail(no, "expected + - * or /, found '{s}'", .{t})
                    else switch (t[0]) {
                        '+' => .add,
                        '-' => .sub,
                        '*' => .mul,
                        '/' => .div,
                        else => return c.fail(no, "expected + - * or /, found '{s}'", .{t}),
                    } }
                else if (t.len > 0 and std.ascii.isDigit(t[0]))
                    .{ .num = if (std.mem.indexOfNone(u8, t, "0123456789") == null)
                        t
                    else
                        return c.fail(no, "a number in an omitted formula is a whole one, " ++
                            "found '{s}'", .{t}) }
                else if (std.mem.indexOfScalar(u8, t, '.') != null) first: {
                    const fk, const fs = try dotted(c, no, t);
                    break :first .{ .first = .{ .kind = fk, .slot = fs } };
                } else .{ .slot = try slotNamed(c, no, kind, t) };
                // Operands first: each operator goes after its second operand.
                if (i % 2 == 0 and i > 0) {
                    const op = o.terms[o.terms.len - 1];
                    o.terms = try c.add(Omitted.Term, o.terms[0 .. o.terms.len - 1], term);
                    o.terms = try c.add(Omitted.Term, o.terms, op);
                } else o.terms = try c.add(Omitted.Term, o.terms, term);
            }
            omitted = try c.add(Omitted, omitted, o);
        } else if (std.mem.eql(u8, head, "libsections")) {
            if (!std.mem.startsWith(u8, rest, "opened : "))
                return c.fail(no, "libsections is `libsections opened : reason`", .{});
            libsections_opened = rest["opened : ".len..];
        } else if (std.mem.eql(u8, head, "variation")) {
            if (!std.mem.eql(u8, rest, "inline"))
                return c.fail(no, "variation is `variation inline`", .{});
            variation_inline = true;
        } else if (std.mem.eql(u8, head, "unique")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "unique is `unique param|master|analysis kind... [beside kind] : reason`",
                .{},
            );
            const what = std.mem.trim(u8, rest[0..colon], " \t");
            if (std.mem.eql(u8, what, "param")) {
                unique_param = rest[colon + 3 ..];
            } else if (std.mem.eql(u8, what, "master")) {
                unique_master = rest[colon + 3 ..];
            } else if (std.mem.startsWith(u8, what, "analysis ")) {
                var u: UniqueAnalysis = .{ .reason = rest[colon + 3 ..] };
                var it = std.mem.tokenizeAny(u8, what["analysis ".len..], " \t");
                while (it.next()) |word| {
                    const beside = std.mem.eql(u8, word, "beside");
                    const k = try kindOf(c, no, if (beside) it.next() orelse "" else word);
                    if (schema.info(k).class != .analysis)
                        return c.fail(
                            no,
                            "unique analysis: '{s}' is not an analysis",
                            .{@tagName(k)},
                        );
                    if (beside) u.beside = k;
                    u.kinds = try c.add(Kind, u.kinds, k);
                }
                unique_analysis = u;
            } else return c.fail(no, "unique takes param, master or analysis, not '{s}'", .{what});
        } else if (std.mem.eql(u8, head, "hoist")) {
            const a = try args(c, no, rest);
            if (a.len < 3 or !std.mem.eql(u8, a[0], "param") or !std.mem.eql(u8, a[1], "from"))
                return c.fail(no, "hoist is `hoist param from dialect...`", .{});
            hoist_param = a[2..];
        } else if (std.mem.eql(u8, head, "models")) {
            models = try parseModels(c, &lines, fold);
        } else if (std.mem.eql(u8, head, "implied")) {
            const a = try args(c, no, rest);
            if (a.len < 4 or a.len > 5 or !std.mem.eql(u8, a[2], "="))
                return c.fail(no, "implied is `implied kind slot = value [slot=atom]`", .{});
            const kind, const slot = try kindSlot(c, no, a[0], a[1]);
            var im: Implied = .{ .kind = kind, .slot = slot, .text = a[3] };
            if (a.len == 5) im.when_slot, im.when_atom = try condition(c, no, kind, a[4]);
            implied = try c.add(Implied, implied, im);
        } else if (std.mem.eql(u8, head, "enum")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "enum is `enum kind slot : canonical=spelling ...`",
                .{},
            );
            const ks = try args(c, no, rest[0..colon]);
            if (ks.len != 2) return c.fail(no, "enum needs a kind and a slot", .{});
            const kind, const slot = try kindSlot(c, no, ks[0], ks[1]);
            if (schema.info(kind).slots[slot].ty != .atom)
                return c.fail(no, "enum needs an atom slot", .{});
            var pairs: []const EnumPair = &.{};
            for (try args(c, no, rest[colon + 3 ..])) |pair| {
                const pe = std.mem.indexOfScalar(u8, pair, '=') orelse return c.fail(
                    no,
                    "expected canonical=spelling in '{s}'",
                    .{pair},
                );
                pairs = try c.add(
                    EnumPair,
                    pairs,
                    .{ .canon = pair[0..pe], .spelling = try c.foldIf(fold, pair[pe + 1 ..]) },
                );
            }
            enums = try c.add(EnumMap, enums, .{ .kind = kind, .slot = slot, .pairs = pairs });
        } else if (std.mem.eql(u8, head, "move")) {
            const a = try args(c, no, rest);
            const oneway = a.len == 4 and std.mem.eql(u8, a[3], "oneway");
            if ((a.len != 3 and !oneway) or !std.mem.eql(u8, a[1], "->"))
                return c.fail(no, "move is `move kind.slot -> kind.slot [oneway]`", .{});
            const fk, const fs = try dotted(c, no, a[0]);
            const tk, const ts = try dotted(c, no, a[2]);
            moves = try c.add(
                Move,
                moves,
                .{ .from = fk, .from_slot = fs, .to = tk, .to_slot = ts, .oneway = oneway },
            );
        } else if (std.mem.eql(u8, head, "merge")) {
            const a = try args(c, no, rest);
            if (a.len != 3 or !std.mem.eql(u8, a[1], "->"))
                return c.fail(no, "merge is `merge kind -> kind`", .{});
            merges = try c.add(
                Merge,
                merges,
                .{ .from = try kindOf(c, no, a[0]), .into = try kindOf(c, no, a[2]) },
            );
        } else if (std.mem.eql(u8, head, "signals")) {
            signals = try parseSignals(c, &lines, fold);
        } else if (std.mem.eql(u8, head, "functions")) {
            functions = try parseSpellings(c, &lines, fold, "function", &schema.functions);
        } else if (std.mem.eql(u8, head, "variables")) {
            variables = try parseSpellings(c, &lines, fold, "variable", &schema.variables);
        } else if (std.mem.eql(u8, head, "operators")) {
            operators = try parseSpellings(c, &lines, false, "operator", &schema.operators);
        } else if (std.mem.eql(u8, head, "params")) {
            const kind = try kindOf(c, no, rest);
            if (schema.slotOf(kind, "params") == null)
                return c.fail(no, "params needs a kind with parameters", .{});
            params = try c.add(
                ParamTable,
                params,
                .{ .kind = kind, .names = try parseSpellings(c, &lines, fold, "parameter", null) },
            );
        } else if (std.mem.eql(u8, head, "modelparams")) {
            const only = std.mem.endsWith(u8, rest, " only");
            const fam = if (only) rest[0 .. rest.len - " only".len] else rest;
            if (schema.familyKind(fam) == null)
                return c.fail(no, "unknown model family '{s}'", .{fam});
            modelparams = try c.add(
                ModelParamTable,
                modelparams,
                .{
                    .family = fam,
                    .names = try parseSpellings(c, &lines, fold, "model parameter", null),
                    .only = only,
                },
            );
        } else if (std.mem.eql(u8, head, "differs")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "differs is `differs function-or-operator : reason`",
                .{},
            );
            const canon = std.mem.trim(u8, rest[0..colon], " \t");
            var known = false;
            for (schema.functions) |k| known = known or std.mem.eql(u8, k, canon);
            for (schema.operators) |k| known = known or std.mem.eql(u8, k, canon);
            if (!known) return c.fail(no, "unknown function or operator '{s}'", .{canon});
            differs = try c.add(Differs, differs, .{ .canon = canon, .text = rest[colon + 3 ..] });
        } else if (std.mem.eql(u8, head, "means")) {
            const eq = std.mem.indexOf(u8, rest, " = ") orelse return c.fail(
                no,
                "means is `means [kind] f(x, y) = expression`",
                .{},
            );
            var lhs = std.mem.trim(u8, rest[0..eq], " \t");
            var kind: ?Kind = null;
            if (std.mem.indexOfScalar(u8, lhs, ' ')) |sp|
                if (sp < (std.mem.indexOfScalar(u8, lhs, '(') orelse lhs.len)) {
                    kind = try kindOf(c, no, lhs[0..sp]);
                    lhs = std.mem.trim(u8, lhs[sp + 1 ..], " \t");
                };
            const open = std.mem.indexOfScalar(u8, lhs, '(') orelse return c.fail(
                no,
                "means needs `f(x, y)` before '='",
                .{},
            );
            if (lhs[lhs.len - 1] != ')') return c.fail(no, "means needs `f(x, y)` before '='", .{});
            const canon = lhs[0..open];
            if (!schema.isFunction(canon)) return c.fail(no, "unknown function '{s}'", .{canon});
            var margs: []const []const u8 = &.{};
            var it = std.mem.splitScalar(u8, lhs[open + 1 .. lhs.len - 1], ',');
            while (it.next()) |a| margs = try c.add([]const u8, margs, std.mem.trim(u8, a, " \t"));
            means = try c.add(
                Means,
                means,
                .{
                    .kind = kind,
                    .canon = canon,
                    .args = margs,
                    .body = std.mem.trim(u8, rest[eq + 3 ..], " \t"),
                },
            );
        } else if (std.mem.eql(u8, head, "switch")) {
            const arrow = std.mem.indexOf(u8, rest, " -> ") orelse return c.fail(
                no,
                "switch is `switch \"words\" -> dialect`",
                .{},
            );
            const lits = try args(c, no, rest[0..arrow]);
            if (lits.len != 1) return c.fail(no, "switch needs one quoted line start", .{});
            switches = try c.add(
                Switch,
                switches,
                .{ .words = lits[0], .dialect = std.mem.trim(u8, rest[arrow + 4 ..], " \t") },
            );
        } else if (std.mem.eql(u8, head, "requires")) {
            const usage = "requires is `requires dc-path|cutset|no-vloop|no-vlloop|no-lloop " ++
                "error|warning [analysis ...] : reason`";
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(no, usage, .{});
            var it = std.mem.tokenizeAny(u8, rest[0..colon], " \t[]");
            const what = std.meta.stringToEnum(
                Topo,
                it.next() orelse "",
            ) orelse return c.fail(no, usage, .{});
            const sev = it.next() orelse "";
            if (!(std.mem.eql(u8, sev, "error") or std.mem.eql(u8, sev, "warning")))
                return c.fail(no, usage, .{});
            const open = std.mem.indexOfScalar(u8, rest[0..colon], '[');
            if ((open == null) != (it.peek() == null) or (open != null and std.mem.indexOfScalar(u8, rest[open.?..colon], ']') == null)) return c.fail(
                no,
                usage,
                .{},
            );
            var analyses: []const Kind = &.{};
            while (it.next()) |w| {
                const k = std.meta.stringToEnum(Kind, w) orelse return c.fail(
                    no,
                    "requires: '{s}' is not an analysis",
                    .{w},
                );
                if (schema.info(k).class != .analysis)
                    return c.fail(no, "requires: '{s}' is not an analysis", .{w});
                analyses = try c.add(Kind, analyses, k);
            }
            requires = try c.add(
                Require,
                requires,
                .{
                    .what = what,
                    .err = sev[0] == 'e',
                    .analyses = analyses,
                    .reason = rest[colon + 3 ..],
                },
            );
        } else if (std.mem.eql(u8, head, "reserved")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "reserved is `reserved name ... : reason`",
                .{},
            );
            const names = try args(c, no, rest[0..colon]);
            const shadowed = names.len > 1 and std.mem.eql(u8, names[0], "shadowed");
            reserved = try c.add(Reserved, reserved, .{ .names = if (shadowed)
                names[1..]
            else
                names, .reason = rest[colon + 3 ..], .shadowed = shadowed });
        } else if (std.mem.eql(u8, head, "spread")) {
            const a = try args(c, no, rest);
            if (a.len < 1 or a.len > 2)
                return c.fail(no, "spread is `spread kind [\"word\"]`", .{});
            spreads = try c.add(
                Spread,
                spreads,
                .{ .kind = try kindOf(c, no, a[0]), .word = if (a.len == 2)
                    try c.foldIf(fold, a[1])
                else
                    "" },
            );
        } else if (std.mem.eql(u8, head, "rerun")) {
            reruns = try c.add(Kind, reruns, try kindOf(c, no, rest));
        } else if (std.mem.eql(u8, head, "no")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(
                no,
                "no is `no kind [slot] : reason`",
                .{},
            );
            const e = try args(c, no, rest[0..colon]);
            // `no model mos6 : reason`: a family this dialect has no model of.
            if (e.len == 2 and std.mem.eql(u8, e[0], "model")) {
                if (schema.familyKind(e[1]) == null)
                    return c.fail(no, "no model: '{s}' is no model family", .{e[1]});
                no_families = try c.add(
                    NoFamily,
                    no_families,
                    .{ .family = e[1], .reason = rest[colon + 3 ..] },
                );
                continue;
            }
            if (e.len != 1 and e.len != 2)
                return c.fail(no, "no needs a kind, or a kind and a slot", .{});
            const kind, const slot = if (e.len == 2)
                try kindSlot(c, no, e[0], e[1])
            else
                .{ try kindOf(c, no, e[0]), no_slot };
            absent = try c.add(
                Absent,
                absent,
                .{ .kind = kind, .slot = slot, .reason = rest[colon + 3 ..] },
            );
        } else return c.fail(no, "unknown directive `{s}`", .{head});
    }
    if (std.mem.eql(u8, c.name, "?")) return c.fail(1, "missing `dialect <name>`", .{});
    rules = try markEndings(c, rules, spreads);
    // A device named by its module is a plugin's: the block says what to
    // tell who has none, and a block with no such rule says it to no one.
    if (anyWrites(rules, .device, schema.slot(.device, "module")) != (plugin != null))
        return c.fail(
            0,
            "a device rule that names the module (`module`) and a plugin block go together",
            .{},
        );
    return .{
        .read_index = try readIndex(c, rules, blocks, raws),
        .name = c.name,
        .lex = lex,
        .preamble = preamble,
        .preamble_unless = preamble_unless,
        .header = header,
        .header_folded = header_folded,
        .needs = needs,
        .wraps = wraps,
        .raws = raws,
        .owns = owns,
        .no_families = no_families,
        .blocks = blocks,
        .rules = rules,
        .models = models,
        .caveats = caveats,
        .implied = implied,
        .enums = enums,
        .moves = moves,
        .merges = merges,
        .signals = signals,
        .functions = functions,
        .variables = variables,
        .operators = operators,
        .absent = absent,
        .converts = converts,
        .checks = checks,
        .differs = differs,
        .means = means,
        .thresholds = thresholds,
        .params = params,
        .modelparams = modelparams,
        .fills = fills,
        .omitted = omitted,
        .unique_param = unique_param,
        .variation_inline = variation_inline,
        .unique_master = unique_master,
        .libsections_opened = libsections_opened,
        .unique_analysis = unique_analysis,
        .hoist_param = hoist_param,
        .spreads = spreads,
        .reruns = reruns,
        .reserved = reserved,
        .requires = requires,
        .switches = switches,
        .noparams = noparams,
        .computes = computes,
        .edges = edges,
        .inerts = inerts,
        .rewrites = rewrites,
        .plugin = plugin,
    };
}

// ---- private ----

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
