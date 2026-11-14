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

/// Every function name an expression calls that is not a canonical one.
pub fn isPlainNumber(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == 'e' or c == '-')) return false;
    return std.ascii.isDigit(text[0]) or text[0] == '.' or text[0] == '-';
}

const testing = std.testing;

test "expressions between two small tables" {
    const spice = comptime grammar.compile(
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
    const spectre = comptime grammar.compile(
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
