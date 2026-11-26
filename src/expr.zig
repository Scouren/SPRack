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

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const lexer = @import("lexer");
const ir = @import("ir");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;

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
    func: ?*const fn (ctx: ?*const anyopaque, arena: Allocator, word: []const u8, space: ?schema.Space) Allocator.Error![]const u8 = null,

    fn resolve(r: Resolver, arena: Allocator, word: []const u8, space: ?schema.Space) Allocator.Error![]const u8 {
        const f = r.func orelse return word;
        return f(r.ctx, arena, word, space);
    }
};

/// What the names in the parentheses of a call to `word` are: the nodes of
/// a voltage probe (`v(a,b)`, `vdb(out)`, the forms a `signals` section
/// spells), the device of a current probe (`i(v1)`, `idb(v1)`) or of a
/// terminal current (`id(m1)`, `ig(m1)`), parameters in any other (#72).
pub fn argSpace(word: []const u8) schema.Space {
    var buf: [3]u8 = undefined;
    if (word.len == 0 or word.len > buf.len) return .param;
    const w = std.ascii.lowerString(&buf, word);
    for ([_][]const u8{ "v", "vdb", "vm", "vp", "vr", "vi" }) |f| if (std.mem.eql(u8, w, f)) return .node;
    for ([_][]const u8{ "i", "idb", "im", "ip", "ir", "ii" }) |f| if (std.mem.eql(u8, w, f)) return .instance;
    // A terminal current: `i` and the terminal's letter or number.
    if (w.len == 2 and w[0] == 'i' and std.mem.indexOfScalar(u8, "dgsbec1234", w[1]) != null) return .instance;
    return .param;
}

test "argSpace: probes name nodes and devices, other calls parameters" {
    try std.testing.expectEqual(.node, argSpace("VDB"));
    try std.testing.expectEqual(.instance, argSpace("id"));
    try std.testing.expectEqual(.instance, argSpace("I"));
    try std.testing.expectEqual(.param, argSpace("max"));
    try std.testing.expectEqual(.param, argSpace("vt"));
}

pub const canon_pow = "**";
pub const canon_xor = "^^";
pub const canon_ne = "!=";

/// Before a parameter whose name is a simulator variable's canonical name
/// in a dialect where that word is no variable (Spectre's `temper`,
/// LTspice's `hertz`): in canonical text it is the parameter, and the
/// plain word the variable.
pub const param_mark = '`';

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '$' or c == '#' or c == '!';
}

/// The end of a name from `j` on. A `!` may be part of a name, but not the
/// one of `!=`: `a!=b` is `a`, `!=`, `b`.
fn wordEnd(text: []const u8, from: usize) usize {
    var j = from;
    while (j < text.len and isWordChar(text[j]) and !std.mem.startsWith(u8, text[j..], canon_ne)) j += 1;
    return j;
}

/// An operator's spelling. A blank at either end of it is one the target
/// needs there (Spectre's ` != `), written unless the text has one already.
fn writeOp(aw: *std.Io.Writer.Allocating, spelling: []const u8, rest: []const u8) Allocator.Error!void {
    const done = aw.written();
    const lead = spelling[0] == ' ' and done.len > 0 and done[done.len - 1] != ' ';
    const trail = spelling[spelling.len - 1] == ' ' and rest.len > 0 and rest[0] != ' ';
    const op = std.mem.trim(u8, spelling, " ");
    aw.writer.print("{s}{s}{s}", .{ if (lead) " " else "", op, if (trail) " " else "" }) catch return error.OutOfMemory;
}

fn canonOf(list: []const grammar.Spellings, word: []const u8) ?[]const u8 {
    for (list) |e| {
        for (e.spellings) |s| if (std.mem.eql(u8, s, word)) return e.canon;
    }
    return null;
}

fn spellingOf(list: []const grammar.Spellings, canon: []const u8) ?[]const u8 {
    for (list) |e| if (std.mem.eql(u8, e.canon, canon)) return e.spellings[0];
    return null;
}

fn nextIsCall(text: []const u8, from: usize) bool {
    var k = from;
    while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
    return k < text.len and text[k] == '(';
}

/// The end of a numeric literal starting at `i`, including a scale suffix.
fn numberEnd(src: []const u8, i: usize) usize {
    var j = i;
    while (j < src.len and (std.ascii.isDigit(src[j]) or src[j] == '.')) j += 1;
    if (j < src.len and (src[j] == 'e' or src[j] == 'E')) {
        var k = j + 1;
        if (k < src.len and (src[k] == '+' or src[k] == '-')) k += 1;
        if (k < src.len and std.ascii.isDigit(src[k])) {
            while (k < src.len and std.ascii.isDigit(src[k])) k += 1;
            j = k;
        }
    }
    while (j < src.len and (std.ascii.isAlphabetic(src[j]) or src[j] == '_' or src[j] == '%')) j += 1;
    return j;
}

