//! Compiles a `.spgrammar` file into reader/writer tables, at compile time.
//!
//! `compile` is only ever evaluated in a comptime context. A mistake in a
//! grammar file (unknown kind, unknown slot, a list marker on a scalar slot,
//! an unterminated group) is a compile error that names the file and line.

const std = @import("std");
const schema = @import("schema.zig");
const Kind = schema.Kind;

pub const Scale = struct { suffix: []const u8, exp10: i32 };
/// A scale factor that is not a power of ten (`mil` = 25.4e-6), held as an
/// integer times a power of ten so applying it stays exact.
pub const OddScale = struct { suffix: []const u8, mant: u64, exp10: i32 };

fn parseDecimal(comptime gname: []const u8, comptime line: u32, comptime text: []const u8) struct { u64, i32 } {
    var mant: u64 = 0;
    var exp: i32 = 0;
    var i: usize = 0;
    var seen_point = false;
    while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '.')) : (i += 1) {
        if (text[i] == '.') {
            seen_point = true;
            continue;
        }
        mant = mant * 10 + (text[i] - '0');
        if (seen_point) exp -= 1;
    }
    if (i < text.len) {
        if (text[i] != 'e' and text[i] != 'E') fail(gname, line, "bad multiplier '" ++ text ++ "'");
        exp += std.fmt.parseInt(i32, text[i + 1 ..], 10) catch fail(gname, line, "bad multiplier '" ++ text ++ "'");
    }
    if (mant == 0) fail(gname, line, "bad multiplier '" ++ text ++ "'");
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
    /// First entry for an exponent is the one used when writing.
    scales: []const Scale = &.{},
    /// Accepted when reading, never used when writing (`%`, `c`).
    read_scales: []const Scale = &.{},
    odd_scales: []const OddScale = &.{},
    /// Letters after a number are ignored even with no scale factor (`10Volts`).
    units_ignored: bool = true,
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

pub const BagForm = enum { plain, quoted, vector, fixed, rest, call };

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
    kids: []const Node = &.{},
    bag: []const BagEntry = &.{},
    /// Separator of a repeated group: none, or one `lit` or `glue` node.
    sep: []const Node = &.{},
};

pub const Dir = enum { both, read, write };
pub const Rule = struct { kind: Kind, dir: Dir, pat: []const Node, line: u32 };
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
pub const RawBlock = struct { open: []const u8, close: []const u8 };
/// Boilerplate this dialect needs when a kind is used (VACASK `load`).
pub const Needs = struct { kind: Kind, lines: []const []const u8 };

/// Something a reader of the translated netlist should know when a slot
/// crosses into or out of this dialect (`uic` is not quite `skipdc=yes`).
pub const Caveat = struct { kind: Kind, slot: u8, text: []const u8 };

/// A value the dialect assumes when the statement does not say it.
pub const Implied = struct { kind: Kind, slot: u8, text: []const u8 };
pub const EnumPair = struct { canon: []const u8, spelling: []const u8 };
/// How the dialect spells the values of a closed-set slot.
pub const EnumMap = struct { kind: Kind, slot: u8, pairs: []const EnumPair };
/// The dialect says this value on a different statement.
pub const Move = struct { from: Kind, from_slot: u8, to: Kind, to_slot: u8 };
pub const SignalForm = struct { form: []const u8, template: []const u8 };
/// One canonical function, variable or operator and its spellings here.
/// The first spelling is the one written.
pub const Spellings = struct { canon: []const u8, spellings: []const []const u8 };
/// A kind the simulator itself lacks, and why.
pub const Absent = struct { kind: Kind, reason: []const u8 };

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
    /// Like the preamble, but written at the top of every file, included
    /// files too (`simulator lang=spectre`).
    header: []const []const u8 = &.{},
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
    signals: []const SignalForm = &.{},
    functions: []const Spellings = &.{},
    variables: []const Spellings = &.{},
    operators: []const Spellings = &.{},
    absent: []const Absent = &.{},

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

    pub fn wrapOf(g: *const Grammar, kind: Kind) ?*const Wrap {
        for (g.wraps) |*w| for (w.kinds) |k| if (k == kind) return w;
        return null;
    }
};

// ---------------------------------------------------------------- compiler

fn fail(comptime gname: []const u8, comptime line: u32, comptime msg: []const u8) noreturn {
    @compileError(std.fmt.comptimePrint("{s}.spgrammar:{d}: {s}", .{ gname, line, msg }));
}

fn lower(comptime s: []const u8) []const u8 {
    var buf: [s.len]u8 = undefined;
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const final = buf;
    return &final;
}

