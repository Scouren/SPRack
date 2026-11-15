//! Compiles a `.spgrammar` file into reader/writer tables.
//!
//! The same `compile` runs at compile time (the built-in grammars, where a
//! mistake is a compile error naming the file and line) and at run time (a
//! grammar file given by path, where the mistake comes back as
//! `error.BadGrammar` with `file:line: message` in the `Diag`). Each step
//! that allocates branches on `@inComptime()`: `++` at compile time, the
//! allocator at run time.

const std = @import("std");
const schema = @import("schema.zig");
const Kind = schema.Kind;
const Allocator = std.mem.Allocator;

pub const Scale = struct { suffix: []const u8, exp10: i32 };
/// A scale factor that is not a power of ten (`mil` = 25.4e-6), held as an
/// integer times a power of ten so applying it stays exact.
pub const OddScale = struct { suffix: []const u8, mant: u64, exp10: i32 };

fn parseDecimal(c: *C, line: u32, text: []const u8) Error!struct { u64, i32 } {
    var mant: u64 = 0;
    var exp: i32 = 0;
    var i: usize = 0;
    var seen_point = false;
    while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '.')) : (i += 1) {
        if (text[i] == '.') {
            seen_point = true;
            continue;
        }
        mant = std.math.mul(u64, mant, 10) catch return c.fail(line, "bad multiplier '{s}'", .{text});
        mant += text[i] - '0';
        if (seen_point) exp -= 1;
    }
    if (i < text.len) {
        if (text[i] != 'e' and text[i] != 'E') return c.fail(line, "bad multiplier '{s}'", .{text});
        exp += std.fmt.parseInt(i32, text[i + 1 ..], 10) catch return c.fail(line, "bad multiplier '{s}'", .{text});
    }
    if (mant == 0) return c.fail(line, "bad multiplier '{s}'", .{text});
    return .{ mant, exp };
}

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
pub const BagForm = enum { plain, quoted, vector, fixed, rest, call, pairs };

pub const BagEntry = struct {
    key: []const u8 = "",
    slot: u8 = no_slot,
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
    /// as GMIN and GMINDC). Read, it takes only a repeat of the slot's value.
    also: bool = false,
    /// `maxstep=maxstep?$step`: written, from another dialect's statement
    /// only, when the slot is empty; `$slot` expands.
    default: []const u8 = "",
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
pub const Rule = struct { kind: Kind, dir: Dir, pat: []const Node, line: u32, family: []const u8 = "" };
pub const Block = struct {
    kind: Kind,
    open: []const Node,
    inner: []const []const Node,
    close: []const Node,
};
/// Statements of `kinds` live between `open` and `close` in this dialect
/// (VACASK's `control` ... `endc`). Transparent to the IR.
pub const Wrap = struct { open: []const u8, close: []const u8, kinds: []const Kind };
/// A region in a different language, kept verbatim (ngspice `.control`).
/// `reason`: why no other dialect can take it (`raw "embed" ">>>FILE" : ...`).
pub const RawBlock = struct { open: []const u8, close: []const u8, reason: []const u8 = "" };
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
pub const NoParam = struct { family: []const u8, key: []const u8, value: []const u8, err: bool, text: []const u8 };

pub const Threshold = struct { family: []const u8, on: []const u8, off: []const u8, mid: []const u8, half: []const u8 };

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
    /// `td1 + tran.step`: counted from that slot of the statement itself.
    plus: u8 = no_slot,
    /// `from ngspice espice`: only a statement of one of these dialects,
    /// the ones measured to mean that default; and with nothing in the
    /// netlist to take it from, an error. Empty: any dialect without an
    /// `invalid` line of its own for the slot.
    only: []const []const u8 = &.{},
};

/// Something a reader of the translated netlist should know when a slot
/// crosses into or out of this dialect (`uic` is not quite `skipdc=yes`).
/// `caveat hdl path=*.osdi : ...` holds only where the value ends so.
/// `read`: said when a translation reads this dialect, not writes it.
pub const Caveat = struct { kind: Kind, slot: u8, text: []const u8, suffix: []const u8 = "", read: bool = false };
/// `inert options post : why`: a parameter that changes no result here; a
/// translation out of this dialect leaves it out with a note, not an error.
pub const Inert = struct { kind: Kind, key: []const u8, text: []const u8 };

/// A value the dialect assumes when the statement does not say it;
/// `wave=exp` after it: only where that atom slot holds that word.
pub const Implied = struct { kind: Kind, slot: u8, text: []const u8, when_slot: u8 = no_slot, when_atom: []const u8 = "" };
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
};
/// `params kind ... end`: the instance parameters a device of that kind
/// takes here, by canonical (ngspice) name. A parameter a statement brings
/// from another dialect that the table lacks is a loss; a kind without a
/// table is not checked.
pub const ParamTable = struct { kind: Kind, names: []const Spellings };

/// Does a `params` table end in `same ...`: unlisted parameters are not checked?
pub fn paramsOpen(table: []const Spellings) bool {
    for (table) |e| if (std.mem.eql(u8, e.canon, "...")) return true;
    return false;
}
/// A function or operator this dialect spells like the others but
/// evaluates differently (HSPICE `pow` truncates its exponent).
pub const Differs = struct { canon: []const u8, text: []const u8 };
/// A kind the simulator itself lacks, and why.
pub const Absent = struct { kind: Kind, reason: []const u8 };
/// `switch "simulator lang=spice" -> hspice`: from a line that starts with
/// these words on, the file is in another dialect.
pub const Switch = struct { words: []const u8, dialect: []const u8 };
pub const Spread = struct { kind: Kind, word: []const u8 = "" };
/// `reserved name ... : reason`: parameter names the simulator refuses.
pub const Reserved = struct { names: []const []const u8, reason: []const u8 };
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
pub const Require = struct { what: Topo, err: bool, analyses: []const Kind = &.{}, reason: []const u8 };

