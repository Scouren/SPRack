//! Lines: the logical lines of a netlist, made as they are asked for:
//! continuations joined, comments cut, the title and end marker found.

const std = @import("std");
const grammar = @import("grammar");
const ir = @import("ir");
const lexer = @import("lexer.zig");
const Allocator = std.mem.Allocator;
const LexCfg = grammar.LexCfg;
const Tok = lexer.Tok;
const tokens = @import("tokens.zig");
const Line = lexer.Line;
const LineKind = lexer.LineKind;
const tokenizeLine = tokens.tokenizeLine;

pub fn startsWithAny(s: []const u8, markers: []const []const u8) ?usize {
    for (markers) |m| if (m.len > 0 and std.mem.startsWith(u8, s, m)) return m.len;
    return null;
}

/// What a byte can open where `tailStart` looks for a trailing comment: for
/// most bytes nothing, and the scan steps over them without a comparison.
const ByteClass = packed struct(u8) {
    quote: bool = false,
    /// The first byte of an expression's opening delimiter.
    expr_open: bool = false,
    /// The first byte of a trailing-comment marker.
    tail_mark: bool = false,
    _: u5 = 0,

    const Table = [256]ByteClass;

    fn table(cfg: *const LexCfg) Table {
        var classes: Table = @splat(.{});
        classes['"'].quote = true;
        for (cfg.expr_delims) |d| {
            // An empty opening delimiter starts an expression anywhere.
            if (d[0].len == 0) {
                for (&classes) |*class| class.expr_open = true;
            } else classes[d[0][0]].expr_open = true;
        }
        for (cfg.tail_comments) |m| {
            if (m.len > 0) classes[m[0]].tail_mark = true;
        }
        return classes;
    }
};

/// Where a trailing comment starts. A marker only counts at the start of the
/// line or after a blank, and never inside a string or an expression.
/// `open` carries a string or expression left open at the end of a line
/// into its continuation: the closing delimiter still to come.
fn tailStart(
    cfg: *const LexCfg,
    classes: *const ByteClass.Table,
    line: []const u8,
    open: *[]const u8,
) ?struct { usize, usize } {
    if (cfg.tail_comments.len == 0) return null;
    var i: usize = 0;
    if (open.len > 0) {
        i = (std.mem.indexOfPos(u8, line, 0, open.*) orelse return null) + open.len;
        open.* = "";
    }
    while (i < line.len) {
        const c = line[i];
        const class = classes[c];
        if (@as(u8, @bitCast(class)) == 0) {
            i += 1;
            continue;
        }
        if (c == '"') {
            i = (std.mem.indexOfScalarPos(u8, line, i + 1, '"') orelse {
                open.* = "\"";
                return null;
            }) + 1;
            continue;
        }
        var skipped = false;
        if (class.expr_open) for (cfg.expr_delims) |d| {
            if (std.mem.startsWith(u8, line[i..], d[0])) {
                const close = std.mem.indexOfPos(u8, line, i + d[0].len, d[1]) orelse {
                    open.* = d[1];
                    return null;
                };
                i = close + d[1].len;
                skipped = true;
                break;
            }
        };
        if (skipped) continue;
        if (class.tail_mark and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) {
            if (startsWithAny(line[i..], cfg.tail_comments)) |n| return .{ i, n };
        }
        i += 1;
    }
    return null;
}

