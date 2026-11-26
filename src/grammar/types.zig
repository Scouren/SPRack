//! The rows of a compiled grammar: pattern nodes, rules, blocks, and one
//! struct per directive whose lines become a table of `Grammar`.
//!
//! Contents:
//! - `pub const Scale = struct`
//! - `pub const OddScale = struct`
//! - `pub const LexCfg = struct`
//! - `pub const no_slot: u8`
//! - `pub const wild_slot: u8`
//! - `pub const NodeTag = enum`
//! - `pub const BagForm = enum`
//! - `pub const BagEntry = struct`
//! - `pub const Node = struct`
//! - `pub const Dir = enum`
//! - `pub const Rule = struct`
//! - `pub const Block = struct`
//! - `pub const Wrap = struct`
//! - `pub const RawBlock = struct`
//! - `pub const NoFamily = struct`
//! - `pub const Own = struct`
//! - `pub const Needs = struct`
//! - `pub const Convert = struct`
//! - `pub const Computes = struct`
//! - `pub const Edge = struct`
//! - `pub const NoParam = struct`
//! - `pub const Threshold = struct`
//! - `pub const Check = struct`
//! - `pub const Fill = struct`
//! - `pub const Omitted = struct`
//! - `pub const Caveat = struct`
//! - `pub const Plugin = struct`
//! - `pub const Rewrite = struct`
//! - `pub const Inert = struct`
//! - `pub const Implied = struct`
//! - `pub const EnumPair = struct`
//! - `pub const EnumMap = struct`
//! - `pub const Move = struct`
//! - `pub const Merge = struct`
//! - `pub const SignalForm = struct`
//! - `pub const Spellings = struct`
//! - `pub const ParamTable = struct`
//! - `pub const ModelParamTable = struct`
//! - `pub const Differs = struct`
//! - `pub const Means = struct`
//! - `pub const Absent = struct`
//! - `pub const Switch = struct`
//! - `pub const Spread = struct`
//! - `pub const Reserved = struct`
//! - `pub const Topo = enum`
//! - `pub const Require = struct`
//! - `pub const UniqueAnalysis = struct`
//! - `pub const ModelKv = struct`
//! - `pub const ModelWhen = struct`
//! - `pub const ModelSpelling = struct`
//! - `pub const ModelEntry = struct`
//! - `pub fn paramsOpen(table: []const Spellings) bool`

const std = @import("std");
const schema = @import("schema");
const Kind = schema.Kind;

pub const Scale = struct { suffix: []const u8, exp10: i32 };

/// A scale factor that is not a power of ten (`mil` = 25.4e-6), held as an
/// integer times a power of ten so applying it stays exact.
pub const OddScale = struct { suffix: []const u8, mant: u64, exp10: i32 };

pub const LexCfg = struct {
    case_sensitive: bool = false,
    /// First line of the file is a title, not a statement.
    title: bool = true,
    /// Written before the title, stripped when reading (`// ` in Spectre).
    title_prefix: []const u8 = "",
    line_comments: []const []const u8 = &.{},
    tail_comments: []const []const u8 = &.{},
    /// Open and close markers of comments that can sit inside a line.
    block_comment: ?[2][]const u8 = null,
    /// A line starting with this continues the previous one (`+`).
    cont_lead: []const u8 = "",
    /// A line ending with this continues on the next one (`\`).
    cont_trail: []const u8 = "",
    /// SPICE treats `(`, `)` as blanks; Spectre treats them as tokens.
    parens_are_space: bool = true,
    /// Delimiter pairs around expressions; the first is used when writing.
    expr_delims: []const [2][]const u8 = &.{},
    /// Expressions need no delimiters (`w=2*l`).
    bare_expr: bool = false,
    /// After `=`, an undelimited expression runs to the next blank
    /// outside parentheses (`r=2*rv`, `i=1m*v(a,b)`).
    bare_after_eq: bool = false,
    /// A bare identifier may stand where a value is expected (`R1 a b rval`).
    ident_values: bool = false,
    /// `quotes '"' expr-in-values`: a double-quoted value is an expression
    /// (HSPICE), as a single-quoted one is; a path or label stays a string.
    dquote_expr: bool = false,
    /// `... except k1 k2`: parameters whose quoted value is still a string
    /// (a file name, as HSPICE's `rlgcfile=`).
    dquote_strings: []const []const u8 = &.{},
    /// Between the items of a written `[...]` vector.
    vector_sep: []const u8 = " ",
    /// First entry for an exponent is the one used when writing.
    scales: []const Scale = &.{},
    /// Accepted when reading, never used when writing (`%`, `c`).
    read_scales: []const Scale = &.{},
    odd_scales: []const OddScale = &.{},
    /// Letters after a number are ignored even with no scale factor (`10Volts`).
    units_ignored: bool = true,
    /// `numbers strict`: the simulator refuses a malformed number such as
    /// `3.3.0` that a lenient one reads as far as it can.
    strict_numbers: bool = false,
    /// Statement that ends the input (`.end`).
    end_marker: []const u8 = "",
};