fn lowered(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    for (s) |c| if (std.ascii.isUpper(c)) return std.ascii.allocLowerString(arena, s);
    return s;
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
            const known = if (is_call) canonOf(g.functions, folded) else canonOf(g.variables, folded);
            // `@m1[gm]`: the device whose quantity is read.
            const at_device = i > 0 and src[i - 1] == '@';
            const name = known orelse try names.resolve(arena, word, if (is_call) null else if (at_device) .instance else space);
            // A parameter that a variable's canonical name would take for the variable.
            if (known == null and !is_call and space == .param and schema.isVariable(name)) try out.append(arena, param_mark);
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
                if (std.mem.startsWith(u8, src[i..], s) and (best == null or s.len > best.?.len)) best = .{ .canon = op.canon, .len = s.len };
            }
        }
        if (best) |b| {
            try out.appendSlice(arena, if (std.mem.eql(u8, b.canon, "pow")) canon_pow else if (std.mem.eql(u8, b.canon, "xor")) canon_xor else src[i .. i + b.len]);
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

fn canonNumber(text: []const u8) ?ir.Number {
    const e = std.mem.indexOfScalar(u8, text, 'e') orelse return .init(text, 0);
    const exp = std.fmt.parseInt(i32, text[e + 1 ..], 10) catch return null;
    return .init(text[0..e], exp);
}

pub const Funcs = std.StringHashMapUnmanaged(void);

pub const ChoiceForm = enum { ternary, call };

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
                if (if (cfg.case_sensitive) std.mem.eql(u8, sp, word) else std.ascii.eqlIgnoreCase(sp, word)) try problems.append(arena, .{ .kind = .shadowed, .text = word });
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
        if (std.mem.startsWith(u8, text[i..], canon_pow) or std.mem.startsWith(u8, text[i..], canon_xor)) {
            const is_pow = c == '*';
            if (spellingOf(g.operators, if (is_pow) "pow" else "xor")) |s| {
                try writeOp(&aw, s, text[i + 2 ..]);
            } else {
                try problems.append(arena, .{ .kind = .operator, .text = if (is_pow) "pow" else "xor" });
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
        if (c == '\\' and foreign and spellingOf(g.operators, "idiv") == null) try problems.append(arena, .{ .kind = .operator, .text = "idiv" });
        // A `%` glued to a number is the number's suffix (`30%`), not a modulo.
        if (foreign and ((c == '%' and !prev_word) or (c == '!' and !(i + 1 < text.len and text[i + 1] == '=')))) {
            const canon = if (c == '%') "mod" else "not";
            if (spellingOf(g.operators, canon) == null) try problems.append(arena, .{ .kind = .operator, .text = canon });
        }
        w.writeByte(c) catch return error.OutOfMemory;
        i += 1;
    }
    return aw.written();
}

/// A plain number as an integer times a power of ten, when it fits.
fn decimal(n: ir.Number) ?struct { i128, i32 } {
    var m: i128 = 0;
    var e = n.exp10;
    var neg = false;
    var point = false;
    for (n.digits(), 0..) |c, i| switch (c) {
        '-', '+' => {
            if (i != 0) return null;
            neg = c == '-';
        },
        '.' => {
            if (point) return null;
            point = true;
        },
        '0'...'9' => {
            m = std.math.add(i128, std.math.mul(i128, m, 10) catch return null, c - '0') catch return null;
            if (point) e -= 1;
        },
        else => return null,
    };
    return .{ if (neg) -m else m, e };
}

/// A number or an expression as canonical expression text.
pub fn canonText(arena: Allocator, v: ir.Value) Allocator.Error![]const u8 {
    return switch (v) {
        .num => |n| if (n.exp10 == 0) n.digits() else try std.fmt.allocPrint(arena, "{s}e{d}", .{ n.digits(), n.exp10 }),
        .expr => |s| s,
        .atom => |s| s,
        else => "0",
    };
}

pub const Op = enum { add, sub, recip, mul, div };

/// `a + b`, `a - b`, `a * b`, `a / b` or `1 / a`, exact when both are plain
/// numbers (for `1 / a`, when `a` is a power of ten; for `a / b`, when `b`
/// has no prime factor but 2 and 5); otherwise a canonical expression.
pub fn arith(arena: Allocator, op: Op, a: ir.Value, b: ir.Value) Allocator.Error!ir.Value {
    const da = if (a == .num) decimal(a.num) else null;
    const db = if (b == .num) decimal(b.num) else null;
    switch (op) {
        .recip => if (da) |x| {
            var m = if (x[0] < 0) -x[0] else x[0];
            var k: i32 = 0;
            while (m >= 10 and @rem(m, 10) == 0) : (k += 1) m = @divExact(m, 10);
            if (m == 1) return .{ .num = .init(if (x[0] < 0) "-1" else "1", -(x[1] + k)) };
        },
        .mul => if (da != null and db != null) exact: {
            var m = std.math.mul(i128, da.?[0], db.?[0]) catch break :exact;
            var ex = da.?[1] + db.?[1];
            while (m != 0 and @rem(m, 10) == 0) : (ex += 1) m = @divExact(m, 10);
            while (m != 0 and @mod(ex, 3) != 0) : (ex -= 1) m *= 10;
            return .{ .num = .init(try std.fmt.allocPrint(arena, "{d}", .{m}), ex) };
        },
        // Exact by a divisor with no prime factor but 2 and 5: a / 2 is
        // a * 5 / 10.
        .div => if (da != null and db != null) exact: {
            var d = db.?[0];
            var m = da.?[0];
            var ex = da.?[1] - db.?[1];
            if (d == 0) break :exact;
            if (d < 0) {
                d = -d;
                m = -m;
            }
            while (@rem(d, 10) == 0) : (ex -= 1) d = @divExact(d, 10);
            while (@rem(d, 2) == 0) : (ex -= 1) {
                d = @divExact(d, 2);
                m = std.math.mul(i128, m, 5) catch break :exact;
            }
            while (@rem(d, 5) == 0) : (ex -= 1) {
                d = @divExact(d, 5);
                m = std.math.mul(i128, m, 2) catch break :exact;
            }
            if (d != 1) break :exact;
            while (m != 0 and @rem(m, 10) == 0) : (ex += 1) m = @divExact(m, 10);
            while (m != 0 and @mod(ex, 3) != 0) : (ex -= 1) m *= 10;
            return .{ .num = .init(try std.fmt.allocPrint(arena, "{d}", .{m}), ex) };
        },
        .add, .sub => if (da != null and db != null) exact: {
            const e = @min(da.?[1], db.?[1]);
            const ma = std.math.mul(i128, da.?[0], std.math.powi(i128, 10, @as(i128, da.?[1] - e)) catch break :exact) catch break :exact;
            const mb = std.math.mul(i128, db.?[0], std.math.powi(i128, 10, @as(i128, db.?[1] - e)) catch break :exact) catch break :exact;
            var m = (if (op == .add) std.math.add(i128, ma, mb) else std.math.sub(i128, ma, mb)) catch break :exact;
            var ex = e;
            // Fewest digits, at an exponent a scale suffix can spell (900n, 1u).
            while (m != 0 and @rem(m, 10) == 0) : (ex += 1) m = @divExact(m, 10);
            while (m != 0 and @mod(ex, 3) != 0) : (ex -= 1) m *= 10;
            return .{ .num = .init(try std.fmt.allocPrint(arena, "{d}", .{m}), ex) };
        },
    }
    const ta = try canonText(arena, a);
    return .{ .expr = switch (op) {
        .recip => try std.fmt.allocPrint(arena, "1/({s})", .{ta}),
        .add => try std.fmt.allocPrint(arena, "{s} + ({s})", .{ ta, try canonText(arena, b) }),
        .sub => try std.fmt.allocPrint(arena, "{s} - ({s})", .{ ta, try canonText(arena, b) }),
        .mul => try std.fmt.allocPrint(arena, "({s}) * ({s})", .{ ta, try canonText(arena, b) }),
        .div => try std.fmt.allocPrint(arena, "({s}) / ({s})", .{ ta, try canonText(arena, b) }),
    } };
}

/// Half a value: exact for a decimal number, else an expression.
pub fn halve(arena: Allocator, v: ir.Value) Allocator.Error!ir.Value {
    if (v == .num) if (decimal(v.num)) |x| {
        const m = std.math.mul(i128, x[0], 5) catch return .{ .expr = try std.fmt.allocPrint(arena, "({s})/2", .{try canonText(arena, v)}) };
        return .{ .num = .init(try std.fmt.allocPrint(arena, "{d}", .{m}), x[1] - 1) };
    };
    return .{ .expr = try std.fmt.allocPrint(arena, "({s})/2", .{try canonText(arena, v)}) };
}

pub const Thresholds = struct { params: []const ir.Param, changed: bool = false, no_half: bool = false };

/// Apply a grammar's `threshold` line for `family` to a model card's
/// parameters. `forward` (writing) turns SPICE's midpoint and half-width into
/// on and off levels; otherwise (reading) the levels go back. `no_half` says
/// a midpoint came with no hysteresis, which gives equal levels.
pub fn thresholds(arena: Allocator, g: *const Grammar, family: []const u8, params: []const ir.Param, forward: bool) Allocator.Error!Thresholds {
    const th = for (g.thresholds) |*t| {
        if (std.mem.eql(u8, t.family, family)) break t;
    } else return .{ .params = params };
    const a_key, const b_key = if (forward) .{ th.mid, th.half } else .{ th.on, th.off };
    var a: ir.Value = .none;
    var b: ir.Value = .none;
    var rest: std.ArrayList(ir.Param) = .empty;
    var at: usize = 0; // the pair goes where the first of the two was
    for (params) |p| {
        if (std.ascii.eqlIgnoreCase(p.key, a_key) or std.ascii.eqlIgnoreCase(p.key, b_key)) {
            if (a == .none and b == .none) at = rest.items.len;
        }
        if (std.ascii.eqlIgnoreCase(p.key, a_key)) {
            a = p.val;
        } else if (std.ascii.eqlIgnoreCase(p.key, b_key)) {
            b = p.val;
        } else try rest.append(arena, p);
    }
    if (a == .none) return .{ .params = params };
    if (forward) {
        // on = mid + half, off = mid - half
        const no_half = b == .none or (b == .num and decimal(b.num) != null and decimal(b.num).?[0] == 0);
        const h: ir.Value = if (b == .none) .{ .num = .init("0", 0) } else b;
        try rest.insertSlice(arena, at, &.{
            .{ .key = th.on, .val = try arith(arena, .add, a, h) },
            .{ .key = th.off, .val = try arith(arena, .sub, a, h) },
        });
        return .{ .params = rest.items, .changed = true, .no_half = no_half };
    }
    // mid = (on + off) / 2, half = (on - off) / 2
    if (b == .none) return .{ .params = params };
    try rest.insertSlice(arena, at, &.{
        .{ .key = th.mid, .val = try halve(arena, try arith(arena, .add, a, b)) },
        .{ .key = th.half, .val = try halve(arena, try arith(arena, .sub, a, b)) },
    });
    return .{ .params = rest.items, .changed = true };
}

/// Apply a grammar's `convert` lines in place: `forward` turns canonical
/// values into the dialect's (writing), otherwise the dialect's into
/// canonical ones (reading, in reverse order). Values are copied before
/// they change; bodies are walked too.
pub fn convert(arena: Allocator, g: *const Grammar, stmts: []ir.Stmt, forward: bool) Allocator.Error!void {
    if (g.converts.len == 0) return;
    for (stmts) |*st| if (st.body.len > 0) {
        st.body = try arena.dupe(ir.Stmt, st.body);
        try convert(arena, g, st.body, forward);
    };
    try convertFlat(arena, g, stmts, forward);
}

/// `convert` on these statements, not on what their bodies hold: for a pass
/// that visits every body itself (the reader's), where `convert` at each
/// level would copy everything below it again.
pub fn convertFlat(arena: Allocator, g: *const Grammar, stmts: []ir.Stmt, forward: bool) Allocator.Error!void {
    if (g.converts.len == 0) return;
    for (stmts) |*st| {
        var copied = false;
        for (0..g.converts.len) |n| {
            const cv = g.converts[if (forward) n else g.converts.len - 1 - n];
            if (cv.kind != st.kind) continue;
            if (cv.when_slot != grammar.no_slot) {
                const w = st.at(cv.when_slot);
                if (w != .atom or !std.mem.eql(u8, w.atom, cv.when_atom)) continue;
            }
            if (cv.op == .wrap) {
                // Forward: a == b becomes l = [a]. Back: a one-item l with no a.
                const a = st.at(cv.src);
                const l = st.at(cv.dst);
                if (forward and (a == .none or !a.eql(st.at(cv.when_eq)))) continue;
                if (!forward and (a != .none or l != .list or l.list.len != 1)) continue;
                if (!copied) {
                    try st.own(arena);
                    copied = true;
                }
                if (forward) {
                    try st.set(arena, cv.dst, .{ .list = try arena.dupe(ir.Value, &.{a}) });
                    try st.set(arena, cv.src, .none);
                } else {
                    try st.set(arena, cv.src, l.list[0]);
                    try st.set(arena, cv.dst, .none);
                }
                continue;
            }
            const from = if (forward) cv.src else cv.dst;
            const to = if (forward) cv.dst else cv.src;
            const v = st.at(from);
            if (v == .none) continue;
            const arg: ir.Value = if (cv.arg_slot != grammar.no_slot)
                st.at(cv.arg_slot)
            else if (cv.arg_num.len > 0) .{ .num = .init(cv.arg_num, 0) } else .none;
            const out: ir.Value = switch (cv.op) {
                .copy => v,
                .recip => try arith(arena, .recip, v, .none),
                .wrap => unreachable,
                // A missing operand counts as zero: nothing to do.
                .sub, .add => if (arg == .none) continue else try arith(arena, if ((cv.op == .sub) == forward) .sub else .add, v, arg),
                .mul, .div => if (arg == .none) continue else try arith(arena, if ((cv.op == .mul) == forward) .mul else .div, v, arg),
            };
            if (!copied) {
                try st.own(arena);
                copied = true;
            }
            if (cv.op == .copy) try st.set(arena, from, .none);
            try st.set(arena, to, out);
        }
    }
}

/// Does a canonical expression call function `name`, or (for `pow`, `xor`,
/// `ternary`) use that operator? `negpow` is a minus right after another
/// operator, before a power (`1+-2**2`), where dialects disagree on which
/// binds first.
pub fn uses(text: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, name, "pow") and std.mem.indexOf(u8, text, canon_pow) != null) return true;
    if (std.mem.eql(u8, name, "xor") and std.mem.indexOf(u8, text, canon_xor) != null) return true;
    if (std.mem.eql(u8, name, "ternary")) return nested(text, '?');
    if (std.mem.eql(u8, name, "mod")) return nested(text, '%');
    if (std.mem.eql(u8, name, "negpow")) return negPow(text);
    if (std.mem.eql(u8, name, "minuspow")) return minusPow(text);
    if (std.mem.eql(u8, name, "andor")) return std.mem.indexOf(u8, text, "&&") != null or std.mem.indexOf(u8, text, "||") != null;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, name)) |at| : (i = at + 1) {
        const end = at + name.len;
        if ((at == 0 or !isWordChar(text[at - 1])) and (end == text.len or !isWordChar(text[end])) and nextIsCall(text, end)) return true;
    }
    return false;
}