pub const ModelKv = struct { key: []const u8, val: []const u8, absent: bool };
pub const ModelSpelling = struct { type: []const u8, kv: []const ModelKv };
pub const ModelEntry = struct {
    family: []const u8,
    polarity: []const u8,
    spellings: []const ModelSpelling,
};

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
    thresholds: []const Threshold = &.{},
    params: []const ParamTable = &.{},
    fills: []const Fill = &.{},
    /// `unique param : why`: a parameter defined twice in one scope is
    /// refused here. Empty: allowed.
    unique_param: []const u8 = "",
    /// `unique master : why`: models and subcircuits share one name space
    /// here, so an instance of a name both define is ambiguous.
    unique_master: []const u8 = "",
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
    inerts: []const Inert = &.{},

    /// Does this dialect give the slot a meaning of its own when it is
    /// missing (an `invalid` line)? Then a missing value is not SPICE's
    /// default, and no `default` line fills it.
    pub fn checksSlot(g: *const Grammar, kind: Kind, slot: u8) bool {
        for (g.checks) |ck| if (ck.kind == kind and ck.slot == slot) return true;
        return false;
    }

    pub fn paramsOf(g: *const Grammar, kind: Kind) ?[]const Spellings {
        for (g.params) |t| if (t.kind == kind) return t.names;
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
        const word = g.spreadWord(rule.kind) orelse return false;
        return rule.pat.len > 0 and rule.pat[0].tag == .lit and std.mem.eql(u8, rule.pat[0].text, word);
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
        for (g.absent) |e| if (e.kind == kind) return e.reason;
        return null;
    }

    pub fn canWrite(g: *const Grammar, kind: Kind) bool {
        for (g.rules) |r| if (r.kind == kind and r.dir != .read) return true;
        for (g.blocks) |b| if (b.kind == kind) return true;
        return false;
    }

    pub fn canWriteRule(g: *const Grammar, kind: Kind) bool {
        for (g.rules) |r| if (r.kind == kind and r.dir != .read) return true;
        return false;
    }

    pub fn blockOf(g: *const Grammar, kind: Kind) ?*const Block {
        for (g.blocks) |*b| if (b.kind == kind) return b;
        return null;
    }

    pub fn canRead(g: *const Grammar, kind: Kind) bool {
        for (g.rules) |r| if (r.kind == kind and r.dir != .write) return true;
        for (g.blocks) |b| if (b.kind == kind) return true;
        return false;
    }

    pub fn hasModel(g: *const Grammar, family: []const u8, polarity: []const u8) bool {
        for (g.models) |m| {
            if (std.mem.eql(u8, m.family, family) and std.mem.eql(u8, m.polarity, polarity)) return true;
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

// ---------------------------------------------------------------- compiler

pub const Error = error{ BadGrammar, OutOfMemory };

/// What a failed run-time `compile` says: `file:line: message`, allocated
/// with the allocator given to `compile`.
pub const Diag = struct { msg: []const u8 = "" };

/// The compiler's context: where to allocate and where to report.
const C = struct {
    /// Unused at compile time.
    gpa: Allocator,
    diag: *Diag,
    /// File named in messages; empty means `<dialect>.spgrammar`.
    file: []const u8,
    name: []const u8 = "?",
    /// Lists `add` grew with room to spare, by address: appending to one
    /// of them again fills the room instead of copying.
    grown: std.AutoHashMapUnmanaged(usize, Grown) = .empty,
    /// Nodes the pattern being parsed has so far, defines expanded.
    nodes: u32 = 0,

    const Grown = struct { len: usize, cap: usize };

    fn fail(c: *C, line: u32, comptime fmt: []const u8, a: anytype) Error {
        if (@inComptime()) {
            const f = if (c.file.len > 0) c.file else c.name ++ ".spgrammar";
            @compileError(std.fmt.comptimePrint("{s}:{d}: ", .{ f, line }) ++ std.fmt.comptimePrint(fmt, a));
        }
        const where = if (c.file.len > 0)
            try std.fmt.allocPrint(c.gpa, "{s}:{d}: ", .{ c.file, line })
        else
            try std.fmt.allocPrint(c.gpa, "{s}.spgrammar:{d}: ", .{ c.name, line });
        c.diag.msg = try std.mem.concat(c.gpa, u8, &.{ where, try std.fmt.allocPrint(c.gpa, fmt, a) });
        return error.BadGrammar;
    }

    /// `list` with `item` appended. At run time a list grows geometrically:
    /// copying it on every append made a long line cost O(n^2) memory, and
    /// a mutated grammar of 6 KB took more than 1 GB.
    fn add(c: *C, comptime T: type, list: []const T, item: T) Error![]const T {
        if (@inComptime()) return list ++ &[_]T{item};
        if (list.len > 0) if (c.grown.getPtr(@intFromPtr(list.ptr))) |g| {
            // Only the newest slice of a list may take the room after it;
            // an older, shorter slice of the same list is copied.
            if (g.len == list.len and g.len < g.cap) {
                const out = @constCast(list.ptr)[0 .. list.len + 1];
                out[list.len] = item;
                g.len += 1;
                return out;
            }
        };
        const buf = try c.gpa.alloc(T, @max(4, 2 * list.len));
        @memcpy(buf[0..list.len], list);
        buf[list.len] = item;
        try c.grown.put(c.gpa, @intFromPtr(buf.ptr), .{ .len = list.len + 1, .cap = buf.len });
        return buf[0 .. list.len + 1];
    }

    fn cat(c: *C, a: []const u8, b: []const u8) Error![]const u8 {
        if (@inComptime()) return a ++ b;
        return std.mem.concat(c.gpa, u8, &.{ a, b });
    }

    fn lower(c: *C, s: []const u8) Error![]const u8 {
        if (@inComptime()) {
            var buf: [s.len]u8 = undefined;
            for (s, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
            const final = buf;
            return &final;
        }
        return std.ascii.allocLowerString(c.gpa, s);
    }

    fn foldIf(c: *C, fold: bool, s: []const u8) Error![]const u8 {
        return if (fold) c.lower(s) else s;
    }
};

/// Strip a `#` comment (only at line start or after a blank, outside quotes).
fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    for (line, 0..) |ch, i| {
        if (quote != 0) {
            if (ch == quote) quote = 0;
        } else if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (ch == '#' and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) {
            return line[0..i];
        }
    }
    return line;
}

const Lines = struct {
    src: []const u8,
    pos: usize = 0,
    no: u32 = 0,

    /// Next non-blank line with comments removed, or null at end of file.
    fn next(l: *Lines) ?[]const u8 {
        while (l.pos < l.src.len) {
            const eol = std.mem.indexOfScalarPos(u8, l.src, l.pos, '\n') orelse l.src.len;
            const raw = l.src[l.pos..eol];
            l.pos = eol + 1;
            l.no += 1;
            const t = std.mem.trim(u8, stripComment(raw), " \t\r");
            if (t.len > 0) return t;
        }
        return null;
    }
};

/// Split a directive line into words and quoted strings.
fn args(c: *C, line_no: u32, line: []const u8) Error![]const []const u8 {
    var out: []const []const u8 = &.{};
    var i: usize = 0;
    while (i < line.len) {
        const ch = line[i];
        if (ch == ' ' or ch == '\t') {
            i += 1;
        } else if (ch == '"' or ch == '\'') {
            const end = std.mem.indexOfScalarPos(u8, line, i + 1, ch) orelse return c.fail(line_no, "unterminated string", .{});
            // An empty word matches everywhere and consumes nothing.
            if (end == i + 1) return c.fail(line_no, "empty string", .{});
            out = try c.add([]const u8, out, line[i + 1 .. end]);
            i = end + 1;
        } else {
            var j = i;
            while (j < line.len and line[j] != ' ' and line[j] != '\t') j += 1;
            out = try c.add([]const u8, out, line[i..j]);
            i = j;
        }
    }
    return out;
}

fn splitHead(line: []const u8) struct { []const u8, []const u8 } {
    const sp = std.mem.indexOfAny(u8, line, " \t") orelse return .{ line, "" };
    return .{ line[0..sp], std.mem.trim(u8, line[sp..], " \t") };
}

fn kindOf(c: *C, line: u32, name: []const u8) Error!Kind {
    return schema.kindFromName(name) orelse return c.fail(line, "unknown kind '{s}'", .{name});
}

/// `define name = pattern`: a named fragment, kept as text and parsed
/// where it is used, so its slot names resolve against the using rule's kind.
const Def = struct { name: []const u8, text: []const u8 };

const P = struct {
    s: []const u8,
    i: usize = 0,
    kind: Kind,
    fold: bool,
    c: *C,
    line: u32,
    defs: []const Def = &.{},
    /// Inside a repeated group: list slots are taken one item at a time.
    in_rep: bool = false,
    /// Groups and defines open around `p.i`. Each is a level of recursion,
    /// so a mutated grammar of a few thousand `(` overflowed the stack.
    depth: u32 = 0,

    const max_depth = 100;
    /// A define used twice in a define used twice ... doubles at each
    /// level: 40 levels of a 1 KB grammar asked for 2^40 nodes.
    const max_nodes = 10_000;

    fn err(p: *P, comptime fmt: []const u8, a: anytype) Error {
        if (@inComptime()) return p.c.fail(p.line, fmt ++ " in pattern `{s}`", a ++ .{p.s});
        return p.c.fail(p.line, "{s} in pattern `{s}`", .{ try std.fmt.allocPrint(p.c.gpa, fmt, a), p.s });
    }

    fn ws(p: *P) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t')) p.i += 1;
    }

    fn peek(p: *P) u8 {
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    fn startsWith(p: *P, what: []const u8) bool {
        return std.mem.startsWith(u8, p.s[p.i..], what);
    }

    fn string(p: *P) Error![]const u8 {
        const q = p.s[p.i];
        const end = std.mem.indexOfScalarPos(u8, p.s, p.i + 1, q) orelse return p.err("unterminated string", .{});
        const out = p.s[p.i + 1 .. end];
        p.i = end + 1;
        return out;
    }

    fn ident(p: *P) Error![]const u8 {
        const start = p.i;
        while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or p.s[p.i] == '_')) p.i += 1;
        if (p.i == start) return p.err("expected a name", .{});
        return p.s[start..p.i];
    }

    /// Characters up to the next blank or closing bracket.
    fn bare(p: *P) []const u8 {
        const start = p.i;
        while (p.i < p.s.len and std.mem.indexOfScalar(u8, " \t]})|", p.s[p.i]) == null) p.i += 1;
        return p.s[start..p.i];
    }

    fn quoted(p: *P) bool {
        return p.peek() == '"' or p.peek() == '\'';
    }

    /// A named slot of the rule's kind. `_` is not one: only a capture
    /// may be the wildcard, and the capture checks for it first.
    fn slotOf(p: *P, name: []const u8) Error!u8 {
        return schema.slotIndex(p.kind, name) orelse {
            var known: []const u8 = "";
            for (schema.info(p.kind).slots) |s| known = try p.c.cat(try p.c.cat(known, " "), s.name);
            return p.err("unknown slot '{s}' for kind '{s}' (known:{s})", .{ name, @tagName(p.kind), known });
        };
    }

    fn slotInfo(p: *P, slot: u8) schema.Slot {
        return schema.info(p.kind).slots[slot];
    }

    fn lit(p: *P, text: []const u8) Error![]const u8 {
        return p.c.foldIf(p.fold, text);
    }

    fn seq(p: *P) Error![]const Node {
        if (p.depth == max_depth) return p.err("groups nested more than {d} deep", .{max_depth});
        p.depth += 1;
        defer p.depth -= 1;
        var out: []const Node = &.{};
        while (true) {
            p.ws();
            const ch = p.peek();
            if (ch == 0 or ch == ']' or ch == ')' or ch == '|') break;
            if (ch == '<') {
                const more = try p.use();
                try p.count(more.len);
                for (more) |n| out = try p.c.add(Node, out, n);
                continue;
            }
            const n = try p.item();
            try p.count(1);
            out = try p.c.add(Node, out, n);
        }
        return out;
    }

    fn count(p: *P, n: usize) Error!void {
        p.c.nodes += @intCast(n);
        if (p.c.nodes > max_nodes) return p.err("more than {d} nodes, defines expanded", .{max_nodes});
    }

    /// `<name>`: the nodes of a `define`, spliced in place.
    fn use(p: *P) Error![]const Node {
        p.i += 1;
        const name = try p.ident();
        if (p.peek() != '>') return p.err("missing '>' after '<{s}'", .{name});
        p.i += 1;
        for (p.defs, 0..) |d, di| {
            if (!std.mem.eql(u8, d.name, name)) continue;
            // A define sees only the ones before it, so it cannot refer to itself.
            var sub: P = .{ .s = d.text, .kind = p.kind, .fold = p.fold, .c = p.c, .line = p.line, .defs = p.defs[0..di], .depth = p.depth };
            const out = try sub.seq();
            if (sub.i < sub.s.len) return sub.err("unexpected '{c}'", .{sub.s[sub.i]});
            return out;
        }
        return p.err("no `define {s}` before this rule", .{name});
    }

    /// Is the group opened just before `p.i` followed by `*` or `+`?
    fn repeats(p: *P) bool {
        var depth: usize = 1;
        var j = p.i;
        while (j < p.s.len) : (j += 1) {
            switch (p.s[j]) {
                '"', '\'' => j = std.mem.indexOfScalarPos(u8, p.s, j + 1, p.s[j]) orelse return false,
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) return j + 1 < p.s.len and (p.s[j + 1] == '*' or p.s[j + 1] == '+' or p.s[j + 1] == '#');
                },
                else => {},
            }
        }
        return false;
    }

    fn item(p: *P) Error!Node {
        switch (p.peek()) {
            '"', '\'' => return .{ .tag = .lit, .text = try p.lit(try p.string()) },
            '[' => {
                p.i += 1;
                const kids = try p.seq();
                if (p.peek() != ']') return p.err("missing ']'", .{});
                p.i += 1;
                return .{ .tag = .opt, .kids = kids };
            },
            '(' => {
                p.i += 1;
                const rep = p.repeats();
                if (rep and p.in_rep) return p.err("a repeated group cannot hold another", .{});
                const outer = p.in_rep;
                p.in_rep = outer or rep;
                var alts: []const Node = &.{};
                while (true) {
                    alts = try p.c.add(Node, alts, .{ .tag = .seq, .kids = try p.seq() });
                    if (p.peek() == '|') {
                        p.i += 1;
                        continue;
                    }
                    break;
                }
                p.in_rep = outer;
                if (p.peek() != ')') return p.err("missing ')'", .{});
                p.i += 1;
                const group: Node = .{ .tag = .alt, .kids = alts };
                if (!rep) return group;
                // `( ... )*` or `( ... )+`, a separator glued on: `( ... )*","`.
                var n: Node = .{ .tag = .rep, .plus = p.peek() != '*', .kids = try p.c.add(Node, &.{}, group) };
                p.i += 1;
                if (p.s[p.i - 1] == '#') n.count = try p.countSlot();
                if (p.quoted()) {
                    n.sep = try p.c.add(Node, &.{}, .{ .tag = .lit, .text = try p.lit(try p.string()) });
                } else if (p.peek() == '~') {
                    p.i += 1;
                    if (!p.quoted()) return p.err("expected a quoted separator after '~'", .{});
                    n.sep = try p.c.add(Node, &.{}, .{ .tag = .glue, .text = try p.string() });
                }
                if (canBeEmpty(n.kids)) return p.err("a repeated group must take at least one word each time", .{});
                return n;
            },
            '{' => {
                if (p.in_rep) return p.err("a repeated group cannot hold '{{ }}'", .{});
                return p.bag();
            },
            '/' => {
                p.i += 1;
                return .{ .tag = .nl };
            },
            '-' => {
                p.i += 1;
                return .{ .tag = .drop, .slot = try p.slotOf(try p.ident()) };
            },
            '~' => {
                p.i += 1;
                if (!p.quoted()) return p.err("expected a quoted literal after '~'", .{});
                return .{ .tag = .glue, .text = try p.string() };
            },
            '.' => if (p.startsWith("...")) {
                if (p.in_rep) return p.err("a repeated group cannot take the rest of the line", .{});
                p.i += 3;
                return .{ .tag = .rest, .slot = wild_slot };
            },
            else => {},
        }
        const name = try p.ident();
        if (p.in_rep and p.startsWith("...")) return p.err("a repeated group cannot take the rest of the line", .{});
        if (p.startsWith("...")) {
            p.i += 3;
            const slot = try p.slotOf(name);
            const rt = p.slotInfo(slot).ty;
            if (rt != .text and rt != .value) return p.err("'{s}...' needs a text or a value slot", .{name});
            return .{ .tag = .rest, .slot = slot };
        }
        if (p.peek() == ':') {
            p.i += 1;
            if (!p.quoted()) return p.err("expected a quoted literal after ':'", .{});
            const text = try p.string();
            var atom: []const u8 = text;
            if (p.peek() == '=') {
                p.i += 1;
                atom = try p.ident();
            }
            const slot = try p.slotOf(name);
            // On a value slot (`acmag:"ac"=1`) the literal stands for a number.
            const vty = p.slotInfo(slot).ty;
            if (vty != .atom and !(vty == .value and !p.slotInfo(slot).list)) return p.err("tagged literal needs an atom slot, '{s}' is not one", .{name});
            if (p.in_rep and !p.slotInfo(slot).list) return p.err("'{s}' is in a repeated group but is not a list slot", .{name});
            var soft = false;
            if (p.peek() == '?') {
                p.i += 1;
                soft = true;
            }
            return .{ .tag = .taglit, .slot = slot, .text = try p.lit(text), .atom = atom, .soft = soft };
        }
        var n: Node = .{ .tag = .cap, .slot = if (std.mem.eql(u8, name, "_")) wild_slot else try p.slotOf(name) };
        while (true) {
            switch (p.peek()) {
                '~' => {
                    p.i += 1;
                    if (!p.quoted()) return p.err("expected a quoted prefix after '~'", .{});
                    n.prefix = try p.lit(try p.string());
                },
                '*' => {
                    p.i += 1;
                    n.star = true;
                },
                '+' => {
                    p.i += 1;
                    n.plus = true;
                },
                '?' => {
                    p.i += 1;
                    n.default = if (p.quoted()) try p.string() else p.bare();
                },
                '!' => {
                    p.i += 1;
                    if (n.slot == wild_slot or p.slotInfo(n.slot).ty != .path) return p.err("'{s}!' needs a path slot", .{name});
                    n.bare = true;
                },
                '#' => {
                    p.i += 1;
                    if (n.slot == wild_slot or !p.slotInfo(n.slot).list) return p.err("'{s}#' needs a list slot", .{name});
                    if (p.peek() == '1') {
                        p.i += 1;
                        n.one = true;
                    } else {
                        n.count = try p.countSlot();
                        n.plus = true;
                    }
                },
                else => break,
            }
        }
        if (n.slot != wild_slot) {
            const si = p.slotInfo(n.slot);
            if ((n.star or n.plus) and !si.list) return p.err("'{s}' is not a list slot", .{name});
            if (p.in_rep) {
                if (!si.list) return p.err("'{s}' is in a repeated group but is not a list slot", .{name});
                if (n.star or n.plus) return p.err("in a repeated group, '{s}' takes one item per pass; drop the '*' or '+'", .{name});
            } else if (!(n.star or n.plus or n.one) and si.list) return p.err("list slot '{s}' needs '*' or '+'", .{name});
            if (si.ty == .params or si.ty == .text) return p.err("slot '{s}' cannot be captured as a single token", .{name});
        }
        return n;
    }

    /// The slot after `#` that holds a count: a single value.
    fn countSlot(p: *P) Error!u8 {
        const name = try p.ident();
        const slot = try p.slotOf(name);
        const si = p.slotInfo(slot);
        if (si.ty != .value or si.list) return p.err("'#{s}' needs a value slot holding a count", .{name});
        return slot;
    }

    fn bag(p: *P) Error!Node {
        p.i += 1;
        var entries: []const BagEntry = &.{};
        while (true) {
            p.ws();
            if (p.peek() == 0) return p.err("missing '}}'", .{});
            if (p.peek() == '}') {
                p.i += 1;
                break;
            }
            if (p.startsWith("...")) {
                p.i += 3;
                const slot = try p.slotOf(try p.ident());
                if (p.slotInfo(slot).ty != .params) return p.err("'...' in a bag needs a params slot", .{});
                var flags = false;
                if (p.peek() == '?') {
                    p.i += 1;
                    flags = true;
                }
                entries = try p.c.add(BagEntry, entries, .{ .slot = slot, .form = .rest, .flags = flags });
                continue;
            }
            const kstart = p.i;
            while (p.i < p.s.len and std.mem.indexOfScalar(u8, " \t=}(", p.s[p.i]) == null) p.i += 1;
            var e: BagEntry = .{ .key = try p.lit(p.s[kstart..p.i]) };
            if (p.startsWith("(*)=")) {
                // `v(*)=slot`: entries are written `v(key)=value`.
                p.i += 4;
                e.form = .call;
                e.slot = try p.slotOf(try p.ident());
                if (p.peek() == '+') {
                    p.i += 1;
                    e.bare_pairs = true;
                }
                if (p.slotInfo(e.slot).ty != .params) return p.err("'key(*)=' needs a params slot", .{});
                entries = try p.c.add(BagEntry, entries, e);
                continue;
            }
            if (e.key.len == 0 or p.peek() != '=') return p.err("expected key=slot inside '{{ }}'", .{});
            p.i += 1;
            switch (p.peek()) {
                '=' => {
                    p.i += 1;
                    e.form = .fixed;
                    e.fixed = p.bare();
                    // `param==temp!@var:temp`: the fixed pair stands for an atom.
                    if (std.mem.indexOfAny(u8, e.fixed, "!@")) |at| {
                        p.i -= e.fixed.len - at;
                        e.fixed = e.fixed[0..at];
                    }
                },
                '"' => {
                    e.form = .quoted;
                    e.slot = try p.slotOf(try p.string());
                },
                '{' => {
                    p.i += 1;
                    e.form = .pairs;
                    e.slot = try p.slotOf(try p.ident());
                    if (p.peek() != '}') return p.err("missing '}}'", .{});
                    p.i += 1;
                    if (p.slotInfo(e.slot).ty != .params) return p.err("'{{slot}}' needs a params slot", .{});
                },
                '[' => {
                    p.i += 1;
                    e.form = .vector;
                    e.slot = try p.slotOf(try p.ident());
                    if (p.peek() != ']') return p.err("missing ']'", .{});
                    p.i += 1;
                    if (!p.slotInfo(e.slot).list) return p.err("'[slot]' needs a list slot", .{});
                },
                else => {
                    e.slot = try p.slotOf(try p.ident());
                    if (p.peek() == '+') {
                        p.i += 1;
                        e.also = true;
                    }
                },
            }
            if (p.peek() == '!') {
                p.i += 1;
                e.required = true;
            }
            if (p.peek() == '?') {
                p.i += 1;
                if (e.form != .plain) return p.err("only a plain key=slot takes a default", .{});
                e.default = p.bare();
            }
            if (p.peek() == '@') {
                p.i += 1;
                e.tag_slot = try p.slotOf(try p.ident());
                if (p.peek() != ':') return p.err("expected ':' after '@slot'", .{});
                p.i += 1;
                e.tag_atom = try p.ident();
            }
            entries = try p.c.add(BagEntry, entries, e);
        }
        return .{ .tag = .bag, .bag = entries };
    }
};

