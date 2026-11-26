//! Scanning expression text: where a name or a number ends, whether a call
//! follows, a character outside parentheses and quotes, and a word's entry
//! in a grammar's spelling lists.
//!
//! Contents:
//! - `pub fn isWordChar(c: u8) bool`
//! - `pub fn wordEnd(text: []const u8, from: usize) usize`
//! - `pub fn canonOf(list: []const grammar.Spellings, word: []const u8) ?[]const u8`
//! - `pub fn spellingOf(list: []const grammar.Spellings, canon: []const u8) ?[]const u8`
//! - `pub fn nextIsCall(text: []const u8, from: usize) bool`
//! - `pub fn numberEnd(src: []const u8, i: usize) usize`
//! - `pub fn lowered(arena: Allocator, s: []const u8) Allocator.Error![]const u8`
//! - `pub fn topLevel(text: []const u8, from: usize, c: u8) ?usize`
//! - `pub fn matching(text: []const u8, open: usize) ?usize`

const std = @import("std");
const grammar = @import("grammar");
const expr = @import("expr.zig");
const Allocator = std.mem.Allocator;
const canon_ne = expr.canon_ne;

pub fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '$' or c == '#' or c == '!';
}

/// The end of a name from `j` on. A `!` may be part of a name, but not the
/// one of `!=`: `a!=b` is `a`, `!=`, `b`.
pub fn wordEnd(text: []const u8, from: usize) usize {
    var j = from;
    while (j < text.len and isWordChar(text[j]) and !std.mem.startsWith(u8, text[j..], canon_ne))
        j += 1;
    return j;
}

pub fn canonOf(list: []const grammar.Spellings, word: []const u8) ?[]const u8 {
    for (list) |e| {
        for (e.spellings) |s| if (std.mem.eql(u8, s, word)) return e.canon;
    }
    return null;
}

pub fn spellingOf(list: []const grammar.Spellings, canon: []const u8) ?[]const u8 {
    for (list) |e| if (std.mem.eql(u8, e.canon, canon)) return e.spellings[0];
    return null;
}

pub fn nextIsCall(text: []const u8, from: usize) bool {
    var k = from;
    while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
    return k < text.len and text[k] == '(';
}

/// The end of a numeric literal starting at `i`, including a scale suffix.
pub fn numberEnd(src: []const u8, i: usize) usize {
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
    while (j < src.len and (std.ascii.isAlphabetic(src[j]) or src[j] == '_' or src[j] == '%'))
        j += 1;
    return j;
}

pub fn lowered(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    for (s) |c| if (std.ascii.isUpper(c)) return std.ascii.allocLowerString(arena, s);
    return s;
}

/// The index of the first `c` in `text[from..]` outside parentheses and
/// quotes, or null.
pub fn topLevel(text: []const u8, from: usize, c: u8) ?usize {
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

pub fn matching(text: []const u8, open: usize) ?usize {
    const close = topLevel(text, open + 1, ')') orelse return null;
    return close;
}