fn nested(text: []const u8, c: u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '"' or text[i] == '\'') {
            i = std.mem.indexOfScalarPos(u8, text, i + 1, text[i]) orelse return false;
            continue;
        }
        if (text[i] == c) return true;
    }
    return false;
}

/// The index of the first `c` in `text[from..]` outside parentheses and
/// quotes, or null.
fn topLevel(text: []const u8, from: usize, c: u8) ?usize {
    var depth: usize = 0;
    var i = from;
    while (i < text.len) : (i += 1) {
        if (depth == 0 and text[i] == c) return i;
        switch (text[i]) {
            '"', '\'' => i = std.mem.indexOfScalarPos(u8, text, i + 1, text[i]) orelse return null,
            '(', '[' => depth += 1,
            ')', ']' => depth -|= 1,
            else => {},
        }
    }
    return null;
}

/// The `:` that closes the `?` at `q`: nested choices pair inside it.
fn colonOf(text: []const u8, q: usize) ?usize {
    var open: usize = 0;
    var i = q + 1;
    while (topLevelAny(text, i)) |at| : (i = at + 1) {
        if (text[at] == '?') {
            open += 1;
        } else if (open == 0) return at else open -= 1;
    }
    return null;
}

fn topLevelAny(text: []const u8, from: usize) ?usize {
    const a = topLevel(text, from, '?');
    const b = topLevel(text, from, ':');
    if (a == null) return b;
    if (b == null) return a;
    return @min(a.?, b.?);
}

