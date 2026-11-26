//! A statement the target cannot write: the report entry that says why,
//! and the statement and what it holds in the output as comments.

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
pub fn bodyComments(w: *Writer, a: Allocator, stmts: []const ir.Stmt) Error!void {
    for (stmts) |*s| {
        if (s.kind == .comment) continue;
        if (s.kind == .@"opaque") {
            var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, s.raw, "\n"), '\n');
            while (it.next()) |l| try output.comment(w, try a.print("[sprack] not written: {s}", .{l}));
        } else {
            if (s.kind == .simctl) {
                const args: []const u8 = switch (s.get("args")) {
                    .atom, .str, .expr => |x| x,
                    else => "",
                };
                try output.comment(
                    w,
                    try a.print("[sprack] not written: {s}{s}{s}", .{ if (s.get("cmd") == .atom)
                        s.get("cmd").atom
                    else
                        "", if (args.len > 0) " " else "", args }),
                );
                continue;
            }
            const name = s.get("name");
            try output.comment(
                w,
                try a.print(
                    "[sprack] not written: {s}{s}{s}",
                    .{ @tagName(s.kind), if (name == .atom)
                        " "
                    else
                        "", if (name == .atom) name.atom else "" },
                ),
            );
        }
        try bodyComments(w, a, s.body);
    }
}

/// `also`: what more there is to the reason, as the end of its sentence.
/// The statements a block holds, at any depth, comments aside.
pub fn bodyCount(stmts: []const ir.Stmt) usize {
    var n: usize = 0;
    for (stmts) |*s| {
        if (s.kind != .comment) n += 1;
        n += bodyCount(s.body);
    }
    return n;
}

pub fn unsupported(w: *Writer, a: Allocator, st: *const ir.Stmt, also: []const u8) Error!void {
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
    const reason = w.g.absentReason(st.kind) orelse if (w.g.movedTo(st.kind)) |mv|
        try a.print("{s} says it as {s}.{s}, and this netlist has no {s}", .{
            w.g.name, @tagName(mv.to), schema.info(mv.to).slots[mv.to_slot].name, @tagName(mv.to),
        })
    else
        try a.print("{s}.spgrammar defines no rule for it", .{w.g.name});
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