pub const no_slot: u8 = 0xff;

pub const wild_slot: u8 = 0xfe;

pub const NodeTag = enum {
    lit,
    /// Punctuation written tight against its neighbours (`v(out,ref)`) that a
    /// paren-blind lexer never sees when reading.
    glue,
    cap,
    taglit,
    opt,
    alt,
    seq,
    bag,
    rest,
    nl,
    /// `-slot`: when writing, the slot is deliberately not written (a
    /// `caveat` says why). Matches nothing when reading.
    drop,
    /// `( ... )*` or `( ... )+`: `kids` is the one group, repeated; each
    /// pass takes the next item of every list slot in it. `sep` goes
    /// between passes.
    rep,
};

/// `pairs`: `k={slot}` writes a params slot as a list of quoted names and
/// values, `ic={"out",0.5,"a","b",1}` (a name pair is a difference).
/// `pair`: `k=[a b]` writes `k="a"`, or `k=["a","b"]` when `b` is given
/// and is not ground (VACASK's `out` of a noise analysis).
pub const BagForm = enum { plain, quoted, vector, fixed, rest, call, pairs, pair };

pub const BagEntry = struct {
    key: []const u8 = "",
    slot: u8 = no_slot,
    /// The second slot of a `pair`.
    slot2: u8 = no_slot,
    form: BagForm = .plain,
    /// `dec=points@sweep:dec`: reading the key also sets `sweep` to `dec`;
    /// the entry is written only when `sweep` is `dec`.
    tag_slot: u8 = no_slot,
    tag_atom: []const u8 = "",
    fixed: []const u8 = "",
    /// `dev=src!`: the statement is only this kind when the key is present.
    required: bool = false,
    /// On a `...rest` entry: bare words are accepted as value-less flags.
    flags: bool = false,
    /// `v(*)=slot+`: bare `key value` pairs are read into the slot too
    /// (HSPICE `.dcvolt n1 1`).
    bare_pairs: bool = false,
    /// `gmindc=gmin+`: only written, from another dialect's statement, and
    /// after another key has written the slot (HSPICE says one SPICE gmin
    /// as GMIN and GMINDC), on this line or on an earlier one of those the
    /// statement is written as (Xyce says one reltol under three packages).
    /// Read, it takes only a repeat of the slot's value.
    also: bool = false,
    /// `maxstep=maxstep?$step`: written, from another dialect's statement
    /// only, when the slot is empty; `$slot` expands.
    default: []const u8 = "",
    /// `out="iout:flow(br)"`: a quoted value is the slot's value and then
    /// this text; read, a value without it is not this entry's.
    suffix: []const u8 = "",
};

pub const Node = struct {
    tag: NodeTag,
    /// Literal text.
    text: []const u8 = "",
    slot: u8 = no_slot,
    star: bool = false,
    plus: bool = false,
    /// Required first characters of a captured name (`R` for resistors).
    prefix: []const u8 = "",
    /// Text written when the slot is empty but the target needs a value.
    default: []const u8 = "",
    /// Canonical value a tagged literal stands for.
    atom: []const u8 = "",
    /// A tagged literal that is also written when its slot is unbound.
    soft: bool = false,
    /// `path!`: written without quotes when it has no blank.
    bare: bool = false,
    /// `signals#1`: a list slot that this form holds exactly one item of.
    one: bool = false,
    /// `vsrcs#dim`, `( cpos cneg )#dim`: as many items, or passes, as the
    /// number captured earlier in slot `count`.
    count: u8 = no_slot,
    kids: []const Node = &.{},
    bag: []const BagEntry = &.{},
    /// Separator of a repeated group: none, or one `lit` or `glue` node.
    sep: []const Node = &.{},
};