/// Can these nodes match no word at all?
fn canBeEmpty(items: []const Node) bool {
    for (items) |n| {
        switch (n.tag) {
            .lit, .taglit => return false,
            .cap => if (!n.star) return false,
            .seq => if (!canBeEmpty(n.kids)) return false,
            .alt => {
                var all = true;
                for (n.kids) |k| all = all and !canBeEmpty(k.kids);
                if (all) return false;
            },
            .rep => if (n.plus and !canBeEmpty(n.kids)) return false,
            else => {},
        }
    }
    return true;
}

fn pattern(c: *C, line: u32, kind: Kind, fold: bool, text: []const u8, defs: []const Def) Error![]const Node {
    var p: P = .{ .s = text, .kind = kind, .fold = fold, .c = c, .line = line, .defs = defs };
    c.nodes = 0;
    const out = try p.seq();
    if (p.i < p.s.len) return p.err("unexpected '{c}'", .{p.s[p.i]});
    if (out.len == 0) return p.err("empty pattern", .{});
    return out;
}

fn parseLexer(c: *C, lines: *Lines) Error!LexCfg {
    var cfg: LexCfg = .{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return cfg;
        const a = try args(c, lines.no, line);
        const key = a[0];
        const n = a.len - 1;
        if (std.mem.eql(u8, key, "case") and n == 1) {
            cfg.case_sensitive = std.mem.eql(u8, a[1], "sensitive");
        } else if (std.mem.eql(u8, key, "title") and n >= 1) {
            cfg.title = std.mem.eql(u8, a[1], "yes");
            if (n == 2) cfg.title_prefix = a[2];
        } else if (std.mem.eql(u8, key, "comment") and n >= 2) {
            if (std.mem.eql(u8, a[1], "line")) {
                for (a[2..]) |x| cfg.line_comments = try c.add([]const u8, cfg.line_comments, x);
            } else if (std.mem.eql(u8, a[1], "tail")) {
                for (a[2..]) |x| cfg.tail_comments = try c.add([]const u8, cfg.tail_comments, x);
            } else if (std.mem.eql(u8, a[1], "block") and n == 3) {
                cfg.block_comment = .{ a[2], a[3] };
            } else return c.fail(lines.no, "comment must be 'line', 'tail' or 'block \"open\" \"close\"'", .{});
        } else if (std.mem.eql(u8, key, "continue") and n == 2) {
            if (std.mem.eql(u8, a[1], "lead")) {
                cfg.cont_lead = a[2];
            } else if (std.mem.eql(u8, a[1], "trail")) {
                cfg.cont_trail = a[2];
            } else return c.fail(lines.no, "continue must be 'lead' or 'trail'", .{});
        } else if (std.mem.eql(u8, key, "parens") and n == 1) {
            cfg.parens_are_space = std.mem.eql(u8, a[1], "space");
        } else if (std.mem.eql(u8, key, "expr") and n == 1 and std.mem.eql(u8, a[1], "bare")) {
            cfg.bare_expr = true;
        } else if (std.mem.eql(u8, key, "expr") and n == 1 and std.mem.eql(u8, a[1], "after-equals")) {
            cfg.bare_after_eq = true;
        } else if (std.mem.eql(u8, key, "expr") and n == 2) {
            cfg.expr_delims = try c.add([2][]const u8, cfg.expr_delims, .{ a[1], a[2] });
        } else if (std.mem.eql(u8, key, "vectors") and n == 1) {
            cfg.vector_sep = if (std.mem.eql(u8, a[1], "comma")) ", " else " ";
        } else if (std.mem.eql(u8, key, "quotes") and n >= 2 and std.mem.eql(u8, a[1], "\"")) {
            if (std.mem.eql(u8, a[2], "expr-in-values")) {
                cfg.dquote_expr = true;
            } else if (!std.mem.eql(u8, a[2], "string")) return c.fail(lines.no, "quotes '\"' takes 'string' or 'expr-in-values'", .{});
            if (n > 2) {
                if (n == 3 or !std.mem.eql(u8, a[3], "except")) return c.fail(lines.no, "expected `except key...` after the quote rule", .{});
                for (a[4..]) |x| cfg.dquote_strings = try c.add([]const u8, cfg.dquote_strings, try c.foldIf(!cfg.case_sensitive, x));
            }
        } else if (std.mem.eql(u8, key, "values") and n == 1) {
            cfg.ident_values = std.mem.eql(u8, a[1], "idents");
        } else if (std.mem.eql(u8, key, "scale") or std.mem.eql(u8, key, "readscale")) {
            for (a[1..]) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return c.fail(lines.no, "scale entries are suffix=exponent", .{});
                const exp = std.fmt.parseInt(i32, pair[eq + 1 ..], 10) catch return c.fail(lines.no, "bad scale exponent in '{s}'", .{pair});
                const entry: Scale = .{ .suffix = try c.foldIf(!cfg.case_sensitive, pair[0..eq]), .exp10 = exp };
                if (key[0] == 's') {
                    cfg.scales = try c.add(Scale, cfg.scales, entry);
                } else cfg.read_scales = try c.add(Scale, cfg.read_scales, entry);
            }
        } else if (std.mem.eql(u8, key, "oddscale")) {
            for (a[1..]) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return c.fail(lines.no, "oddscale entries are suffix=multiplier", .{});
                const mant, const exp = try parseDecimal(c, lines.no, pair[eq + 1 ..]);
                const suf = try c.foldIf(!cfg.case_sensitive, pair[0..eq]);
                cfg.odd_scales = try c.add(OddScale, cfg.odd_scales, .{ .suffix = suf, .mant = mant, .exp10 = exp });
            }
        } else if (std.mem.eql(u8, key, "numbers") and n == 1 and std.mem.eql(u8, a[1], "strict")) {
            cfg.strict_numbers = true;
        } else if (std.mem.eql(u8, key, "units") and n == 1) {
            cfg.units_ignored = std.mem.eql(u8, a[1], "ignore");
        } else if (std.mem.eql(u8, key, "end") and n == 1) {
            cfg.end_marker = try c.foldIf(!cfg.case_sensitive, a[1]);
        } else return c.fail(lines.no, "unknown lexer setting `{s}`", .{line});
    }
    return c.fail(lines.no, "lexer section is missing 'end'", .{});
}

