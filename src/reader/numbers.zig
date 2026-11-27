//! Numbers: a literal with its dialect's scale factors read exactly, and a
//! number spelled back with the shortest suffix that is exact.
//!
//! Contents:
//! - `pub fn shiftDecimal(arena: Allocator, digits: []const u8,
//!   exp10: i32) Allocator.Error!?[]const u8`
//! - `pub fn parseNumber(arena: Allocator, cfg: *const LexCfg, text: []const u8) ?ir.Number`
//! - `pub fn renderNumber(w: *std.Io.Writer, cfg: *const LexCfg,
//!   n: ir.Number) std.Io.Writer.Error!void`

const std = @import("std");
const grammar = @import("grammar");
const ir = @import("ir");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const LexCfg = grammar.LexCfg;

/// Move the decimal point instead of writing an exponent, when that stays short.
pub fn shiftDecimal(arena: Allocator, digits: []const u8, exp10: i32) Allocator.Error!?[]const u8 {
    if (exp10 == 0) return digits;
    if (exp10 > 6 or exp10 < -6) return null;
    const neg = digits.len > 0 and digits[0] == '-';
    const body = if (neg) digits[1..] else digits;
    const point = std.mem.indexOfScalar(u8, body, '.') orelse body.len;
    var all: std.ArrayList(u8) = .empty;
    for (body) |c| if (c != '.') try all.append(arena, c);
    var pos: i64 = @as(i64, @intCast(point)) + exp10;
    while (pos <= 0) : (pos += 1) try all.insert(arena, 0, '0');
    while (pos > all.items.len) try all.append(arena, '0');
    const p: usize = @intCast(pos);
    assert(p <= all.items.len);
    var out: std.ArrayList(u8) = .empty;
    if (neg) try out.append(arena, '-');
    try out.appendSlice(arena, all.items[0..p]);
    if (p < all.items.len) {
        try out.append(arena, '.');
        try out.appendSlice(arena, all.items[p..]);
    }
    var res: []const u8 = out.items;
    if (std.mem.indexOfScalar(u8, res, '.') != null) {
        res = std.mem.trimEnd(u8, res, "0");
        res = std.mem.trimEnd(u8, res, ".");
    }
    if (res.len > 12) return null;
    return res;
}

/// Parse a numeric literal under this dialect's scale-factor rules.
/// `text` must already be case-folded for case-insensitive dialects.
pub fn parseNumber(arena: Allocator, cfg: *const LexCfg, text: []const u8) ?ir.Number {
    var i: usize = 0;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
    const int_start = i;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    var digits_seen = i - int_start;
    if (i < text.len and text[i] == '.') {
        i += 1;
        const frac = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        digits_seen += i - frac;
    }
    if (digits_seen == 0) return null;
    var mant = text[0..i];
    if (mant[mant.len - 1] == '.') mant = mant[0 .. mant.len - 1];
    if (mant.len > 0 and mant[0] == '+') mant = mant[1..];
    // At least one digit, which neither a sign nor a point is.
    assert(mant.len > 0);

    var exp: i32 = 0;
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        var j = i + 1;
        if (j < text.len and (text[j] == '+' or text[j] == '-')) j += 1;
        const d0 = j;
        while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
        if (j > d0) {
            exp = std.fmt.parseInt(i32, text[i + 1 .. j], 10) catch return null;
            i = j;
        }
    }
    const rest = text[i..];
    if (rest.len == 0) return .init(mant, exp);

    // Longest suffix wins, so `meg` beats `m`.
    var best_len: usize = 0;
    var best_exp: i32 = 0;
    var best_odd: ?grammar.OddScale = null;
    for (cfg.scales) |s| {
        if (s.suffix.len > best_len and std.mem.startsWith(u8, rest, s.suffix)) {
            best_len = s.suffix.len;
            best_exp = s.exp10;
            best_odd = null;
        }
    }
    for (cfg.read_scales) |s| {
        if (s.suffix.len > best_len and std.mem.startsWith(u8, rest, s.suffix)) {
            best_len = s.suffix.len;
            best_exp = s.exp10;
            best_odd = null;
        }
    }
    for (cfg.odd_scales) |s| {
        if (s.suffix.len > best_len and std.mem.startsWith(u8, rest, s.suffix)) {
            best_len = s.suffix.len;
            best_odd = s;
        }
    }
    const units = rest[best_len..];
    // A unit is letters, ASCII or not: `15kΩ` is 15k where letters after
    // the scale are ignored (ngspice 45 solves it as 15k).
    for (units) |c| if (!std.ascii.isAlphabetic(c) and c < 0x80) return null;
    if (best_len == 0 and !cfg.units_ignored) return null;
    if (best_odd) |odd| {
        const digits = mulDecimal(arena, mant, odd.mant) catch return null;
        return .init(digits, exp + odd.exp10);
    }
    return .init(mant, exp + best_exp);
}

