//! The frame of a netlist: what the target has before its statements (the
//! title, its header, the boilerplate the kinds in use need, the options
//! the source assumes) and after them (the control blocks, the end marker,
//! the notes said once a file). Both drivers write it, so it is here once.
//!
//! Contents:
//! - `pub const Facts = struct`
//! - `pub fn foldsHeader(g: *const Grammar, dialect: []const u8, folds_case: bool) bool`
//! - `pub fn open(w: *Writer, f: *const Facts) Writer.Error!void`
//! - `pub fn assumedOptions(w: *Writer, nl: *const ir.Netlist) Allocator.Error!?ir.Stmt`
//! - `pub fn markSole(w: *Writer, st: *const ir.Stmt, analyses: usize) void`
//! - `pub fn wrapped(w: *Writer, stmts: []const ir.Stmt, analyses: usize) Writer.Error!void`
//! - `pub fn close(w: *Writer, library: bool) Writer.Error!void`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const dialects = @import("dialects");
const analysis_passes = @import("analyses.zig");
const statement = @import("statement.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Writer = statement.Writer;

/// What of the whole netlist the lines before its first statement depend on.
pub const Facts = struct {
    title: []const u8,
    /// The dialect the netlist was read in.
    dialect: []const u8,
    /// An included file: no title, no boilerplate, no end marker of its own.
    library: bool,
    /// The reader folded case (a file that says so, or a dialect that does).
    folds_case: bool,
    /// The kinds and the model families the netlist and its environment use.
    used: [schema.kind_count]bool,
    families: [schema.families.len]bool,
};

/// Is the header the one of a case-sensitive target told to fold case
/// (`header folded`)? Such a target merges names the way one that ignores
/// case does.
pub fn foldsHeader(g: *const Grammar, dialect: []const u8, folds_case: bool) bool {
    if (g.header_folded.len == 0) return false;
    if (folds_case) return true;
    const source = dialects.find(dialect) orelse return false;
    return !source.lex.case_sensitive;
}

/// The title, the header, and the boilerplate of the kinds and the model
/// families in use. An included file is not a netlist: it has no title of
/// its own and leaves the boilerplate to the top file.
pub fn open(w: *Writer, f: *const Facts) Writer.Error!void {
    const g = w.g;
    // Only the boilerplate below is written unwrapped.
    assert(!w.nowrap);
    if (g.lex.title and !f.library) {
        const title = if (f.title.len > 0) f.title else "untitled";
        try w.out.print("{s}{s}\n", .{ g.lex.title_prefix, title });
    }
    const folded = foldsHeader(g, f.dialect, f.folds_case);
    for (if (folded) g.header_folded else g.header) |l| try w.line(l);
    if (f.library) return;
    const said = if (g.preamble_unless) |k| f.used[@backingInt(k)] else false;
    if (!said) for (g.preamble) |l| try w.line(l);
    for (g.needs) |n| {
        if (!needed(f, n)) continue;
        // A needs line stays whole: ngspice lowercases a continuation
        // line inside .control, and so a path given with --provide (4.43).
        w.nowrap = true;
        defer w.nowrap = false;
        for (n.lines) |l| try w.line(try statement.needLine(w.arena, l, n.family, w.env));
    }
}

/// The options the source's dialect assumes where the target assumes
/// others, as the statement that says them, with the caveat that it is
/// written; null where the two assume the same. `nl`: the dialect and the
/// top-level option statements of the netlist.
pub fn assumedOptions(w: *Writer, nl: *const ir.Netlist) Allocator.Error!?ir.Stmt {
    const a = w.arena;
    try analysis_passes.reportDefaults(a, w.g, nl, w.report);
    const d = try analysis_passes.defaultOptions(a, w.g, nl) orelse return null;
    var names: std.ArrayList(u8) = .empty;
    for (schema.info(.options).slots, 0..) |sl, i| {
        if (d.at(i) == .none) continue;
        try names.print(a, "{s}{s}", .{ if (names.items.len > 0) ", " else "", sl.name });
    }
    assert(names.items.len > 0);
    w.report.add(
        .warning,
        .caveat,
        0,
        "options: {s} assumes other defaults for {s} than {s} does; they are written out",
        .{ nl.dialect, names.items, w.g.name },
    );
    return d;
}

/// `st` is the netlist's only analysis: the one a kind with lines of its
/// own (`spread`, HSPICE `.temp`) may be written beside as such a line.
pub fn markSole(w: *Writer, st: *const ir.Stmt, analyses: usize) void {
    if (analyses == 1 and schema.runs(st.kind)) w.sole = st;
}

/// The statements of `stmts` the target writes inside a control block
/// (`wrap`), each block after everything else. A control block runs in
/// order (VACASK), so its settings come before every analysis: SPICE
/// applies them wherever they stand.
pub fn wrapped(w: *Writer, stmts: []const ir.Stmt, analyses: usize) Writer.Error!void {
    const g = w.g;
    for (g.wraps) |*wr| {
        var any = false;
        for ([_]bool{ false, true }) |runs| for (stmts) |*st| {
            if (g.wrapOf(st.kind) != wr) continue;
            if ((schema.info(st.kind).class == .analysis) != runs) continue;
            if (!any) try w.line(wr.open);
            any = true;
            markSole(w, st, analyses);
            try w.stmt(st);
        };
        if (any) try w.line(wr.close);
    }
}

/// The end marker, which an included file must not have (it would end the
/// simulation), and the notes said once a file.
pub fn close(w: *Writer, library: bool) Writer.Error!void {
    const g = w.g;
    if (g.lex.end_marker.len > 0 and !library) try w.line(g.lex.end_marker);
    w.refusals();
    w.keptNote();
    w.foreignNote();
    w.copiedNote();
}

// ---- private ----

/// Does the netlist use what the boilerplate `n` is for: a model family,
/// or a kind?
fn needed(f: *const Facts, n: grammar.Needs) bool {
    if (n.family.len == 0) return f.used[@backingInt(n.kind)];
    for (schema.families, f.families) |family, used| {
        if (std.mem.eql(u8, family.name, n.family)) return used;
    }
    unreachable; // the grammar compiler takes only families of the schema
}