/// Strip a `#` comment (only at line start or after a blank, outside quotes).
fn stripComment(comptime line: []const u8) []const u8 {
    var quote: u8 = 0;
    for (line, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '#' and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) {
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
    fn next(comptime l: *Lines) ?[]const u8 {
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
fn args(comptime gname: []const u8, comptime line_no: u32, comptime line: []const u8) []const []const u8 {
    var out: []const []const u8 = &.{};
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == ' ' or c == '\t') {
            i += 1;
        } else if (c == '"' or c == '\'') {
            const end = std.mem.indexOfScalarPos(u8, line, i + 1, c) orelse fail(gname, line_no, "unterminated string");
            out = out ++ &[_][]const u8{line[i + 1 .. end]};
            i = end + 1;
        } else {
            var j = i;
            while (j < line.len and line[j] != ' ' and line[j] != '\t') j += 1;
            out = out ++ &[_][]const u8{line[i..j]};
            i = j;
        }
    }
    return out;
}

fn splitHead(comptime line: []const u8) struct { []const u8, []const u8 } {
    const sp = std.mem.indexOfAny(u8, line, " \t") orelse return .{ line, "" };
    return .{ line[0..sp], std.mem.trim(u8, line[sp..], " \t") };
}

fn kindOf(comptime gname: []const u8, comptime line: u32, comptime name: []const u8) Kind {
    return schema.kindFromName(name) orelse fail(gname, line, "unknown kind '" ++ name ++ "'");
}

/// `define name = pattern`: a named fragment, kept as text and parsed
/// where it is used, so its slot names resolve against the using rule's kind.
const Def = struct { name: []const u8, text: []const u8 };

const P = struct {
    s: []const u8,
    i: usize = 0,
    kind: Kind,
    fold: bool,
    gname: []const u8,
    line: u32,
    defs: []const Def = &.{},
    /// Inside a repeated group: list slots are taken one item at a time.
    in_rep: bool = false,

    fn err(comptime p: *P, comptime msg: []const u8) noreturn {
        fail(p.gname, p.line, msg ++ " in pattern `" ++ p.s ++ "`");
    }

    fn ws(comptime p: *P) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t')) p.i += 1;
    }

    fn peek(comptime p: *P) u8 {
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    fn startsWith(comptime p: *P, comptime what: []const u8) bool {
        return std.mem.startsWith(u8, p.s[p.i..], what);
    }

    fn string(comptime p: *P) []const u8 {
        const q = p.s[p.i];
        const end = std.mem.indexOfScalarPos(u8, p.s, p.i + 1, q) orelse p.err("unterminated string");
        const out = p.s[p.i + 1 .. end];
        p.i = end + 1;
        return out;
    }

    fn ident(comptime p: *P) []const u8 {
        const start = p.i;
        while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or p.s[p.i] == '_')) p.i += 1;
        if (p.i == start) p.err("expected a name");
        return p.s[start..p.i];
    }

    /// Characters up to the next blank or closing bracket.
    fn bare(comptime p: *P) []const u8 {
        const start = p.i;
        while (p.i < p.s.len and std.mem.indexOfScalar(u8, " \t]})|", p.s[p.i]) == null) p.i += 1;
        return p.s[start..p.i];
    }

    fn slotOf(comptime p: *P, comptime name: []const u8) u8 {
        if (std.mem.eql(u8, name, "_")) return wild_slot;
        return schema.slotIndex(p.kind, name) orelse {
            var known: []const u8 = "";
            for (schema.info(p.kind).slots) |s| known = known ++ " " ++ s.name;
            p.err("unknown slot '" ++ name ++ "' for kind '" ++ @tagName(p.kind) ++ "' (known:" ++ known ++ ")");
        };
    }

    fn slotInfo(comptime p: *P, comptime slot: u8) schema.Slot {
        return schema.info(p.kind).slots[slot];
    }

    fn lit(comptime p: *P, comptime text: []const u8) []const u8 {
        return if (p.fold) lower(text) else text;
    }

    fn seq(comptime p: *P) []const Node {
        var out: []const Node = &.{};
        while (true) {
            p.ws();
            const c = p.peek();
            if (c == 0 or c == ']' or c == ')' or c == '|') break;
            if (c == '<') {
                out = out ++ p.use();
                continue;
            }
            out = out ++ &[_]Node{p.item()};
        }
        return out;
    }

    /// `<name>`: the nodes of a `define`, spliced in place.
    fn use(comptime p: *P) []const Node {
        p.i += 1;
        const name = p.ident();
        if (p.peek() != '>') p.err("missing '>' after '<" ++ name ++ "'");
        p.i += 1;
        for (p.defs, 0..) |d, di| {
            if (!std.mem.eql(u8, d.name, name)) continue;
            // A define sees only the ones before it, so it cannot refer to itself.
            var sub: P = .{ .s = d.text, .kind = p.kind, .fold = p.fold, .gname = p.gname, .line = p.line, .defs = p.defs[0..di] };
            const out = sub.seq();
            if (sub.i < sub.s.len) sub.err("unexpected '" ++ sub.s[sub.i .. sub.i + 1] ++ "'");
            return out;
        }
        p.err("no `define " ++ name ++ "` before this rule");
    }

    /// Is the group opened just before `p.i` followed by `*` or `+`?
    fn repeats(comptime p: *P) bool {
        var depth: usize = 1;
        var j = p.i;
        while (j < p.s.len) : (j += 1) {
            switch (p.s[j]) {
                '"', '\'' => j = std.mem.indexOfScalarPos(u8, p.s, j + 1, p.s[j]) orelse return false,
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) return j + 1 < p.s.len and (p.s[j + 1] == '*' or p.s[j + 1] == '+');
                },
                else => {},
            }
        }
        return false;
    }

    fn item(comptime p: *P) Node {
        const c = p.peek();
        switch (c) {
            '"', '\'' => return .{ .tag = .lit, .text = p.lit(p.string()) },
            '[' => {
                p.i += 1;
                const kids = p.seq();
                if (p.peek() != ']') p.err("missing ']'");
                p.i += 1;
                return .{ .tag = .opt, .kids = kids };
            },
            '(' => {
                p.i += 1;
                const rep = p.repeats();
                if (rep and p.in_rep) p.err("a repeated group cannot hold another");
                const outer = p.in_rep;
                p.in_rep = outer or rep;
                var alts: []const Node = &.{};
                while (true) {
                    alts = alts ++ &[_]Node{.{ .tag = .seq, .kids = p.seq() }};
                    if (p.peek() == '|') {
                        p.i += 1;
                        continue;
                    }
                    break;
                }
                p.in_rep = outer;
                if (p.peek() != ')') p.err("missing ')'");
                p.i += 1;
                const group: Node = .{ .tag = .alt, .kids = alts };
                if (!rep) return group;
                // `( ... )*` or `( ... )+`, a separator glued on: `( ... )*","`.
                var n: Node = .{ .tag = .rep, .plus = p.peek() == '+', .kids = &.{group} };
                p.i += 1;
                if (p.peek() == '"' or p.peek() == '\'') {
                    n.sep = &.{.{ .tag = .lit, .text = p.lit(p.string()) }};
                } else if (p.peek() == '~') {
                    p.i += 1;
                    if (p.peek() != '"' and p.peek() != '\'') p.err("expected a quoted separator after '~'");
                    n.sep = &.{.{ .tag = .glue, .text = p.string() }};
                }
                if (canBeEmpty(n.kids)) p.err("a repeated group must take at least one word each time");
                return n;
            },
            '{' => {
                if (p.in_rep) p.err("a repeated group cannot hold '{ }'");
                return p.bag();
            },
            '/' => {
                p.i += 1;
                return .{ .tag = .nl };
            },
            '-' => {
                p.i += 1;
                return .{ .tag = .drop, .slot = p.slotOf(p.ident()) };
            },
            '~' => {
                p.i += 1;
                if (p.peek() != '"' and p.peek() != '\'') p.err("expected a quoted literal after '~'");
                return .{ .tag = .glue, .text = p.string() };
            },
            '.' => if (p.startsWith("...")) {
                if (p.in_rep) p.err("a repeated group cannot take the rest of the line");
                p.i += 3;
                return .{ .tag = .rest, .slot = wild_slot };
            },
            else => {},
        }
        const name = p.ident();
        if (p.in_rep and p.startsWith("...")) p.err("a repeated group cannot take the rest of the line");
        if (p.startsWith("...")) {
            p.i += 3;
            const slot = p.slotOf(name);
            const rt = p.slotInfo(slot).ty;
            if (rt != .text and rt != .value) p.err("'" ++ name ++ "...' needs a text or a value slot");
            return .{ .tag = .rest, .slot = slot };
        }
        if (p.peek() == ':') {
            p.i += 1;
            if (p.peek() != '"' and p.peek() != '\'') p.err("expected a quoted literal after ':'");
            const text = p.string();
            var atom: []const u8 = text;
            if (p.peek() == '=') {
                p.i += 1;
                atom = p.ident();
            }
            const slot = p.slotOf(name);
            if (p.slotInfo(slot).ty != .atom) p.err("tagged literal needs an atom slot, '" ++ name ++ "' is not one");
            if (p.in_rep and !p.slotInfo(slot).list) p.err("'" ++ name ++ "' is in a repeated group but is not a list slot");
            var soft = false;
            if (p.peek() == '?') {
                p.i += 1;
                soft = true;
            }
            return .{ .tag = .taglit, .slot = slot, .text = p.lit(text), .atom = atom, .soft = soft };
        }
        var n: Node = .{ .tag = .cap, .slot = p.slotOf(name) };
        while (true) {
            switch (p.peek()) {
                '~' => {
                    p.i += 1;
                    n.prefix = p.lit(p.string());
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
                    n.default = if (p.peek() == '"' or p.peek() == '\'') p.string() else p.bare();
                },
                else => break,
            }
        }
        if (n.slot != wild_slot) {
            const si = p.slotInfo(n.slot);
            if ((n.star or n.plus) and !si.list) p.err("'" ++ name ++ "' is not a list slot");
            if (p.in_rep) {
                if (!si.list) p.err("'" ++ name ++ "' is in a repeated group but is not a list slot");
                if (n.star or n.plus) p.err("in a repeated group, '" ++ name ++ "' takes one item per pass; drop the '*' or '+'");
            } else if (!(n.star or n.plus) and si.list) p.err("list slot '" ++ name ++ "' needs '*' or '+'");
            if (si.ty == .params or si.ty == .text) p.err("slot '" ++ name ++ "' cannot be captured as a single token");
        }
        return n;
    }

    fn bag(comptime p: *P) Node {
        p.i += 1;
        var entries: []const BagEntry = &.{};
        while (true) {
            p.ws();
            if (p.peek() == 0) p.err("missing '}'");
            if (p.peek() == '}') {
                p.i += 1;
                break;
            }
            if (p.startsWith("...")) {
                p.i += 3;
                const slot = p.slotOf(p.ident());
                if (p.slotInfo(slot).ty != .params) p.err("'...' in a bag needs a params slot");
                var flags = false;
                if (p.peek() == '?') {
                    p.i += 1;
                    flags = true;
                }
                entries = entries ++ &[_]BagEntry{.{ .slot = slot, .form = .rest, .flags = flags }};
                continue;
            }
            const kstart = p.i;
            while (p.i < p.s.len and std.mem.indexOfScalar(u8, " \t=}(", p.s[p.i]) == null) p.i += 1;
            var e: BagEntry = .{ .key = p.lit(p.s[kstart..p.i]) };
            if (p.startsWith("(*)=")) {
                // `v(*)=slot`: entries are written `v(key)=value`.
                p.i += 4;
                e.form = .call;
                e.slot = p.slotOf(p.ident());
                if (p.slotInfo(e.slot).ty != .params) p.err("'key(*)=' needs a params slot");
                entries = entries ++ &[_]BagEntry{e};
                continue;
            }
            if (e.key.len == 0 or p.peek() != '=') p.err("expected key=slot inside '{ }'");
            p.i += 1;
            switch (p.peek()) {
                '=' => {
                    p.i += 1;
                    e.form = .fixed;
                    e.fixed = p.bare();
                },
                '"' => {
                    e.form = .quoted;
                    e.slot = p.slotOf(p.string());
                },
                '[' => {
                    p.i += 1;
                    e.form = .vector;
                    e.slot = p.slotOf(p.ident());
                    if (p.peek() != ']') p.err("missing ']'");
                    p.i += 1;
                    if (!p.slotInfo(e.slot).list) p.err("'[slot]' needs a list slot");
                },
                else => e.slot = p.slotOf(p.ident()),
            }
            if (p.peek() == '!') {
                p.i += 1;
                e.required = true;
            }
            if (p.peek() == '@') {
                p.i += 1;
                e.tag_slot = p.slotOf(p.ident());
                if (p.peek() != ':') p.err("expected ':' after '@slot'");
                p.i += 1;
                e.tag_atom = p.ident();
            }
            entries = entries ++ &[_]BagEntry{e};
        }
        return .{ .tag = .bag, .bag = entries };
    }
};