pub const Dir = enum { both, read, write };

/// `rule bjt[hicum2] = ...`: `family` set, the form is written only for an
/// instance whose model card is of that family. Reading ignores it.
/// `within`: `rule tran@script = ...`, a rule only for lines inside that
/// block (ngspice's control language inside .control); rules without it are
/// not used there.
/// `ending`: the rule is one of its kind's `spread` endings (`sweep ...`),
/// read only at the end of another statement's line; `compile` sets it.
pub const Rule = struct {
    kind: Kind,
    dir: Dir,
    pat: []const Node,
    family: []const u8 = "",
    within: ?Kind = null,
    ending: bool = false,
};

pub const Block = struct {
    kind: Kind,
    open: []const Node,
    inner: []const []const Node,
    close: []const Node,
    /// `closed`: the opening line opens the block only where a line that
    /// starts with the closing word follows; elsewhere the rules read it.
    closed: bool = false,
};

/// Statements of `kinds` live between `open` and `close` in this dialect
/// (VACASK's `control` ... `endc`). Transparent to the IR.
pub const Wrap = struct { open: []const u8, close: []const u8, kinds: []const Kind };

/// A region in a different language, kept verbatim (ngspice `.control`).
/// `reason`: why no other dialect can take it (`raw "embed" ">>>FILE" : ...`).
/// `as embed`: the region is a statement of that kind (a named file and
/// its text), not text.
pub const RawBlock = struct {
    open: []const u8,
    close: []const u8,
    reason: []const u8 = "",
    kind: ?Kind = null,
};

/// `own ".check" ".dout" : reason`: statements of this dialect that no kind
/// of the schema holds, and why no other dialect gets them. Read as text,
/// as any line no rule reads; written elsewhere they are `unsupported` with
/// the reason, not `untranslated`. `"S*"`: every line whose first word
/// starts so (an element letter).
/// `own model "opt" : reason`: a `.model` type word, not a line's first.
/// `no model family : reason`: why this dialect has no model of a family.
pub const NoFamily = struct { family: []const u8, reason: []const u8 };

pub const Own = struct { word: []const u8, reason: []const u8, model: bool = false };

/// Boilerplate this dialect needs when a kind, or a model of a family, is
/// used (VACASK `load`).
pub const Needs = struct { kind: Kind, family: []const u8 = "", lines: []const []const u8 };

/// `convert kind [slot=atom] : a = b op c`: this dialect's slot `a` holds a
/// function of canonical slots. Writing computes it; reading inverts it.
/// `op` is `-` or `+` (`c` a slot or a number), `1/` (`a = 1 / a`), or none
/// (`a = b`, the value only changes slot). `convert kind a==b : l = [a]`:
/// when `a` equals `b`, `a` is written as the one item of the list `l`
/// (Spectre refuses a sweep whose stop is its start, but takes `values=[f]`).
pub const Convert = struct {
    kind: Kind,
    when_slot: u8 = no_slot,
    when_atom: []const u8 = "",
    /// `a==b`: the slot `src` must equal.
    when_eq: u8 = no_slot,
    dst: u8,
    src: u8,
    op: enum { copy, sub, add, recip, mul, div, wrap } = .copy,
    /// The other operand of `-` or `+`: a slot, or else a number.
    arg_slot: u8 = no_slot,
    arg_num: []const u8 = "",
};

/// `threshold family : on off = mid half`: this dialect gives a switch's
/// thresholds as the levels where it is fully on and fully off, where SPICE
/// gives a midpoint and a hysteresis half-width: on = mid + half,
/// off = mid - half. The names are model parameters, as written.
/// `noparam family key[=value] warning|error : text`: a model parameter this
/// dialect's module for the family does not take (or not with that value);
/// not written when a card of that family crosses into this dialect, and
/// reported as a loss with the severity given (warning: the card still
/// means the same model, said once per file; error: it does not, card by card).
/// `computes resistor narrow short : formula`: how this dialect's model of
/// the family computes with these parameters (canonical names), as measured.
/// Said, with the other dialect's, where a card has no form in one of them.
pub const Computes = struct { family: []const u8, keys: []const []const u8, text: []const u8 };

