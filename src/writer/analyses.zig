//! Analyses and options: the statements of a netlist → the same statements
//! with what the target says another way said that way: a pole-zero
//! analysis by its ports or by its source, an integration order the target
//! has no place for, a step ceiling that limits nothing, and the options
//! the source assumes where the target assumes others.
//!
//! Each function is a pass of the writer (`root.zig` runs them in order):
//! statements in, statements or report entries out.

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const dialects = @import("dialects");
const expr = @import("expr");
const lexer = @import("lexer");
const reader = @import("reader");
const tables = @import("tables.zig");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Kind = schema.Kind;
const Value = ir.Value;
const idleCeiling = tables.idleCeiling;
const describeValue = tables.describeValue;
const Node = grammar.Node;

/// Is there a statement a `convert` line applies to? Copying a large
/// netlist's statement list to convert none of it costs its size again.
pub fn anyConverted(g: *const Grammar, stmts: []const ir.Stmt) bool {
    for (stmts) |*s| {
        for (g.converts) |cv| if (cv.kind == s.kind) return true;
        if (anyConverted(g, s.body)) return true;
    }
    return false;
}

pub fn mentions(nodes: []const Node, slot: u8) bool {
    for (nodes) |n| {
        if (n.slot == slot or mentions(n.kids, slot)) return true;
        for (n.bag) |b| if (b.slot == slot or b.slot2 == slot) return true;
    }
    return false;
}

/// A `.tran` step ceiling at or above the stop time limits nothing, and in
/// HSPICE a fourth number above the stop is a second segment: not written.
pub fn idleCeilings(
    arena: Allocator,
    stmts: []const ir.Stmt,
    report: *ir.Report,
) Allocator.Error![]const ir.Stmt {
    const mi = schema.slot(.tran, "maxstep");
    var list: ?[]ir.Stmt = null;
    for (stmts, 0..) |*st, k| {
        if (!idleCeiling(st, mi, st.at(mi))) continue;
        const l = list orelse blk: {
            list = try arena.dupe(ir.Stmt, stmts);
            break :blk list.?;
        };
        try l[k].own(arena);
        try l[k].set(arena, mi, .none);
        report.add(
            .info,
            .oneway,
            st.line,
            "tran.maxstep at or above the stop time limits nothing and is not written; it " ++
                "reads back without one",
            .{},
        );
    }
    return list orelse stmts;
}

/// A maximum order of integration where the target has no option for it
/// (Spectre): 1 is backward Euler, the method `euler`; 2 or more changes
/// nothing beside the methods the target has (gear is order 2 there, and
/// ngspice's gear of order 3 to 6 is measured to change nothing,
/// docs/verification.md). Said as an info either way.
pub fn foldMaxord(
    arena: Allocator,
    g: *const Grammar,
    stmts: []const ir.Stmt,
    report: *ir.Report,
) Allocator.Error![]const ir.Stmt {
    const mo = schema.slot(.options, "maxord");
    const me = schema.slot(.options, "method");
    for (g.rules) |r|
        if (r.kind == .options and r.dir != .read and mentions(r.pat, mo)) return stmts;
    var list: ?[]ir.Stmt = null;
    for (stmts, 0..) |*st, k| {
        if (st.kind != .options or st.at(mo) != .num) continue;
        const n = st.at(mo).num.toFloat();
        if (n != @floor(n) or n < 1) continue;
        const l = list orelse blk: {
            list = try arena.dupe(ir.Stmt, stmts);
            break :blk list.?;
        };
        try l[k].own(arena);
        try l[k].set(arena, mo, .none);
        if (n == 1) {
            try l[k].set(arena, me, .{ .atom = "euler" });
            report.add(
                .info,
                .oneway,
                st.line,
                "options.maxord = 1 is backward Euler: {s} has no maximum order, so it is " ++
                    "written as the method euler",
                .{g.name},
            );
        } else report.add(.info, .loss, st.line, "options.maxord = {d} is not written: {s} " ++
            "has no maximum order, and its methods are of order 2 at most, which a maximum of " ++
            "2 or more leaves as they are", .{ @as(u32, @intFromFloat(n)), g.name });
    }
    return list orelse stmts;
}

