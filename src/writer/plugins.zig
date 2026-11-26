//! Compiled modules: a Verilog-A model where the target takes its module
//! only as a plugin (the `plugin` block of its grammar). The model card and
//! the instance are written as the plugin has them, with what it has no
//! place for left out and said; without a plugin given to the translation,
//! the error says how to get one.
//!
//! Contents:
//! - `pub const WithModule = union(enum)`
//! - `pub fn pluginText(w: *const Writer, a: Allocator, comptime which: enum`
//! - `pub fn needsPlugin(w: *const Writer, module: []const u8) bool`
//! - `pub fn providedFile(w: *const Writer, name: []const u8) ?[]const u8`
//! - `pub fn pluginDrops(w: *Writer, a: Allocator, st: *const ir.Stmt, module: []const u8,
//!   card: bool) Allocator.Error!?ir.Stmt`
//! - `pub fn withModule(w: *Writer, st: *const ir.Stmt) Error!WithModule`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const tables = @import("tables.zig");
const statement = @import("statement.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Value = ir.Value;
const Writer = statement.Writer;
const Error = Writer.Error;

/// What `withModule` made of an instance: left as it is, already said
/// and not to be written, or to be written as this statement.
pub const WithModule = union(enum) { keep, done, stmt: ir.Stmt };

/// A line of the target's `plugin` block, for the module `module`
/// (and, for `given`, the plugin `file` of it).
pub fn pluginText(
    w: *const Writer,
    a: Allocator,
    comptime which: enum { missing, given },
    module: []const u8,
    file: []const u8,
) Allocator.Error![]const u8 {
    const pl = w.g.plugin.?;
    const text = if (which == .missing) pl.missing else pl.given;
    const vars = [_][2][]const u8{
        .{ "{to}", w.g.name }, .{ "{module}", module }, .{ "{file}", file },
    };
    return tables.filled(a, text, &vars);
}

/// Does this dialect take a module only as a plugin, and has no plugin
/// of this one been given to the translation?
pub fn needsPlugin(w: *const Writer, module: []const u8) bool {
    if (w.g.plugin == null) return false;
    return providedFile(w, module) == null;
}

/// The file given to the translation under this name (`--provide`).
pub fn providedFile(w: *const Writer, name: []const u8) ?[]const u8 {
    const given: []const [2][]const u8 = if (w.env) |e| e.provided else &.{};
    for (given) |p| if (std.ascii.eqlIgnoreCase(p[0], name)) return p[1];
    return null;
}

/// `st`, the model card (`card`) or the instance of the plugin of
/// `module`, without the parameters the target's `plugin` block says a
/// plugin has no place for, each reported unless it is given at the
/// value the plugin behaves as having. Null: it gives none of them.
pub fn pluginDrops(
    w: *Writer,
    a: Allocator,
    st: *const ir.Stmt,
    module: []const u8,
    card: bool,
) Allocator.Error!?ir.Stmt {
    assert(module.len > 0);
    const pl = w.g.plugin.?;
    const pi = schema.slotOf(st.kind, "params").?;
    var out: ?ir.Stmt = null;
    for (pl.drops) |drop| {
        if (drop.card != card) continue;
        const cur = if (out) |*o| o else st;
        if (cur.at(pi) != .params) break;
        const ps = cur.at(pi).params;
        const i = for (ps, 0..) |p, i| {
            if (std.ascii.eqlIgnoreCase(p.key, drop.key)) break i;
        } else continue;
        if (!neutral(drop, ps[i].val)) try reportDrop(w, a, st, drop, ps[i].val, module);
        var next = cur.*;
        try next.own(a);
        const rest = try std.mem.concat(a, ir.Param, &.{ ps[0..i], ps[i + 1 ..] });
        try next.set(a, pi, if (rest.len > 0) .{ .params = rest } else .none);
        out = next;
    }
    return out;
}

/// A Verilog-A instance where the target takes its module as a plugin
/// and names it on the instance (`plugin`): the instance with the
/// module of its model card, if a plugin of it was given to the
/// translation (`ir.Env.provided`); else an error that says how to get
/// one. `keep`: written as it is.
pub fn withModule(w: *Writer, st: *const ir.Stmt) Error!WithModule {
    const mi = schema.slot(.device, "module");
    assert(st.kind == .device);
    // An instance that names its module is written as it is.
    assert(st.at(mi) == .none);
    if (w.g.plugin == null) return .keep;
    const master = if (st.get("master") == .atom) st.get("master").atom else return .keep;
    const module = w.modules.get(master) orelse (if (w.env) |e|
        e.modules.get(master)
    else
        null) orelse return .keep;
    const file = providedFile(w, module) orelse {
        w.report.add(
            .@"error",
            .unsupported,
            st.line,
            "device: {s} instantiates the Verilog-A module '{s}' only through a plugin of " ++
                "it: {s}",
            .{ w.g.name, module, try pluginText(w, w.arena, .missing, module, "") },
        );
        try w.comment(
            try w.arena.print("[sprack] not written: {s}", .{if (st.get("name") == .atom)
                st.get("name").atom
            else
                "device"}),
        );
        return .done;
    };
    if (w.plugins_said.get(module) == null) {
        try w.plugins_said.put(w.perm, try w.perm.dupe(u8, module), {});
        w.report.add(
            .warning,
            .caveat,
            st.line,
            "device: the Verilog-A module '{s}' is the plugin {s}: {s}",
            .{ module, file, try pluginText(w, w.arena, .given, module, file) },
        );
    }
    var d = st.*;
    try d.own(w.arena);
    try d.set(w.arena, mi, .{ .atom = module });
    if (try pluginDrops(w, w.arena, &d, module, false)) |without| return .{ .stmt = without };
    return .{ .stmt = d };
}

// ---- private ----

/// Is `v` the value a plugin behaves as having for `drop`'s parameter?
fn neutral(drop: grammar.Plugin.Drop, v: Value) bool {
    if (drop.neutral.len == 0 or v != .num) return false;
    // The grammar compiler took only a number; a text that is none is
    // the value of no parameter.
    const same = std.fmt.parseFloat(f64, drop.neutral) catch return false;
    return v.num.toFloat() == same;
}

fn reportDrop(
    w: *Writer,
    a: Allocator,
    st: *const ir.Stmt,
    drop: grammar.Plugin.Drop,
    v: Value,
    module: []const u8,
) Allocator.Error!void {
    const vars = [_][2][]const u8{ .{ "{to}", w.g.name }, .{ "{module}", module } };
    const why = try tables.filled(a, drop.text, &vars);
    const sev: ir.Severity = if (drop.err) .@"error" else .warning;
    if (drop.card) {
        w.report.add(sev, .loss, st.line, "model '{s}': {s} not written: {s}", .{
            st.get("name").atom, drop.key, why,
        });
    } else {
        var em = w.emitter(a, st);
        w.report.add(sev, .loss, st.line, "device: '{s}={s}' not written: {s}", .{
            drop.key, try em.describe(v), why,
        });
    }
}