fn parseModels(c: *C, lines: *Lines, fold: bool) Error![]const ModelEntry {
    var out: []const ModelEntry = &.{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return out;
        const eq = std.mem.indexOf(u8, line, " = ") orelse return c.fail(lines.no, "model lines are `family [polarity] = spelling | spelling`", .{});
        const lhs = try args(c, lines.no, line[0..eq]);
        if (lhs.len < 1 or lhs.len > 2) return c.fail(lines.no, "expected `family [polarity]` before '='", .{});
        if (schema.familyKind(lhs[0]) == null) return c.fail(lines.no, "unknown model family '{s}'", .{lhs[0]});
        var spellings: []const ModelSpelling = &.{};
        var it = std.mem.splitScalar(u8, line[eq + 3 ..], '|');
        while (it.next()) |alt| {
            const w = try args(c, lines.no, alt);
            if (w.len == 0) return c.fail(lines.no, "empty model spelling", .{});
            var kv: []const ModelKv = &.{};
            for (w[1..]) |pair| {
                if (pair[0] == '!') {
                    kv = try c.add(ModelKv, kv, .{ .key = try c.foldIf(fold, pair[1..]), .val = "", .absent = true });
                } else {
                    const pe = std.mem.indexOfScalar(u8, pair, '=') orelse return c.fail(lines.no, "expected key=value or !key in '{s}'", .{pair});
                    kv = try c.add(ModelKv, kv, .{ .key = try c.foldIf(fold, pair[0..pe]), .val = pair[pe + 1 ..], .absent = false });
                }
            }
            spellings = try c.add(ModelSpelling, spellings, .{ .type = try c.foldIf(fold, w[0]), .kv = kv });
        }
        out = try c.add(ModelEntry, out, .{
            .family = lhs[0],
            .polarity = if (lhs.len == 2) lhs[1] else "",
            .spellings = spellings,
        });
    }
    return c.fail(lines.no, "models section is missing 'end'", .{});
}