/// Can these nodes match no word at all?
fn canBeEmpty(comptime items: []const Node) bool {
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

fn pattern(
    comptime gname: []const u8,
    comptime line: u32,
    comptime kind: Kind,
    comptime fold: bool,
    comptime text: []const u8,
    comptime defs: []const Def,
) []const Node {
    var p: P = .{ .s = text, .kind = kind, .fold = fold, .gname = gname, .line = line, .defs = defs };
    const out = p.seq();
    if (p.i < p.s.len) p.err("unexpected '" ++ p.s[p.i .. p.i + 1] ++ "'");
    if (out.len == 0) p.err("empty pattern");
    return out;
}

fn parseLexer(comptime gname: []const u8, comptime lines: *Lines) LexCfg {
    var cfg: LexCfg = .{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return cfg;
        const a = args(gname, lines.no, line);
        const key = a[0];
        const n = a.len - 1;
        if (std.mem.eql(u8, key, "case") and n == 1) {
            cfg.case_sensitive = std.mem.eql(u8, a[1], "sensitive");
        } else if (std.mem.eql(u8, key, "title") and n >= 1) {
            cfg.title = std.mem.eql(u8, a[1], "yes");
            if (n == 2) cfg.title_prefix = a[2];
        } else if (std.mem.eql(u8, key, "comment") and n >= 2) {
            if (std.mem.eql(u8, a[1], "line")) {
                cfg.line_comments = cfg.line_comments ++ a[2..];
            } else if (std.mem.eql(u8, a[1], "tail")) {
                cfg.tail_comments = cfg.tail_comments ++ a[2..];
            } else if (std.mem.eql(u8, a[1], "block") and n == 3) {
                cfg.block_comment = .{ a[2], a[3] };
            } else fail(gname, lines.no, "comment must be 'line', 'tail' or 'block \"open\" \"close\"'");
        } else if (std.mem.eql(u8, key, "continue") and n == 2) {
            if (std.mem.eql(u8, a[1], "lead")) {
                cfg.cont_lead = a[2];
            } else if (std.mem.eql(u8, a[1], "trail")) {
                cfg.cont_trail = a[2];
            } else fail(gname, lines.no, "continue must be 'lead' or 'trail'");
        } else if (std.mem.eql(u8, key, "parens") and n == 1) {
            cfg.parens_are_space = std.mem.eql(u8, a[1], "space");
        } else if (std.mem.eql(u8, key, "expr") and n == 1 and std.mem.eql(u8, a[1], "bare")) {
            cfg.bare_expr = true;
        } else if (std.mem.eql(u8, key, "expr") and n == 1 and std.mem.eql(u8, a[1], "after-equals")) {
            cfg.bare_after_eq = true;
        } else if (std.mem.eql(u8, key, "expr") and n == 2) {
            cfg.expr_delims = cfg.expr_delims ++ &[_][2][]const u8{.{ a[1], a[2] }};
        } else if (std.mem.eql(u8, key, "values") and n == 1) {
            cfg.ident_values = std.mem.eql(u8, a[1], "idents");
        } else if (std.mem.eql(u8, key, "scale") or std.mem.eql(u8, key, "readscale")) {
            for (a[1..]) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse fail(gname, lines.no, "scale entries are suffix=exponent");
                const exp = std.fmt.parseInt(i32, pair[eq + 1 ..], 10) catch fail(gname, lines.no, "bad scale exponent in '" ++ pair ++ "'");
                const suf = if (cfg.case_sensitive) pair[0..eq] else lower(pair[0..eq]);
                const entry = [_]Scale{.{ .suffix = suf, .exp10 = exp }};
                if (key[0] == 's') cfg.scales = cfg.scales ++ &entry else cfg.read_scales = cfg.read_scales ++ &entry;
            }
        } else if (std.mem.eql(u8, key, "oddscale")) {
            for (a[1..]) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse fail(gname, lines.no, "oddscale entries are suffix=multiplier");
                const mant, const exp = parseDecimal(gname, lines.no, pair[eq + 1 ..]);
                const suf = if (cfg.case_sensitive) pair[0..eq] else lower(pair[0..eq]);
                cfg.odd_scales = cfg.odd_scales ++ &[_]OddScale{.{ .suffix = suf, .mant = mant, .exp10 = exp }};
            }
        } else if (std.mem.eql(u8, key, "units") and n == 1) {
            cfg.units_ignored = std.mem.eql(u8, a[1], "ignore");
        } else if (std.mem.eql(u8, key, "end") and n == 1) {
            cfg.end_marker = if (cfg.case_sensitive) a[1] else lower(a[1]);
        } else fail(gname, lines.no, "unknown lexer setting `" ++ line ++ "`");
    }
    fail(gname, lines.no, "lexer section is missing 'end'");
}

