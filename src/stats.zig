//! Random parameters between the two ways dialects say them.
//!
//! SPICE dialects vary a parameter by calling `agauss`, `gauss`, `aunif`
//! or `unif` in its expression. Spectre has no such functions: a parameter
//! is given its nominal value and varied in a `statistics` block, once per
//! run (`process`) or once per instance (`mismatch`). Before a netlist is
//! written, `prepare` turns one form into the other when the target only
//! has one of them:
//!
//! * into Spectre, `.param p = agauss(nom, a, n)` becomes `p = nom` and
//!   `vary p dist=gauss std=a/n`; any other call becomes a new parameter
//!   with a nominal value of 0 and a standard deviation of 1, varied per
//!   run at the top level and per instance inside a subcircuit, and the
//!   call is replaced by `nom + a/n * that parameter`;
//! * into SPICE, a process `vary p` on a parameter defined in the same list
//!   becomes `p = agauss(nom, std, 1)` (or `aunif`).
//!
//! What cannot be turned (a mismatch variation of a global parameter, a
//! correlation, a model parameter's variation) is left for the writer to
//! report.

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir");
const grammar = @import("grammar");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Stmt = ir.Stmt;
const Value = ir.Value;

const random = [_][]const u8{ "agauss", "gauss", "aunif", "unif" };

fn hasFunction(g: *const Grammar, canon: []const u8) bool {
    for (g.functions) |f| if (std.mem.eql(u8, f.canon, canon)) return true;
    return false;
}

pub fn prepare(arena: Allocator, g: *const Grammar, source: []const u8, stmts_in: []const Stmt, report: *ir.Report) Allocator.Error![]const Stmt {
    var stmts = stmts_in;
    var functions: usize = 0;
    // ponytail: HSPICE is the one dialect named here, as the home of the
    // `dev/gauss=` form; a grammar directive if a second one needs it.
    if (devLots(g, source) and usesDevLot(stmts)) stmts = try devLot(arena, stmts, report, &functions);
    checkReserved(g, stmts, report);
    if (!hasFunction(g, "agauss") and g.canWrite(.statistics) and g.canWrite(.vary)) {
        if (!usesRandom(stmts)) return stmts;
        var l: Lower = .{ .arena = arena, .report = report, .g = g };
        const out = try l.list(stmts, null);
        l.caveat();
        return out;
    }
    if (hasFunction(g, "agauss") and usesKind(stmts, .statistics)) stmts = try fold(arena, g, stmts, report, &functions);
    asFunctions(g, functions, report);
    return stmts;
}

/// One note for the file, where a PDK has thousands: `n` parameters whose
/// variation (`dev/gauss=`, a `vary`) is now a random function in the
/// definition, which is what `g` reads back.
pub fn asFunctions(g: *const Grammar, n: usize, report: *ir.Report) void {
    if (n == 0 or !hasFunction(g, "agauss")) return;
    report.add(.info, .oneway, 0, "{d} parameter{s} varied by a random function in the definition, in place of a variation given separately; {s} reads back the function, not the variation", .{ n, if (n == 1) "" else "s", g.name });
}

/// Does `prepare` need every statement of the netlist at once for
/// `stmts`? Only to fold statistics blocks into random functions: `devLot`
/// changes a statement by itself, and `Stream` lowers them as they come.
pub fn changes(g: *const Grammar, stmts: []const Stmt) bool {
    return hasFunction(g, "agauss") and usesKind(stmts, .statistics);
}

