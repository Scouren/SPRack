//! What is said once a file, after its last statement: the instance that
//! gives parameters to another file's subcircuit, the cards copied by name,
//! the lines kept as text, the parameters refused and the subcircuits whose
//! inner parameters were hoisted or kept.

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

/// After the last statement: an instance whose subcircuit may be
/// written once for each branch in its own file, said once.
pub fn foreignNote(w: *Writer) void {
    const x = w.foreign_inst orelse return;
    w.report.add(.warning, .ambiguous, x.line, "instance '{s}' gives parameters to " ++
        "subcircuit '{s}', which is not in this file; {s} has no conditional blocks, so a " ++
        "subcircuit that holds one is written once for each branch, and which one this " ++
        "instance names can only be told with the library: translate the two together " ++
        "(`sprack project`, or a PDK)", .{
        x.name, x.master, w.g.name,
    });
}

/// After the last statement: the lines written back as text, said once.
pub fn keptNote(w: *Writer) void {
    if (w.kept.n == 0) return;
    w.report.add(.info, .oneway, w.kept.line, "{d} statement{s} no {s} rule understood " ++
        "{s} written back as {s}, from this line on; {s} itself may refuse {s}, and they " ++
        "read back as text (`sprack audit` counts them)", .{
        w.kept.n,
        if (w.kept.n == 1)
            ""
        else
            "s",
        w.g.name,
        if (w.kept.n == 1) "is" else "are",
        if (w.kept.n == 1) "it was" else "they were",
        w.g.name,
        if (w.kept.n == 1) "it" else "them",
    });
}

/// After the last statement: the model cards whose parameters were
/// copied by name, said once, naming the first.
pub fn copiedNote(w: *Writer) void {
    const cp = w.copied;
    const g = w.g;
    if (cp.n == 1) {
        w.report.add(.warning, .caveat, cp.line, "model '{s}' ({s}): {s} and {s} ship " ++
            "different implementations and versions of this model; parameters were copied " ++
            "as written, check them against {s}", .{
            cp.name, cp.family, cp.source, g.name, g.name,
        });
    } else if (cp.n > 1) {
        w.report.add(.warning, .caveat, cp.line, "model '{s}' ({s}) and {d} more model " ++
            "cards: {s} and {s} ship different implementations and versions of these " ++
            "models; parameters were copied as written, check them against {s}", .{
            cp.name, cp.family, cp.n - 1, cp.source, g.name, g.name,
        });
    }
}

/// After the last statement: what `refused` gathered, one entry a rule.
/// A loss, so that the cards reading back without the parameter is explained.
pub fn refusals(w: *Writer) void {
    for (w.refused.keys(), w.refused.values()) |np, r| {
        if (r.n == 1) {
            w.report.add(
                .warning,
                .loss,
                r.line,
                "model '{s}': {s} not written: {s}",
                .{ r.name, np.key, np.text },
            );
        } else {
            w.report.add(
                .warning,
                .loss,
                r.line,
                "model '{s}' and {d} more card{s} in this file: {s} not written: {s}",
                .{ r.name, r.n - 1, if (r.n == 2) "" else "s", np.key, np.text },
            );
        }
    }
    var buf: [48]u8 = undefined;
    const hs = w.hoisted;
    if (hs.n > 0)
        w.report.add(.info, .oneway, hs.line, "subckt '{s}'{s}: the parameters defined " ++
            "inside are written on the header, which reads back there; {s} gives an " ++
            "instance's value to that instance alone only for a parameter of the header", .{
            hs.name,
            if (hs.n > 1)
                std.fmt.bufPrint(
                    &buf,
                    " and {d} more in this file",
                    .{hs.n - 1},
                ) catch unreachable
            else
                "",
            w.g.name,
        });
    const us = w.unhoisted;
    if (us.n > 0)
        w.report.add(.warning, .ambiguous, us.line, "subckt '{s}'{s}: the parameters " ++
            "defined inside are written as they were; {s} gives an instance's value to " ++
            "that instance alone only for a parameter of the header, and what {s} does " ++
            "with one defined inside is not measured", .{
            us.name,
            if (us.n > 1)
                std.fmt.bufPrint(
                    &buf,
                    " and {d} more in this file",
                    .{us.n - 1},
                ) catch unreachable
            else
                "",
            w.g.name,
            us.source,
        });
}