/// A netlist built with no dialect of its own on a PDK (`ir.Netlist.defaults`)
/// that sets no temperature, written for a target whose defaults differ
/// from the PDK simulator's (HSPICE's 25 against 27 elsewhere): an error,
/// since the result then depends on the simulator that runs it. Nothing is
/// written for it. A netlist read in a dialect gets that dialect's defaults
/// written instead (`defaultOptions`).
pub fn reportDefaults(
    arena: Allocator,
    g: *const Grammar,
    nl: *const ir.Netlist,
    report: *ir.Report,
) Allocator.Error!void {
    if (nl.defaults.len == 0) return;
    var as = nl.*;
    as.dialect = nl.defaults;
    const d = try defaultOptions(arena, g, &as) orelse return;
    const sg = dialects.find(nl.defaults) orelse return;
    var keys: std.ArrayList(u8) = .empty;
    var said: std.ArrayList(u8) = .empty;
    var theirs: std.ArrayList(u8) = .empty;
    for (schema.info(.options).slots, 0..) |sl, i| if (d.at(i) != .none) {
        const first = said.items.len == 0;
        try keys.print(arena, "{s}{s}", .{ if (first) "" else " or ", sl.name });
        try said.print(arena, "{s}{s}={s}", .{ if (first)
            ""
        else
            ", ", sl.name, try describeValue(arena, d.at(i)) });
        const have = impliedValue(arena, g, sg, nl.stmts, @intCast(i), 0);
        try theirs.print(arena, "{s}{s}={s}", .{ if (first)
            ""
        else
            ", ", sl.name, if (have) |h| try describeValue(arena, h) else "its own" });
    };
    report.add(.@"error", .ambiguous, 0, "options: the circuit sets no {s}; its PDK's " ++
        "simulator ({s}) assumes {s} and {s} assumes {s}, so the result depends on the " ++
        "simulator that runs it: set them in the circuit", .{
        keys.items, nl.defaults, said.items, g.name, theirs.items,
    });
}