/// `edge family key : text`: where this dialect's model computes something
/// else than the others at a corner of the parameter (HSPICE's floor
/// resistance where W - 2 DW is 0). A card with the key crossing into or
/// out of the dialect is a caveat with the text.
pub const Edge = struct { family: []const u8, key: []const u8, text: []const u8 };

pub const NoParam = struct {
    family: []const u8,
    key: []const u8,
    value: []const u8,
    err: bool,
    text: []const u8,
};

pub const Threshold = struct {
    family: []const u8,
    on: []const u8,
    off: []const u8,
    mid: []const u8,
    half: []const u8,
};

/// `invalid kind slot[=0] [slot=atom] : text`: a statement without that slot
/// (or, with `=0`, with it zero) means something else here; an error
/// whenever it crosses into or out of this dialect.
pub const Check = struct {
    kind: Kind,
    slot: u8,
    zero: bool,
    when_slot: u8 = no_slot,
    when_atom: []const u8 = "",
    text: []const u8,
};

/// `default kind slot[=0] [slot=atom] : kind.slot`: where a statement
/// crossing into this dialect leaves the slot out (or, with `=0`, gives it
/// as zero) and its own dialect means "the default" by that, this dialect
/// needs the default written: the value of `from_slot` on the netlist's
/// first `from` statement (a pulse's rise time is the `.tran` step).
pub const Fill = struct {
    kind: Kind,
    slot: u8,
    zero: bool,
    when_slot: u8 = no_slot,
    when_atom: []const u8 = "",
    from: Kind,
    from_slot: u8,
};

/// `omitted kind slot[=0] [slot=atom] : formula [given slot] [zero value]`: what this
/// dialect itself means by a statement that leaves the slot out (or, with
/// `=0`, gives it as zero), as measured. A statement crossing to a dialect
/// whose line for the slot says another formula, or that has none, is
/// written with the value of this one; a zero crossing into a dialect that
/// reads it as left out is written as that dialect's `zero` value, or is an
/// error where it has none.
pub const Omitted = struct {
    kind: Kind,
    slot: u8,
    zero: bool,
    when_slot: u8 = no_slot,
    when_atom: []const u8 = "",
    /// `given td2`: the formula holds where the statement gives that slot;
    /// without it the value plays no part (an EXP source that never falls).
    given: u8 = no_slot,
    /// `zero 1e-18`: what is written for a zero crossing into this dialect,
    /// the smallest value measured to be taken as given. Without it such a
    /// zero cannot be said.
    zero_as: []const u8 = "",
    /// The formula as written, blanks apart: two dialects' lines are
    /// compared by it.
    text: []const u8,
    /// The same, operands first: `(a - b) / c` is a b sub c div.
    terms: []const Term,

    pub const Op = enum { add, sub, mul, div };
    pub const Term = union(enum) {
        /// A whole number.
        num: []const u8,
        /// A slot of the statement itself.
        slot: u8,
        /// A slot of the netlist's first statement of a kind (`tran.step`).
        first: struct { kind: Kind, slot: u8 },
        op: Op,
    };
};

/// Something a reader of the translated netlist should know when a slot
/// crosses into or out of this dialect (`uic` is not quite `skipdc=yes`).
/// `caveat hdl path=*.osdi : ...` holds only where the value ends so.
/// `read`: said when a translation reads this dialect, not writes it.
pub const Caveat = struct {
    kind: Kind,
    slot: u8,
    text: []const u8,
    suffix: []const u8 = "",
    read: bool = false,
};

/// `plugin ... end`: this dialect takes a Verilog-A module only compiled,
/// as a plugin, and names the module on the instance (a device rule that
/// says `module`). `missing`: what gets one, said to whoever gave none to
/// the translation; `given`: how the one given is loaded. Both may name
/// `{to}`, `{module}` and, for `given`, `{file}`.
pub const Plugin = struct {
    missing: []const u8,
    given: []const u8,
    drops: []const Drop = &.{},

    /// `card key sev : text` and `instance key[=value] sev : text`: a
    /// parameter a plugin's model card, or its instance, has no place for.
    /// It is not written, and `text` says so, but for an instance that
    /// gives it at `neutral`, where leaving it out changes nothing.
    pub const Drop = struct {
        card: bool,
        key: []const u8,
        /// A number, as written; empty where no value is the plugin's own.
        neutral: []const u8 = "",
        /// An error, else a warning.
        err: bool,
        text: []const u8,
    };
};