/// `c ? a : b` as `if(c, a, b)`, in every group and argument.
pub fn ternaryToIf(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (topLevel(text, 0, ',')) |comma| {
        return std.fmt.allocPrint(arena, "{s},{s}", .{ try ternaryToIf(arena, text[0..comma]), try ternaryToIf(arena, text[comma + 1 ..]) });
    }
    if (topLevel(text, 0, '?')) |q| if (colonOf(text, q)) |colon| {
        const t = " \t";
        return std.fmt.allocPrint(arena, "if({s}, {s}, {s})", .{
            std.mem.trim(u8, try ternaryToIf(arena, text[0..q]), t),
            std.mem.trim(u8, try ternaryToIf(arena, text[q + 1 .. colon]), t),
            std.mem.trim(u8, try ternaryToIf(arena, text[colon + 1 ..]), t),
        });
    };
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"' or c == '\'') {
            const end = (std.mem.indexOfScalarPos(u8, text, i + 1, c) orelse text.len - 1) + 1;
            try out.appendSlice(arena, text[i..end]);
            i = end;
        } else if (c == '(') {
            const close = matching(text, i) orelse text.len;
            try out.append(arena, '(');
            try out.appendSlice(arena, try ternaryToIf(arena, text[i + 1 .. close]));
            if (close < text.len) try out.append(arena, ')');
            i = close + 1;
        } else {
            try out.append(arena, c);
            i += 1;
        }
    }
    return out.items;
}

