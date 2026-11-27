//! The IR as JSON, in both directions.
//!
//! This is how programs other than the translator get at a netlist: the
//! Python package builds a circuit as a list of statements in this form and
//! hands it to a writer, and `sprack read` prints any netlist in it.
//!
//!     {"title": "...", "dialect": "ngspice", "stmts": [
//!        {"kind": "resistor", "name": "R1", "pos": "a", "neg": "0", "r": "1e3"},
//!        {"kind": "subckt", "name": "inv", "ports": ["in", "out"], "body": [...]}]}
//!
//! A value is a string: a number (`"1.5e-12"`, or with a scale suffix
//! `"10n"`), otherwise an expression in the canonical spelling. `{"str": s}`
//! is a quoted string, a list is an array, parameters are an object, and a
//! flag without a value is `null`.
//!
//! In a slot that holds a name the string is the name. In one that holds a
//! signal it is the signal (`"v(out)"`), or an expression recorded as one
//! if it is not in that form (`"-i(vc)"`). A dotted version (`"3.3.0"`) is a
//! word, not arithmetic.
//!
//! Reading the JSON `writeNetlist` wrote gives the statements it was given.
//! So what a plain string would not read back as is written tagged:
//! `{"raw": s}` is a word kept as written where a value stands,
//! `{"expr": s}` an expression a plain string would not be (`{13}`, which
//! looks like a number), and parameters that repeat a key are an array of
//! `[key, value]` pairs.
//!
//! Writing is `json_write.zig`, reading `json_read.zig`.
//!
//! Contents:
//! - `pub const writeNetlist`, `pub const writeEnv`, `pub const writeReport`,
//!   `pub const writeInfo` (`json_write.zig`)
//! - `pub const number_cfg`, `pub const parseNetlist`, `pub const parseDocument`
//!   (`json_read.zig`)

const std = @import("std");
const ir = @import("ir");
const json_write = @import("json_write.zig");
const json_read = @import("json_read.zig");

pub const number_cfg = json_read.number_cfg;
pub const writeNetlist = json_write.writeNetlist;
pub const writeEnv = json_write.writeEnv;
pub const writeReport = json_write.writeReport;
pub const writeInfo = json_write.writeInfo;
pub const parseNetlist = json_read.parseNetlist;
pub const parseDocument = json_read.parseDocument;

test "IR to JSON and back" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const text =
        \\{"title":"t","stmts":[
        \\ {"kind":"resistor","name":"R1","pos":"a","neg":0,"r":"4.7k","params":{"tc1":"1m","noisy":null}},
        \\ {"kind":"tran","step":"10p","stop":2e-8,"skip_dc":true},
        \\ {"kind":"subckt","name":"x","ports":["a","b"],"params":{"w":"2*wmin"},"body":[
        \\   {"kind":"capacitor","name":"C1","pos":"a","neg":"b","c":"1p"}]}]}
    ;
    const nl = try parseNetlist(a, text, &report);
    try std.testing.expectEqual(0, report.items.items.len);
    try std.testing.expectEqual(3, nl.stmts.len);
    try std.testing.expectEqualStrings("4.7", nl.stmts[0].get("r").num.digits());
    try std.testing.expectEqual(@as(i32, 3), nl.stmts[0].get("r").num.exp10);
    try std.testing.expectEqualStrings("0", nl.stmts[0].get("neg").atom);
    try std.testing.expectEqualStrings("yes", nl.stmts[1].get("skip_dc").atom);
    try std.testing.expectEqualStrings("2*wmin", nl.stmts[2].get("params").params[0].val.expr);

    var aw: std.Io.Writer.Allocating = .init(a);
    try writeNetlist(&aw.writer, &nl);
    const again = try parseNetlist(a, aw.written(), &report);
    try std.testing.expect(ir.sameCircuit(&nl, &again));

    // The one trap in the number notation is refused, not guessed.
    var r2: ir.Report = .init(a);
    _ = try parseNetlist(
        a,
        "{\"stmts\":[{\"kind\":\"resistor\",\"name\":\"R1\",\"pos\":\"a\",\"neg\":\"0\",\"r\":\"1M\"}]}",
        &r2,
    );
    try std.testing.expect(r2.contains(.@"error", "'1M' is ambiguous"));
    var r3: ir.Report = .init(a);
    _ = try parseNetlist(
        a,
        "{\"stmts\":[{\"kind\":\"resistor\",\"nmae\":\"R1\"},{\"kind\":\"zener\"}]}",
        &r3,
    );
    try std.testing.expect(
        r3.contains(.@"error", "'resistor' has no 'nmae'; it has: name pos neg r master params"),
    );
    try std.testing.expect(r3.contains(.@"error", "unknown statement kind 'zener'"));
}
