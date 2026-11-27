//! Values: what one token (or the few of a recorded signal) is as the
//! value of a slot of a given type, for the matcher.
//!
//! Contents:
//! - `pub const Sig = struct`
//! - `pub fn own(self: *const Matcher, t: Tok) Allocator.Error![]const u8`
//! - `pub fn spelled(self: *const Matcher, t: Tok) Allocator.Error![]const u8`
//! - `pub fn number(self: *const Matcher, t: Tok) ?ir.Number`
//! - `pub fn toValue(self: *const Matcher, ty: schema.SlotType, t: Tok) Allocator.Error!?Value`
//! - `pub fn signalAt(self: *const Matcher, ti: usize) Allocator.Error!?Sig`
//! - `pub fn quotedExpr(self: *const Matcher, t: Tok, key: []const u8) Allocator.Error!?Value`
//! - `pub fn anyValue(self: *const Matcher, t: Tok, key: []const u8) Allocator.Error!?Value`
//! - `pub fn vector(self: *const Matcher, text: []const u8) Allocator.Error![]const Value`
//! - `pub fn pairs(self: *Matcher, into: u8, vt: Tok) Allocator.Error!bool`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const expr = @import("expr");
const matcher = @import("matcher.zig");
const signals = @import("signals.zig");
const Matcher = matcher.Matcher;
const signalCanon = signals.signalCanon;
const isVersion = signals.isVersion;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Tok = lexer.Tok;
const Value = ir.Value;

pub const Sig = struct { v: Value, n: usize };

/// A word's folded text lives only as long as its line's tokens.
pub fn own(self: *const Matcher, t: Tok) Allocator.Error![]const u8 {
    return if (t.tag == .word and t.text.ptr != t.raw.ptr)
        self.arena.dupe(u8, t.text)
    else
        t.text;
}

/// A name as the source spells it, without the marks that escape its
/// characters (`B\[0\]` is `B[0]`, `names` with `escape each`).
pub fn spelled(self: *const Matcher, t: Tok) Allocator.Error![]const u8 {
    const esc = self.g.lex.escape;
    if (esc.len == 0 or std.mem.indexOf(u8, t.raw, esc) == null) return t.raw;
    return lexer.unescaped(self.arena, esc, t.raw);
}

/// A number keeps its digits from the source spelling, not from the
/// folded copy, which goes away with the line.
pub fn number(self: *const Matcher, t: Tok) ?ir.Number {
    var n = lexer.parseNumber(self.arena, &self.g.lex, t.text) orelse return null;
    const off = @intFromPtr(n.ptr) -% @intFromPtr(t.text.ptr);
    if (t.text.ptr != t.raw.ptr and off < t.text.len) n.ptr = t.raw.ptr + off;
    return n;
}

pub fn toValue(self: *const Matcher, ty: schema.SlotType, t: Tok) Allocator.Error!?Value {
    // The lexer marks only a word as the key of a `key=value`.
    assert(!t.f.key or t.tag == .word);
    if (t.f.key and !self.allow_key) return null;
    const cfg = &self.g.lex;
    switch (ty) {
        // HSPICE `.meas dc "ia" ...` is the measurement ia: a label.
        .name => return if ((t.tag == .word or (t.tag == .str and cfg.dquote_expr)) and
            lexer.isNameLike(t.text))
            .{
                .atom = if (t.tag == .str) t.text else try self.spelled(t),
            }
        else
            null,
        // A word ending in a colon is a keyword (`params:`), never a node.
        .node => return if (t.tag == .word and lexer.isNameLike(t.text) and !std.mem.endsWith(
            u8,
            t.text,
            ":",
        )) .{ .atom = try self.spelled(t) } else null,
        .ident, .ref => {
            if (t.tag != .word or !lexer.isNameLike(t.text) or std.mem.endsWith(
                u8,
                t.text,
                ":",
            )) return null;
            // A model or subcircuit name starts like a name, not like an operator.
            if (!(std.ascii.isAlphanumeric(t.text[0]) or t.text[0] == '_')) return null;
            if (lexer.parseNumber(self.arena, cfg, t.text) != null) return null;
            return .{ .atom = try self.spelled(t) };
        },
        .atom => return if (t.tag == .word or t.tag == .str)
            .{ .atom = try self.own(t) }
        else
            null,
        .value => switch (t.tag) {
            .word => {
                if (self.number(t)) |n| return .{ .num = n };
                // A bare identifier is a value only where the dialect allows it,
                // and never when it names a model or subcircuit.
                // After `=` a bare name is a parameter reference where
                // the dialect reads undelimited expressions there.
                if (!(cfg.ident_values or cfg.bare_expr or (cfg.bare_after_eq and t.f.val)))
                    return null;
                if (!lexer.isIdent(t.text) or self.declared.contains(t.text)) return null;
                return .{ .expr = t.raw };
            },
            .expr => return .{ .expr = t.text },
            .str => return (try self.quotedExpr(t, "")) orelse .{ .str = t.text },
            else => return null,
        },
        .path => return switch (t.tag) {
            .str => .{ .str = t.text },
            .word => .{ .str = t.raw },
            // `.include 'file'` where quotes are also expression delimiters.
            .expr => .{ .str = t.text },
            else => null,
        },
        .text, .params, .signal => return null,
    }
}