/// A pole-zero analysis names its input either as a source (HSPICE `.pz
/// v(out) vin`, Spectre's iprobe=) or as a node pair with `vol` or `cur`
/// (SPICE), and its output either as a signal (HSPICE) or as a node pair
/// (SPICE, Spectre). Each half is put in the form `g` writes. A source's
/// nodes are the input pair, `vol` for a voltage source and `cur` for a
/// current source; a node pair is the one source of that kind across it.
/// A signal-form dialect (HSPICE) takes the poles and zeros of the first
/// node of v(a,b) only: measured, docs/verification.md.
pub fn pzPorts(
    arena: Allocator,
    g: *const Grammar,
    origin: tables.Origin,
    stmts: []const ir.Stmt,
    report: *ir.Report,
) Allocator.Error![]const ir.Stmt {
    const src_i = schema.slot(.pz, "src");
    const out_i = schema.slot(.pz, "out");
    const ip_i = schema.slot(.pz, "in_pos");
    const in_i = schema.slot(.pz, "in_neg");
    const op_i = schema.slot(.pz, "out_pos");
    const on_i = schema.slot(.pz, "out_neg");
    const tr_i = schema.slot(.pz, "transfer");
    const fi_i = schema.slot(.pz, "find");
    const form = pzForm(g);
    if (!form.writes) return stmts;
    const by_src, const by_sig = .{ form.by_src, form.by_sig };
    var list: ?[]ir.Stmt = null;
    for (stmts, 0..) |*st, k| {
        if (st.kind != .pz) continue;
        const has_src = st.at(src_i) == .atom;
        const has_sig = st.at(out_i) != .none;
        const in_nodes = st.at(ip_i) == .atom and st.at(in_i) == .atom and st.at(tr_i) == .atom;
        const out_nodes = st.at(op_i) == .atom and st.at(on_i) == .atom;
        const move_in = (has_src and !by_src) or (!has_src and by_src and in_nodes);
        const move_out = (has_sig and !by_sig) or (!has_sig and by_sig and out_nodes);
        if (!move_in and !move_out) continue;

        // The source for a node pair, or the node pair of a source.
        var dev: ?*const ir.Stmt = null;
        if (move_in and has_src) {
            const name = st.at(src_i).atom;
            dev = for (stmts) |*d| {
                if ((d.kind == .vsource or d.kind == .isource) and d.get("name") == .atom and
                    std.ascii.eqlIgnoreCase(
                        d.get("name").atom,
                        name,
                    )) break d;
            } else {
                report.add(
                    .@"error",
                    .unsupported,
                    st.line,
                    "pz: {s} names the input by its nodes, and no voltage or current source " ++
                        "'{s}' is in this file to take them from",
                    .{ g.name, name },
                );
                continue;
            };
        } else if (move_in) {
            const p, const n = .{ st.at(ip_i).atom, st.at(in_i).atom };
            const tr = st.at(tr_i).atom;
            const want: schema.Kind = if (std.ascii.eqlIgnoreCase(tr, "cur"))
                .isource
            else
                .vsource;
            var hits: usize = 0;
            for (stmts) |*d| {
                if (d.kind != want or d.get("name") != .atom or d.get("pos") != .atom or
                    d.get("neg") != .atom)
                    continue;
                const dp, const dn = .{ d.get("pos").atom, d.get("neg").atom };
                const fwd = std.ascii.eqlIgnoreCase(dp, p) and std.ascii.eqlIgnoreCase(dn, n);
                const rev = std.ascii.eqlIgnoreCase(dp, n) and std.ascii.eqlIgnoreCase(dn, p);
                if (!fwd and !rev) continue;
                hits += 1;
                dev = d;
            }
            if (hits != 1) {
                report.add(.@"error", .unsupported, st.line, "pz: {s} names the input by its " ++
                    "source, and {s} {s} sources connect nodes {s} and {s} ({s} input); it " ++
                    "takes exactly one", .{
                    g.name,
                    if (hits == 0)
                        "no"
                    else
                        "several",
                    if (want == .vsource) "voltage" else "current",
                    p,
                    n,
                    tr,
                });
                continue;
            }
        }
        var args: [3][]const u8 = undefined;
        var n_args: usize = 0;
        var out_text: []const u8 = "";
        if (move_out and has_sig) {
            const text: ?[]const u8 = switch (st.at(out_i)) {
                .expr, .atom, .str => |x| x,
                else => null,
            };
            out_text = text orelse "";
            const sform, n_args = (if (text) |t|
                reader.signalParts(t, &args)
            else
                null) orelse .{ "", 0 };
            if (!(std.mem.eql(u8, sform, "v") or std.mem.eql(u8, sform, "vdiff")) or n_args == 0) {
                report.add(
                    .@"error",
                    .unsupported,
                    st.line,
                    "pz: {s} names the output by its nodes; the output here is not a node voltage",
                    .{g.name},
                );
                continue;
            }
        } else if (move_out and !std.mem.eql(u8, st.at(on_i).atom, "0")) {
            report.add(.@"error", .unsupported, st.line, "pz: {s} takes the poles and zeros " ++
                "of v({s}) alone for v({s},{s}), so the differential output has no {s} form", .{
                g.name, st.at(op_i).atom, st.at(op_i).atom, st.at(on_i).atom, g.name,
            });
            continue;
        }
        if (n_args == 2 and !std.mem.eql(u8, args[1], "0"))
            if (origin.grammarOf(st)) |sg| if (pzForm(sg).by_sig) {
                report.add(.warning, .caveat, st.line, "pz: {s} took the poles and zeros of " ++
                    "v({s}) alone for v({s},{s}); {s} finds those of the difference", .{
                    sg.name, args[0], args[0], args[1], g.name,
                });
            };

        const l = list orelse blk: {
            list = try arena.dupe(ir.Stmt, stmts);
            break :blk list.?;
        };
        const p = &l[k];
        try p.own(arena);
        if (move_in and has_src) {
            const d = dev.?;
            try p.set(arena, ip_i, d.get("pos"));
            try p.set(arena, in_i, d.get("neg"));
            try p.set(arena, tr_i, .{ .atom = if (d.kind == .vsource) "vol" else "cur" });
            try p.set(arena, fi_i, .{ .atom = "pz" });
            try p.set(arena, src_i, .none);
            report.add(
                .info,
                .oneway,
                st.line,
                "pz: the input is source {s}'s nodes, as {s} names it",
                .{ d.get("name").atom, g.name },
            );
        } else if (move_in) {
            const d = dev.?;
            const find = st.at(fi_i);
            if (find == .atom and !std.ascii.eqlIgnoreCase(find.atom, "pz")) {
                report.add(.warning, .caveat, st.line, "pz: {s} finds both poles and zeros; " ++
                    "only the {s} were asked for", .{
                    g.name, if (std.ascii.eqlIgnoreCase(find.atom, "pol")) "poles" else "zeros",
                });
            }
            if (std.ascii.eqlIgnoreCase(
                d.get("pos").atom,
                st.at(in_i).atom,
            ) and !std.ascii.eqlIgnoreCase(d.get("pos").atom, st.at(ip_i).atom)) {
                report.add(.info, .oneway, st.line, "pz: source {s} is connected from {s} to " ++
                    "{s}, the reverse of the input pair; the transfer function changes sign, " ++
                    "its poles and zeros do not", .{
                    d.get("name").atom, d.get("pos").atom, d.get("neg").atom,
                });
            }
            try p.set(arena, src_i, d.get("name"));
            inline for (.{ ip_i, in_i, tr_i, fi_i }) |i| try p.set(arena, i, .none);
            report.add(
                .info,
                .oneway,
                st.line,
                "pz: the input nodes {s} {s} are source {s}, as {s} names it",
                .{ st.at(ip_i).atom, st.at(in_i).atom, d.get("name").atom, g.name },
            );
        }
        if (move_out and has_sig) {
            try p.set(arena, op_i, .{ .atom = args[0] });
            try p.set(arena, on_i, .{ .atom = if (n_args > 1) args[1] else "0" });
            try p.set(arena, out_i, .none);
            report.add(
                .info,
                .oneway,
                st.line,
                "pz: the output {s} is the node pair {s} {s}, as {s} names it",
                .{ out_text, args[0], if (n_args > 1) args[1] else "0", g.name },
            );
        } else if (move_out) {
            const pos, const neg = .{ st.at(op_i).atom, st.at(on_i).atom };
            const sig = if (std.mem.eql(u8, neg, "0"))
                try std.fmt.allocPrint(arena, "v({s})", .{pos})
            else
                try std.fmt.allocPrint(arena, "v({s},{s})", .{ pos, neg });
            try p.set(arena, out_i, .{ .atom = sig });
            try p.set(arena, op_i, .none);
            try p.set(arena, on_i, .none);
            report.add(
                .info,
                .oneway,
                st.line,
                "pz: the output nodes {s} {s} are the signal {s}, as {s} names it",
                .{ pos, neg, sig, g.name },
            );
        }
    }
    return list orelse stmts;
}

