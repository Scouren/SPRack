//! A statement the target cannot write: the report entry that says why,
//! and the statement and what it holds in the output as comments.
//!
//! Contents:
//! - `pub fn bodyComments(w: *Writer, a: Allocator, stmts: []const ir.Stmt) Error!void`
//! - `pub fn bodyCount(stmts: []const ir.Stmt) usize`
//! - `pub fn unsupported(w: *Writer, a: Allocator, st: *const ir.Stmt,
//!   also: []const u8) Error!void`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const output = @import("output.zig");
const statement = @import("statement.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Kind = schema.Kind;
const Writer = statement.Writer;
const Error = Writer.Error;

/// The statements of a block not written, each as a comment.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn bodyComments(w: *Writer, a: Allocator, stmts: []const ir.Stmt) Error!void {
    for (stmts) |*s| {
        if (s.kind == .comment) continue;
        try notWritten(w, a, s);
        if (s.kind == .simctl) continue;
        try bodyComments(w, a, s.body);
    }
}

/// The statements a block holds, at any depth, comments aside.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn bodyCount(stmts: []const ir.Stmt) usize {
    var n: usize = 0;
    for (stmts) |*s| {
        if (s.kind != .comment) n += 1;
        n += bodyCount(s.body);
    }
    return n;
}

/// `st` cannot be written here: reported, with the dialects that can,
/// and in the output as a comment with what it holds. `also`: what more
/// there is to the reason, as the end of its sentence.
pub fn unsupported(w: *Writer, a: Allocator, st: *const ir.Stmt, also: []const u8) Error!void {
    // A comment is always written.
    assert(st.kind != .comment);
    const held = bodyCount(st.body);
    const after = if (held == 0)
        ""
    else
        try a.print(". The {d} statement{s} it holds {s} not written either, and {s} in " ++
            "the output as comments", .{
            held,
            if (held == 1)
                ""
            else
                "s",
            if (held == 1) "is" else "are",
            if (held == 1) "is" else "are",
        });
    const who = w.supporters(st.kind);
    const what = switch (schema.info(st.kind).class) {
        .analysis => "analysis",
        .device => "device",
        else => "statement",
    };
    const reason = try absentReason(w, a, st.kind);
    w.report.add(.@"error", .unsupported, st.line, "{s} '{s}' cannot be written for {s}: " ++
        "{s}{s}. Dialects that define it: {s}{s}", .{
        what,  @tagName(st.kind), w.g.name, reason, also,
        if (who.len > 0)
            who
        else
            "none",
        after,
    });
    try output.comment(
        w,
        try a.print(
            "[sprack] not written: {s} '{s}' has no {s} form",
            .{ what, @tagName(st.kind), w.g.name },
        ),
    );
    try bodyComments(w, a, st.body);
}

// ---- private ----

/// Why the target has no rule for `kind`: its grammar's reason, the kind
/// it says it as, or that it defines none.
fn absentReason(w: *Writer, a: Allocator, kind: Kind) Allocator.Error![]const u8 {
    return w.g.absentReason(kind) orelse if (w.g.movedTo(kind)) |mv|
        try a.print("{s} says it as {s}.{s}, and this netlist has no {s}", .{
            w.g.name,
            @tagName(mv.to),
            schema.info(mv.to).slots[mv.to_slot].name,
            @tagName(mv.to),
        })
    else
        try a.print("{s}.spgrammar defines no rule for it", .{w.g.name});
}

/// One statement of a block not written, as a comment: an opaque one line
/// by line, a control command by its words, any other by its kind and name.
fn notWritten(w: *Writer, a: Allocator, s: *const ir.Stmt) Error!void {
    // `bodyComments` passes comments by.
    assert(s.kind != .comment);
    if (s.kind == .@"opaque") {
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, s.raw, "\n"), '\n');
        while (it.next()) |l|
            try output.comment(w, try a.print("[sprack] not written: {s}", .{l}));
        return;
    }
    if (s.kind == .simctl) {
        const args: []const u8 = switch (s.get("args")) {
            .atom, .str, .expr => |x| x,
            else => "",
        };
        const cmd = if (s.get("cmd") == .atom) s.get("cmd").atom else "";
        const blank = if (args.len > 0) " " else "";
        return output.comment(w, try a.print("[sprack] not written: {s}{s}{s}", .{
            cmd, blank, args,
        }));
    }
    const name = s.get("name");
    const blank = if (name == .atom) " " else "";
    const said = if (name == .atom) name.atom else "";
    try output.comment(w, try a.print("[sprack] not written: {s}{s}{s}", .{
        @tagName(s.kind), blank, said,
    }));
}