/// One recorded signal starting at `ti`: `v(out)`, `v(a,b)`, `out`, `v1:p`.
pub fn signalAt(self: *const Matcher, ti: usize) Allocator.Error!?Sig {
    assert(ti < self.toks().len);
    const t = self.toks()[ti];
    if (t.f.key) return null;
    if (t.tag == .expr) return .{ .v = .{ .expr = t.text }, .n = 1 };
    if (t.tag != .word) return null;
    // `par('-i(vc)')`: the dialect's way of recording an expression.
    if (t.f.call and self.toks()[ti + 1].tag == .expr and self.g.lex.parens_are_space) {
        for (self.g.signals) |sf| {
            if (!std.mem.eql(u8, sf.form, "expr")) continue;
            if (sf.template.len > t.text.len and std.mem.startsWith(
                u8,
                sf.template,
                t.text,
            ) and sf.template[t.text.len] == '(') {
                return .{ .v = .{ .expr = self.toks()[ti + 1].text }, .n = 2 };
            }
        }
    }
    // `-i(vc)`: a signal negated is an expression.
    const neg = t.raw.len > 1 and t.raw[0] == '-';
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(self.arena, if (neg) t.raw[1..] else t.raw);
    var n: usize = 1;
    if (t.f.call) {
        // Calls may nest (`db(i(vm))`); at most three names per call.
        const tokens = !self.g.lex.parens_are_space;
        var j = ti + 1;
        if (tokens) {
            if (self.toks()[j].tag != .lparen) return null;
            j += 1;
        }
        try text.append(self.arena, '(');
        var depth: usize = 1;
        var count: usize = 0;
        while (depth > 0) : (j += 1) {
            // The window ends before the call closes: no signal.
            if (j + 1 >= self.toks().len) return null;
            const a = self.toks()[j];
            if (tokens and a.tag == .rparen) {
                try text.append(self.arena, ')');
                depth -= 1;
                continue;
            }
            // `v(a)=0.5`: the `=` after the call marks its last name a key.
            const closes = if (tokens) self.toks()[j + 1].tag == .rparen else a.closes > 0;
            if (a.tag != .word or (a.f.key and !closes) or count == 3 or j - ti > 12)
                return null;
            if (count > 0) try text.append(self.arena, ',');
            try text.appendSlice(self.arena, a.raw);
            count += 1;
            if (a.f.call) {
                if (tokens) {
                    if (self.toks()[j + 1].tag != .lparen) return null;
                    j += 1;
                }
                try text.append(self.arena, '(');
                depth += 1;
                count = 0;
            }
            if (!tokens) for (0..a.closes) |_| {
                if (depth == 0) break;
                try text.append(self.arena, ')');
                depth -= 1;
            };
        }
        n = j - ti;
    }
    const canon = (try signalCanon(self.arena, self.g, text.items)) orelse return null;
    if (neg)
        return .{
            .v = .{ .expr = try std.mem.concat(self.arena, u8, &.{ "-", canon }) },
            .n = n,
        };
    return .{ .v = .{ .atom = canon }, .n = n };
}