/// `rewrite capacitor ic ... end`: an instance parameter this dialect's
/// device does not take, said by other statements. A statement of `kind`
/// read in another dialect that gives `param` is written as `parts`: the
/// statement itself with some slots replaced (`keep`), or another statement
/// in its place (`become`), and any number more (`add`).
pub const Rewrite = struct {
    kind: Kind,
    /// The parameter, by its canonical name.
    param: []const u8,
    /// `when`: what this dialect must be able to write and to spell for the
    /// rewrite to apply; without them the parameter is the loss it was.
    kinds: []const Kind = &.{},
    functions: []const []const u8 = &.{},
    /// At least one; only the first may be `keep`.
    parts: []const Part = &.{},
    /// `clash`: a statement elsewhere that says the parameter another way.
    clash: ?Clash = null,
    /// `loss`: said for each thing of the statement the new one has no
    /// place for; `{what}` in it is that thing.
    loss: []const u8 = "",
    /// `oneway`: said once for the statement.
    note: []const u8 = "",

    /// One statement written. `keep`: the original, the slots of `sets`
    /// replaced and the parameter gone; else a new statement of `kind`
    /// with only those slots.
    pub const Part = struct { kind: Kind, keep: bool, sets: []const Set };

    /// `slot=template`. In a template `{x}` is slot or parameter `x` of the
    /// original; `[...]` is left out when a name inside it has no value.
    pub const Set = struct { slot: u8, template: []const u8 };

    /// `clash ic.values pos neg : text`: an error where a statement of
    /// `kind` has, among the keys of its `slot`, the name one of the
    /// original's `nodes` (slot indices) holds.
    pub const Clash = struct { kind: Kind, slot: u8, nodes: []const u8, text: []const u8 };
};

/// `inert options post : why`: a parameter that changes no result here; a
/// translation out of this dialect leaves it out with a note, not an error.
/// For a kind that is a command (`simctl`), `key` is the command's word.
/// `{to}` in `text` stands for the dialect being written.
pub const Inert = struct { kind: Kind, key: []const u8, text: []const u8 };

/// A value the dialect assumes when the statement does not say it;
/// `wave=exp` after it: only where that atom slot holds that word.
pub const Implied = struct {
    kind: Kind,
    slot: u8,
    text: []const u8,
    when_slot: u8 = no_slot,
    when_atom: []const u8 = "",
};

pub const EnumPair = struct { canon: []const u8, spelling: []const u8 };

/// How the dialect spells the values of a closed-set slot.
pub const EnumMap = struct { kind: Kind, slot: u8, pairs: []const EnumPair };

/// The dialect says this value on a different statement.
/// `oneway`: only written; reading leaves the value where this dialect put it.
pub const Move = struct { from: Kind, from_slot: u8, to: Kind, to_slot: u8, oneway: bool = false };

/// `merge ac -> noise`: what this dialect writes as two statements is one.
/// When reading, an `into` statement takes the slots it lacks from the
/// nearest `from` statement before it, and absorbs that statement when only
/// comments stand between them.
pub const Merge = struct { from: Kind, into: Kind };

pub const SignalForm = struct { form: []const u8, template: []const u8 };

/// One canonical function, variable or operator and its spellings here.
/// The first spelling is the one written.
pub const Spellings = struct {
    canon: []const u8,
    spellings: []const []const u8,
    /// `m>0` in a `params` table: the simulator refuses zero or less.
    positive: bool = false,
    /// `canon = spelling / 2` in a `modelparams` table: the canonical value
    /// is half this dialect's.
    halved: bool = false,
};

/// `params kind ... end`: the instance parameters a device of that kind
/// takes here, by canonical (ngspice) name. A parameter a statement brings
/// from another dialect that the table lacks is a loss; a kind without a
/// table is not checked.
pub const ParamTable = struct { kind: Kind, names: []const Spellings };