/// `text` with each word `renames` names written as its new name, where the
/// word is a parameter: not the name of a call, and not a node or a branch
/// inside a probe (`v()`, `i()`, `vdb()`, `id()`: `argSpace`). `hit` gets each word renamed. The same slice when
/// there is none.
pub fn rename(arena: Allocator, text: []const u8, renames: anytype, hit: *std.ArrayList([]const u8)) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var copied: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"' or c == '\'') {
            i = (std.mem.indexOfScalarPos(u8, text, i + 1, c) orelse text.len - 1) + 1;
            continue;
        }
        // A marked parameter (`param_mark`): renamed as itself, the mark
        // dropped, since the new name is no variable's.
        const marked = c == param_mark;
        if (marked) {
            const j = wordEnd(text, i + 1);
            const word = text[i + 1 .. j];
            const at = i;
            i = j;
            const to = renames.get(word) orelse continue;
            try out.appendSlice(arena, text[copied..at]);
            try out.appendSlice(arena, to);
            try hit.append(arena, word);
            copied = j;
            continue;
        }
        if (!(std.ascii.isAlphabetic(c) or c == '_' or c == '$') or (i > 0 and isWordChar(text[i - 1]))) {
            i += 1;
            continue;
        }
        const j = wordEnd(text, i);
        const word = text[i..j];
        i = j;
        // A variable's own word is the variable, never a parameter.
        if (schema.isVariable(word)) continue;
        if (nextIsCall(text, j)) {
            if (argSpace(word) != .param) {
                const open = std.mem.indexOfScalarPos(u8, text, j, '(').?;
                i = (matching(text, open) orelse text.len - 1) + 1;
            }
            continue;
        }
        const to = renames.get(word) orelse continue;
        try out.appendSlice(arena, text[copied .. j - word.len]);
        try out.appendSlice(arena, to);
        try hit.append(arena, word);
        copied = j;
    }
    if (copied == 0) return text;
    try out.appendSlice(arena, text[copied..]);
    return out.items;
}

fn matching(text: []const u8, open: usize) ?usize {
    const close = topLevel(text, open + 1, ')') orelse return null;
    return close;
}

/// A name, a number or one call: nothing an operator around it could split.
fn atomic(text: []const u8) bool {
    if (text.len == 0) return false;
    if (wordEnd(text, 0) == text.len) return true;
    const j = wordEnd(text, 0);
    if (j == 0 or j >= text.len or text[j] != '(') return false;
    return matching(text, j) == text.len - 1;
}

