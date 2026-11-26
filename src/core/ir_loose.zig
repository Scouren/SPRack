//! Loose equality of two netlists: the same circuit and the same analyses,
//! whatever their comments, labels, blanks and the order of their groups.
//!
//! Contents:
//! - `pub fn looseListEql(a: []const Stmt, b: []const Stmt) bool`
//! - `pub fn sameCircuit(a: *const Netlist, b: *const Netlist) bool`

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir.zig");
const Kind = ir.Kind;
const Netlist = ir.Netlist;
const Stmt = ir.Stmt;
const Value = ir.Value;

const Group = enum { circuit, analysis, control, options, skip };

/// Analyses and control statements may sit anywhere among the devices
/// (VACASK keeps them in a block at the end): compare each group in its
/// own order.
pub fn looseListEql(a: []const Stmt, b: []const Stmt) bool {
    inline for (.{ Group.circuit, Group.analysis, Group.control }) |want| {
        var i: usize = 0;
        var j: usize = 0;
        // Until either list has no statement of the group left.
        while (true) {
            while (i < a.len and groupOf(&a[i]) != want) i += 1;
            while (j < b.len and groupOf(&b[j]) != want) j += 1;
            if (i == a.len or j == b.len) {
                if (i != a.len or j != b.len) return false;
                break;
            }
            std.debug.assert(groupOf(&a[i]) == groupOf(&b[j]));
            if (!looseStmtEql(&a[i], &b[j])) return false;
            i += 1;
            j += 1;
        }
    }
    return optionsEql(a, b);
}

/// Same circuit and same analyses. Comments, analysis labels and the
/// position of analyses and control statements are not part of that.
pub fn sameCircuit(a: *const Netlist, b: *const Netlist) bool {
    return looseListEql(a.stmts, b.stmts);
}

// ---- private ----

fn looseVal(s: *const Stmt, i: usize) Value {
    const sl = schema.info(s.kind).slots[i];
    if (schema.info(s.kind).class == .analysis and sl.ty == .name) return .none;
    return s.at(i);
}

/// A long line may be re-wrapped on the way out; blanks are not content.
fn sameWords(a: []const u8, b: []const u8) bool {
    var x = std.mem.tokenizeAny(u8, a, " \t\r\n");
    var y = std.mem.tokenizeAny(u8, b, " \t\r\n");
    // Until either text has no word left.
    while (true) {
        const p = x.next();
        const q = y.next();
        if (p == null or q == null) return p == null and q == null;
        if (!std.mem.eql(u8, p.?, q.?)) return false;
    }
}

/// An instance of a Verilog-A model is a `device` where the dialect marks it
/// (ngspice's N) and a plain `instance` where it does not.
fn looseKind(k: Kind) Kind {
    return if (k == .device) .instance else k;
}

/// Blanks in an expression are not content either: a writer adds them where
/// its dialect needs them (Spectre reads `a!=b` as the name `a!`).
fn sameSquashed(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    // Until either text has no character left.
    while (true) {
        while (i < a.len and (a[i] == ' ' or a[i] == '\t')) i += 1;
        while (j < b.len and (b[j] == ' ' or b[j] == '\t')) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
    }
}

// tidy: allow(recursion) bounded by the nesting of a value's lists, ir.max_depth
fn looseValueEql(a: Value, b: Value) bool {
    if (a == .expr and b == .expr) return sameSquashed(a.expr, b.expr);
    if (a == .list and b == .list) {
        if (a.list.len != b.list.len) return false;
        for (a.list, b.list) |x, y| if (!looseValueEql(x, y)) return false;
        return true;
    }
    if (a == .params and b == .params) {
        if (a.params.len != b.params.len) return false;
        for (a.params, b.params) |x, y|
            if (!std.mem.eql(u8, x.key, y.key) or !looseValueEql(x.val, y.val)) return false;
        return true;
    }
    return a.eql(b);
}