fn parseModels(comptime gname: []const u8, comptime lines: *Lines, comptime fold: bool) []const ModelEntry {
    var out: []const ModelEntry = &.{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return out;
        const eq = std.mem.indexOf(u8, line, " = ") orelse fail(gname, lines.no, "model lines are `family [polarity] = spelling | spelling`");
        const lhs = args(gname, lines.no, line[0..eq]);
        if (lhs.len < 1 or lhs.len > 2) fail(gname, lines.no, "expected `family [polarity]` before '='");
        if (schema.familyKind(lhs[0]) == null) fail(gname, lines.no, "unknown model family '" ++ lhs[0] ++ "'");
        var spellings: []const ModelSpelling = &.{};
        var it = std.mem.splitScalar(u8, line[eq + 3 ..], '|');
        while (it.next()) |alt| {
            const w = args(gname, lines.no, alt);
            if (w.len == 0) fail(gname, lines.no, "empty model spelling");
            var kv: []const ModelKv = &.{};
            for (w[1..]) |pair| {
                if (pair[0] == '!') {
                    const k = if (fold) lower(pair[1..]) else pair[1..];
                    kv = kv ++ &[_]ModelKv{.{ .key = k, .val = "", .absent = true }};
                } else {
                    const pe = std.mem.indexOfScalar(u8, pair, '=') orelse fail(gname, lines.no, "expected key=value or !key in '" ++ pair ++ "'");
                    const k = if (fold) lower(pair[0..pe]) else pair[0..pe];
                    kv = kv ++ &[_]ModelKv{.{ .key = k, .val = pair[pe + 1 ..], .absent = false }};
                }
            }
            spellings = spellings ++ &[_]ModelSpelling{.{ .type = if (fold) lower(w[0]) else w[0], .kv = kv }};
        }
        out = out ++ &[_]ModelEntry{.{
            .family = lhs[0],
            .polarity = if (lhs.len == 2) lhs[1] else "",
            .spellings = spellings,
        }};
    }
    fail(gname, lines.no, "models section is missing 'end'");
}

