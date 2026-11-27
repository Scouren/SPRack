//! Lines that hold more than one statement: a keyword that starts rules of
//! two kinds (HSPICE's `.param f(x)='x*2' k=1`), and an analysis that ends
//! with the rule of a block kind (`.tran 1n 1u sweep monte=30`).
//!
//! Contents:
//! - `pub fn splitAt(self: *Reader, ti: usize, line_no: u32, out: anytype)
//!   Allocator.Error!bool`
//! - `pub fn ruleAt(self: *Reader, ti: usize, line_no: u32) Allocator.Error!?ir.Stmt`
//! - `pub fn spreadAt(self: *Reader, ti: usize, line_no: u32) Allocator.Error!?ir.Stmt`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const step = @import("step.zig");
const assert = std.debug.assert;
const Reader = step.Reader;
const Allocator = std.mem.Allocator;
const Kind = schema.Kind;
const Tok = lexer.Tok;

/// A line whose keyword starts rules of two kinds may hold statements
/// of both, one after another: HSPICE's `.param f(x)='x*2' k=1`. Each
/// shortest run that some rule reads is a statement, and the keyword is
/// put back in front of what is left.
pub fn splitAt(self: *Reader, ti: usize, line_no: u32, out: anytype) Allocator.Error!bool {
    const head = self.toks()[ti];
    if (head.tag != .word or !sharedKeyword(self, head)) return false;
    var end = ti;
    while (self.toks()[end].tag != .nl) end += 1;
    // A word comes before the `nl` that ends its line.
    assert(end > ti);
    const items = self.m.win.toks.items;
    // Every token changed, to put back whatever happens.
    var saved: std.ArrayList(struct { usize, Tok }) = .empty;
    defer for (saved.items) |s| {
        items[s[0]] = s[1];
    };
    var found: std.ArrayList(ir.Stmt) = .empty;
    var from = ti;
    // Bounded by the line: each pass that goes on starts one token further.
    outer: while (true) {
        if (try self.ruleAt(from, line_no)) |st| {
            try found.append(self.arena, st);
            break;
        }
        var j = from + 2;
        while (j < end) : (j += 1) {
            try saved.append(self.arena, .{ j, items[j] });
            items[j] = items[end];
            items[j].text = "";
            const st = try self.ruleAt(from, line_no);
            items[j] = saved.pop().?[1];
            const s = st orelse continue;
            try found.append(self.arena, s);
            try saved.append(self.arena, .{ j - 1, items[j - 1] });
            items[j - 1] = head;
            from = j - 1;
            continue :outer;
        }
        return false;
    }
    for (found.items) |st| try out.append(self.arena, st);
    self.ti = end + 1;
    return true;
}

/// The statement a rule reads from `ti` to the end of its line.
pub fn ruleAt(self: *Reader, ti: usize, line_no: u32) Allocator.Error!?ir.Stmt {
    const head = self.toks()[ti];
    for (self.g.readCandidates(if (head.tag == .word) head.text else null)) |ri| {
        const rule = &self.g.rules[ri];
        if (rule.dir == .write or rule.within != null) continue;
        if (!try self.m.run(rule.kind, rule.pat, ti)) continue;
        if (rule.kind == .@"opaque") return null;
        var st = try self.m.build(line_no);
        if (!self.g.lex.case_sensitive) try self.spell.statement(self.arena, &st);
        try self.canonStmt(&st);
        self.flagOddValues(&st);
        return st;
    }
    return null;
}

/// `spread`: an analysis line that ends with the rule of a block kind
/// (`.tran 1n 1u sweep monte=30`) is that block around the analysis.
pub fn spreadAt(self: *Reader, ti: usize, line_no: u32) Allocator.Error!?ir.Stmt {
    if (self.g.spreads.len == 0) return null;
    var end = ti;
    while (self.toks()[end].tag != .nl) end += 1;
    for (self.g.rules) |*sr| {
        if (sr.dir == .write or !self.g.isSpread(sr.kind)) continue;
        if (self.g.spreadWord(sr.kind) != null and !self.g.isEnding(sr)) continue;
        var j = ti + 1;
        while (j < end) : (j += 1) {
            if (!try self.m.run(sr.kind, sr.pat, j)) continue;
            return spreadFrom(self, ti, j, end, line_no);
        }
    }
    return null;
}

// ---- private ----

/// Does the head word start rules of two kinds?
fn sharedKeyword(self: *const Reader, head: Tok) bool {
    var first_kind: ?Kind = null;
    for (self.g.rules) |*rule| {
        if (rule.dir == .write or rule.within != null or rule.pat.len == 0 or
            rule.pat[0].tag != .lit)
            continue;
        if (!std.mem.eql(u8, rule.pat[0].text, head.text)) continue;
        if (first_kind) |k| {
            if (k != rule.kind) return true;
        } else first_kind = rule.kind;
    }
    return false;
}

/// The block a spread rule just matched at `j` around the analysis the
/// line reads up to `j`. Null where no analysis rule reads that part.
fn spreadFrom(
    self: *Reader,
    ti: usize,
    j: usize,
    end: usize,
    line_no: u32,
) Allocator.Error!?ir.Stmt {
    assert(ti < j);
    assert(j < end);
    var wrap = try self.m.build(line_no);
    wrap.tail = self.toks()[end].text;
    // The line without its suffix, read as a statement of its own.
    const items = self.m.win.toks.items;
    const cut = items[j];
    items[j] = items[end];
    items[j].text = "";
    defer items[j] = cut;
    for (self.g.rules) |*rule| {
        if (rule.dir == .write or rule.within != null or
            schema.info(rule.kind).class != .analysis)
            continue;
        if (!try self.m.run(rule.kind, rule.pat, ti)) continue;
        var st = try self.m.build(line_no);
        try self.canonStmt(&st);
        wrap.body = try self.arena.dupe(ir.Stmt, &.{st});
        try self.canonStmt(&wrap);
        self.ti = end + 1;
        return wrap;
    }
    return null;
}
