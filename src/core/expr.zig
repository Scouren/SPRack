//! Expressions, translated token by token.
//!
//! An expression is stored in the IR in one canonical spelling: numbers as
//! `1.5e-12`, functions and simulator variables under the names listed in
//! `schema.zig`, power as `**`, exclusive-or as `^^`. Everything else — the
//! author's spacing, parentheses and operand order — is left exactly as
//! written, so nothing is re-associated and no precedence has to be guessed.
//!
//! `read` maps a dialect's spelling onto the canonical one and `write` maps
//! it back, both driven by the `functions`, `variables` and `operators`
//! sections of the grammar.
//!
//! Contents:
//! - `pub const isPlainNumber`
//! - `pub const eval`
//! - `pub const rename`
//! - `pub const applyMeans`
//! - `pub const uses`
//! - `pub const ternaryToIf`
//! - `pub const ifToTernary`
//! - `pub const canonText`
//! - `pub const Op`
//! - `pub const arith`
//! - `pub const halve`
//! - `pub const Thresholds`
//! - `pub const thresholds`
//! - `pub const convert`
//! - `pub const convertFlat`
//! - `pub const Problem = struct`
//! - `pub const Resolver = struct`
//! - `pub const canon_pow`
//! - `pub const canon_xor`
//! - `pub const canon_ne`
//! - `pub const param_mark`
//! - `pub const Funcs`
//! - `pub const ChoiceForm = enum`
//! - `pub fn argSpace(word: []const u8) schema.Space`
//! - `pub fn read(arena: Allocator, g: *const Grammar, text: []const u8, names: Resolver,
//!   problems: *std.ArrayList(Problem)) Allocator.Error![]const u8`
//! - `pub fn choiceForm(g: *const Grammar) ?ChoiceForm`
//! - `pub fn write(arena: Allocator, g: *const Grammar, text_in: []const u8,
//!   user_funcs: ?*const Funcs, foreign: bool,
//!   problems: *std.ArrayList(Problem)) Allocator.Error![]const u8`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const lexer = @import("lexer");
const ir = @import("ir");
const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const expr_scan = @import("expr_scan.zig");
const isWordChar = expr_scan.isWordChar;
const wordEnd = expr_scan.wordEnd;
const canonOf = expr_scan.canonOf;
const spellingOf = expr_scan.spellingOf;
const nextIsCall = expr_scan.nextIsCall;
const numberEnd = expr_scan.numberEnd;
const lowered = expr_scan.lowered;
const expr_eval = @import("expr_eval.zig");
const expr_rename = @import("expr_rename.zig");
const expr_forms = @import("expr_forms.zig");
const expr_arith = @import("expr_arith.zig");
const testing = std.testing;

pub const isPlainNumber = expr_eval.isPlainNumber;
pub const eval = expr_eval.eval;
pub const rename = expr_rename.rename;
pub const applyMeans = expr_rename.applyMeans;
pub const uses = expr_forms.uses;
pub const ternaryToIf = expr_forms.ternaryToIf;
pub const ifToTernary = expr_forms.ifToTernary;
pub const canonText = expr_arith.canonText;
pub const Op = expr_arith.Op;
pub const arith = expr_arith.arith;
pub const halve = expr_arith.halve;
pub const Thresholds = expr_arith.Thresholds;
pub const thresholds = expr_arith.thresholds;
pub const convert = expr_arith.convert;
pub const convertFlat = expr_arith.convertFlat;

pub const Problem = struct {
    /// `form`: not a problem but a note, the expression was restructured
    /// for the target (`?:` as `if()`), so it reads back in another shape.
    /// `shadowed`: a parameter whose name the target takes for a variable.
    kind: enum { function, variable, operator, form, shadowed },
    text: []const u8,
};

