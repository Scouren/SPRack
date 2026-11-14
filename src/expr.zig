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
const grammar = @import("grammar.zig");
const schema = @import("schema.zig");
const lexer = @import("lexer.zig");
const ir = @import("ir.zig");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;

pub const Problem = struct {
    kind: enum { function, variable, operator },
    text: []const u8,
};

/// Settles the spelling of a name the netlist itself defines.
pub const Resolver = struct {
    ctx: ?*const anyopaque = null,
    func: ?*const fn (ctx: ?*const anyopaque, arena: Allocator, word: []const u8, is_call: bool) Allocator.Error![]const u8 = null,

    fn resolve(r: Resolver, arena: Allocator, word: []const u8, is_call: bool) Allocator.Error![]const u8 {
        const f = r.func orelse return word;
        return f(r.ctx, arena, word, is_call);
    }
};

pub const canon_pow = "**";
pub const canon_xor = "^^";

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '$' or c == '#' or c == '!';
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
    while (i < src.len) {
        const c = src[i];
        const prev_word = i > 0 and isWordChar(src[i - 1]);
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
            var j = i;
            while (j < src.len and isWordChar(src[j])) j += 1;
            const word = src[i..j];
            const folded = if (cfg.case_sensitive) word else try lowered(arena, word);
            const is_call = nextIsCall(src, j);
            const known = if (is_call) canonOf(g.functions, folded) else canonOf(g.variables, folded);
            try out.appendSlice(arena, known orelse try names.resolve(arena, word, is_call));
            i = j;
            continue;
        }
        // Operators that differ between dialects; the longest spelling wins.
        var best: ?struct { canon: []const u8, len: usize } = null;
        for (g.operators) |op| {
            for (op.spellings) |s| {
                if (std.mem.startsWith(u8, src[i..], s) and (best == null or s.len > best.?.len)) best = .{ .canon = op.canon, .len = s.len };
            }
        }
        if (best) |b| {
            try out.appendSlice(arena, if (std.mem.eql(u8, b.canon, "pow")) canon_pow else canon_xor);
            i += b.len;
            continue;
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

/// Canonical spelling to dialect spelling. `foreign` is false when the
/// expression came from this same dialect; names its tables do not list
/// are then written back as they were read.
pub fn write(
    arena: Allocator,
    g: *const Grammar,
    text: []const u8,
    user_funcs: ?*const Funcs,
    foreign: bool,
    problems: *std.ArrayList(Problem),
) Allocator.Error![]const u8 {
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
            while (j < text.len and isWordChar(text[j])) j += 1;
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
        if ((std.ascii.isAlphabetic(c) or c == '_' or c == '$') and !prev_word) {
            var j = i;
            while (j < text.len and isWordChar(text[j])) j += 1;
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
                w.writeAll(s) catch return error.OutOfMemory;
            } else {
                try problems.append(arena, .{ .kind = .operator, .text = if (is_pow) "pow" else "xor" });
                w.writeAll(text[i .. i + 2]) catch return error.OutOfMemory;
            }
            i += 2;
            continue;
        }
        if (c == '^' and foreign) try problems.append(arena, .{ .kind = .operator, .text = "^" });
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

fn canonText(arena: Allocator, v: ir.Value) Allocator.Error![]const u8 {
    return switch (v) {
        .num => |n| if (n.exp10 == 0) n.digits() else try std.fmt.allocPrint(arena, "{s}e{d}", .{ n.digits(), n.exp10 }),
        .expr => |s| s,
        .atom => |s| s,
        else => "0",
    };
}

pub const Op = enum { add, sub, recip };

/// `a + b`, `a - b` or `1 / a`, exact when both are plain numbers (and, for
/// `1 / a`, when `a` is a power of ten); otherwise a canonical expression.
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
    } };
}

/// Half a value: exact for a decimal number, else an expression.
fn halve(arena: Allocator, v: ir.Value) Allocator.Error!ir.Value {
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
    for (stmts) |*st| {
        if (st.body.len > 0) {
            st.body = try arena.dupe(ir.Stmt, st.body);
            try convert(arena, g, st.body, forward);
        }
        var copied = false;
        for (0..g.converts.len) |n| {
            const cv = g.converts[if (forward) n else g.converts.len - 1 - n];
            if (cv.kind != st.kind) continue;
            if (cv.when_slot != grammar.no_slot) {
                const w = st.at(cv.when_slot);
                if (w != .atom or !std.mem.eql(u8, w.atom, cv.when_atom)) continue;
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
                // A missing operand counts as zero: nothing to do.
                .sub, .add => if (arg == .none) continue else try arith(arena, if ((cv.op == .sub) == forward) .sub else .add, v, arg),
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

/// Does a canonical expression call function `name`, or (for `pow`) use
/// the power operator?
pub fn uses(text: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, name, "pow") and std.mem.indexOf(u8, text, canon_pow) != null) return true;
    if (std.mem.eql(u8, name, "xor") and std.mem.indexOf(u8, text, canon_xor) != null) return true;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, name)) |at| : (i = at + 1) {
        const end = at + name.len;
        if ((at == 0 or !isWordChar(text[at - 1])) and (end == text.len or !isWordChar(text[end])) and nextIsCall(text, end)) return true;
    }
    return false;
}

/// Every function name an expression calls that is not a canonical one.
pub fn isPlainNumber(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == 'e' or c == '-')) return false;
    return std.ascii.isDigit(text[0]) or text[0] == '.' or text[0] == '-';
}

const testing = std.testing;

test "expressions between two small tables" {
    const spice = grammar.compileBuiltin(
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
    );
    const spectre = grammar.compileBuiltin(
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
    );
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
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