/// Every call of `m.canon` in `text` as `m.body`, each argument put in
/// parentheses where the body names it; `n` counts the calls rewritten.
pub fn applyMeans(arena: Allocator, text: []const u8, m: anytype, n: *usize) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"' or c == '\'') {
            const end = (std.mem.indexOfScalarPos(u8, text, i + 1, c) orelse text.len - 1) + 1;
            try out.appendSlice(arena, text[i..end]);
            i = end;
            continue;
        }
        const starts = (std.ascii.isAlphabetic(c) or c == '_') and (i == 0 or !isWordChar(text[i - 1]));
        if (!starts) {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        const j = wordEnd(text, i);
        const word = text[i..j];
        if (!std.mem.eql(u8, word, m.canon) or !nextIsCall(text, j)) {
            try out.appendSlice(arena, word);
            i = j;
            continue;
        }
        const open = std.mem.indexOfScalarPos(u8, text, j, '(').?;
        const close = matching(text, open) orelse {
            try out.appendSlice(arena, text[i..]);
            break;
        };
        // The arguments, themselves rewritten.
        var args: std.ArrayList([]const u8) = .empty;
        var from = open + 1;
        while (true) {
            const comma = topLevel(text[0..close], from, ',');
            const end = comma orelse close;
            try args.append(arena, try applyMeans(arena, std.mem.trim(u8, text[from..end], " \t"), m, n));
            if (comma == null) break;
            from = end + 1;
        }
        if (args.items.len != m.args.len) {
            try out.appendSlice(arena, text[i .. close + 1]);
            i = close + 1;
            continue;
        }
        // The body, its parameters replaced; in parentheses unless it is one call.
        const wrap = !atomic(m.body);
        if (wrap) try out.append(arena, '(');
        var k: usize = 0;
        const body = m.body;
        while (k < body.len) {
            const bc = body[k];
            if ((std.ascii.isAlphabetic(bc) or bc == '_') and (k == 0 or !isWordChar(body[k - 1]))) {
                const e = wordEnd(body, k);
                const w = body[k..e];
                const at = for (m.args, 0..) |p, pi| {
                    if (std.mem.eql(u8, p, w)) break pi;
                } else null;
                if (at) |pi| {
                    const arg = args.items[pi];
                    // A whole argument of a call in the body needs no parentheses.
                    const before = std.mem.trimEnd(u8, body[0..k], " \t");
                    const after = std.mem.trimStart(u8, body[e..], " \t");
                    const whole = before.len > 0 and (before[before.len - 1] == '(' or before[before.len - 1] == ',') and after.len > 0 and (after[0] == ')' or after[0] == ',');
                    if (whole or atomic(arg)) try out.appendSlice(arena, arg) else try out.print(arena, "({s})", .{arg});
                } else try out.appendSlice(arena, w);
                k = e;
                continue;
            }
            try out.append(arena, bc);
            k += 1;
        }
        if (wrap) try out.append(arena, ')');
        n.* += 1;
        i = close + 1;
    }
    return out.items;
}

/// `if(c, a, b)` as `(c ? a : b)`.
pub fn ifToTernary(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"' or c == '\'') {
            const end = (std.mem.indexOfScalarPos(u8, text, i + 1, c) orelse text.len - 1) + 1;
            try out.appendSlice(arena, text[i..end]);
            i = end;
            continue;
        }
        const word = std.mem.startsWith(u8, text[i..], "if") and (i == 0 or !isWordChar(text[i - 1])) and
            (i + 2 == text.len or !isWordChar(text[i + 2])) and nextIsCall(text, i + 2);
        if (!word) {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        const open = std.mem.indexOfScalarPos(u8, text, i + 2, '(').?;
        const close = matching(text, open) orelse {
            try out.appendSlice(arena, text[i..]);
            break;
        };
        const inner = text[open + 1 .. close];
        const c1 = topLevel(inner, 0, ',');
        const c2 = if (c1) |x| topLevel(inner, x + 1, ',') else null;
        if (c1 == null or c2 == null or topLevel(inner, c2.? + 1, ',') != null) {
            try out.appendSlice(arena, text[i .. open + 1]);
            try out.appendSlice(arena, try ifToTernary(arena, inner));
            try out.append(arena, ')');
        } else {
            const t = " \t";
            const parts = [3][]const u8{ inner[0..c1.?], inner[c1.? + 1 .. c2.?], inner[c2.? + 1 ..] };
            try out.append(arena, '(');
            for (parts, 0..) |part, k| {
                const conv = std.mem.trim(u8, try ifToTernary(arena, part), t);
                // A choice inside a choice keeps its own parentheses.
                const wrap = topLevel(conv, 0, '?') != null;
                if (k == 1) try out.appendSlice(arena, " ? ");
                if (k == 2) try out.appendSlice(arena, " : ");
                if (wrap) try out.append(arena, '(');
                try out.appendSlice(arena, conv);
                if (wrap) try out.append(arena, ')');
            }
            try out.append(arena, ')');
        }
        i = close + 1;
    }
    return out.items;
}