/// Settles the spelling of a name the netlist itself defines: a call
/// (`space` null), or a name of `space`.
pub const Resolver = struct {
    ctx: ?*const anyopaque = null,
    func: ?*const fn (
        ctx: ?*const anyopaque,
        arena: Allocator,
        word: []const u8,
        space: ?schema.Space,
    ) Allocator.Error![]const u8 = null,

    fn resolve(
        r: Resolver,
        arena: Allocator,
        word: []const u8,
        space: ?schema.Space,
    ) Allocator.Error![]const u8 {
        const f = r.func orelse return word;
        return f(r.ctx, arena, word, space);
    }
};

pub const canon_pow = "**";

pub const canon_xor = "^^";

pub const canon_ne = "!=";

/// Before a parameter whose name is a simulator variable's canonical name
/// in a dialect where that word is no variable (Spectre's `temper`,
/// LTspice's `hertz`): in canonical text it is the parameter, and the
/// plain word the variable.
pub const param_mark = '`';

pub const Funcs = std.StringHashMapUnmanaged(void);

pub const ChoiceForm = enum { ternary, call };

/// What the names in the parentheses of a call to `word` are: the nodes of
/// a voltage probe (`v(a,b)`, `vdb(out)`, the forms a `signals` section
/// spells), the device of a current probe (`i(v1)`, `idb(v1)`) or of a
/// terminal current (`id(m1)`, `ig(m1)`), parameters in any other (#72).
pub fn argSpace(word: []const u8) schema.Space {
    var buf: [3]u8 = undefined;
    if (word.len == 0 or word.len > buf.len) return .param;
    const w = std.ascii.lowerString(&buf, word);
    for ([_][]const u8{ "v", "vdb", "vm", "vp", "vr", "vi" }) |f|
        if (std.mem.eql(u8, w, f)) return .node;
    for ([_][]const u8{ "i", "idb", "im", "ip", "ir", "ii" }) |f|
        if (std.mem.eql(u8, w, f)) return .instance;
    // A terminal current: `i` and the terminal's letter or number.
    if (w.len == 2 and w[0] == 'i' and std.mem.indexOfScalar(u8, "dgsbec1234", w[1]) != null)
        return .instance;
    return .param;
}

