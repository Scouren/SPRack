//! What every part of the compiler shares: the context `C` that allocates
//! and reports, the error and the diagnostic, the line reader, and the
//! small parsers of words, kinds, slots and numbers a directive is made of.
//!
//! Contents:
//! - `pub const Error`
//! - `pub const Diag = struct`
//! - `pub const C = struct`: `fail`, `add`, `cat`, `lower`, `foldIf`
//! - `pub const Lines = struct`: `next`
//! - `pub fn parseDecimal(c: *C, line: u32, text: []const u8) Error!struct`
//! - `pub fn stripComment(line: []const u8) []const u8`
//! - `pub fn args(c: *C, line_no: u32, line: []const u8) Error![]const []const u8`
//! - `pub fn splitHead(line: []const u8) struct`
//! - `pub fn kindOf(c: *C, line: u32, name: []const u8) Error!Kind`
//! - `pub fn kindSlot(c: *C, line: u32, kind_name: []const u8, slot_name: []const u8) Error!struct`
//! - `pub fn dotted(c: *C, line: u32, text: []const u8) Error!struct`
//! - `pub fn literalLines(c: *C, lines: *Lines) Error![]const []const u8`
//! - `pub fn slotNamed(c: *C, line: u32, kind: Kind, s: []const u8) Error!u8`
//! - `pub fn condition(c: *C, line: u32, kind: Kind, text: []const u8) Error!struct`
//! - `pub fn isNumber(text: []const u8) bool`

const std = @import("std");
const schema = @import("schema");
const Kind = schema.Kind;
const Allocator = std.mem.Allocator;

pub const Error = error{ BadGrammar, OutOfMemory };

/// What a failed run-time `compile` says: `file:line: message`, allocated
/// with the allocator given to `compile`.
pub const Diag = struct { msg: []const u8 = "" };

/// The compiler's context: where to allocate and where to report.
pub const C = struct {
    /// Unused at compile time.
    gpa: Allocator,
    diag: *Diag,
    /// File named in messages; empty means `<dialect>.spgrammar`.
    file: []const u8,
    name: []const u8 = "?",
    /// Lists `add` grew with room to spare, by address: appending to one
    /// of them again fills the room instead of copying.
    grown: std.AutoHashMapUnmanaged(usize, Grown) = .empty,
    /// Nodes the pattern being parsed has so far, defines expanded.
    nodes: u32 = 0,
    /// Captures of the pattern being parsed that pick items (`slot*@sel=atom`).
    picks: u32 = 0,
    /// The lexer's whole-line comment marks: a literal that starts with
    /// one is never read, so it keeps its case (CDL's `*.PININFO`).
    comments: []const []const u8 = &.{},

    const Grown = struct { len: usize, cap: usize };

    pub fn fail(c: *C, line: u32, comptime fmt: []const u8, a: anytype) Error {
        const where = if (c.file.len > 0)
            try std.fmt.allocPrint(c.gpa, "{s}:{d}: ", .{ c.file, line })
        else
            try std.fmt.allocPrint(c.gpa, "{s}.spgrammar:{d}: ", .{ c.name, line });
        c.diag.msg = try std.mem.concat(
            c.gpa,
            u8,
            &.{ where, try std.fmt.allocPrint(c.gpa, fmt, a) },
        );
        return error.BadGrammar;
    }

    /// `list` with `item` appended. At run time a list grows geometrically:
    /// copying it on every append made a long line cost O(n^2) memory, and
    /// a mutated grammar of 6 KB took more than 1 GB.
    pub fn add(c: *C, comptime T: type, list: []const T, item: T) Error![]const T {
        if (list.len > 0) if (c.grown.getPtr(@intFromPtr(list.ptr))) |g| {
            // Only the newest slice of a list may take the room after it;
            // an older, shorter slice of the same list is copied.
            if (g.len == list.len and g.len < g.cap) {
                const out = @constCast(list.ptr)[0 .. list.len + 1];
                out[list.len] = item;
                g.len += 1;
                return out;
            }
        };
        const buf = try c.gpa.alloc(T, @max(4, 2 * list.len));
        @memcpy(buf[0..list.len], list);
        buf[list.len] = item;
        try c.grown.put(c.gpa, @intFromPtr(buf.ptr), .{ .len = list.len + 1, .cap = buf.len });
        return buf[0 .. list.len + 1];
    }

    pub fn cat(c: *C, a: []const u8, b: []const u8) Error![]const u8 {
        return std.mem.concat(c.gpa, u8, &.{ a, b });
    }

    pub fn lower(c: *C, s: []const u8) Error![]const u8 {
        return std.ascii.allocLowerString(c.gpa, s);
    }

    pub fn foldIf(c: *C, fold: bool, s: []const u8) Error![]const u8 {
        return if (fold) c.lower(s) else s;
    }
};

