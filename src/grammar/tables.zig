//! `Grammar`: the tables `compile` makes of a `.spgrammar` file, and the
//! questions the reader and writer ask of them.
//!
//! Contents:
//! - `pub const Grammar = struct`
//!   - reading: `readCandidates`, `rulesOf`, `ruleHere`, `isEnding`, `canRead`
//!   - writing: `canWrite`, `canWriteRule`, `writesSlot`, `checksSlot`,
//!     `blockOf`, `rawOf`, `wrapOf`, `movedTo`, `isSpread`, `spreadWord`,
//!     `isRerun`, `enumOf`, `impliedOf`
//!   - what has no form: `ownReason`, `ownModelReason`, `noFamilyReason`,
//!     `absentReason`, `slotAbsentReason`, `inertReason`, `statementInert`
//!   - model cards: `hasModel`, `paramsOf`, `modelParamsOf`, `modelParamsOnly`,
//!     `edgeText`, `computesText`

const std = @import("std");
const schema = @import("schema");
const Kind = schema.Kind;
const index = @import("index.zig");
const types = @import("types.zig");
const ReadIndex = index.ReadIndex;
const anyWrites = index.anyWrites;
const Absent = types.Absent;
const Block = types.Block;
const Caveat = types.Caveat;
const Check = types.Check;
const Computes = types.Computes;
const Convert = types.Convert;
const Differs = types.Differs;
const Edge = types.Edge;
const EnumMap = types.EnumMap;
const Fill = types.Fill;
const Implied = types.Implied;
const Inert = types.Inert;
const LexCfg = types.LexCfg;
const Means = types.Means;
const Merge = types.Merge;
const ModelEntry = types.ModelEntry;
const ModelParamTable = types.ModelParamTable;
const Move = types.Move;
const Needs = types.Needs;
const NoFamily = types.NoFamily;
const NoParam = types.NoParam;
const Omitted = types.Omitted;
const Own = types.Own;
const ParamTable = types.ParamTable;
const Plugin = types.Plugin;
const RawBlock = types.RawBlock;
const Require = types.Require;
const Reserved = types.Reserved;
const Rewrite = types.Rewrite;
const Rule = types.Rule;
const SignalForm = types.SignalForm;
const Spellings = types.Spellings;
const Spread = types.Spread;
const Switch = types.Switch;
const Threshold = types.Threshold;
const UniqueAnalysis = types.UniqueAnalysis;
const Wrap = types.Wrap;
const no_slot = types.no_slot;