/// Dialect spelling to canonical spelling.
pub fn read(
    arena: Allocator,
    g: *const Grammar,
    text: []const u8,
    names: Resolver,
    problems: *std.ArrayList(Problem),
) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const src = std.mem.trim(u8, text, " \t");
    const cfg = &g.lex;
    var i: usize = 0;
    // What a name is here: a parameter, or what `v(` or `i(` names.
    var space: schema.Space = .param;
    while (i < src.len) {
        const c = src[i];
        const prev_word = i > 0 and isWordChar(src[i - 1]);
        if (c == ')') space = .param;
        if (c == '"' or c == '\'') {
            const end = std.mem.indexOfScalarPos(u8, src, i + 1, c) orelse src.len - 1;
            try out.appendSlice(arena, src[i .. end + 1]);
            i = end + 1;
            continue;
        }
        const starts_num = std.ascii.isDigit(c) or (c == '.' and i + 1 < src.len and std.ascii.isDigit(src[i + 1]));
        if (starts_num and !prev_word) {
            const j = numberEnd(src, i);
            const word = if (cfg.case_sensitive) src[i..j] else try lowered(arena, src[i..j]);
            if (lexer.parseNumber(arena, cfg, word)) |n| {
                try out.appendSlice(arena, n.digits());
                if (n.exp10 != 0) try out.print(arena, "e{d}", .{n.exp10});
            } else try out.appendSlice(arena, src[i..j]);
            i = j;
            continue;
        }
        if ((std.ascii.isAlphabetic(c) or c == '_' or c == '$') and !prev_word) {
            const j = wordEnd(src, i);
            const word = src[i..j];
            const folded = if (cfg.case_sensitive) word else try lowered(arena, word);
            const is_call = nextIsCall(src, j);
            const known = if (is_call)
                canonOf(g.functions, folded)
            else
                canonOf(g.variables, folded);
            // `@m1[gm]`: the device whose quantity is read.
            const at_device = i > 0 and src[i - 1] == '@';
            const name = known orelse try names.resolve(arena, word, if (is_call)
                null
            else if (at_device) .instance else space);
            // A parameter that a variable's canonical name would take for the variable.
            if (known == null and !is_call and space == .param and schema.isVariable(name))
                try out.append(arena, param_mark);
            try out.appendSlice(arena, name);
            if (is_call) space = argSpace(word);
            i = j;
            continue;
        }
        // Operators that differ between dialects; the longest spelling wins.
        var best: ?struct { canon: []const u8, len: usize } = null;
        for (g.operators) |op| {
            for (op.spellings) |spelled| {
                const s = std.mem.trim(u8, spelled, " ");
                if (std.mem.startsWith(u8, src[i..], s) and (best == null or s.len > best.?.len))
                    best = .{ .canon = op.canon, .len = s.len };
            }
        }
        if (best) |b| {
            try out.appendSlice(arena, if (std.mem.eql(u8, b.canon, "pow"))
                canon_pow
            else if (std.mem.eql(u8, b.canon, "xor")) canon_xor else src[i .. i + b.len]);
            i += b.len;
            continue;
        }
        // Unary not and modulo, where this dialect lists neither (the
        // listed spellings were taken above).
        if (c == '%' or (c == '!' and !(i + 1 < src.len and src[i + 1] == '='))) {
            try problems.append(arena, .{ .kind = .operator, .text = src[i .. i + 1] });
        }
        if (c == '^' or std.mem.startsWith(u8, src[i..], "**")) {
            const n: usize = if (c == '^') 1 else 2;
            try problems.append(arena, .{ .kind = .operator, .text = src[i .. i + n] });
            try out.appendSlice(arena, src[i .. i + n]);
            i += n;
            continue;
        }
        try out.append(arena, c);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// How the dialect says a choice inside an expression, `c ? a : b` or
/// `if(c, a, b)`, when it has either.
pub fn choiceForm(g: *const Grammar) ?ChoiceForm {
    if (spellingOf(g.operators, "ternary") != null) return .ternary;
    return if (spellingOf(g.functions, "if") != null) .call else null;
}

/// Canonical spelling to dialect spelling. `foreign` is false when the
/// expression came from this same dialect; names its tables do not list
/// are then written back as they were read.
///
/// The one restructuring: a choice is written `c ? a : b` or `if(c, a, b)`,
/// whichever the target has (`operators ternary "?"`, `functions if`).
pub fn write(
    arena: Allocator,
    g: *const Grammar,
    text_in: []const u8,
    user_funcs: ?*const Funcs,
    foreign: bool,
    problems: *std.ArrayList(Problem),
) Allocator.Error![]const u8 {
    var text = text_in;
    const has_ternary = spellingOf(g.operators, "ternary") != null;
    const has_if = spellingOf(g.functions, "if") != null;
    if (foreign and !has_ternary and has_if and uses(text, "ternary")) {
        text = try ternaryToIf(arena, text);
        try problems.append(arena, .{ .kind = .form, .text = "if" });
    } else if (foreign and has_ternary and !has_if and uses(text, "if")) {
        text = try ifToTernary(arena, text);
        try problems.append(arena, .{ .kind = .form, .text = "ternary" });
    } else if (foreign and !has_ternary and uses(text, "ternary")) {
        try problems.append(arena, .{ .kind = .operator, .text = "ternary" });
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    const cfg = &g.lex;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        const prev_word = i > 0 and isWordChar(text[i - 1]);
        if (c == '"' or c == '\'') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, c) orelse text.len - 1;
            w.writeAll(text[i .. end + 1]) catch return error.OutOfMemory;
            i = end + 1;
            continue;
        }
        const starts_num = std.ascii.isDigit(c) or (c == '.' and i + 1 < text.len and std.ascii.isDigit(text[i + 1]));
        if (starts_num and !prev_word) {
            var j = i;
            while (j < text.len and (std.ascii.isDigit(text[j]) or text[j] == '.')) j += 1;
            if (j < text.len and text[j] == 'e') {
                var k = j + 1;
                if (k < text.len and text[k] == '-') k += 1;
                if (k < text.len and std.ascii.isDigit(text[k])) {
                    while (k < text.len and std.ascii.isDigit(text[k])) k += 1;
                    j = k;
                }
            }
            j = wordEnd(text, j);
            // A scale suffix only where it is exact: inside an expression
            // the digits stay as written, so it reads back the same.
            const exact = if (canonNumber(text[i..j])) |n| blk: {
                if (n.exp10 == 0) break :blk false;
                for (cfg.scales) |sc| {
                    if (sc.exp10 != n.exp10) continue;
                    w.writeAll(n.digits()) catch return error.OutOfMemory;
                    w.writeAll(sc.suffix) catch return error.OutOfMemory;
                    break :blk true;
                }
                break :blk false;
            } else false;
            if (!exact) w.writeAll(text[i..j]) catch return error.OutOfMemory;
            i = j;
            continue;
        }
        if (c == param_mark and i + 1 < text.len) {
            // The parameter, under its own name; where the target spells a
            // variable so, the word is the variable there.
            const j = wordEnd(text, i + 1);
            const word = text[i + 1 .. j];
            for (g.variables) |v| for (v.spellings) |sp| {
                if (if (cfg.case_sensitive) std.mem.eql(
                    u8,
                    sp,
                    word,
                ) else std.ascii.eqlIgnoreCase(sp, word)) try problems.append(
                    arena,
                    .{ .kind = .shadowed, .text = word },
                );
            };
            w.writeAll(word) catch return error.OutOfMemory;
            i = j;
            continue;
        }
        if ((std.ascii.isAlphabetic(c) or c == '_' or c == '$') and !prev_word) {
            const j = wordEnd(text, i);
            const word = text[i..j];
            i = j;
            if (nextIsCall(text, j)) {
                if (schema.isFunction(word)) {
                    if (spellingOf(g.functions, word)) |s| {
                        w.writeAll(s) catch return error.OutOfMemory;
                        continue;
                    }
                    try problems.append(arena, .{ .kind = .function, .text = word });
                } else if (foreign) {
                    const key = try lowered(arena, word);
                    const defined = if (user_funcs) |uf| uf.contains(key) else false;
                    if (!defined) try problems.append(arena, .{ .kind = .function, .text = word });
                }
            } else if (schema.isVariable(word)) {
                if (spellingOf(g.variables, word)) |s| {
                    w.writeAll(s) catch return error.OutOfMemory;
                    continue;
                }
                try problems.append(arena, .{ .kind = .variable, .text = word });
            }
            w.writeAll(word) catch return error.OutOfMemory;
            continue;
        }
        if (std.mem.startsWith(
            u8,
            text[i..],
            canon_pow,
        ) or std.mem.startsWith(u8, text[i..], canon_xor)) {
            const is_pow = c == '*';
            if (spellingOf(g.operators, if (is_pow) "pow" else "xor")) |s| {
                try writeOp(&aw, s, text[i + 2 ..]);
            } else {
                try problems.append(arena, .{ .kind = .operator, .text = if (is_pow)
                    "pow"
                else
                    "xor" });
                w.writeAll(text[i .. i + 2]) catch return error.OutOfMemory;
            }
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], canon_ne)) {
            try writeOp(&aw, spellingOf(g.operators, "ne") orelse canon_ne, text[i + 2 ..]);
            i += 2;
            continue;
        }
        if (c == '^' and foreign) try problems.append(arena, .{ .kind = .operator, .text = "^" });
        // ngspice's integer division.
        if (c == '\\' and foreign and spellingOf(g.operators, "idiv") == null)
            try problems.append(arena, .{ .kind = .operator, .text = "idiv" });
        // A `%` glued to a number is the number's suffix (`30%`), not a modulo.
        if (foreign and ((c == '%' and !prev_word) or (c == '!' and !(i + 1 < text.len and text[i + 1] == '=')))) {
            const canon = if (c == '%') "mod" else "not";
            if (spellingOf(g.operators, canon) == null)
                try problems.append(arena, .{ .kind = .operator, .text = canon });
        }
        w.writeByte(c) catch return error.OutOfMemory;
        i += 1;
    }
    return aw.written();
}