/// `known` null: any name goes (instance parameters), and `name>0` marks
/// one that must be positive.
fn parseSpellings(c: *C, lines: *Lines, fold: bool, what: []const u8, known: ?[]const []const u8) Error![]const Spellings {
    var out: []const Spellings = &.{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return out;
        const a = try args(c, lines.no, line);
        var names: []const []const u8 = &.{};
        var spell: []const []const u8 = &.{};
        if (std.mem.eql(u8, a[0], "same")) {
            names = a[1..];
        } else {
            names = a[0..1];
            const from: usize = if (a.len > 1 and std.mem.eql(u8, a[1], "=")) 2 else 1;
            if (a.len <= from) return c.fail(lines.no, "expected `name = spelling ...` or `same name ...`", .{});
            spell = a[from..];
        }
        for (names) |raw| {
            const positive = known == null and std.mem.endsWith(u8, raw, ">0");
            const n = if (positive) raw[0 .. raw.len - 2] else raw;
            if (known) |list| {
                var ok = false;
                for (list) |k| {
                    if (std.mem.eql(u8, k, n)) ok = true;
                }
                if (!ok) return c.fail(lines.no, "unknown {s} '{s}'", .{ what, n });
            }
            var sp: []const []const u8 = &.{};
            if (spell.len == 0) sp = try c.add([]const u8, sp, try c.foldIf(fold, n));
            for (spell) |x| sp = try c.add([]const u8, sp, try c.foldIf(fold, x));
            out = try c.add(Spellings, out, .{ .canon = n, .spellings = sp, .positive = positive });
        }
    }
    return c.fail(lines.no, "{s} section is missing 'end'", .{what});
}

fn parseSignals(c: *C, lines: *Lines, fold: bool) Error![]const SignalForm {
    var out: []const SignalForm = &.{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return out;
        const a = try args(c, lines.no, line);
        if (a.len != 3 or !std.mem.eql(u8, a[1], "=")) return c.fail(lines.no, "signal lines are `form = \"template\"`", .{});
        var ok = false;
        for (schema.signal_forms) |k| {
            if (std.mem.eql(u8, k, a[0])) ok = true;
        }
        if (!ok) return c.fail(lines.no, "unknown signal form '{s}'", .{a[0]});
        out = try c.add(SignalForm, out, .{ .form = a[0], .template = try c.foldIf(fold, a[2]) });
    }
    return c.fail(lines.no, "signals section is missing 'end'", .{});
}

fn kindSlot(c: *C, line: u32, kind_name: []const u8, slot_name: []const u8) Error!struct { Kind, u8 } {
    const kind = try kindOf(c, line, kind_name);
    const slot = schema.slotIndex(kind, slot_name) orelse return c.fail(line, "unknown slot '{s}' for kind '{s}'", .{ slot_name, kind_name });
    return .{ kind, slot };
}

fn dotted(c: *C, line: u32, text: []const u8) Error!struct { Kind, u8 } {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return c.fail(line, "expected kind.slot, found '{s}'", .{text});
    return kindSlot(c, line, text[0..dot], text[dot + 1 ..]);
}

fn literalLines(c: *C, lines: *Lines) Error![]const []const u8 {
    var out: []const []const u8 = &.{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return out;
        out = try c.add([]const u8, out, line);
    }
    return c.fail(lines.no, "section is missing 'end'", .{});
}