fn parseSpellings(
    comptime gname: []const u8,
    comptime lines: *Lines,
    comptime fold: bool,
    comptime what: []const u8,
    comptime known: []const []const u8,
) []const Spellings {
    var out: []const Spellings = &.{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return out;
        const a = args(gname, lines.no, line);
        var names: []const []const u8 = &.{};
        var spell: []const []const u8 = &.{};
        if (std.mem.eql(u8, a[0], "same")) {
            names = a[1..];
        } else {
            names = a[0..1];
            const from: usize = if (a.len > 1 and std.mem.eql(u8, a[1], "=")) 2 else 1;
            if (a.len <= from) fail(gname, lines.no, "expected `name = spelling ...` or `same name ...`");
            spell = a[from..];
        }
        for (names) |n| {
            var ok = false;
            for (known) |k| {
                if (std.mem.eql(u8, k, n)) ok = true;
            }
            if (!ok) fail(gname, lines.no, "unknown " ++ what ++ " '" ++ n ++ "'");
            var sp: []const []const u8 = &.{};
            if (spell.len == 0) sp = &[_][]const u8{n};
            for (spell) |x| sp = sp ++ &[_][]const u8{if (fold) lower(x) else x};
            out = out ++ &[_]Spellings{.{ .canon = n, .spellings = sp }};
        }
    }
    fail(gname, lines.no, what ++ " section is missing 'end'");
}