/// An option the netlist itself sets: not one in a body (an `.alter`
/// changes it for its own run only).
pub fn topValue(stmts: []const ir.Stmt, slot: u8) ?Value {
    for (stmts) |*s| if (s.kind == .options and s.at(slot) != .none) return s.at(slot);
    return null;
}

/// An option's value in a netlist of dialect `sg`: the one it sets, else
/// the one `sg` assumes (`implied options tnom = 25`; `$temp` is another
/// option's value).
pub fn optionValue(
    arena: Allocator,
    sg: *const Grammar,
    stmts: []const ir.Stmt,
    slot: u8,
    depth: u8,
) ?Value {
    if (topValue(stmts, slot)) |v| return v;
    return impliedValue(arena, sg, sg, stmts, slot, depth);
}

/// The options the netlist's own dialect assumes and `g` does not (HSPICE's
/// TNOM of 25 against ngspice's 27), as one statement to write at the top;
/// null when there are none. An option set anywhere in the netlist is left
/// to that statement.
// ponytail: an option set only in an included file is not seen here; pass it via ir.Env if that matters.
pub fn defaultOptions(
    arena: Allocator,
    g: *const Grammar,
    nl: *const ir.Netlist,
) Allocator.Error!?ir.Stmt {
    if (nl.library or std.mem.eql(u8, nl.dialect, g.name) or !g.canWrite(.options)) return null;
    const sg = dialects.find(nl.dialect) orelse return null;
    var st = try ir.newStmt(arena, .options, 0);
    var any = false;
    for (sg.implied) |im| {
        if (im.kind != .options or topValue(nl.stmts, im.slot) != null) continue;
        const want = optionValue(arena, sg, nl.stmts, im.slot, 0) orelse continue;
        if (impliedValue(arena, g, sg, nl.stmts, im.slot, 0)) |have| if (have.eql(want)) continue;
        try st.set(arena, im.slot, want);
        any = true;
    }
    return if (any) st else null;
}