// ---- private ----

/// An operator's spelling. A blank at either end of it is one the target
/// needs there (Spectre's ` != `), written unless the text has one already.
fn writeOp(
    aw: *std.Io.Writer.Allocating,
    spelling: []const u8,
    rest: []const u8,
) Allocator.Error!void {
    const done = aw.written();
    const lead = spelling[0] == ' ' and done.len > 0 and done[done.len - 1] != ' ';
    const trail = spelling[spelling.len - 1] == ' ' and rest.len > 0 and rest[0] != ' ';
    const op = std.mem.trim(u8, spelling, " ");
    aw.writer.print("{s}{s}{s}", .{ if (lead)
        " "
    else
        "", op, if (trail) " " else "" }) catch return error.OutOfMemory;
}

fn canonNumber(text: []const u8) ?ir.Number {
    const e = std.mem.indexOfScalar(u8, text, 'e') orelse return .init(text, 0);
    const exp = std.fmt.parseInt(i32, text[e + 1 ..], 10) catch return null;
    return .init(text[0..e], exp);
}

test "argSpace: probes name nodes and devices, other calls parameters" {
    try std.testing.expectEqual(.node, argSpace("VDB"));
    try std.testing.expectEqual(.instance, argSpace("id"));
    try std.testing.expectEqual(.instance, argSpace("I"));
    try std.testing.expectEqual(.param, argSpace("max"));
    try std.testing.expectEqual(.param, argSpace("vt"));
}

