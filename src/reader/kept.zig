//! Lines kept as they are: a raw block (`.control` ... `.endc`) as its
//! text, an embedded file (`embed "name" <<<FILE` ... `>>>FILE`), and a
//! statement of the dialect's own as its words.
//!
//! Contents:
//! - `pub fn rawAt(self: *Reader, ti: usize, line_no: u32, out: anytype) Allocator.Error!bool`
//! - `pub fn nativeOf(arena: Allocator, g: *const Grammar, text: []const u8, line_no: u32,
//!   tail: []const u8) Allocator.Error!ir.Stmt`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const step = @import("step.zig");
const assert = std.debug.assert;
const Reader = step.Reader;
const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Value = ir.Value;

/// A raw block that opens at `ti`, read to its closing line. False where
/// none opens there.
pub fn rawAt(self: *Reader, ti: usize, line_no: u32, out: anytype) Allocator.Error!bool {
    // Reading starts where the line does.
    assert(self.ti == ti);
    const first = self.toks()[ti];
    if (first.tag != .word) return false;
    for (self.g.raws) |*rb| {
        if (!std.mem.eql(u8, first.text, rb.open)) continue;
        if (rb.kind) |k| if (k == .embed) {
            try out.append(self.arena, try embed(self, rb, ti, line_no));
            return true;
        };
        const raw = try rawText(self, rb);
        try out.append(
            self.arena,
            .{ .kind = .@"opaque", .raw = raw, .line = line_no },
        );
        return true;
    }
    return false;
}

/// The words of a line no kind holds: the first, then each blank-separated
/// word (parentheses and quotes keep their blanks), a `key=value` one a
/// parameter. Values stay as written.
pub fn nativeOf(
    arena: Allocator,
    g: *const Grammar,
    text: []const u8,
    line_no: u32,
    tail: []const u8,
) Allocator.Error!ir.Stmt {
    const words = try wordsOf(arena, text);
    // `key = value` with blanks: one pair.
    var args: std.ArrayList(Value) = .empty;
    var ps: std.ArrayList(ir.Param) = .empty;
    var k: usize = 1;
    while (k < words.len) : (k += 1) {
        const w = words[k];
        if (k + 2 < words.len and std.mem.eql(u8, words[k + 1], "=")) {
            try ps.append(arena, .{ .key = w, .val = .{ .atom = words[k + 2] } });
            k += 2;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, w, '=');
        if (eq != null and eq.? > 0 and eq.? + 1 < w.len and std.mem.indexOfAny(
            u8,
            w[0..eq.?],
            "('\"[{",
        ) == null) {
            try ps.append(arena, .{ .key = w[0..eq.?], .val = .{ .atom = w[eq.? + 1 ..] } });
        } else try args.append(arena, .{ .atom = w });
    }
    // Each word after the first is an argument or in a parameter.
    assert(args.items.len + ps.items.len <= words.len);
    var st = try ir.newStmt(arena, .native, line_no);
    st.tail = tail;
    try st.set(arena, schema.slot(.native, "of"), .{ .atom = g.name });
    try st.set(arena, schema.slot(.native, "word"), .{ .atom = if (words.len > 0)
        words[0]
    else
        "" });
    if (args.items.len > 0)
        try st.set(arena, schema.slot(.native, "args"), .{ .list = args.items });
    if (ps.items.len > 0)
        try st.set(arena, schema.slot(.native, "params"), .{ .params = ps.items });
    return st;
}

// ---- private ----

/// `embed "name" <<<FILE`, its lines, `>>>FILE`: the file's text.
fn embed(
    self: *Reader,
    rb: *const grammar.RawBlock,
    ti: usize,
    line_no: u32,
) Allocator.Error!ir.Stmt {
    assert(rb.kind.? == .embed);
    const path: Value = switch (self.toks()[ti + 1].tag) {
        .str, .word, .expr => .{ .str = self.toks()[ti + 1].text },
        else => .none,
    };
    self.skipLine();
    var text: std.ArrayList(u8) = .empty;
    while (try self.m.win.has(self.ti)) {
        const t = self.toks()[self.ti];
        const rl = self.lines.get(t.lno);
        self.skipLine();
        if (t.tag == .word and std.mem.eql(u8, t.text, rb.close)) break;
        try text.appendSlice(self.arena, rl.text);
        if (rl.tail.len > 0 and self.g.lex.tail_comments.len > 0)
            try text.print(
                self.arena,
                " {s} {s}",
                .{ self.g.lex.tail_comments[0], rl.tail },
            );
        try text.append(self.arena, '\n');
    }
    var st = try ir.newStmt(self.arena, .embed, line_no);
    try st.set(self.arena, schema.slot(.embed, "path"), path);
    try st.set(
        self.arena,
        schema.slot(.embed, "text"),
        .{ .atom = try text.toOwnedSlice(self.arena) },
    );
    return st;
}

/// The lines of a raw block, its opening and closing lines with them.
fn rawText(self: *Reader, rb: *const grammar.RawBlock) Allocator.Error![]const u8 {
    assert(self.ti < self.toks().len);
    var raw: std.ArrayList(u8) = .empty;
    while (try self.m.win.has(self.ti)) {
        const t = self.toks()[self.ti];
        if (raw.items.len > 0) try raw.append(self.arena, '\n');
        const rl = self.lines.get(t.lno);
        try raw.appendSlice(self.arena, rl.text);
        if (rl.tail.len > 0 and self.g.lex.tail_comments.len > 0) {
            try raw.print(
                self.arena,
                " {s} {s}",
                .{ self.g.lex.tail_comments[0], rl.tail },
            );
        }
        self.skipLine();
        if (t.tag == .word and std.mem.eql(u8, t.text, rb.close)) break;
    }
    return raw.toOwnedSlice(self.arena);
}

/// The blank-separated words of a line; parentheses and quotes keep their blanks.
fn wordsOf(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i >= text.len) break;
        const from = i;
        var depth: usize = 0;
        var quote: u8 = 0;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (quote != 0) {
                if (ch == quote) quote = 0;
            } else if (ch == '\'' or ch == '"') {
                quote = ch;
            } else if (ch == '(' or ch == '[' or ch == '{') {
                depth += 1;
            } else if ((ch == ')' or ch == ']' or ch == '}') and depth > 0) {
                depth -= 1;
            } else if (depth == 0 and (ch == ' ' or ch == '\t')) break;
        }
        try words.append(arena, text[from..i]);
    }
    // Each word holds at least one byte.
    assert(words.items.len <= text.len);
    return words.items;
}