fn parseSignals(comptime gname: []const u8, comptime lines: *Lines, comptime fold: bool) []const SignalForm {
    var out: []const SignalForm = &.{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return out;
        const a = args(gname, lines.no, line);
        if (a.len != 3 or !std.mem.eql(u8, a[1], "=")) fail(gname, lines.no, "signal lines are `form = \"template\"`");
        var ok = false;
        for (schema.signal_forms) |k| {
            if (std.mem.eql(u8, k, a[0])) ok = true;
        }
        if (!ok) fail(gname, lines.no, "unknown signal form '" ++ a[0] ++ "'");
        out = out ++ &[_]SignalForm{.{ .form = a[0], .template = if (fold) lower(a[2]) else a[2] }};
    }
    fail(gname, lines.no, "signals section is missing 'end'");
}

fn kindSlot(comptime gname: []const u8, comptime line: u32, comptime kind_name: []const u8, comptime slot_name: []const u8) struct { Kind, u8 } {
    const kind = kindOf(gname, line, kind_name);
    const slot = schema.slotIndex(kind, slot_name) orelse fail(gname, line, "unknown slot '" ++ slot_name ++ "' for kind '" ++ kind_name ++ "'");
    return .{ kind, slot };
}

fn dotted(comptime gname: []const u8, comptime line: u32, comptime text: []const u8) struct { Kind, u8 } {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse fail(gname, line, "expected kind.slot, found '" ++ text ++ "'");
    return kindSlot(gname, line, text[0..dot], text[dot + 1 ..]);
}

fn literalLines(comptime gname: []const u8, comptime lines: *Lines) []const []const u8 {
    var out: []const []const u8 = &.{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return out;
        out = out ++ &[_][]const u8{line};
    }
    fail(gname, lines.no, "section is missing 'end'");
}