/// `prepare`'s turning of random functions into statistics, for a netlist
/// written a few top-level statements at a time: the variations they make
/// are one parameter statement and one statistics block after the last.
pub const Stream = struct {
    l: Lower,
    acc: Lower.Acc = .{},
    any: bool = false,
    /// The line of the last statement given.
    line: u32 = 0,

    /// Null when `g` has random functions of its own, or no statistics.
    pub fn init(k: ir.Keep, g: *const Grammar, report: *ir.Report) ?Stream {
        if (hasFunction(g, "agauss") or !g.canWrite(.statistics) or !g.canWrite(.vary)) return null;
        return .{ .l = .{ .arena = k.perm, .report = report, .g = g, .keep = k } };
    }

    /// The next statements, lowered into `arena`.
    pub fn group(s: *Stream, arena: Allocator, stmts: []const Stmt) Allocator.Error![]const Stmt {
        if (stmts.len > 0) s.line = stmts[stmts.len - 1].line;
        if (!usesRandom(stmts)) return stmts;
        s.any = true;
        s.l.arena = arena;
        return s.l.walk(&s.acc, stmts, null);
    }

    /// After the last statement: those of the variations made.
    pub fn end(s: *Stream, arena: Allocator) Allocator.Error![]const Stmt {
        if (!s.any) return &.{};
        s.l.arena = arena;
        const out = try s.l.variations(&s.acc, s.line);
        s.l.caveat();
        return out;
    }
};

/// Is `dev/gauss=` rewritten (`devLot`) on the way from `source` to `g`?
pub fn devLots(g: *const Grammar, source: []const u8) bool {
    return !std.mem.eql(u8, g.name, source) and !std.mem.eql(u8, g.name, "hspice");
}

/// HSPICE's `p=nom dev/gauss=s` (per device) and `lot/gauss=s` (per run),
/// or `/unif`: an entry of its own after the parameter it varies.
pub fn devLotKey(key: []const u8) ?enum { gauss, unif } {
    const slash = std.mem.indexOfScalar(u8, key, '/') orelse return null;
    const who = key[0..slash];
    if (!std.ascii.eqlIgnoreCase(who, "dev") and !std.ascii.eqlIgnoreCase(who, "lot")) return null;
    const dist = key[slash + 1 ..];
    if (std.ascii.eqlIgnoreCase(dist, "gauss")) return .gauss;
    if (std.ascii.eqlIgnoreCase(dist, "unif")) return .unif;
    return null;
}

pub fn usesDevLot(stmts: []const Stmt) bool {
    for (stmts) |*s| {
        if (s.kind == .param and s.get("params") == .params) {
            for (s.get("params").params) |p| if (devLotKey(p.key) != null) return true;
        }
        if (usesDevLot(s.body)) return true;
    }
    return false;
}

/// `p=nom dev/gauss=s` as `p=agauss(nom, s, 1)`, which the rest of this
/// file and every dialect with agauss() understand.
/// `n` counts them, for `asFunctions`.
pub fn devLot(arena: Allocator, stmts: []const Stmt, report: *ir.Report, n: *usize) Allocator.Error![]const Stmt {
    const out = try arena.dupe(Stmt, stmts);
    const pi = schema.slotIndex(.param, "params").?;
    for (out) |*st| {
        if (st.body.len > 0) st.body = @constCast(try devLot(arena, st.body, report, n));
        if (st.kind != .param or st.at(pi) != .params) continue;
        var ps: std.ArrayList(ir.Param) = .empty;
        var changed = false;
        for (st.at(pi).params) |p| {
            const dist = devLotKey(p.key) orelse {
                try ps.append(arena, p);
                continue;
            };
            if (ps.items.len == 0) {
                try ps.append(arena, p);
                continue;
            }
            const prev = &ps.items[ps.items.len - 1];
            const nom = try valueText(arena, prev.val);
            const s = try valueText(arena, p.val);
            prev.val = .{ .expr = switch (dist) {
                .gauss => try std.fmt.allocPrint(arena, "agauss({s}, {s}, 1)", .{ nom, s }),
                .unif => try std.fmt.allocPrint(arena, "aunif({s}, {s})", .{ nom, s }),
            } };
            changed = true;
            n.* += 1;
            report.add(.warning, .caveat, st.line, "{s}={s} on parameter '{s}': written as a random function in its definition, so it is drawn per instance inside a subcircuit and per run at the top level, whatever dev or lot said", .{ p.key, s, prev.key });
        }
        if (!changed) continue;
        try st.own(arena);
        try st.set(arena, pi, .{ .params = ps.items });
    }
    return out;
}