/// Turn the text of a `.spgrammar` file into a `Grammar`.
///
/// At compile time a mistake is a compile error and `gpa` is never used
/// (pass `undefined`). At run time the grammar's tables are allocated from
/// `gpa` and point into `src`, so both must outlive it: pass an arena. A
/// mistake returns `error.BadGrammar` with `file:line: message` in `diag`;
/// `file` names the grammar in messages (empty: `<dialect>.spgrammar`).
pub fn compile(gpa: Allocator, src: []const u8, file: []const u8, diag: *Diag) Error!Grammar {
    @setEvalBranchQuota(20_000_000);
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
    var thresholds: []const Threshold = &.{};
    var params: []const ParamTable = &.{};
    var fills: []const Fill = &.{};
    var unique_param: []const u8 = "";
    var unique_master: []const u8 = "";
    var spreads: []const Spread = &.{};
    var reruns: []const Kind = &.{};
    var reserved: []const Reserved = &.{};
    var requires: []const Require = &.{};
    var switches: []const Switch = &.{};
    var noparams: []const NoParam = &.{};
    var inerts: []const Inert = &.{};

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
            if (std.mem.startsWith(u8, rest, "unless ")) preamble_unless = try kindOf(c, no, rest["unless ".len..]);
            preamble = try literalLines(c, &lines);
        } else if (std.mem.eql(u8, head, "header")) {
            if (std.mem.eql(u8, rest, "folded")) {
                header_folded = try literalLines(c, &lines);
            } else if (rest.len > 0) {
                return c.fail(no, "`header {s}`: only `header folded` takes a word", .{rest});
            } else header = try literalLines(c, &lines);
        } else if (std.mem.eql(u8, head, "needs")) {
            if (schema.kindFromName(rest) == null and schema.familyKind(rest) != null) {
                needs = try c.add(Needs, needs, .{ .kind = .model, .family = rest, .lines = try literalLines(c, &lines) });
            } else {
                const kind = try kindOf(c, no, rest);
                needs = try c.add(Needs, needs, .{ .kind = kind, .lines = try literalLines(c, &lines) });
            }
        } else if (std.mem.eql(u8, head, "wrap")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(no, "wrap is `wrap \"open\" \"close\" : kind ...`", .{});
            const lits = try args(c, no, rest[0..colon]);
            if (lits.len != 2) return c.fail(no, "wrap needs an opening and a closing literal", .{});
            var kinds: []const Kind = &.{};
            for (try args(c, no, rest[colon + 3 ..])) |k| kinds = try c.add(Kind, kinds, try kindOf(c, no, k));
            wraps = try c.add(Wrap, wraps, .{
                .open = try c.foldIf(fold, lits[0]),
                .close = try c.foldIf(fold, lits[1]),
                .kinds = kinds,
            });
        } else if (std.mem.eql(u8, head, "raw")) {
            const colon = std.mem.indexOf(u8, rest, " : ");
            const lits = try args(c, no, if (colon) |k| rest[0..k] else rest);
            if (lits.len != 2) return c.fail(no, "raw is `raw \"open\" \"close\" [: reason]`", .{});
            raws = try c.add(RawBlock, raws, .{
                .open = try c.foldIf(fold, lits[0]),
                .close = try c.foldIf(fold, lits[1]),
                .reason = if (colon) |k| rest[k + 3 ..] else "",
            });
        } else if (std.mem.eql(u8, head, "block")) {
            const kind = try kindOf(c, no, rest);
            var open: []const Node = &.{};
            var close: []const Node = &.{};
            var inner: []const []const Node = &.{};
            while (true) {
                const bl = lines.next() orelse return c.fail(lines.no, "block is missing 'end'", .{});
                if (std.mem.eql(u8, bl, "end")) break;
                const bh, const br = splitHead(bl);
                const pat = try pattern(c, lines.no, kind, fold, br, defs);
                if (std.mem.eql(u8, bh, "open")) {
                    open = pat;
                } else if (std.mem.eql(u8, bh, "close")) {
                    close = pat;
                } else if (std.mem.eql(u8, bh, "inner")) {
                    inner = try c.add([]const Node, inner, pat);
                } else return c.fail(lines.no, "expected open, inner, close or end", .{});
            }
            if (open.len == 0 or close.len == 0) return c.fail(lines.no, "block needs both open and close", .{});
            blocks = try c.add(Block, blocks, .{ .kind = kind, .open = open, .inner = inner, .close = close });
        } else if (std.mem.eql(u8, head, "rule") or std.mem.eql(u8, head, "read") or std.mem.eql(u8, head, "write")) {
            const eq = std.mem.indexOf(u8, rest, " = ") orelse return c.fail(no, "expected `{s} kind = pattern`", .{head});
            var kname = std.mem.trim(u8, rest[0..eq], " \t");
            var family: []const u8 = "";
            if (std.mem.indexOfScalar(u8, kname, '[')) |b| {
                if (kname[kname.len - 1] != ']') return c.fail(no, "expected `kind[family]`", .{});
                family = kname[b + 1 .. kname.len - 1];
                kname = kname[0..b];
            }
            const kind = try kindOf(c, no, kname);
            if (family.len > 0) {
                if (schema.familyKind(family) == null) return c.fail(no, "unknown model family '{s}'", .{family});
                if (schema.slotIndex(kind, "master") == null) return c.fail(no, "'{s}' names no model, so it cannot depend on a family", .{kname});
            }
            const dir: Dir = if (head[0] == 'r' and head[1] == 'u') .both else if (head[0] == 'r') .read else .write;
            rules = try c.add(Rule, rules, .{
                .kind = kind,
                .dir = dir,
                .pat = try pattern(c, no, kind, fold, rest[eq + 3 ..], defs),
                .line = no,
                .family = family,
            });
        } else if (std.mem.eql(u8, head, "define")) {
            const eq = std.mem.indexOf(u8, rest, " = ") orelse return c.fail(no, "expected `define name = pattern`", .{});
            const dname = std.mem.trim(u8, rest[0..eq], " \t");
            for (defs) |d| if (std.mem.eql(u8, d.name, dname)) return c.fail(no, "`{s}` is already defined", .{dname});
            defs = try c.add(Def, defs, .{ .name = dname, .text = rest[eq + 3 ..] });
        } else if (std.mem.eql(u8, head, "caveat")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(no, "caveat is `caveat kind slot : text`", .{});
            const all = try args(c, no, rest[0..colon]);
            const read = all.len > 0 and std.mem.eql(u8, all[0], "read");
            const ks = all[@intFromBool(read)..];
            if (ks.len != 2) return c.fail(no, "caveat needs a kind and a slot", .{});
            const star = std.mem.indexOf(u8, ks[1], "=*");
            const kind, const slot = try kindSlot(c, no, ks[0], if (star) |k| ks[1][0..k] else ks[1]);
            caveats = try c.add(Caveat, caveats, .{ .kind = kind, .slot = slot, .text = rest[colon + 3 ..], .suffix = if (star) |k| ks[1][k + 2 ..] else "", .read = read });
        } else if (std.mem.eql(u8, head, "inert")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(no, "inert is `inert kind key : text`", .{});
            const e = try args(c, no, rest[0..colon]);
            if (e.len != 2) return c.fail(no, "inert needs a kind and a parameter", .{});
            inerts = try c.add(Inert, inerts, .{ .kind = try kindOf(c, no, e[0]), .key = e[1], .text = rest[colon + 3 ..] });
        } else if (std.mem.eql(u8, head, "threshold")) {
            const e = try args(c, no, rest);
            if (e.len != 7 or !std.mem.eql(u8, e[1], ":") or !std.mem.eql(u8, e[4], "="))
                return c.fail(no, "threshold is `threshold family : on off = mid half`", .{});
            if (schema.familyKind(e[0]) == null) return c.fail(no, "unknown model family '{s}'", .{e[0]});
            thresholds = try c.add(Threshold, thresholds, .{ .family = e[0], .on = e[2], .off = e[3], .mid = e[5], .half = e[6] });
        } else if (std.mem.eql(u8, head, "noparam")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(no, "noparam is `noparam family key[=value] warning|error : text`", .{});
            const e = try args(c, no, rest[0..colon]);
            if (e.len != 3) return c.fail(no, "noparam needs a model family, a parameter and a severity", .{});
            if (!(std.mem.eql(u8, e[2], "error") or std.mem.eql(u8, e[2], "warning"))) return c.fail(no, "noparam severity is warning or error, not '{s}'", .{e[2]});
            if (schema.familyKind(e[0]) == null) return c.fail(no, "unknown model family '{s}'", .{e[0]});
            const eq = std.mem.indexOfScalar(u8, e[1], '=') orelse e[1].len;
            if (eq < e[1].len) _ = std.fmt.parseFloat(f64, e[1][eq + 1 ..]) catch return c.fail(no, "noparam takes a plain number after '='", .{});
            noparams = try c.add(NoParam, noparams, .{
                .family = e[0],
                .key = e[1][0..eq],
                .value = if (eq < e[1].len) e[1][eq + 1 ..] else "",
                .err = std.mem.eql(u8, e[2], "error"),
                .text = rest[colon + 3 ..],
            });
        } else if (std.mem.eql(u8, head, "convert")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(no, "convert is `convert kind [slot=atom] : a = b [op c]`", .{});
            const ks = try args(c, no, rest[0..colon]);
            if (ks.len < 1 or ks.len > 2) return c.fail(no, "convert needs a kind and at most one condition", .{});
            const kind = try kindOf(c, no, ks[0]);
            var cv: Convert = .{ .kind = kind, .dst = 0, .src = 0 };
            var eq: ?[2]u8 = null;
            if (ks.len == 2) {
                if (std.mem.indexOf(u8, ks[1], "==")) |at| {
                    eq = .{ try slotNamed(c, no, kind, ks[1][0..at]), try slotNamed(c, no, kind, ks[1][at + 2 ..]) };
                } else cv.when_slot, cv.when_atom = try condition(c, no, kind, ks[1]);
            }
            const e = try args(c, no, rest[colon + 3 ..]);
            if (e.len < 3 or !std.mem.eql(u8, e[1], "=")) return c.fail(no, "expected `a = b [op c]` after ':'", .{});
            cv.dst = try slotNamed(c, no, kind, e[0]);
            if (eq) |pair| {
                const inner = if (e.len == 3 and e[2].len > 2 and e[2][0] == '[' and e[2][e[2].len - 1] == ']') e[2][1 .. e[2].len - 1] else "";
                if (inner.len == 0 or !std.mem.eql(u8, inner, ks[1][0..std.mem.indexOf(u8, ks[1], "==").?]))
                    return c.fail(no, "with `a==b` the conversion is `l = [a]`", .{});
                if (!schema.info(kind).slots[cv.dst].list) return c.fail(no, "`l = [a]` needs a list slot", .{});
                cv.op = .wrap;
                cv.src = pair[0];
                cv.when_eq = pair[1];
            } else if (e.len == 3) {
                cv.src = try slotNamed(c, no, kind, e[2]);
            } else if (e.len == 5 and std.mem.eql(u8, e[2], "1") and std.mem.eql(u8, e[3], "/")) {
                cv.op = .recip;
                cv.src = try slotNamed(c, no, kind, e[4]);
                if (cv.src != cv.dst) return c.fail(no, "`a = 1 / b` needs a and b to be the same slot", .{});
            } else if (e.len == 5 and e[3].len == 1 and std.mem.indexOfScalar(u8, "-+*/", e[3][0]) != null) {
                cv.op = switch (e[3][0]) {
                    '-' => .sub,
                    '+' => .add,
                    '*' => .mul,
                    else => .div,
                };
                cv.src = try slotNamed(c, no, kind, e[2]);
                if (cv.src != cv.dst) return c.fail(no, "`a = b - c` needs a and b to be the same slot", .{});
                if (schema.slotIndex(kind, e[4])) |si| {
                    cv.arg_slot = si;
                } else {
                    _ = try parseDecimal(c, no, e[4]);
                    cv.arg_num = e[4];
                }
            } else return c.fail(no, "expected `a = b`, `a = a - c`, `a = a + c`, `a = a * c`, `a = a / c` or `a = 1 / a`", .{});
            converts = try c.add(Convert, converts, cv);
        } else if (std.mem.eql(u8, head, "invalid")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(no, "invalid is `invalid kind slot[=0] [slot=atom] : text`", .{});
            const ks = try args(c, no, rest[0..colon]);
            if (ks.len < 2 or ks.len > 3) return c.fail(no, "invalid needs a kind, a slot and at most one condition", .{});
            const kind = try kindOf(c, no, ks[0]);
            const zero = std.mem.endsWith(u8, ks[1], "=0");
            const sname = if (zero) ks[1][0 .. ks[1].len - 2] else ks[1];
            var ck: Check = .{ .kind = kind, .slot = try slotNamed(c, no, kind, sname), .zero = zero, .text = rest[colon + 3 ..] };
            if (ks.len == 3) ck.when_slot, ck.when_atom = try condition(c, no, kind, ks[2]);
            checks = try c.add(Check, checks, ck);
        } else if (std.mem.eql(u8, head, "default")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(no, "default is `default kind slot[=0] [slot=atom] : kind.slot`", .{});
            const ks = try args(c, no, rest[0..colon]);
            if (ks.len < 2 or ks.len > 3) return c.fail(no, "default needs a kind, a slot and at most one condition", .{});
            const kind = try kindOf(c, no, ks[0]);
            const zero = std.mem.endsWith(u8, ks[1], "=0");
            const sname = if (zero) ks[1][0 .. ks[1].len - 2] else ks[1];
            var to = try args(c, no, rest[colon + 3 ..]);
            var plus: u8 = no_slot;
            if (to.len > 2 and std.mem.eql(u8, to[1], "+")) {
                plus = try slotNamed(c, no, kind, to[0]);
                to = to[2..];
            }
            if (to.len == 0 or (to.len > 1 and (to.len == 2 or !std.mem.eql(u8, to[1], "from")))) return c.fail(no, "default takes `[slot +] kind.slot [from dialect...]`", .{});
            const fk, const fs = try dotted(c, no, to[0]);
            var f: Fill = .{ .kind = kind, .slot = try slotNamed(c, no, kind, sname), .zero = zero, .from = fk, .from_slot = fs, .plus = plus, .only = if (to.len > 2) to[2..] else &.{} };
            if (ks.len == 3) f.when_slot, f.when_atom = try condition(c, no, kind, ks[2]);
            fills = try c.add(Fill, fills, f);
        } else if (std.mem.eql(u8, head, "unique")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(no, "unique is `unique param|master : reason`", .{});
            const what = std.mem.trim(u8, rest[0..colon], " \t");
            if (std.mem.eql(u8, what, "param")) {
                unique_param = rest[colon + 3 ..];
            } else if (std.mem.eql(u8, what, "master")) {
                unique_master = rest[colon + 3 ..];
            } else return c.fail(no, "unique takes param or master, not '{s}'", .{what});
        } else if (std.mem.eql(u8, head, "models")) {
            models = try parseModels(c, &lines, fold);
        } else if (std.mem.eql(u8, head, "implied")) {
            const a = try args(c, no, rest);
            if (a.len < 4 or a.len > 5 or !std.mem.eql(u8, a[2], "=")) return c.fail(no, "implied is `implied kind slot = value [slot=atom]`", .{});
            const kind, const slot = try kindSlot(c, no, a[0], a[1]);
            var im: Implied = .{ .kind = kind, .slot = slot, .text = a[3] };
            if (a.len == 5) im.when_slot, im.when_atom = try condition(c, no, kind, a[4]);
            implied = try c.add(Implied, implied, im);
        } else if (std.mem.eql(u8, head, "enum")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(no, "enum is `enum kind slot : canonical=spelling ...`", .{});
            const ks = try args(c, no, rest[0..colon]);
            if (ks.len != 2) return c.fail(no, "enum needs a kind and a slot", .{});
            const kind, const slot = try kindSlot(c, no, ks[0], ks[1]);
            if (schema.info(kind).slots[slot].ty != .atom) return c.fail(no, "enum needs an atom slot", .{});
            var pairs: []const EnumPair = &.{};
            for (try args(c, no, rest[colon + 3 ..])) |pair| {
                const pe = std.mem.indexOfScalar(u8, pair, '=') orelse return c.fail(no, "expected canonical=spelling in '{s}'", .{pair});
                pairs = try c.add(EnumPair, pairs, .{ .canon = pair[0..pe], .spelling = try c.foldIf(fold, pair[pe + 1 ..]) });
            }
            enums = try c.add(EnumMap, enums, .{ .kind = kind, .slot = slot, .pairs = pairs });
        } else if (std.mem.eql(u8, head, "move")) {
            const a = try args(c, no, rest);
            const oneway = a.len == 4 and std.mem.eql(u8, a[3], "oneway");
            if ((a.len != 3 and !oneway) or !std.mem.eql(u8, a[1], "->")) return c.fail(no, "move is `move kind.slot -> kind.slot [oneway]`", .{});
            const fk, const fs = try dotted(c, no, a[0]);
            const tk, const ts = try dotted(c, no, a[2]);
            moves = try c.add(Move, moves, .{ .from = fk, .from_slot = fs, .to = tk, .to_slot = ts, .oneway = oneway });
        } else if (std.mem.eql(u8, head, "merge")) {
            const a = try args(c, no, rest);
            if (a.len != 3 or !std.mem.eql(u8, a[1], "->")) return c.fail(no, "merge is `merge kind -> kind`", .{});
            merges = try c.add(Merge, merges, .{ .from = try kindOf(c, no, a[0]), .into = try kindOf(c, no, a[2]) });
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
            if (schema.info(kind).class != .device or schema.slotIndex(kind, "params") == null) return c.fail(no, "params needs a device kind with parameters", .{});
            params = try c.add(ParamTable, params, .{ .kind = kind, .names = try parseSpellings(c, &lines, fold, "parameter", null) });
        } else if (std.mem.eql(u8, head, "differs")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(no, "differs is `differs function-or-operator : reason`", .{});
            const canon = std.mem.trim(u8, rest[0..colon], " \t");
            var known = false;
            for (schema.functions) |k| known = known or std.mem.eql(u8, k, canon);
            for (schema.operators) |k| known = known or std.mem.eql(u8, k, canon);
            if (!known) return c.fail(no, "unknown function or operator '{s}'", .{canon});
            differs = try c.add(Differs, differs, .{ .canon = canon, .text = rest[colon + 3 ..] });
        } else if (std.mem.eql(u8, head, "switch")) {
            const arrow = std.mem.indexOf(u8, rest, " -> ") orelse return c.fail(no, "switch is `switch \"words\" -> dialect`", .{});
            const lits = try args(c, no, rest[0..arrow]);
            if (lits.len != 1) return c.fail(no, "switch needs one quoted line start", .{});
            switches = try c.add(Switch, switches, .{ .words = lits[0], .dialect = std.mem.trim(u8, rest[arrow + 4 ..], " \t") });
        } else if (std.mem.eql(u8, head, "requires")) {
            const usage = "requires is `requires dc-path|cutset|no-vloop|no-vlloop|no-lloop error|warning [analysis ...] : reason`";
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(no, usage, .{});
            var it = std.mem.tokenizeAny(u8, rest[0..colon], " \t[]");
            const what = std.meta.stringToEnum(Topo, it.next() orelse "") orelse return c.fail(no, usage, .{});
            const sev = it.next() orelse "";
            if (!(std.mem.eql(u8, sev, "error") or std.mem.eql(u8, sev, "warning"))) return c.fail(no, usage, .{});
            const open = std.mem.indexOfScalar(u8, rest[0..colon], '[');
            if ((open == null) != (it.peek() == null) or (open != null and std.mem.indexOfScalar(u8, rest[open.?..colon], ']') == null)) return c.fail(no, usage, .{});
            var analyses: []const Kind = &.{};
            while (it.next()) |w| {
                const k = std.meta.stringToEnum(Kind, w) orelse return c.fail(no, "requires: '{s}' is not an analysis", .{w});
                if (schema.info(k).class != .analysis) return c.fail(no, "requires: '{s}' is not an analysis", .{w});
                analyses = try c.add(Kind, analyses, k);
            }
            requires = try c.add(Require, requires, .{ .what = what, .err = sev[0] == 'e', .analyses = analyses, .reason = rest[colon + 3 ..] });
        } else if (std.mem.eql(u8, head, "reserved")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(no, "reserved is `reserved name ... : reason`", .{});
            reserved = try c.add(Reserved, reserved, .{ .names = try args(c, no, rest[0..colon]), .reason = rest[colon + 3 ..] });
        } else if (std.mem.eql(u8, head, "spread")) {
            const a = try args(c, no, rest);
            if (a.len < 1 or a.len > 2) return c.fail(no, "spread is `spread kind [\"word\"]`", .{});
            spreads = try c.add(Spread, spreads, .{ .kind = try kindOf(c, no, a[0]), .word = if (a.len == 2) try c.foldIf(fold, a[1]) else "" });
        } else if (std.mem.eql(u8, head, "rerun")) {
            reruns = try c.add(Kind, reruns, try kindOf(c, no, rest));
        } else if (std.mem.eql(u8, head, "no")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse return c.fail(no, "no is `no kind : reason`", .{});
            absent = try c.add(Absent, absent, .{ .kind = try kindOf(c, no, std.mem.trim(u8, rest[0..colon], " \t")), .reason = rest[colon + 3 ..] });
        } else return c.fail(no, "unknown directive `{s}`", .{head});
    }
    if (std.mem.eql(u8, c.name, "?")) return c.fail(1, "missing `dialect <name>`", .{});
    return .{
        .name = c.name,
        .lex = lex,
        .preamble = preamble,
        .preamble_unless = preamble_unless,
        .header = header,
        .header_folded = header_folded,
        .needs = needs,
        .wraps = wraps,
        .raws = raws,
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
        .thresholds = thresholds,
        .params = params,
        .fills = fills,
        .unique_param = unique_param,
        .unique_master = unique_master,
        .spreads = spreads,
        .reruns = reruns,
        .reserved = reserved,
        .requires = requires,
        .switches = switches,
        .noparams = noparams,
        .inerts = inerts,
    };
}