/// `modelparams family ... end`: the parameters of a model card of that
/// family that this dialect's model was measured to take, by canonical
/// (ngspice) name. A card crossing between two dialects that both have the
/// table gets the target's spelling of each; what a table does not list is
/// copied as written. `canon = spelling / 2`: the canonical value is half
/// this dialect's. Canonical names that share such a spelling are one
/// parameter here and must be equal to be written (one left out counts as
/// 0); a name listed without itself among its spellings is not taken here.
/// `modelparams family [only]`: with `only`, the table lists every
/// parameter the family's card takes here, and any other is a loss.
pub const ModelParamTable = struct {
    family: []const u8,
    names: []const Spellings,
    only: bool = false,
};

/// A function or operator this dialect spells like the others but
/// evaluates differently (HSPICE `pow` truncates its exponent).
pub const Differs = struct { canon: []const u8, text: []const u8 };

/// `means [kind] f(x, y) = body`: what this dialect means by a function,
/// in canonical functions, for a target that lacks it; with a kind, in
/// statements of that kind only (a behavioural source).
pub const Means = struct {
    kind: ?Kind = null,
    canon: []const u8,
    args: []const []const u8,
    body: []const u8,
};

/// A kind the simulator itself lacks, and why; with a slot, the one value
/// of a kind it has (`no options vntol : why`), the reason ending the error.
pub const Absent = struct { kind: Kind, slot: u8 = no_slot, reason: []const u8 };

/// `switch "simulator lang=spice" -> hspice`: from a line that starts with
/// these words on, the file is in another dialect.
pub const Switch = struct { words: []const u8, dialect: []const u8 };

pub const Spread = struct { kind: Kind, word: []const u8 = "" };

/// `reserved name ... : reason`: parameter names the simulator refuses.
/// `reserved [shadowed] name ... : reason`. `shadowed`: the simulator
/// takes a parameter of the name, but the word in an expression is its
/// variable, so the parameter is renamed all the same.
pub const Reserved = struct {
    names: []const []const u8,
    reason: []const u8,
    shadowed: bool = false,
};

/// A circuit topology the simulator cannot solve (`src/topology.zig`):
/// nodes with no DC path to ground, or a loop of voltage sources only, of
/// voltage sources and inductors, or of inductors only. `cutset` is such an
/// island fed by a current source; with no line for it, the dc-path rule
/// reports it with any analysis.
pub const Topo = enum { @"dc-path", @"no-vloop", @"no-vlloop", @"no-lloop", cutset };

/// `requires dc-path error [op dc ac] : reason`: such a topology is reported
/// here, an error when the simulator fails on it, a warning when it solves it
/// its own way. Only in a netlist with one of `analyses` (`tran`: one without
/// UIC); with none listed, with any analysis.
pub const Require = struct {
    what: Topo,
    err: bool,
    analyses: []const Kind = &.{},
    reason: []const u8,
};

/// `kinds`: the statements that count as an analysis. More than one in a
/// netlist is refused, except two when one is of the kind `beside` (it
/// counts too), which is then loaded and not run.
pub const UniqueAnalysis = struct {
    kinds: []const Kind = &.{},
    beside: ?Kind = null,
    reason: []const u8,
};

/// `level>=99`: read only, any number from `val` up (what the dialect itself
/// takes as another level); never written.
pub const ModelKv = struct { key: []const u8, val: []const u8, absent: bool, min: bool = false };

/// `when key=value` or `when nodes>=n` after a spelling: it is the one
/// written only where the card gives that value for the parameter, or
/// every instance that names the card has at least `n` terminals. The
/// first spelling whose conditions hold is written.
pub const ModelWhen = struct {
    key: []const u8,
    val: []const u8,
    /// `>=`: at least; otherwise equal.
    ge: bool = false,

    /// The terminal count of the instances, not a parameter of the card.
    pub fn isNodes(w: ModelWhen) bool {
        return std.mem.eql(u8, w.key, "nodes");
    }
};

pub const ModelSpelling = struct {
    type: []const u8,
    kv: []const ModelKv,
    when: []const ModelWhen = &.{},
};

/// `provided`: the dialect has the family only as a compiled module the
/// translation is given (`--provide family=FILE`); without one it is an
/// error, as a family with no line.
pub const ModelEntry = struct {
    family: []const u8,
    polarity: []const u8,
    spellings: []const ModelSpelling,
    provided: bool = false,
};

/// Does a `params` table end in `same ...`: unlisted parameters are not checked?
pub fn paramsOpen(table: []const Spellings) bool {
    for (table) |e| if (std.mem.eql(u8, e.canon, "...")) return true;
    return false;
}
