//! A subcircuit for each branch: where the target has no conditional
//! blocks, a subcircuit that holds one is written once for each branch it
//! can take, and each instance names the one its parameters select.
//!
//! Contents:
//! - `pub fn noteSplits(w: *Writer, stmts: []const ir.Stmt) Allocator.Error!usize`
//! - `pub fn foreignInstance(w: *Writer, stmts: []const ir.Stmt) Allocator.Error!?*const ir.Stmt`
//! - `pub fn split(w: *Writer, st: *const ir.Stmt, v: *const cond.Variants) Error!void`
//! - `pub fn variantOf(w: *Writer, a: Allocator, st: *const ir.Stmt) Allocator.Error!?[]const u8`
//! - `pub fn knownSplits(w: *Writer, a: Allocator) Allocator.Error![]const cond.Known`
//! - `pub fn noteAllSplits(w: *Writer, stmts: []const ir.Stmt,
//!   env: ?*const ir.Env) Allocator.Error!void`

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir");
const expr = @import("expr");
const cond = @import("cond");
const statement = @import("statement.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Writer = statement.Writer;
const Error = Writer.Error;

/// Notes every subcircuit of `stmts` that is written as several. A
/// subcircuit that holds an instance of one, decided by its own
/// parameters, is one too: noted once the other is (`cond.passDown`).
/// Returns how many were noted.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn noteSplits(w: *Writer, stmts: []const ir.Stmt) Allocator.Error!usize {
    const before = w.splits.items.len;
    var n: usize = 0;
    for (stmts) |*s| {
        if (s.kind == .subckt and s.get("name") == .atom) noted: {
            for (w.splits.items) |sp|
                if (std.ascii.eqlIgnoreCase(sp.name, s.get("name").atom)) break :noted;
            const sp = try cond.split(
                w.perm,
                s,
                expr.choiceForm(w.g),
                &w.declared,
                try knownSplits(w, w.perm),
            );
            if (sp == .variants or sp == .clash) {
                try w.splits.append(w.perm, .{ .name = s.get("name").atom, .split = sp });
                n += 1;
            }
        }
        n += try noteSplits(w, s.body);
    }
    // Each one noted is one more of `w.splits`, those of the bodies too.
    assert(w.splits.items.len == before + n);
    return n;
}

/// The first instance that gives parameters to a subcircuit no file
/// read declares.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn foreignInstance(w: *Writer, stmts: []const ir.Stmt) Allocator.Error!?*const ir.Stmt {
    for (stmts) |*s| {
        if (s.kind == .instance and s.get("master") == .atom and s.get("params") == .params and
            s.get("name") == .atom)
        {
            if (!w.declared.contains(
                try std.ascii.allocLowerString(w.arena, s.get("master").atom),
            )) return s;
        }
        if (try foreignInstance(w, s.body)) |x| return x;
    }
    return null;
}