fn slotNamed(c: *C, line: u32, kind: Kind, s: []const u8) Error!u8 {
    return schema.slotIndex(kind, s) orelse c.fail(line, "unknown slot '{s}' for kind '{s}'", .{ s, @tagName(kind) });
}

/// `slot=atom`: a condition on an atom slot.
fn condition(c: *C, line: u32, kind: Kind, text: []const u8) Error!struct { u8, []const u8 } {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return c.fail(line, "expected slot=atom, found '{s}'", .{text});
    const slot = try slotNamed(c, line, kind, text[0..eq]);
    if (schema.info(kind).slots[slot].ty != .atom) return c.fail(line, "a condition needs an atom slot", .{});
    return .{ slot, text[eq + 1 ..] };
}

/// `compile` for a built-in grammar, evaluated at compile time.
pub fn compileBuiltin(comptime src: []const u8) Grammar {
    const g = comptime blk: {
        var diag: Diag = .{};
        break :blk compile(undefined, src, "", &diag) catch unreachable;
    };
    return g;
}

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
    \\end
;

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
    try std.testing.expectEqual(2, g.models.len);
    try std.testing.expect(g.models[1].spellings[1].kv[0].absent);
    try std.testing.expect(g.canWrite(.tran) and !g.canWrite(.noise));
}