/// A double-quoted value read as the expression it is where the dialect
/// says so (`quotes '"' expr-in-values`: HSPICE `.param t2="a^3"` is 8
/// with a=2). Null keeps it a string: a key the grammar names as a
/// file name (`rlgcfile=`), an empty pair of quotes.
pub fn quotedExpr(self: *const Matcher, t: Tok, key: []const u8) Allocator.Error!?Value {
    const cfg = &self.g.lex;
    if (!cfg.dquote_expr) return null;
    for (cfg.dquote_strings) |k| if (std.ascii.eqlIgnoreCase(k, key)) return null;
    const text = std.mem.trim(u8, t.text, " \t");
    if (text.len == 0) return null;
    const folded = if (cfg.case_sensitive)
        text
    else
        try std.ascii.allocLowerString(self.arena, text);
    if (lexer.parseNumber(self.arena, cfg, folded)) |n| return .{ .num = n };
    return .{ .expr = text };
}

/// Value of an open-ended `key=value` parameter: take whatever is there.
pub fn anyValue(self: *const Matcher, t: Tok, key: []const u8) Allocator.Error!?Value {
    switch (t.tag) {
        .word => {
            if (self.number(t)) |n| return .{ .num = n };
            if (lexer.isIdent(t.text)) return .{ .expr = t.raw };
            // Neither a number, a name nor a delimited expression in this
            // dialect (`w={w}` in HSPICE, where braces mean nothing).
            // Keep the exact spelling rather than guess.
            return .{ .atom = t.raw };
        },
        // `version=3.3.0` read as an undelimited expression is a word, not arithmetic.
        .expr => return if (isVersion(t.text)) .{ .atom = t.text } else .{ .expr = t.text },
        // An unknown option keeps a string; a declared one is typed.
        .str => return (if (self.kind == .options)
            null
        else
            try self.quotedExpr(t, key)) orelse .{ .str = t.text },
        .vec => return .{ .list = try self.vector(t.text) },
        else => return null,
    }
}

pub fn vector(self: *const Matcher, text: []const u8) Allocator.Error![]const Value {
    var out: std.ArrayList(Value) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t,");
    while (it.next()) |w| {
        const cfg = &self.g.lex;
        const folded = if (cfg.case_sensitive)
            w
        else
            try std.ascii.allocLowerString(self.arena, w);
        if (lexer.parseNumber(self.arena, cfg, folded)) |n| {
            try out.append(self.arena, .{ .num = n });
        } else try out.append(self.arena, .{ .expr = w });
    }
    return out.toOwnedSlice(self.arena);
}

/// `{"out",0.5,"a","b",1}`: quoted names, each run of them ended by a
/// value; two names are a difference, kept as the key `a,b`.
pub fn pairs(self: *Matcher, into: u8, vt: Tok) Allocator.Error!bool {
    const t = vt.text;
    if (t.len < 2 or t[0] != '{' or t[t.len - 1] != '}') return false;
    const start = self.log.items.len;
    var names: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, t[1 .. t.len - 1], ", ");
    while (it.next()) |w| {
        if (w.len >= 2 and w[0] == '"' and w[w.len - 1] == '"') {
            if (names.items.len > 0) try names.append(self.arena, ',');
            try names.appendSlice(self.arena, w[1 .. w.len - 1]);
            continue;
        }
        if (names.items.len == 0) break;
        const v: Value = if (lexer.parseNumber(self.arena, &self.g.lex, w)) |n|
            .{ .num = n }
        else
            .{ .expr = w };
        try self.log.append(
            self.arena,
            .{ .slot = into, .key = try names.toOwnedSlice(self.arena), .val = v },
        );
    } else if (names.items.len == 0 and self.log.items.len > start) return true;
    self.log.shrinkRetainingCapacity(start);
    // Refused, the log is as it was.
    assert(self.log.items.len == start);
    return false;
}