/// A parameter named like a variable the target keeps for itself is
/// refused there. What is left of them after `writer.renameParams`: a name
/// that is a variable everywhere (`time`).
pub fn checkReserved(g: *const Grammar, stmts: []const Stmt, report: *ir.Report) void {
    if (g.reserved.len == 0) return;
    for (stmts) |*s| {
        checkReserved(g, s.body, report);
        if (s.kind != .param and s.kind != .subckt) continue;
        const v = s.get("params");
        if (v != .params) continue;
        for (v.params) |p| for (g.reserved) |r| for (r.names) |n| {
            if (std.ascii.eqlIgnoreCase(n, p.key)) report.add(.@"error", .invalid, s.line, "parameter '{s}': {s}; rename it", .{ p.key, r.reason });
        };
    }
}

fn usesKind(stmts: []const Stmt, kind: schema.Kind) bool {
    for (stmts) |*s| if (s.kind == kind or usesKind(s.body, kind)) return true;
    return false;
}

fn isRandomCall(text: []const u8) bool {
    var it = Calls{ .text = text };
    return it.next() != null;
}

fn valueUsesRandom(v: Value) bool {
    return switch (v) {
        .expr => |e| isRandomCall(e),
        .list => |l| for (l) |x| {
            if (valueUsesRandom(x)) break true;
        } else false,
        .params => |ps| for (ps) |p| {
            if (valueUsesRandom(p.val)) break true;
        } else false,
        else => false,
    };
}

fn usesRandom(stmts: []const Stmt) bool {
    for (stmts) |*s| {
        for (s.values()) |v| if (valueUsesRandom(v)) return true;
        if (usesRandom(s.body)) return true;
    }
    return false;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '$' or c == '#' or c == '!';
}

/// One call of a random function in a canonical expression.
const Call = struct { name: []const u8, start: usize, end: usize, args: [3][]const u8, n: usize };

const Calls = struct {
    text: []const u8,
    i: usize = 0,

    fn next(it: *Calls) ?Call {
        const t = it.text;
        while (it.i < t.len) {
            const c = t[it.i];
            if (c == '"' or c == '\'') {
                it.i = (std.mem.indexOfScalarPos(u8, t, it.i + 1, c) orelse t.len - 1) + 1;
                continue;
            }
            if (!(std.ascii.isAlphabetic(c) or c == '_') or (it.i > 0 and isWordChar(t[it.i - 1]))) {
                it.i += 1;
                continue;
            }
            var j = it.i;
            while (j < t.len and isWordChar(t[j])) j += 1;
            const word = t[it.i..j];
            const start = it.i;
            it.i = j;
            const known = for (random) |r| {
                if (std.mem.eql(u8, r, word)) break true;
            } else false;
            if (!known) continue;
            var k = j;
            while (k < t.len and (t[k] == ' ' or t[k] == '\t')) k += 1;
            if (k >= t.len or t[k] != '(') continue;
            var call: Call = .{ .name = word, .start = start, .end = 0, .args = .{ "", "", "" }, .n = 0 };
            var depth: usize = 0;
            var arg_start = k + 1;
            var m = k;
            while (m < t.len) : (m += 1) {
                switch (t[m]) {
                    '(' => depth += 1,
                    ')' => {
                        depth -= 1;
                        if (depth == 0) break;
                    },
                    ',' => if (depth == 1) {
                        if (call.n == 3) return null;
                        call.args[call.n] = std.mem.trim(u8, t[arg_start..m], " \t");
                        call.n += 1;
                        arg_start = m + 1;
                    },
                    else => {},
                }
            }
            if (m >= t.len or call.n == 3) return null;
            call.args[call.n] = std.mem.trim(u8, t[arg_start..m], " \t");
            call.n += 1;
            call.end = m + 1;
            return call;
        }
        return null;
    }
};

fn isNumber(text: []const u8) bool {
    _ = std.fmt.parseFloat(f64, text) catch return false;
    return true;
}

fn isOne(text: []const u8) bool {
    const v = std.fmt.parseFloat(f64, text) catch return false;
    return v == 1;
}

