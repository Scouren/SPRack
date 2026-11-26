//! The output itself: a statement as one line or broken with the
//! dialect's continuation mark, a comment, a statement with the comment
//! that trailed it.

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const statement = @import("statement.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Kind = schema.Kind;
const Writer = statement.Writer;
const Error = Writer.Error;

const wrap_at = 100;

/// A statement and the comment that trailed it in the source.
pub fn lineTail(w: *Writer, text: []const u8, tail: []const u8) Error!void {
    if (tail.len == 0) return line(w, text);
    if (w.g.lex.tail_comments.len == 0 or std.mem.indexOfScalar(u8, text, '\n') != null) {
        try comment(w, tail);
        return line(w, text);
    }
    if (text.len + tail.len > wrap_at) {
        try comment(w, tail);
        return line(w, text);
    }
    try w.out.print("{s} {s} {s}\n", .{ text, w.g.lex.tail_comments[0], tail });
    w.last_blank = false;
}

/// Write one statement. A long one is broken at a blank, outside any
/// quotes and brackets, with the dialect's continuation mark.
pub fn line(w: *Writer, text: []const u8) Error!void {
    w.last_blank = false;
    const cfg = &w.g.lex;
    const can_wrap = cfg.cont_lead.len > 0 or cfg.cont_trail.len > 0;
    if (text.len <= wrap_at or !can_wrap or w.nowrap or std.mem.indexOfScalar(
        u8,
        text,
        '\n',
    ) != null) {
        try w.out.writeAll(text);
        return w.out.writeByte('\n');
    }
    var start: usize = 0;
    var last_break: ?usize = null;
    var depth: usize = 0;
    var quote: u8 = 0;
    for (text, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            ' ' => if (depth == 0) {
                if (i - start > wrap_at) if (last_break) |b| if (b > start) {
                    try w.out.writeAll(text[start..b]);
                    try breakLine(w);
                    start = b + 1;
                };
                last_break = i;
            },
            else => {},
        }
    }
    if (text.len - start > wrap_at) if (last_break) |b| if (b > start) {
        try w.out.writeAll(text[start..b]);
        try breakLine(w);
        start = b + 1;
    };
    try w.out.writeAll(text[start..]);
    try w.out.writeByte('\n');
}

pub fn breakLine(w: *Writer) Error!void {
    const cfg = &w.g.lex;
    if (cfg.cont_lead.len > 0) {
        try w.out.print("\n{s} ", .{cfg.cont_lead});
    } else try w.out.print(" {s}\n    ", .{cfg.cont_trail});
}

pub fn comment(w: *Writer, text: []const u8) Error!void {
    const marker = if (w.g.lex.line_comments.len > 0) w.g.lex.line_comments[0] else "*";
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (l.len == 0)
            try w.out.print("{s}\n", .{marker})
        else
            try w.out.print("{s} {s}\n", .{ marker, l });
    }
    w.last_blank = false;
}