/// A unary minus right after another operator, in an operand of `**`.
fn negPow(text: []const u8) bool {
    if (std.mem.indexOf(u8, text, canon_pow) == null) return false;
    var prev: u8 = 0;
    var prev2: u8 = 0;
    for (text) |c| {
        if (c == ' ' or c == '\t') continue;
        if (c == '-' and prev != 0 and std.mem.indexOfScalar(u8, "+-*/^?:<>=!&|%", prev) != null) {
            // After `**` it is the exponent's sign: `2**-1`.
            if (!(prev == '*' and prev2 == '*')) return true;
        }
        prev2 = prev;
        prev = c;
    }
    return false;
}

/// A unary minus whose operand is the base of a power: `-2**2`, `(-x**2)`,
/// `1+-f(x)**2`, `-(a+b)**2`. Not `2**-1`, where it is the exponent's sign.
fn minusPow(text: []const u8) bool {
    var prev: u8 = 0;
    var prev2: u8 = 0;
    for (text, 0..) |c, at| {
        if (c == ' ' or c == '\t') continue;
        defer {
            prev2 = prev;
            prev = c;
        }
        if (c != '-' or (prev == '*' and prev2 == '*')) continue;
        if (prev != 0 and std.mem.indexOfScalar(u8, "(,+-*/^?:<>=!&|%", prev) == null) continue;
        // One operand: a group, or a word or number with the call after it.
        var i = at + 1;
        while (i < text.len and text[i] == ' ') i += 1;
        while (i < text.len and (isWordChar(text[i]) or text[i] == '.')) i += 1;
        if (i < text.len and text[i] == '(') i = (topLevel(text, i + 1, ')') orelse return false) + 1;
        while (i < text.len and text[i] == ' ') i += 1;
        if (std.mem.startsWith(u8, text[i..], canon_pow)) return true;
    }
    return false;
}

/// Every function name an expression calls that is not a canonical one.
pub fn isPlainNumber(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == 'e' or c == '-')) return false;
    return std.ascii.isDigit(text[0]) or text[0] == '.' or text[0] == '-';
}

/// The value of a condition over parameters whose values are known: no
/// more than that needs (`eval`).
const Eval = struct {
    text: []const u8,
    at: usize = 0,
    params: []const ir.Param,
    stop: *[]const u8,
    depth: u8,

    /// Loosest first; of two spellings that start alike, the longer first.
    const levels = [_][]const []const u8{
        &.{"||"}, &.{"&&"}, &.{ "==", canon_ne }, &.{ "<=", ">=", "<", ">" }, &.{ "+", "-" }, &.{ "*", "/" },
    };

    fn fail(e: *Eval, what: []const u8) ?f64 {
        if (e.stop.len == 0) e.stop.* = what;
        return null;
    }

    fn op(e: *Eval, spelling: []const u8) bool {
        while (e.at < e.text.len and (e.text[e.at] == ' ' or e.text[e.at] == '\t')) e.at += 1;
        if (!std.mem.startsWith(u8, e.text[e.at..], spelling)) return false;
        e.at += spelling.len;
        return true;
    }

    fn binary(e: *Eval, level: usize) ?f64 {
        if (level == levels.len) return e.unary();
        var a = e.binary(level + 1) orelse return null;
        next: while (true) {
            for (levels[level]) |o| {
                if (!e.op(o)) continue;
                const b = e.binary(level + 1) orelse return null;
                if (o[0] == '/' and b == 0) return e.fail(o);
                a = switch (o[0]) {
                    '+' => a + b,
                    '-' => a - b,
                    '*' => a * b,
                    '/' => a / b,
                    else => if (switch (o[0]) {
                        '|' => a != 0 or b != 0,
                        '&' => a != 0 and b != 0,
                        '=' => a == b,
                        '!' => a != b,
                        '<' => if (o.len == 2) a <= b else a < b,
                        else => if (o.len == 2) a >= b else a > b,
                    }) 1 else 0,
                };
                continue :next;
            }
            return a;
        }
    }

    fn unary(e: *Eval) ?f64 {
        if (e.op("-")) return -(e.unary() orelse return null);
        if (e.op("!")) return if ((e.unary() orelse return null) == 0) 1 else 0;
        if (e.op("(")) {
            const v = e.binary(0) orelse return null;
            return if (e.op(")")) v else e.fail(")");
        }
        const from = e.at;
        if (from == e.text.len) return e.fail("its end");
        if (std.ascii.isDigit(e.text[from]) or e.text[from] == '.') {
            e.at = numberEnd(e.text, from);
            return std.fmt.parseFloat(f64, e.text[from..e.at]) catch e.fail(e.text[from..e.at]);
        }
        e.at = wordEnd(e.text, from);
        const word = e.text[from..e.at];
        if (word.len == 0 or nextIsCall(e.text, e.at)) return e.fail(if (word.len == 0) e.text[from .. from + 1] else word);
        for (e.params) |p| {
            if (!std.ascii.eqlIgnoreCase(p.key, word)) continue;
            return switch (p.val) {
                .num => |n| n.toFloat(),
                // Bounded, so a parameter that is its own value ends.
                .expr, .atom => |t| if (e.depth < 16) eval(t, e.params, e.stop, e.depth + 1) orelse e.fail(word) else e.fail(word),
                else => e.fail(word),
            };
        }
        return e.fail(word);
    }
};