/// `a / n`, simplified when `n` is 1.
fn over(arena: Allocator, a: []const u8, n: []const u8) Allocator.Error![]const u8 {
    if (isOne(n)) return a;
    return std.fmt.allocPrint(arena, "({s})/({s})", .{ a, n });
}

/// What a call varies: the nominal value, the distribution, and the spread
/// as a standard deviation (gauss) or a half width (unif).
const Spread = struct { nominal: []const u8, dist: []const u8, spread: []const u8, relative: bool };

/// Null when the sigma divisor is not a known non-zero number, which a
/// variation of its own cannot say (Spectre refuses a zero deviation).
fn spreadOf(arena: Allocator, call: Call, need_constant: bool) Allocator.Error!?Spread {
    const gaussian = std.mem.endsWith(u8, call.name, "gauss");
    const relative = call.name[0] != 'a';
    if (call.n < 2) return null;
    var s: []const u8 = call.args[1];
    if (gaussian) {
        const n = if (call.n == 3) call.args[2] else "1";
        if (need_constant and !(isNumber(n) and (std.fmt.parseFloat(f64, n) catch 0) != 0)) return null;
        s = try over(arena, s, n);
    }
    return .{ .nominal = call.args[0], .dist = if (gaussian) "gauss" else "unif", .spread = s, .relative = relative };
}