/// Spell a number in this dialect: a scale suffix where one fits exactly,
/// plain exponent notation otherwise. No arithmetic, so nothing is rounded.
pub fn renderNumber(w: *std.Io.Writer, cfg: *const LexCfg, n: ir.Number) std.Io.Writer.Error!void {
    if (n.exp10 == 0) return w.writeAll(n.digits());
    assert(n.exp10 != 0);
    for (cfg.scales) |s| {
        if (s.exp10 == n.exp10) {
            try w.writeAll(n.digits());
            return w.writeAll(s.suffix);
        }
    }
    // No suffix for exactly this power. Moving the decimal point is exact, so
    // try the neighbouring suffixes and plain notation, and keep the shortest.
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const a = fba.allocator();
    var best: []const u8 = std.fmt.allocPrint(
        a,
        "{s}e{d}",
        .{ n.digits(), n.exp10 },
    ) catch return w.print("{s}e{d}", .{ n.digits(), n.exp10 });
    if (shiftDecimal(a, n.digits(), n.exp10) catch null) |plain| {
        if (plain.len <= best.len) best = plain;
    }
    for (cfg.scales) |s| {
        // Only towards a larger suffix (254e-7 is 25.4u): padding with
        // zeros to reach a smaller one would turn 1e-14 into 10f.
        const delta = n.exp10 - s.exp10;
        if (delta < -3 or delta >= 0) continue;
        const shifted = (shiftDecimal(a, n.digits(), delta) catch null) orelse continue;
        if (shifted.len + s.suffix.len < best.len) {
            best = std.fmt.allocPrint(a, "{s}{s}", .{ shifted, s.suffix }) catch continue;
        }
    }
    try w.writeAll(best);
}

// ---- private ----

// ------------------------------------------------------------------ numbers

/// Multiply a decimal literal by an integer, digit by digit. No floating
/// point is involved, so `1mil` is exactly 25.4e-6.
fn mulDecimal(arena: Allocator, mant: []const u8, k: u64) Allocator.Error![]const u8 {
    const neg = mant.len > 0 and mant[0] == '-';
    const body = if (neg) mant[1..] else mant;
    var digits: std.ArrayList(u8) = .empty;
    var frac: usize = 0;
    var seen_point = false;
    for (body) |c| {
        if (c == '.') {
            seen_point = true;
        } else {
            try digits.append(arena, c - '0');
            if (seen_point) frac += 1;
        }
    }
    var out: std.ArrayList(u8) = .empty; // least significant digit first
    var carry: u64 = 0;
    var i = digits.items.len;
    while (i > 0) {
        i -= 1;
        const v = digits.items[i] * k + carry;
        try out.append(arena, @intCast(v % 10));
        carry = v / 10;
    }
    while (carry > 0) : (carry /= 10) try out.append(arena, @intCast(carry % 10));
    while (out.items.len <= frac) try out.append(arena, 0);
    // A digit before the point, however many there are after it.
    assert(out.items.len > frac);
    var text: std.ArrayList(u8) = .empty;
    if (neg) try text.append(arena, '-');
    var j = out.items.len;
    while (j > 0) {
        j -= 1;
        try text.append(arena, '0' + out.items[j]);
        if (j == frac and frac > 0) try text.append(arena, '.');
    }
    var res: []const u8 = text.items;
    if (frac > 0) {
        res = std.mem.trimEnd(u8, res, "0");
        res = std.mem.trimEnd(u8, res, ".");
    }
    return res;
}