/// The number that canonical expression text comes to when it holds only
/// numbers, `+ - * /`, comparisons, `&& || !`, parentheses and names that
/// `params` binds to numbers or to such expressions (the first of a name
/// counts, in any case of letters); a truth is 1 or 0. Null for anything
/// else, and `stop` is what it stopped at: a name bound to no number, a
/// function, another operator, a division by zero.
pub fn eval(text: []const u8, params: []const ir.Param, stop: *[]const u8, depth: u8) ?f64 {
    var e: Eval = .{ .text = text, .params = params, .stop = stop, .depth = depth };
    const v = e.binary(0) orelse return null;
    return if (e.op("") and e.at == text.len) v else e.fail(text[e.at .. e.at + 1]);
}

const testing = std.testing;

test "a condition over known parameters" {
    const ps: []const ir.Param = &.{
        .{ .key = "xd", .val = .{ .num = .init("0.7", 0) } },
        .{ .key = "scaling", .val = .{ .num = .init("1", -6) } },
        .{ .key = "xds", .val = .{ .expr = "xd/scaling" } },
        .{ .key = "loop", .val = .{ .expr = "loop+1" } },
        .{ .key = "ic", .val = .none },
    };
    var stop: []const u8 = "";
    try testing.expectEqual(1, eval("xds<0.8e6 && !(XD == 0) || 1 > 2", ps, &stop, 0));
    try testing.expectEqual(0, eval("(xds >= 1e6)", ps, &stop, 0));
    try testing.expectEqual(-5, eval("-(1+2*3) + 4/2", ps, &stop, 0));
    try testing.expectEqual(1, eval("1e-3 != .001 || 2 <= 2", ps, &stop, 0));
    inline for (.{
        .{ "floor(xd) == 0", "floor" }, .{ "xd > vdd", "vdd" },   .{ "ic>1e9", "ic" },   .{ "xd ? 1 : 2", "?" },
        .{ "xd**2 > 1", "*" },          .{ "loop == 1", "loop" }, .{ "1/(xd-xd)", "/" }, .{ "(xd", ")" },
        .{ "xd >", "its end" },
    }) |c| {
        stop = "";
        try testing.expectEqual(null, eval(c[0], ps, &stop, 0));
        try testing.expectEqualStrings(c[1], stop);
    }
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
    try testing.expectEqualStrings("2m * log(x)**2 + temp", try write(a, &spectre, canon, null, true, &problems));
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

test "a choice is written in the form the target has" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("if(x > 1, 3, 4)", try ternaryToIf(a, "x > 1 ? 3 : 4"));
    try testing.expectEqualStrings("if(0, 1, if(1, 5, 6))", try ternaryToIf(a, "0 ? 1 : 1 ? 5 : 6"));
    try testing.expectEqualStrings("2 + (if(x > 1, 3, 4))", try ternaryToIf(a, "2 + (x > 1 ? 3 : 4)"));
    try testing.expectEqualStrings("max(if(a, b, c),d)", try ternaryToIf(a, "max(a ? b : c,d)"));
    try testing.expectEqualStrings("(x > 1 ? 3 : 4)", try ifToTernary(a, "if(x > 1, 3, 4)"));
    try testing.expectEqualStrings("2*(a ? (b ? 1 : 2) : 3)", try ifToTernary(a, "2*if(a, if(b,1,2), 3)"));
    try testing.expectEqualStrings("diff(x)", try ifToTernary(a, "diff(x)"));
    try testing.expect(uses("1+-2**2", "negpow") and uses("2*-x**2", "negpow"));
    try testing.expect(!uses("-2**2", "negpow") and !uses("2**-1", "negpow") and !uses("max(-2**2,0)", "negpow") and !uses("1-2", "negpow"));
    try testing.expect(uses("-2**2", "minuspow") and uses("max(-x**2,0)", "minuspow") and uses("1+-f(x, 2)**2", "minuspow") and uses("- (a+b) ** 2", "minuspow"));
    try testing.expect(!uses("2**-1", "minuspow") and !uses("-a*b**2", "minuspow") and !uses("a-b**2", "minuspow") and !uses("-(a**2)", "minuspow"));
    try testing.expect(uses("a>1 && b>1", "andor") and uses("a||b", "andor") and !uses("a & b | c", "andor"));
}

test "convert arithmetic is exact where it can be" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = try arith(a, .sub, .{ .num = .init("1", -6) }, .{ .num = .init("100", -9) });
    try testing.expectEqualStrings("900", d.num.digits());
    try testing.expectEqual(-9, d.num.exp10);
    const r = try arith(a, .recip, .{ .num = .init("1", 6) }, .none);
    try testing.expectEqual(-6, r.num.exp10);
    // 1/3 is not a decimal: it stays an expression.
    try testing.expectEqualStrings("1/(3)", (try arith(a, .recip, .{ .num = .init("3", 0) }, .none)).expr);
    try testing.expectEqualStrings("w - (1e-9)", (try arith(a, .sub, .{ .expr = "w" }, .{ .num = .init("1", -9) })).expr);
}