const Lower = struct {
    arena: Allocator,
    report: *ir.Report,
    g: *const Grammar,
    first_line: u32 = 0,
    /// How many variations the statistics blocks made here hold.
    varied: usize = 0,
    used: std.StringHashMapUnmanaged(void) = .empty,
    /// Set when the statements go away before the variations are written
    /// (`Stream`): where the variations are kept, `arena` otherwise.
    keep: ?ir.Keep = null,

    fn perm(l: *const Lower) Allocator {
        return if (l.keep) |k| k.perm else l.arena;
    }

    fn kept(l: *const Lower, text: []const u8) Allocator.Error![]const u8 {
        return if (l.keep) |k| k.text(text) else text;
    }

    fn caveat(l: *const Lower) void {
        l.report.add(.warning, .caveat, l.first_line, "agauss(), gauss(), aunif() and unif() are written as {s} statistics variations: outside a Monte Carlo analysis the parameters keep their nominal values, where ngspice draws a new sample on every run", .{l.g.name});
        // One note for the file, where a PDK has thousands.
        if (l.varied > 0) l.report.add(.info, .oneway, l.first_line, "{d} parameter{s} varied in a statistics block in place of a random function; {s} reads back the block, not the function", .{ l.varied, if (l.varied == 1) "" else "s", l.g.name });
    }

    /// Variations made for the list being lowered.
    const Acc = struct {
        process: std.ArrayList(Stmt) = .empty,
        mismatch: std.ArrayList(Stmt) = .empty,
        zeros: std.ArrayList(ir.Param) = .empty,
        line: u32 = 0,
    };

    fn vary(l: *Lower, name: []const u8, dist: []const u8, spread: []const u8, line: u32) Allocator.Error!Stmt {
        const a = l.perm();
        var st = try ir.newStmt(a, .vary, line);
        try st.set(a, schema.slotIndex(.vary, "param").?, .{ .atom = try l.kept(name) });
        try st.set(a, schema.slotIndex(.vary, "dist").?, .{ .atom = dist });
        const slot = if (std.mem.eql(u8, dist, "gauss")) "std" else "range";
        try st.set(a, schema.slotIndex(.vary, slot).?, .{ .expr = try l.kept(spread) });
        return st;
    }

    fn freshName(l: *Lower, hint: []const u8) Allocator.Error![]const u8 {
        var base: std.ArrayList(u8) = .empty;
        try base.appendSlice(l.arena, "sprack_rv_");
        for (hint) |c| try base.append(l.arena, if (std.ascii.isAlphanumeric(c) or c == '_') c else '_');
        var name: []const u8 = base.items;
        var k: usize = 2;
        while (l.used.contains(name)) : (k += 1) name = try std.fmt.allocPrint(l.arena, "{s}_{d}", .{ base.items, k });
        name = try l.kept(name);
        try l.used.put(l.perm(), name, {});
        return name;
    }

    /// Replace every random call in `text` by its nominal value plus a
    /// scaled new parameter.
    fn rewrite(l: *Lower, acc: *Acc, text: []const u8, hint: []const u8, mismatch: bool, line: u32) Allocator.Error![]const u8 {
        var cur = text;
        while (true) {
            var it = Calls{ .text = cur };
            const call = it.next() orelse return cur;
            const sp = (try spreadOf(l.arena, call, false)) orelse return cur;
            const rv = try l.freshName(hint);
            try acc.zeros.append(l.perm(), .{ .key = rv, .val = .{ .expr = "0" } });
            const into = if (mismatch) &acc.mismatch else &acc.process;
            try into.append(l.perm(), try l.vary(rv, sp.dist, "1", line));
            var factor = sp.spread;
            if (std.mem.endsWith(u8, call.name, "gauss") and call.n == 3 and !isNumber(call.args[2])) {
                factor = try std.fmt.allocPrint(l.arena, "(({s}) == 0 ? 0 : {s})", .{ call.args[2], sp.spread });
            }
            const repl = if (sp.relative)
                try std.fmt.allocPrint(l.arena, "({s})*(1 + {s}*{s})", .{ sp.nominal, factor, rv })
            else
                try std.fmt.allocPrint(l.arena, "({s} + {s}*{s})", .{ sp.nominal, factor, rv });
            cur = try std.mem.concat(l.arena, u8, &.{ cur[0..call.start], repl, cur[call.end..] });
            if (l.first_line == 0) l.first_line = line;
        }
    }

    fn value(l: *Lower, acc: *Acc, v: Value, hint: []const u8, mismatch: bool, line: u32) Allocator.Error!Value {
        return switch (v) {
            .expr => |e| if (isRandomCall(e)) .{ .expr = try l.rewrite(acc, e, hint, mismatch, line) } else v,
            .list => |items| blk: {
                const out = try l.arena.dupe(Value, items);
                for (out) |*x| x.* = try l.value(acc, x.*, hint, mismatch, line);
                break :blk .{ .list = out };
            },
            .params => |ps| blk: {
                const out = try l.arena.dupe(ir.Param, ps);
                for (out) |*p| {
                    const h = if (hint.len == 0) p.key else try std.fmt.allocPrint(l.arena, "{s}_{s}", .{ hint, p.key });
                    p.val = try l.value(acc, p.val, h, mismatch, line);
                }
                break :blk .{ .params = out };
            },
            else => v,
        };
    }

    /// A top-level `p = agauss(nom, a, n)`: `p = nom`, varied per run.
    fn wholeParam(l: *Lower, acc: *Acc, st: *Stmt) Allocator.Error!void {
        const pi = schema.slotIndex(.param, "params").?;
        if (st.at(pi) != .params) return;
        const out = try l.arena.dupe(ir.Param, st.at(pi).params);
        var changed = false;
        for (out) |*p| {
            if (p.val != .expr) continue;
            const e = std.mem.trim(u8, p.val.expr, " \t");
            var it = Calls{ .text = e };
            const call = it.next() orelse continue;
            if (call.start != 0 or call.end != e.len) continue;
            const sp = (try spreadOf(l.arena, call, true)) orelse continue;
            const spread = if (sp.relative) try std.fmt.allocPrint(l.arena, "({s})*({s})", .{ sp.nominal, sp.spread }) else sp.spread;
            try acc.process.append(l.perm(), try l.vary(p.key, sp.dist, spread, st.line));
            p.val = .{ .expr = sp.nominal };
            changed = true;
            if (l.first_line == 0) l.first_line = st.line;
        }
        if (changed) try st.set(l.arena, pi, .{ .params = out });
    }

    /// `owner` is the subcircuit the list is the body of, if any. A list
    /// that is not a subcircuit's body gets the variations it and its
    /// subcircuits made, as one parameter statement and one statistics
    /// block at its end.
    fn list(l: *Lower, stmts: []const Stmt, owner: ?[]const u8) Allocator.Error![]const Stmt {
        var acc: Acc = .{};
        const out = try l.walk(&acc, stmts, owner);
        if (owner != null) return out;
        const made = try l.variations(&acc, if (stmts.len > 0) stmts[stmts.len - 1].line else 0);
        return if (made.len > 0) std.mem.concat(l.arena, Stmt, &.{ out, made }) else out;
    }

    /// What `acc` holds, as the statements that end its list.
    fn variations(l: *Lower, acc: *const Acc, line: u32) Allocator.Error![]const Stmt {
        if (acc.process.items.len == 0 and acc.mismatch.items.len == 0) return &.{};
        l.varied += acc.process.items.len + acc.mismatch.items.len;
        var all: std.ArrayList(Stmt) = .empty;
        if (acc.zeros.items.len > 0) {
            var ps = try ir.newStmt(l.arena, .param, line);
            try ps.set(l.arena, schema.slotIndex(.param, "params").?, .{ .params = acc.zeros.items });
            try all.append(l.arena, ps);
        }
        var groups: std.ArrayList(Stmt) = .empty;
        inline for (.{ "process", "mismatch" }) |scope| {
            const items = @field(acc, scope).items;
            if (items.len > 0) {
                var grp = try ir.newStmt(l.arena, .statgroup, line);
                try grp.set(l.arena, schema.slotIndex(.statgroup, "scope").?, .{ .atom = scope });
                grp.body = items;
                try groups.append(l.arena, grp);
            }
        }
        var stat = try ir.newStmt(l.arena, .statistics, line);
        stat.body = groups.items;
        try all.append(l.arena, stat);
        return all.items;
    }

    fn walk(l: *Lower, acc: *Acc, stmts: []const Stmt, owner: ?[]const u8) Allocator.Error![]const Stmt {
        const out = try l.arena.dupe(Stmt, stmts);
        for (out) |*st| {
            if (st.kind == .subckt) {
                const name = if (st.get("name") == .atom) st.get("name").atom else "subckt";
                try st.own(l.arena);
                try l.values(acc, st, name, true);
                st.body = @constCast(try l.walk(acc, st.body, name));
                continue;
            }
            if (st.body.len > 0) {
                // A library section gets its own variations; a conditional
                // inside a subcircuit adds to the subcircuit's.
                st.body = @constCast(if (owner == null) try l.list(st.body, null) else try l.walk(acc, st.body, owner));
            }
            try st.own(l.arena);
            if (owner == null and st.kind == .param) try l.wholeParam(acc, st);
            const hint = if (st.get("name") == .atom) st.get("name").atom else if (st.kind == .param) "" else @tagName(st.kind);
            const full = if (owner) |o| (if (hint.len == 0) o else try std.fmt.allocPrint(l.arena, "{s}_{s}", .{ o, hint })) else hint;
            try l.values(acc, st, full, owner != null);
        }
        return out;
    }

    fn values(l: *Lower, acc: *Acc, st: *Stmt, hint: []const u8, mismatch: bool) Allocator.Error!void {
        var buf: [schema.max_slots]Value = undefined;
        const vals = st.unpack(&buf);
        var changed = false;
        for (vals) |*v| {
            if (!valueUsesRandom(v.*)) continue;
            v.* = try l.value(acc, v.*, hint, mismatch, st.line);
            changed = true;
        }
        if (changed) try st.store(l.arena, vals);
    }
};