/// The subcircuit `st` once for each of `v`, a comment above each
/// saying where it is the one.
pub fn split(w: *Writer, st: *const ir.Stmt, v: *const cond.Variants) Error!void {
    assert(st.kind == .subckt);
    // `noteSplits` notes only a subcircuit that has a name.
    assert(st.get("name") == .atom);
    const name = st.get("name").atom;
    var listed: std.ArrayList(u8) = .empty;
    for (v.list, 0..) |x, i|
        try listed.print(w.arena, "{s}'{s}' where {s}", .{ if (i > 0)
            ", "
        else
            "", x.name, x.cond });
    w.report.add(.info, .oneway, v.line, "subckt '{s}': {s} has no conditional blocks, so " ++
        "the subcircuit is written once for each branch of the {s} {d}: {s}; an instance " ++
        "is written with the one its parameters select; it reads back as {d} subcircuits", .{
        name,       w.g.name,
        if (v.more)
            "blocks from line"
        else
            "block at line",
        v.line,     listed.items,
        v.list.len,
    });
    // A statement outside the blocks is in every one of them: what it
    // reports is said once.
    var said: std.StringHashMapUnmanaged(void) = .empty;
    var new: std.ArrayList([]const u8) = .empty;
    for (v.list) |x| {
        try w.comment(
            try std.fmt.allocPrint(w.arena, "[sprack] '{s}' where {s}", .{ name, x.cond }),
        );
        var one = st.*;
        try one.own(w.arena);
        try one.set(w.arena, schema.slot(.subckt, "name"), .{ .atom = x.name });
        one.body = x.body;
        const from = w.report.items.items.len;
        w.variant = true;
        try w.stmt(&one);
        var kept = from;
        for (w.report.items.items[from..]) |d| {
            const key = try std.fmt.allocPrint(
                w.arena,
                "{d} {s} {s}",
                .{ d.line, @tagName(d.code), d.msg },
            );
            if (said.contains(key)) continue;
            try new.append(w.arena, key);
            w.report.items.items[kept] = d;
            kept += 1;
        }
        w.report.items.shrinkRetainingCapacity(kept);
        for (new.items) |key| try said.put(w.arena, key, {});
        new.clearRetainingCapacity();
    }
}

/// The subcircuit name an instance is written with: of a subcircuit
/// written as several, the one its parameters select. Null, reported,
/// when that cannot be told.
pub fn variantOf(w: *Writer, a: Allocator, st: *const ir.Stmt) Allocator.Error!?[]const u8 {
    assert(st.get("master") == .atom);
    const master = st.get("master").atom;
    var name: ?[]const u8 = null;
    for (w.splits.items) |*sp| {
        if (!std.ascii.eqlIgnoreCase(sp.name, master)) continue;
        var stop: []const u8 = "";
        const pick = switch (sp.split) {
            .variants => |*v| try cond.choose(a, v, if (st.get("params") == .params)
                st.get("params").params
            else
                &.{}, &stop) orelse {
                w.report.add(
                    .@"error",
                    .unsupported,
                    st.line,
                    "instance '{s}': subcircuit '{s}' is written once for each branch of " ++
                        "its conditional block, and which of them this instance is " ++
                        "depends on parameter '{s}', which is not a number here",
                    .{ st.get("name").atom, master, stop },
                );
                return null;
            },
            .clash => |taken| {
                w.report.add(
                    .@"error",
                    .unsupported,
                    st.line,
                    "instance '{s}': subcircuit '{s}' holds a conditional block, which " ++
                        "{s} has not, and is not written once for each branch: '{s}', the " ++
                        "name one of them would take, is already declared",
                    .{ st.get("name").atom, master, w.g.name, taken },
                );
                return null;
            },
            else => unreachable,
        };
        if (name) |other| if (!std.mem.eql(u8, other, pick)) {
            w.report.add(
                .@"error",
                .unsupported,
                st.line,
                "instance '{s}': subcircuit '{s}' is declared more than once, and this " ++
                    "instance is '{s}' by one declaration, '{s}' by another",
                .{ st.get("name").atom, master, other, pick },
            );
            return null;
        };
        name = pick;
    }
    return name orelse master;
}

/// The subcircuits noted so far as written once for each branch.
pub fn knownSplits(w: *Writer, a: Allocator) Allocator.Error![]const cond.Known {
    var out: std.ArrayList(cond.Known) = .empty;
    for (w.splits.items) |*sp|
        if (sp.split == .variants)
            try out.append(a, .{ .name = sp.name, .variants = &sp.split.variants });
    return out.items;
}

/// `noteSplits` until no more are noted: a subcircuit is noted after
/// the ones it holds instances of, at any depth.
pub fn noteAllSplits(w: *Writer, stmts: []const ir.Stmt, env: ?*const ir.Env) Allocator.Error!void {
    var rounds: usize = 0;
    while (rounds < cond.max_variants) : (rounds += 1) {
        var n = try noteSplits(w, stmts);
        if (env) |e| n += try noteSplits(w, e.conditional.items);
        if (n == 0) break;
    }
}