fn looseStmtEql(a: *const Stmt, b: *const Stmt) bool {
    if (looseKind(a.kind) != looseKind(b.kind)) return false;
    if (a.kind == .@"opaque" and !sameWords(a.raw, b.raw)) return false;
    for (0..schema.info(a.kind).slots.len) |i|
        if (!looseValueEql(looseVal(a, i), looseVal(b, i))) return false;
    return looseListEql(a.body, b.body);
}

fn groupOf(s: *const Stmt) Group {
    if (s.kind == .comment) return .skip;
    if (s.kind == .options) return .options;
    return switch (schema.info(s.kind).class) {
        .analysis => .analysis,
        .control => .control,
        else => .circuit,
    };
}

/// Options may be split over several statements, or filed under headings,
/// without meaning anything different: compare what they add up to.
fn optionsEql(a: []const Stmt, b: []const Stmt) bool {
    const slots = schema.info(.options).slots;
    const package = schema.slot(.options, "package");
    std.debug.assert(package < slots.len);
    for (slots, 0..) |sl, i| {
        if (i == package) continue;
        if (sl.ty == .params) {
            if (!paramsEql(a, b, i)) return false;
            continue;
        }
        var va: Value = .none;
        var vb: Value = .none;
        for (a) |*s| if (s.kind == .options and s.at(i) != .none) {
            va = s.at(i);
        };
        for (b) |*s| if (s.kind == .options and s.at(i) != .none) {
            vb = s.at(i);
        };
        if (!va.eql(vb)) return false;
    }
    return true;
}

/// The parameters in slot `i` of every options statement of `a` and of `b`,
/// one after another, are the same.
fn paramsEql(a: []const Stmt, b: []const Stmt, i: usize) bool {
    var ia: usize = 0;
    var ib: usize = 0;
    var pa: usize = 0;
    var pb: usize = 0;
    // Until either list has no parameter left.
    while (true) {
        while (ia < a.len and !hasParam(&a[ia], i, pa)) : (pa = 0) ia += 1;
        while (ib < b.len and !hasParam(&b[ib], i, pb)) : (pb = 0) ib += 1;
        if (ia == a.len or ib == b.len) return ia == a.len and ib == b.len;
        std.debug.assert(pa < a[ia].at(i).params.len);
        std.debug.assert(pb < b[ib].at(i).params.len);
        const x = a[ia].at(i).params[pa];
        const y = b[ib].at(i).params[pb];
        if (!std.mem.eql(u8, x.key, y.key) or !x.val.eql(y.val)) return false;
        pa += 1;
        pb += 1;
    }
}

/// `s` is an options statement with a parameter `p` in slot `i`.
fn hasParam(s: *const Stmt, i: usize, p: usize) bool {
    return s.kind == .options and s.at(i) == .params and p < s.at(i).params.len;
}

test "the same circuit: blanks in an expression are not content, anything else is" {
    try std.testing.expect(sameSquashed("(a<b) && (a!=b)", "(a<b)&&(a != b)"));
    try std.testing.expect(sameSquashed("", " \t"));
    try std.testing.expect(!sameSquashed("a!=b", "a==b"));
    try std.testing.expect(!sameSquashed("a b", "a"));
    const x: Value = .{
        .params = &.{.{ .key = "t", .val = .{ .list = &.{.{ .expr = "a != b" }} } }},
    };
    const y: Value = .{
        .params = &.{.{ .key = "t", .val = .{ .list = &.{.{ .expr = "a!=b" }} } }},
    };
    try std.testing.expect(looseValueEql(x, y) and !x.eql(y));
    // Only an expression: a name, a string or a key with a blank is another.
    try std.testing.expect(!looseValueEql(.{ .atom = "a b" }, .{ .atom = "ab" }));
    try std.testing.expect(!looseValueEql(.{ .expr = "a" }, .{ .atom = "a" }));
}