/// Process variations of parameters defined in the same list, as random
/// functions in their definitions. Whatever is left keeps its statistics
/// block, for the writer to report.
fn fold(arena: Allocator, g: *const Grammar, stmts: []const Stmt, report: *ir.Report, n: *usize) Allocator.Error![]const Stmt {
    var out: std.ArrayList(Stmt) = .empty;
    try out.appendSlice(arena, stmts);
    for (out.items) |*st| {
        if (st.body.len > 0 and st.kind != .statistics) st.body = @constCast(try fold(arena, g, st.body, report, n));
    }
    var i: usize = 0;
    while (i < out.items.len) {
        const st = &out.items[i];
        if (st.kind != .statistics) {
            i += 1;
            continue;
        }
        var groups: std.ArrayList(Stmt) = .empty;
        for (st.body) |grp| {
            if (grp.kind != .statgroup or !std.mem.eql(u8, atomOf(grp.get("scope")), "process")) {
                try groups.append(arena, grp);
                continue;
            }
            var kept: std.ArrayList(Stmt) = .empty;
            for (grp.body) |*v| {
                if (v.kind != .vary or !try foldOne(arena, out.items, v, report)) {
                    try kept.append(arena, v.*);
                } else n.* += 1;
            }
            if (kept.items.len == 0) continue;
            var copy = grp;
            copy.body = kept.items;
            try groups.append(arena, copy);
        }
        var any = false;
        for (groups.items) |grp| any = any or grp.kind != .comment;
        if (!any) {
            // The emptied block goes. Its own parameters have no place in
            // any grammar, and do not go with it unsaid.
            if (st.get("params") == .params) for (st.get("params").params) |p| {
                const val = if (p.val == .none) "" else try valueText(arena, p.val);
                report.add(.@"error", .loss, st.line, "statistics: '{s}{s}{s}' has no spelling in {s}", .{ p.key, if (p.val == .none) "" else "=", val, g.name });
            };
            _ = out.orderedRemove(i);
            continue;
        }
        st.body = groups.items;
        i += 1;
    }
    return out.items;
}