pub const Lines = struct {
    src: []const u8,
    pos: usize = 0,
    no: u32 = 0,

    /// Next non-blank line with comments removed, or null at end of file.
    pub fn next(l: *Lines) ?[]const u8 {
        var pos = l.pos;
        var no = l.no;
        defer {
            l.pos = pos;
            l.no = no;
        }
        while (pos < l.src.len) {
            const eol = std.mem.indexOfScalarPos(u8, l.src, pos, '\n') orelse l.src.len;
            const raw = l.src[pos..eol];
            pos = eol + 1;
            no += 1;
            const t = std.mem.trim(u8, stripComment(raw), " \t\r");
            if (t.len > 0) return t;
        }
        return null;
    }
};

pub fn parseDecimal(c: *C, line: u32, text: []const u8) Error!struct { u64, i32 } {
    var mant: u64 = 0;
    var exp: i32 = 0;
    var i: usize = 0;
    var seen_point = false;
    while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '.')) : (i += 1) {
        if (text[i] == '.') {
            seen_point = true;
            continue;
        }
        mant = std.math.mul(u64, mant, 10) catch return c.fail(
            line,
            "bad multiplier '{s}'",
            .{text},
        );
        mant += text[i] - '0';
        if (seen_point) exp -= 1;
    }
    if (i < text.len) {
        if (text[i] != 'e' and text[i] != 'E') return c.fail(line, "bad multiplier '{s}'", .{text});
        exp += std.fmt.parseInt(i32, text[i + 1 ..], 10) catch return c.fail(
            line,
            "bad multiplier '{s}'",
            .{text},
        );
    }
    if (mant == 0) return c.fail(line, "bad multiplier '{s}'", .{text});
    return .{ mant, exp };
}

/// Strip a `#` comment (only at line start or after a blank, outside quotes).
pub fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    for (line, 0..) |ch, i| {
        if (quote != 0) {
            if (ch == quote) quote = 0;
        } else if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (ch == '#' and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) {
            return line[0..i];
        }
    }
    return line;
}

/// Split a directive line into words and quoted strings.
pub fn args(c: *C, line_no: u32, line: []const u8) Error![]const []const u8 {
    var out: []const []const u8 = &.{};
    var i: usize = 0;
    while (i < line.len) {
        const ch = line[i];
        if (ch == ' ' or ch == '\t') {
            i += 1;
        } else if (ch == '"' or ch == '\'') {
            const end = std.mem.indexOfScalarPos(u8, line, i + 1, ch) orelse return c.fail(
                line_no,
                "unterminated string",
                .{},
            );
            // An empty word matches everywhere and consumes nothing.
            if (end == i + 1) return c.fail(line_no, "empty string", .{});
            out = try c.add([]const u8, out, line[i + 1 .. end]);
            i = end + 1;
        } else {
            var j = i;
            while (j < line.len and line[j] != ' ' and line[j] != '\t') j += 1;
            // `line[i]` is neither a blank nor a quote: the word is not empty.
            std.debug.assert(j > i);
            out = try c.add([]const u8, out, line[i..j]);
            i = j;
        }
    }
    return out;
}

pub fn splitHead(line: []const u8) struct { []const u8, []const u8 } {
    const sp = std.mem.indexOfAny(u8, line, " \t") orelse return .{ line, "" };
    return .{ line[0..sp], std.mem.trim(u8, line[sp..], " \t") };
}

pub fn kindOf(c: *C, line: u32, name: []const u8) Error!Kind {
    return schema.kindFromName(name) orelse return c.fail(line, "unknown kind '{s}'", .{name});
}

pub fn kindSlot(
    c: *C,
    line: u32,
    kind_name: []const u8,
    slot_name: []const u8,
) Error!struct { Kind, u8 } {
    const kind = try kindOf(c, line, kind_name);
    const slot = schema.slotIndex(kind, slot_name) orelse return c.fail(
        line,
        "unknown slot '{s}' for kind '{s}'",
        .{ slot_name, kind_name },
    );
    return .{ kind, slot };
}

pub fn dotted(c: *C, line: u32, text: []const u8) Error!struct { Kind, u8 } {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return c.fail(
        line,
        "expected kind.slot, found '{s}'",
        .{text},
    );
    return kindSlot(c, line, text[0..dot], text[dot + 1 ..]);
}

pub fn literalLines(c: *C, lines: *Lines) Error![]const []const u8 {
    var out: []const []const u8 = &.{};
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "end")) return out;
        out = try c.add([]const u8, out, line);
    }
    return c.fail(lines.no, "section is missing 'end'", .{});
}

pub fn slotNamed(c: *C, line: u32, kind: Kind, s: []const u8) Error!u8 {
    return schema.slotIndex(kind, s) orelse c.fail(
        line,
        "unknown slot '{s}' for kind '{s}'",
        .{ s, @tagName(kind) },
    );
}

/// `slot=atom`: a condition on an atom slot.
pub fn condition(c: *C, line: u32, kind: Kind, text: []const u8) Error!struct { u8, []const u8 } {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return c.fail(
        line,
        "expected slot=atom, found '{s}'",
        .{text},
    );
    const slot = try slotNamed(c, line, kind, text[0..eq]);
    if (schema.info(kind).slots[slot].ty != .atom)
        return c.fail(line, "a condition needs an atom slot", .{});
    return .{ slot, text[eq + 1 ..] };
}

pub fn isNumber(text: []const u8) bool {
    _ = std.fmt.parseFloat(f64, text) catch return false;
    return true;
}