pub const Grammar = struct {
    name: []const u8,
    lex: LexCfg,
    preamble: []const []const u8,
    /// `preamble unless global`: the preamble is left out when the netlist
    /// has a statement of this kind, which says the same (`global 0 vdd`).
    preamble_unless: ?Kind = null,
    /// Like the preamble, but written at the top of every file, included
    /// files too (`simulator lang=spectre`).
    header: []const []const u8 = &.{},
    /// `header folded`: the header instead, when the source folds case
    /// (`simulator lang=spectre insensitive=yes`). Read as the header too.
    header_folded: []const []const u8 = &.{},
    needs: []const Needs,
    wraps: []const Wrap,
    raws: []const RawBlock,
    owns: []const Own = &.{},
    no_families: []const NoFamily = &.{},
    blocks: []const Block,
    rules: []const Rule,
    models: []const ModelEntry,
    caveats: []const Caveat,
    implied: []const Implied = &.{},
    enums: []const EnumMap = &.{},
    moves: []const Move = &.{},
    merges: []const Merge = &.{},
    signals: []const SignalForm = &.{},
    functions: []const Spellings = &.{},
    variables: []const Spellings = &.{},
    operators: []const Spellings = &.{},
    absent: []const Absent = &.{},
    converts: []const Convert = &.{},
    checks: []const Check = &.{},
    differs: []const Differs = &.{},
    means: []const Means = &.{},
    thresholds: []const Threshold = &.{},
    params: []const ParamTable = &.{},
    modelparams: []const ModelParamTable = &.{},
    fills: []const Fill = &.{},
    omitted: []const Omitted = &.{},
    /// `unique param : why`: a parameter defined twice in one scope is
    /// refused here. Empty: allowed.
    unique_param: []const u8 = "",
    /// `variation inline`: a parameter's variation is an entry of its own
    /// after it on the line that defines it (`p=1 dev/gauss=0.1`).
    variation_inline: bool = false,
    /// `variant ngspice`: this dialect is that one for another reader (a
    /// drawing tool), so it is not named apart where a message lists the
    /// dialects that have something.
    variant_of: []const u8 = "",
    /// `unique master : why`: models and subcircuits share one name space
    /// here, so an instance of a name both define is ambiguous.
    unique_master: []const u8 = "",
    /// `libsections opened : why`: the simulator opens the includes of
    /// every section of a library file, not only those of the section a
    /// netlist asks for. Empty: only those.
    libsections_opened: []const u8 = "",
    /// `unique analysis kind... [beside kind] : why`: the statements that
    /// count as an analysis where the simulator refuses a netlist with more
    /// than one. Null: any number is taken.
    unique_analysis: ?UniqueAnalysis = null,
    /// `hoist param from dialect...`: an instance sets only what a
    /// subcircuit's header declares here, so a parameter statement inside a
    /// subcircuit read from one of these dialects, measured to take it per
    /// instance, is written on the header.
    hoist_param: []const []const u8 = &.{},
    /// `spread kind ["word"]`: a block kind this dialect says by adding the
    /// kind's rule to the end of each statement in its body (HSPICE
    /// `monte=`). With a word, only the rules that start with it are such
    /// endings, and the others are the kind's own lines (`.temp`).
    spreads: []const Spread = &.{},
    /// `rerun kind`: this dialect runs its analyses where they stand, so
    /// they are written again after each statement of the kind (Spectre's
    /// `altergroup`).
    reruns: []const Kind = &.{},
    reserved: []const Reserved = &.{},
    requires: []const Require = &.{},
    switches: []const Switch = &.{},
    noparams: []const NoParam = &.{},
    computes: []const Computes = &.{},
    edges: []const Edge = &.{},
    inerts: []const Inert = &.{},
    rewrites: []const Rewrite = &.{},
    plugin: ?Plugin = null,
    read_index: ReadIndex = .{},

    /// The rules that may read a line whose first token is a word of this
    /// text (`null`: the first token is not a word), as indices into `rules`.
    pub fn readCandidates(g: *const Grammar, first_word: ?[]const u8) []const u16 {
        const word = first_word orelse return g.read_index.all;
        if (word.len == 0) return g.read_index.all;
        return g.read_index.by_byte[word[0]];
    }

    /// Why `key` of a `kind` statement changes no result in this dialect
    /// (an `inert` line), case ignored; null where no line says so.
    /// Why a statement of `kind` changes nothing in this dialect (`inert
    /// kind : text`, with no parameter): it is left out, with a note.
    pub fn statementInert(g: *const Grammar, kind: Kind) ?[]const u8 {
        for (g.inerts) |in| {
            if (in.kind == kind and in.key.len == 0) return in.text;
        }
        return null;
    }

    /// Why the parameter (or command) `key` of a `kind` statement changes
    /// nothing here; a line that leaves the whole statement out is not
    /// one, whatever `key` is (a command with no word, a key "").
    pub fn inertReason(g: *const Grammar, kind: Kind, key: []const u8) ?[]const u8 {
        for (g.inerts) |in| {
            if (in.kind != kind or in.key.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(in.key, key)) return in.text;
        }
        return null;
    }

    /// The rules of `kind`, read or write, as indices into `rules` in file order.
    pub fn rulesOf(g: *const Grammar, kind: Kind) []const u16 {
        return g.read_index.by_kind[@backingInt(kind)];
    }

    /// Does a rule this dialect writes `kind` by say `slot`?
    pub fn writesSlot(g: *const Grammar, kind: Kind, slot: u8) bool {
        return anyWrites(g.rules, kind, slot);
    }

    /// Does this dialect give the slot a meaning of its own when it is
    /// missing (an `invalid` line)? Then a missing value is not SPICE's
    /// default, and no `default` line fills it.
    pub fn checksSlot(g: *const Grammar, kind: Kind, slot: u8) bool {
        for (g.checks) |ck| if (ck.kind == kind and ck.slot == slot) return true;
        return false;
    }

    /// The region a statement of this kind is written as (`raw ... as kind`).
    pub fn rawOf(g: *const Grammar, kind: Kind) ?*const RawBlock {
        for (g.raws) |*r| if (r.kind != null and r.kind.? == kind) return r;
        return null;
    }

    /// Why a line of this dialect no kind holds has no form elsewhere
    /// (`own`), by its first word.
    pub fn ownReason(g: *const Grammar, line: []const u8) ?[]const u8 {
        const t = std.mem.trimStart(u8, line, " \t");
        const first = t[0 .. std.mem.indexOfAny(u8, t, " \t\n(=") orelse t.len];
        for (g.owns) |o| {
            if (o.model) continue;
            // `"S*"`: every word that starts so, but not the bare prefix.
            const wild = o.word.len > 1 and o.word[o.word.len - 1] == '*';
            const word = if (wild) o.word[0 .. o.word.len - 1] else o.word;
            const hit = if (wild)
                first.len > word.len and g.sameWord(first[0..word.len], word)
            else
                g.sameWord(first, word);
            if (hit) return o.reason;
        }
        return null;
    }

    /// Are two words the same, by this dialect's case rule?
    fn sameWord(g: *const Grammar, a: []const u8, b: []const u8) bool {
        if (g.lex.case_sensitive) return std.mem.eql(u8, a, b);
        return std.ascii.eqlIgnoreCase(a, b);
    }

    pub fn noFamilyReason(g: *const Grammar, family: []const u8) ?[]const u8 {
        for (g.no_families) |n| if (std.mem.eql(u8, n.family, family)) return n.reason;
        return null;
    }

    /// Why a model type of this dialect (`own model`) has no form elsewhere.
    pub fn ownModelReason(g: *const Grammar, ty: []const u8) ?[]const u8 {
        for (g.owns) |o| if (o.model and std.ascii.eqlIgnoreCase(o.word, ty)) return o.reason;
        return null;
    }

    pub fn paramsOf(g: *const Grammar, kind: Kind) ?[]const Spellings {
        for (g.params) |t| if (t.kind == kind) return t.names;
        return null;
    }

    pub fn modelParamsOf(g: *const Grammar, family: []const u8) ?[]const Spellings {
        for (g.modelparams) |t| if (std.mem.eql(u8, t.family, family)) return t.names;
        return null;
    }

    /// Does the family's `modelparams` table list every parameter its card
    /// takes here (`only`)?
    pub fn modelParamsOnly(g: *const Grammar, family: []const u8) bool {
        for (g.modelparams) |t| if (std.mem.eql(u8, t.family, family)) return t.only;
        return false;
    }

    /// The formula of the `computes` line for `family` that names `key`.
    pub fn edgeText(g: *const Grammar, family: []const u8, key: []const u8) ?[]const u8 {
        for (g.edges) |e|
            if (std.mem.eql(u8, e.family, family) and std.ascii.eqlIgnoreCase(e.key, key))
                return e.text;
        return null;
    }

    pub fn computesText(g: *const Grammar, family: []const u8, key: []const u8) ?[]const u8 {
        for (g.computes) |c| {
            if (!std.mem.eql(u8, c.family, family)) continue;
            for (c.keys) |k| if (std.ascii.eqlIgnoreCase(k, key)) return c.text;
        }
        return null;
    }

    pub fn isSpread(g: *const Grammar, kind: Kind) bool {
        for (g.spreads) |s| if (s.kind == kind) return true;
        return false;
    }

    /// The word that starts the kind's `spread` endings, if it has one.
    pub fn spreadWord(g: *const Grammar, kind: Kind) ?[]const u8 {
        for (g.spreads) |s| if (s.kind == kind and s.word.len > 0) return s.word;
        return null;
    }

    /// Is the rule one of its kind's `spread` endings (`sweep ...`)?
    pub fn isEnding(g: *const Grammar, rule: *const Rule) bool {
        _ = g;
        return rule.ending;
    }

    pub fn isRerun(g: *const Grammar, kind: Kind) bool {
        return std.mem.indexOfScalar(Kind, g.reruns, kind) != null;
    }

    pub fn enumOf(g: *const Grammar, kind: Kind, slot: u8) ?*const EnumMap {
        for (g.enums) |*e| if (e.kind == kind and e.slot == slot) return e;
        return null;
    }

    pub fn impliedOf(g: *const Grammar, kind: Kind, slot: u8) ?[]const u8 {
        for (g.implied) |e| if (e.kind == kind and e.slot == slot) return e.text;
        return null;
    }

    pub fn absentReason(g: *const Grammar, kind: Kind) ?[]const u8 {
        return g.slotAbsentReason(kind, no_slot);
    }

    /// Why the simulator cannot say this slot of a kind it has.
    pub fn slotAbsentReason(g: *const Grammar, kind: Kind, slot: u8) ?[]const u8 {
        for (g.absent) |e| if (e.kind == kind and e.slot == slot) return e.reason;
        return null;
    }

    /// Is the rule one for a line where the writer or reader is (inside a
    /// block of kind `in`, or at none)? Inside a block with rules of its
    /// own, only those.
    pub fn ruleHere(g: *const Grammar, r: *const Rule, in: ?Kind) bool {
        if (r.within) |k| return in != null and in.? == k;
        if (in) |k| return g.read_index.own_rules & ReadIndex.kindBit(k) == 0;
        return true;
    }

    pub fn canWrite(g: *const Grammar, kind: Kind) bool {
        return g.read_index.writes & ReadIndex.kindBit(kind) != 0;
    }

    pub fn canWriteRule(g: *const Grammar, kind: Kind) bool {
        return g.read_index.write_rules & ReadIndex.kindBit(kind) != 0;
    }

    pub fn blockOf(g: *const Grammar, kind: Kind) ?*const Block {
        if (g.read_index.blocks & ReadIndex.kindBit(kind) == 0) return null;
        for (g.blocks) |*b| if (b.kind == kind) return b;
        unreachable; // the index says a block of the kind is there
    }

    pub fn canRead(g: *const Grammar, kind: Kind) bool {
        return g.read_index.reads & ReadIndex.kindBit(kind) != 0;
    }

    pub fn hasModel(g: *const Grammar, family: []const u8, polarity: []const u8) bool {
        for (g.models) |m| {
            if (std.mem.eql(u8, m.family, family) and std.mem.eql(u8, m.polarity, polarity))
                return true;
        }
        return false;
    }

    /// The statement this dialect carries a kind's values on, when it has
    /// no statement of its own for them (`move ic.values -> tran.ic`).
    pub fn movedTo(g: *const Grammar, kind: Kind) ?*const Move {
        for (g.moves) |*m| if (m.from == kind) return m;
        return null;
    }

    pub fn wrapOf(g: *const Grammar, kind: Kind) ?*const Wrap {
        for (g.wraps) |*w| for (w.kinds) |k| if (k == kind) return w;
        return null;
    }
};