fn atomOf(v: Value) []const u8 {
    return if (v == .atom) v.atom else "";
}

fn foldOne(arena: Allocator, list: []Stmt, v: *const Stmt, report: *ir.Report) Allocator.Error!bool {
    if (v.get("model") != .none or v.get("param") != .atom) return false;
    if (v.get("params") != .none) return false;
    const name = v.get("param").atom;
    const dist = atomOf(v.get("dist"));
    const gaussian = dist.len == 0 or std.mem.eql(u8, dist, "gauss");
    if (!gaussian and !std.mem.eql(u8, dist, "unif")) return false;
    const spread = if (gaussian) v.get("std") else v.get("range");
    if (spread == .none) return false;
    const pi = schema.slotIndex(.param, "params").?;
    for (list) |*st| {
        if (st.kind != .param or st.at(pi) != .params) continue;
        for (st.at(pi).params, 0..) |p, k| {
            if (!std.ascii.eqlIgnoreCase(p.key, name)) continue;
            const ps = try arena.dupe(ir.Param, st.at(pi).params);
            const nom = try valueText(arena, p.val);
            const s = try valueText(arena, spread);
            ps[k].val = .{ .expr = if (gaussian)
                try std.fmt.allocPrint(arena, "agauss({s}, {s}, 1)", .{ nom, s })
            else
                try std.fmt.allocPrint(arena, "aunif({s}, {s})", .{ nom, s }) };
            try st.own(arena);
            try st.set(arena, pi, .{ .params = ps });
            report.add(.warning, .caveat, v.line, "vary {s}: written as a random function in the parameter's definition; ngspice draws a new value on every run, where a statistics variation keeps the nominal value outside a Monte Carlo analysis", .{name});
            return true;
        }
    }
    return false;
}

fn valueText(arena: Allocator, v: Value) Allocator.Error![]const u8 {
    return switch (v) {
        .num => |n| if (n.exp10 == 0) n.digits() else try std.fmt.allocPrint(arena, "{s}e{d}", .{ n.digits(), n.exp10 }),
        .expr, .atom, .str => |s| s,
        else => "0",
    };
}

test "random calls are found with their arguments" {
    var it = Calls{ .text = "1 + agauss(w, f(a, b), (m != 1 ? 0 : 1)) * gauss(2,0.1)" };
    const a = it.next().?;
    try std.testing.expectEqualStrings("agauss", a.name);
    try std.testing.expectEqual(3, a.n);
    try std.testing.expectEqualStrings("f(a, b)", a.args[1]);
    try std.testing.expectEqualStrings("(m != 1 ? 0 : 1)", a.args[2]);
    const b = it.next().?;
    try std.testing.expectEqualStrings("gauss", b.name);
    try std.testing.expect(it.next() == null);
}