pub fn commentText(s: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, s, " \t");
    return if (t.len > 0 and t[0] == ' ') t[1..] else t;
}
/// The logical lines of a netlist, made as they are asked for: physical
/// lines are joined a few at a time, never all at once, and a reader that
/// is done with a line `release`s it. A line is numbered from 0 in the
/// order made; it stops before the end marker.
///
/// Text made for a line (joined continuations, comments cut from a line)
/// goes to `keep` when one is given, which outlives the lines; else to one
/// of two arenas in turn, which `recycle` resets once every line whose text
/// it holds is released.
pub const Lines = struct {
    cfg: *const LexCfg,
    /// What each byte can open in a line's text, from `cfg`.
    classes: ByteClass.Table,
    src: []const u8,
    title: []const u8 = "",
    keep: ?Allocator,
    gens: [2]std.heap.ArenaAllocator,
    /// The arena text goes to now, and for each arena the number one past
    /// the last line whose text it may hold.
    gen: u1 = 0,
    hi: [2]u32 = .{ 0, 0 },
    /// The lines made and not released: `buf[i]` is line `base + i`.
    buf: std.ArrayList(Line) = .empty,
    head: usize = 0,
    base: u32 = 0,
    /// Every physical line has been read, or the end marker met.
    done: bool = false,
    last_kind: ?LineKind = null,
    // What the joiner carries from one physical line to the next.
    it: std.mem.SplitIterator(u8, .scalar),
    no: u32 = 0,
    first_phys: bool = true,
    in_block: bool = false,
    trail: bool = false,
    open_delim: []const u8 = "",
    open: bool = false,
    first: []const u8 = "",
    first_tail: []const u8 = "",
    cur: std.ArrayList(u8) = .empty,
    tail: std.ArrayList(u8) = .empty,
    cur_no: u32 = 0,
    /// Comments met while a statement may still be continued. They are
    /// placed after it once it is known to have ended.
    pending: std.ArrayList(Line) = .empty,
    /// `first` points into text made for it, not into the source.
    first_made: bool = false,
    want_switch: bool = false,

    pub fn init(cfg: *const LexCfg, src: []const u8, keep: ?Allocator) Lines {
        return .{
            .cfg = cfg,
            .classes = ByteClass.table(cfg),
            .src = src,
            .keep = keep,
            .gens = .{ .init(ir.big), .init(ir.big) },
            .it = std.mem.splitScalar(u8, src, '\n'),
        };
    }

    pub fn deinit(l: *Lines) void {
        l.buf.deinit(ir.big);
        l.pending.deinit(ir.big);
        for (&l.gens) |*g| g.deinit();
    }

    /// Back to the first line, for another pass. Text made so far stays
    /// where it is until the arenas are recycled.
    /// Nothing made from the lines of the pass before may be used after.
    pub fn restart(l: *Lines, keep: ?Allocator) void {
        var next = init(l.cfg, l.src, keep);
        next.gens = l.gens;
        for (&next.gens) |*g| _ = g.reset(.retain_capacity);
        next.buf = l.buf;
        next.buf.clearRetainingCapacity();
        next.pending = l.pending;
        next.pending.clearRetainingCapacity();
        l.* = next;
    }

    /// The allocator for text that lives as long as line `i`.
    pub fn textFor(l: *Lines, i: u32) Allocator {
        if (l.keep) |k| return k;
        return l.gens[l.get(i).gen].allocator();
    }

    fn text(l: *Lines) Allocator {
        return l.keep orelse l.gens[l.gen].allocator();
    }

    pub fn get(l: *const Lines, i: u32) Line {
        return l.buf.items[l.head + (i - l.base)];
    }

    /// Lines made so far, released or not.
    fn made(l: *const Lines) u32 {
        return l.base + @as(u32, @intCast(l.buf.items.len - l.head));
    }

    /// Is there a line `i`? Joins physical lines until there is, or there
    /// are no more. A trailing blank line is held back until something
    /// follows it: a file's last blank lines are not lines.
    pub fn has(l: *Lines, i: u32) Allocator.Error!bool {
        while (true) {
            const n = l.made();
            const held: u32 = @intFromBool(!l.done and n > l.base and l.get(n - 1).kind == .blank);
            if (i < n - held) return true;
            if (l.done) return false;
            try l.pump();
        }
    }

    /// Forget the lines before `i`.
    pub fn release(l: *Lines, i: u32) void {
        if (i <= l.base) return;
        const n = @min(i - l.base, l.buf.items.len - l.head);
        l.head += n;
        l.base += @intCast(n);
        if (l.head == l.buf.items.len) {
            l.buf.clearRetainingCapacity();
            l.head = 0;
        } else if (l.head > 1024 and l.head * 2 > l.buf.items.len) {
            const left = l.buf.items.len - l.head;
            std.mem.copyForwards(Line, l.buf.items[0..left], l.buf.items[l.head..]);
            l.buf.shrinkRetainingCapacity(left);
            l.head = 0;
        }
    }

    /// Free the text of released lines: call when nothing made from them
    /// (tokens, values) is used any more.
    pub fn recycle(l: *Lines) void {
        if (l.keep != null) return;
        const other: u1 = 1 - l.gen;
        if (l.hi[other] <= l.base) {
            _ = l.gens[other].reset(.retain_capacity);
            l.hi[other] = 0;
            // Text from here on goes to the empty arena, so that this one
            // can be reset in turn.
            if (l.gens[l.gen].queryCapacity() > 1 << 20) l.want_switch = true;
        }
    }

    fn emit(l: *Lines, line: Line) Allocator.Error!void {
        var ln = line;
        ln.gen = l.gen;
        try l.buf.append(ir.big, ln);
        l.hi[l.gen] = l.made();
        l.last_kind = ln.kind;
    }

    fn note(l: *Lines, kind: LineKind, t: []const u8, no: u32) Allocator.Error!void {
        if (kind == .blank) {
            // Runs of blank lines collapse, and none leads the file.
            if (l.open) {
                if (l.pending.items.len > 0 and
                    l.pending.items[l.pending.items.len - 1].kind == .blank)
                    return;
            } else {
                if (l.last_kind == null or l.last_kind.? == .blank) return;
            }
        }
        const ln: Line = .{ .text = t, .no = no, .kind = kind };
        if (l.open) try l.pending.append(ir.big, ln) else try l.emit(ln);
    }

    fn flush(l: *Lines) Allocator.Error!void {
        if (l.open) {
            l.first_made = false;
            const joined = l.cur.items.len > 0;
            const ln: Line = .{
                .text = if (joined) try l.cur.toOwnedSlice(l.text()) else l.first,
                .no = l.cur_no,
                .tail = if (l.tail.items.len > 0)
                    try l.tail.toOwnedSlice(l.text())
                else
                    l.first_tail,
            };
            l.open = false;
            if (try l.isEnd(ln)) {
                l.done = true;
                return;
            }
            try l.emit(ln);
        }
        for (l.pending.items) |p| try l.emit(p);
        l.pending.clearRetainingCapacity();
    }

    /// The end marker: a line whose first token it is.
    fn isEnd(l: *Lines, ln: Line) Allocator.Error!bool {
        const m = l.cfg.end_marker;
        if (m.len == 0 or ln.text.len < m.len or !std.ascii.eqlIgnoreCase(ln.text[0..m.len], m))
            return false;
        var scratch: std.heap.ArenaAllocator = .init(ir.big);
        defer scratch.deinit();
        var toks: std.ArrayList(Tok) = .empty;
        try tokenizeLine(
            scratch.allocator(),
            scratch.allocator(),
            scratch.allocator(),
            l.cfg,
            ln.text,
            0,
            &toks,
        );
        return toks.items.len > 0 and toks.items[0].tag == .word and std.mem.eql(
            u8,
            toks.items[0].text,
            m,
        );
    }

    /// Read one more physical line.
    fn pump(l: *Lines) Allocator.Error!void {
        const cfg = l.cfg;
        const phys_raw = l.it.next() orelse {
            try l.flush();
            if (!l.done) {
                l.done = true;
                const n = l.made();
                if (n > l.base and l.get(n - 1).kind == .blank) _ = l.buf.pop();
            }
            return;
        };
        if (l.done) return;
        // Text from here on goes to the other arena, once no line still
        // being joined has text in this one.
        if (l.want_switch and l.hi[1 - l.gen] == 0 and l.pending.items.len == 0 and
            l.cur.items.len == 0 and l.tail.items.len == 0 and !l.first_made)
        {
            l.gen = 1 - l.gen;
            l.want_switch = false;
        }
        const arena = l.text();
        var made_text = false;
        l.no += 1;
        const no = l.no;
        var phys = std.mem.trimEnd(u8, phys_raw, "\r");
        if (cfg.block_comment) |bc| {
            // `/* ... */` spans, which may also run over several lines,
            // become comment lines of their own.
            if (l.in_block or std.mem.indexOf(u8, phys, bc[0]) != null) {
                var kept: std.ArrayList(u8) = .empty;
                var cut: std.ArrayList(u8) = .empty;
                var i: usize = 0;
                while (i < phys.len) {
                    if (l.in_block) {
                        const close = std.mem.indexOfPos(u8, phys, i, bc[1]) orelse {
                            try cut.appendSlice(arena, phys[i..]);
                            break;
                        };
                        try cut.appendSlice(arena, phys[i..close]);
                        i = close + bc[1].len;
                        l.in_block = false;
                    } else if (std.mem.startsWith(u8, phys[i..], bc[0])) {
                        l.in_block = true;
                        i += bc[0].len;
                    } else {
                        try kept.append(arena, phys[i]);
                        i += 1;
                    }
                }
                const t = std.mem.trim(u8, cut.items, " \t");
                if (t.len > 0) {
                    const marker = if (cfg.line_comments.len > 0) cfg.line_comments[0] else "*";
                    try l.note(
                        .comment,
                        try std.fmt.allocPrint(arena, "{s} {s}", .{ marker, t }),
                        no,
                    );
                }
                phys = kept.items;
                made_text = true;
                if (std.mem.trim(u8, phys, " \t").len == 0) return;
            }
        }
        if (l.first_phys) {
            l.first_phys = false;
            if (cfg.title) {
                var t = std.mem.trim(u8, phys, " \t");
                if (cfg.title_prefix.len > 0) {
                    const p = std.mem.trim(u8, cfg.title_prefix, " \t");
                    if (std.mem.startsWith(u8, t, p)) t = std.mem.trim(u8, t[p.len..], " \t");
                }
                l.title = t;
                return;
            }
        }
        const lead = std.mem.trimStart(u8, phys, " \t");
        if (lead.len == 0) {
            if (!l.trail) try l.note(.blank, "", no);
            return;
        }
        if (startsWithAny(lead, cfg.line_comments) != null) {
            try l.note(.comment, std.mem.trimEnd(u8, lead, " \t"), no);
            return;
        }
        var body = lead;
        var tail: []const u8 = "";
        const continues = l.trail or (cfg.cont_lead.len > 0 and std.mem.startsWith(u8, lead, cfg.cont_lead));
        if (!continues) l.open_delim = "";
        if (tailStart(cfg, &l.classes, lead, &l.open_delim)) |cut| {
            body = lead[0..cut[0]];
            tail = commentText(lead[cut[0] + cut[1] ..]);
        }
        body = std.mem.trimEnd(u8, body, " \t");
        if (body.len == 0) {
            // The whole line was a trailing-style comment.
            try l.note(.comment, std.mem.trimEnd(u8, lead, " \t"), no);
            return;
        }

        var is_cont = l.trail;
        if (!is_cont and cfg.cont_lead.len > 0 and std.mem.startsWith(u8, body, cfg.cont_lead)) {
            if (!l.open) {
                // Nothing to continue but the title or a comment: it is one.
                const marker = if (cfg.line_comments.len > 0) cfg.line_comments[0] else "*";
                try l.note(
                    .comment,
                    try std.fmt.allocPrint(arena, "{s} {s}", .{ marker, lead }),
                    no,
                );
                return;
            }
            is_cont = true;
            body = body[cfg.cont_lead.len..];
        }
        l.trail = false;
        if (cfg.cont_trail.len > 0 and std.mem.endsWith(u8, body, cfg.cont_trail)) {
            l.trail = true;
            body = body[0 .. body.len - cfg.cont_trail.len];
            // HSPICE's `\\` joins with no blank; a blank is harmless here.
            if (std.mem.endsWith(u8, body, cfg.cont_trail))
                body = body[0 .. body.len - cfg.cont_trail.len];
            body = std.mem.trimEnd(u8, body, " \t");
        }
        if (!is_cont) {
            try l.flush();
            if (l.done) return;
            l.open = true;
            l.cur_no = no;
            l.first = body;
            l.first_tail = tail;
            l.first_made = made_text;
            return;
        }
        const a = l.text();
        if (l.cur.items.len == 0) try l.cur.appendSlice(a, l.first);
        try l.cur.append(a, ' ');
        try l.cur.appendSlice(a, body);
        if (tail.len > 0) {
            if (l.tail.items.len == 0 and l.first_tail.len > 0)
                try l.tail.appendSlice(a, l.first_tail);
            if (l.tail.items.len > 0) try l.tail.appendSlice(a, "; ");
            try l.tail.appendSlice(a, tail);
        }
    }
};