test "compile a small grammar at comptime and at run time" {
    try expectTiny(compileBuiltin(tiny));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try expectTiny(try compile(arena.allocator(), tiny, "tiny.spgrammar", &diag));
}

test "a broken grammar at run time names the file and line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { src: []const u8, msg: []const u8 }{
        .{ .src = "dialect x\nlexer\nend\nrule nonsense = \"a\"\n", .msg = "x/bad.spgrammar:4: unknown kind 'nonsense'" },
        .{ .src = "dialect x\nlexer\nend\n\nrule tran = \".tran\" bogus\n", .msg = "x/bad.spgrammar:5: unknown slot 'bogus' for kind 'tran'" },
        .{ .src = "dialect x\nlexer\nend\nrule tran = \".tran\" [ stop\n", .msg = "x/bad.spgrammar:4: missing ']' in pattern" },
        .{ .src = "dialect x\nlexer\n  case insensitive\n", .msg = "x/bad.spgrammar:3: lexer section is missing 'end'" },
        .{ .src = "rule op = \".op\"\n", .msg = "x/bad.spgrammar:1: the lexer section must come before `rule`" },
        .{ .src = "dialect x\nlexer\nend\nrequires dc-path maybe : why\n", .msg = "x/bad.spgrammar:4: requires is `requires dc-path|cutset|no-vloop|no-vlloop|no-lloop error|warning [analysis ...] : reason`" },
        .{ .src = "dialect x\nlexer\nend\nnoparam bsim4 version : why\n", .msg = "x/bad.spgrammar:4: noparam needs a model family, a parameter and a severity" },
        .{ .src = "dialect x\nlexer\nend\nrequires dc-path error [op resistor] : why\n", .msg = "x/bad.spgrammar:4: requires: 'resistor' is not an analysis" },
    };
    for (cases) |cs| {
        var diag: Diag = .{};
        try std.testing.expectError(error.BadGrammar, compile(arena.allocator(), cs.src, "x/bad.spgrammar", &diag));
        if (!std.mem.startsWith(u8, diag.msg, cs.msg)) {
            std.debug.print("got: {s}\nwant prefix: {s}\n", .{ diag.msg, cs.msg });
            return error.TestUnexpectedResult;
        }
    }
}