test "expressions between two small tables" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: grammar.Diag = .{};
    const spice = try grammar.compile(a,
        \\dialect a
        \\lexer
        \\  case insensitive
        \\  scale meg=6 k=3 m=-3 u=-6
        \\end
        \\functions
        \\  same sqrt exp abs
        \\  ln = log ln
        \\end
        \\operators
        \\  pow "**" "^"
        \\end
        \\variables
        \\  temper = temper
        \\end
    , "", &diag);
    const spectre = try grammar.compile(a,
        \\dialect b
        \\lexer
        \\  case sensitive
        \\  scale M=6 k=3 m=-3 u=-6
        \\end
        \\functions
        \\  same sqrt exp
        \\  ln = log
        \\end
        \\operators
        \\  pow "**"
        \\  xor "^"
        \\end
        \\variables
        \\  temper = temp
        \\end
    , "", &diag);
    var problems: std.ArrayList(Problem) = .empty;

    const canon = try read(a, &spice, "2M * LOG(x)^2 + Temper", .{}, &problems);
    try testing.expectEqualStrings("2e-3 * ln(x)**2 + temper", canon);
    try testing.expectEqualStrings(
        "2m * log(x)**2 + temp",
        try write(a, &spectre, canon, null, true, &problems),
    );
    try testing.expectEqual(0, problems.items.len);

    // `^` is exclusive-or in the second dialect, and the first has none.
    const x = try read(a, &spectre, "a ^ b", .{}, &problems);
    try testing.expectEqualStrings("a ^^ b", x);
    _ = try write(a, &spice, x, null, true, &problems);
    try testing.expectEqual(1, problems.items.len);
    try testing.expectEqualStrings("xor", problems.items[0].text);

    // A function the target does not list, and one nobody defines.
    problems.clearRetainingCapacity();
    _ = try write(a, &spectre, "abs(x) + mystery(y)", null, true, &problems);
    try testing.expectEqual(2, problems.items.len);
}

test {
    _ = expr_arith;
    _ = expr_eval;
    _ = expr_forms;
    _ = expr_rename;
    _ = expr_scan;
}