/// What `g` assumes for an option, with a `$other` read in the netlist of `sg`.
pub fn impliedValue(
    arena: Allocator,
    g: *const Grammar,
    sg: *const Grammar,
    stmts: []const ir.Stmt,
    slot: u8,
    depth: u8,
) ?Value {
    const text = g.impliedOf(.options, slot) orelse return null;
    if (text.len > 1 and text[0] == '$') {
        const other = schema.slotIndex(.options, text[1..]) orelse return null;
        return if (depth < 4) optionValue(arena, sg, stmts, @intCast(other), depth + 1) else null;
    }
    const n = lexer.parseNumber(arena, &g.lex, text) orelse return .{ .atom = text };
    return .{ .num = n };
}

/// Whether `g` writes a pole-zero analysis, and does with a source for the
/// input and a signal for the output.
pub fn pzForm(g: *const Grammar) PzForm {
    const src_i = schema.slot(.pz, "src");
    const out_i = schema.slot(.pz, "out");
    var f: PzForm = .{};
    for (g.rules) |r| if (r.kind == .pz and r.dir != .read) {
        f.writes = true;
        f.by_src = f.by_src or mentions(r.pat, src_i);
        f.by_sig = f.by_sig or mentions(r.pat, out_i);
    };
    return f;
}

/// Whether `nl` is written back in its own dialect: read in `g`, or built
/// (Python, JSON) from statements read in `g` (`Stmt.dialect`) and others
/// that name no dialect, such as a subcircuit built around them.
pub fn sameDialect(nl: *const ir.Netlist, g: *const grammar.Grammar) bool {
    if (std.mem.eql(u8, nl.dialect, g.name)) return true;
    var tagged = false;
    return allFrom(nl.stmts, g.name, &tagged) and tagged;
}

pub const PzForm = struct { writes: bool = false, by_src: bool = false, by_sig: bool = false };

pub fn allFrom(stmts: []const ir.Stmt, name: []const u8, tagged: *bool) bool {
    for (stmts) |*s| {
        if (s.dialect != 0) {
            if (!std.ascii.eqlIgnoreCase(dialects.nameOf(s.dialect), name)) return false;
            tagged.* = true;
        }
        if (!allFrom(s.body, name, tagged)) return false;
    }
    return true;
}