/// Turn the text of a `.spgrammar` file into a `Grammar`. Comptime only.
pub fn compile(comptime src: []const u8) Grammar {
    @setEvalBranchQuota(20_000_000);
    var lines: Lines = .{ .src = src };
    var name: []const u8 = "?";
    var lex: LexCfg = .{};
    var have_lexer = false;
    var preamble: []const []const u8 = &.{};
    var header: []const []const u8 = &.{};
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
    var signals: []const SignalForm = &.{};
    var functions: []const Spellings = &.{};
    var variables: []const Spellings = &.{};
    var operators: []const Spellings = &.{};
    var absent: []const Absent = &.{};
    var defs: []const Def = &.{};

    while (lines.next()) |line| {
        const head, const rest = splitHead(line);
        const fold = !lex.case_sensitive;
        if (std.mem.eql(u8, head, "dialect")) {
            name = rest;
        } else if (std.mem.eql(u8, head, "lexer")) {
            lex = parseLexer(name, &lines);
            have_lexer = true;
        } else if (!have_lexer) {
            fail(name, lines.no, "the lexer section must come before `" ++ head ++ "`");
        } else if (std.mem.eql(u8, head, "preamble")) {
            preamble = literalLines(name, &lines);
        } else if (std.mem.eql(u8, head, "header")) {
            header = literalLines(name, &lines);
        } else if (std.mem.eql(u8, head, "needs")) {
            const kind = kindOf(name, lines.no, rest);
            needs = needs ++ &[_]Needs{.{ .kind = kind, .lines = literalLines(name, &lines) }};
        } else if (std.mem.eql(u8, head, "wrap")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse fail(name, lines.no, "wrap is `wrap \"open\" \"close\" : kind ...`");
            const lits = args(name, lines.no, rest[0..colon]);
            if (lits.len != 2) fail(name, lines.no, "wrap needs an opening and a closing literal");
            var kinds: []const Kind = &.{};
            for (args(name, lines.no, rest[colon + 3 ..])) |k| kinds = kinds ++ &[_]Kind{kindOf(name, lines.no, k)};
            wraps = wraps ++ &[_]Wrap{.{
                .open = if (fold) lower(lits[0]) else lits[0],
                .close = if (fold) lower(lits[1]) else lits[1],
                .kinds = kinds,
            }};
        } else if (std.mem.eql(u8, head, "raw")) {
            const lits = args(name, lines.no, rest);
            if (lits.len != 2) fail(name, lines.no, "raw is `raw \"open\" \"close\"`");
            raws = raws ++ &[_]RawBlock{.{
                .open = if (fold) lower(lits[0]) else lits[0],
                .close = if (fold) lower(lits[1]) else lits[1],
            }};
        } else if (std.mem.eql(u8, head, "block")) {
            const kind = kindOf(name, lines.no, rest);
            var open: []const Node = &.{};
            var close: []const Node = &.{};
            var inner: []const []const Node = &.{};
            while (true) {
                const bl = lines.next() orelse fail(name, lines.no, "block is missing 'end'");
                if (std.mem.eql(u8, bl, "end")) break;
                const bh, const br = splitHead(bl);
                const pat = pattern(name, lines.no, kind, fold, br, defs);
                if (std.mem.eql(u8, bh, "open")) {
                    open = pat;
                } else if (std.mem.eql(u8, bh, "close")) {
                    close = pat;
                } else if (std.mem.eql(u8, bh, "inner")) {
                    inner = inner ++ &[_][]const Node{pat};
                } else fail(name, lines.no, "expected open, inner, close or end");
            }
            if (open.len == 0 or close.len == 0) fail(name, lines.no, "block needs both open and close");
            blocks = blocks ++ &[_]Block{.{ .kind = kind, .open = open, .inner = inner, .close = close }};
        } else if (std.mem.eql(u8, head, "rule") or std.mem.eql(u8, head, "read") or std.mem.eql(u8, head, "write")) {
            const eq = std.mem.indexOf(u8, rest, " = ") orelse fail(name, lines.no, "expected `" ++ head ++ " kind = pattern`");
            const kind = kindOf(name, lines.no, std.mem.trim(u8, rest[0..eq], " \t"));
            const dir: Dir = if (head[0] == 'r' and head[1] == 'u') .both else if (head[0] == 'r') .read else .write;
            rules = rules ++ &[_]Rule{.{
                .kind = kind,
                .dir = dir,
                .pat = pattern(name, lines.no, kind, fold, rest[eq + 3 ..], defs),
                .line = lines.no,
            }};
        } else if (std.mem.eql(u8, head, "define")) {
            const eq = std.mem.indexOf(u8, rest, " = ") orelse fail(name, lines.no, "expected `define name = pattern`");
            const dname = std.mem.trim(u8, rest[0..eq], " \t");
            for (defs) |d| if (std.mem.eql(u8, d.name, dname)) fail(name, lines.no, "`" ++ dname ++ "` is already defined");
            defs = defs ++ &[_]Def{.{ .name = dname, .text = rest[eq + 3 ..] }};
        } else if (std.mem.eql(u8, head, "caveat")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse fail(name, lines.no, "caveat is `caveat kind slot : text`");
            const ks = args(name, lines.no, rest[0..colon]);
            if (ks.len != 2) fail(name, lines.no, "caveat needs a kind and a slot");
            const kind = kindOf(name, lines.no, ks[0]);
            const slot = schema.slotIndex(kind, ks[1]) orelse fail(name, lines.no, "unknown slot '" ++ ks[1] ++ "'");
            caveats = caveats ++ &[_]Caveat{.{ .kind = kind, .slot = slot, .text = rest[colon + 3 ..] }};
        } else if (std.mem.eql(u8, head, "models")) {
            models = parseModels(name, &lines, fold);
        } else if (std.mem.eql(u8, head, "implied")) {
            const a = args(name, lines.no, rest);
            if (a.len != 4 or !std.mem.eql(u8, a[2], "=")) fail(name, lines.no, "implied is `implied kind slot = value`");
            const kind, const slot = kindSlot(name, lines.no, a[0], a[1]);
            implied = implied ++ &[_]Implied{.{ .kind = kind, .slot = slot, .text = a[3] }};
        } else if (std.mem.eql(u8, head, "enum")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse fail(name, lines.no, "enum is `enum kind slot : canonical=spelling ...`");
            const ks = args(name, lines.no, rest[0..colon]);
            if (ks.len != 2) fail(name, lines.no, "enum needs a kind and a slot");
            const kind, const slot = kindSlot(name, lines.no, ks[0], ks[1]);
            if (schema.info(kind).slots[slot].ty != .atom) fail(name, lines.no, "enum needs an atom slot");
            var pairs: []const EnumPair = &.{};
            for (args(name, lines.no, rest[colon + 3 ..])) |pair| {
                const pe = std.mem.indexOfScalar(u8, pair, '=') orelse fail(name, lines.no, "expected canonical=spelling in '" ++ pair ++ "'");
                pairs = pairs ++ &[_]EnumPair{.{ .canon = pair[0..pe], .spelling = if (fold) lower(pair[pe + 1 ..]) else pair[pe + 1 ..] }};
            }
            enums = enums ++ &[_]EnumMap{.{ .kind = kind, .slot = slot, .pairs = pairs }};
        } else if (std.mem.eql(u8, head, "move")) {
            const a = args(name, lines.no, rest);
            if (a.len != 3 or !std.mem.eql(u8, a[1], "->")) fail(name, lines.no, "move is `move kind.slot -> kind.slot`");
            const fk, const fs = dotted(name, lines.no, a[0]);
            const tk, const ts = dotted(name, lines.no, a[2]);
            moves = moves ++ &[_]Move{.{ .from = fk, .from_slot = fs, .to = tk, .to_slot = ts }};
        } else if (std.mem.eql(u8, head, "signals")) {
            signals = parseSignals(name, &lines, fold);
        } else if (std.mem.eql(u8, head, "functions")) {
            functions = parseSpellings(name, &lines, fold, "function", &schema.functions);
        } else if (std.mem.eql(u8, head, "variables")) {
            variables = parseSpellings(name, &lines, fold, "variable", &schema.variables);
        } else if (std.mem.eql(u8, head, "operators")) {
            operators = parseSpellings(name, &lines, false, "operator", &schema.operators);
        } else if (std.mem.eql(u8, head, "no")) {
            const colon = std.mem.indexOf(u8, rest, " : ") orelse fail(name, lines.no, "no is `no kind : reason`");
            absent = absent ++ &[_]Absent{.{ .kind = kindOf(name, lines.no, std.mem.trim(u8, rest[0..colon], " \t")), .reason = rest[colon + 3 ..] }};
        } else fail(name, lines.no, "unknown directive `" ++ head ++ "`");
    }
    if (std.mem.eql(u8, name, "?")) fail(name, 1, "missing `dialect <name>`");
    return .{
        .name = name,
        .lex = lex,
        .preamble = preamble,
        .header = header,
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
        .signals = signals,
        .functions = functions,
        .variables = variables,
        .operators = operators,
        .absent = absent,
    };
}

test "compile a small grammar at comptime" {
    const g = comptime compile(
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
    );
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
