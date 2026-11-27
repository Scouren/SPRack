//! What a statement just matched is turned into: closed-set values to
//! their canonical names, a model card's family from the models table, the
//! expressions read once every name is known; and the first pass, which
//! learns the declared names and their spellings.
//!
//! Contents:
//! - `pub fn canonStmt(self: *Reader, st: *ir.Stmt) Allocator.Error!void`
//! - `pub fn finishValue(self: *Reader, v: Value, line: u32) Allocator.Error!Value`
//! - `pub fn finish(self: *Reader, stmts: []ir.Stmt) Allocator.Error!void`
//! - `pub fn flagOddValues(self: *Reader, st: *const ir.Stmt) void`
//! - `pub fn collectDeclared(self: *Reader, declared: *Declared) Allocator.Error!void`
//! - `pub fn mapModel(arena: Allocator, g: *const Grammar, st: *ir.Stmt, report: *ir.Report)
//!   Allocator.Error!void`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const expr = @import("expr");
const matcher = @import("matcher.zig");
const spelling = @import("spelling.zig");
const step = @import("step.zig");
const signals = @import("signals.zig");
const assert = std.debug.assert;
const Reader = step.Reader;
const Spelling = spelling.Spelling;
const Declared = matcher.Declared;
const resolveName = spelling.resolveName;
const funcArgs = spelling.funcArgs;
const isVersion = signals.isVersion;
const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Node = grammar.Node;
const Value = ir.Value;

/// A spelling of the models table and the entry it is a spelling of.
const Hit = struct { e: *const grammar.ModelEntry, s: *const grammar.ModelSpelling };

/// Closed-set values to their canonical names, and the values this
/// dialect leaves unsaid made explicit.
pub fn canonStmt(self: *Reader, st: *ir.Stmt) Allocator.Error!void {
    var buf: [schema.max_slots]Value = undefined;
    const vals = st.unpack(&buf);
    canonEnums(self, st, vals);
    checkKeys(self, st, vals);
    try fillImplied(self, st, vals);
    try st.store(self.arena, vals);
}

pub fn finishValue(self: *Reader, v: Value, line: u32) Allocator.Error!Value {
    switch (v) {
        .expr => |e| return .{ .expr = try finishExpr(self, e, line) },
        .list => |items| {
            const out: []Value = @constCast(items);
            for (out) |*it| it.* = try self.finishValue(it.*, line);
            return v;
        },
        .params => |ps| {
            const out: []ir.Param = @constCast(ps);
            for (out) |*pp| pp.val = try self.finishValue(pp.val, line);
            return v;
        },
        else => return v,
    }
}

/// Last pass, when every name in the netlist is known: expressions,
/// references to instances, and the names inside signals.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn finish(self: *Reader, stmts: []ir.Stmt) Allocator.Error!void {
    const fold_case = !self.g.lex.case_sensitive;
    for (stmts) |*st| {
        var buf: [schema.max_slots]Value = undefined;
        const vals = st.unpack(&buf);
        assert(vals.len == schema.info(st.kind).slots.len);
        for (schema.info(st.kind).slots, 0..) |sl, i| {
            if (sl.ty == .ref) {
                if (fold_case) vals[i] = try self.spell.atom(self.arena, sl.space.?, vals[i]);
            } else if (sl.ty == .signal and fold_case) {
                vals[i] = try finishSignals(self, vals[i], st.line);
            } else vals[i] = try self.finishValue(vals[i], st.line);
        }
        if (st.kind == .func and fold_case) try funcArgs(self.arena, vals);
        try st.store(self.arena, vals);
        try self.finish(st.body);
    }
}

pub fn flagOddValues(self: *Reader, st: *const ir.Stmt) void {
    for (st.values()) |v| {
        if (v != .params) continue;
        if (schema.info(st.kind).class == .control) continue;
        for (v.params) |p| {
            if (p.val == .atom and !isVersion(p.val.atom))
                self.report.add(
                    .warning,
                    .invalid,
                    st.line,
                    "{s}={s}: not a number, a name or a delimited expression in {s}; " ++
                        "copied as written",
                    .{ p.key, p.val.atom, self.g.name },
                );
        }
    }
}

/// First pass: names of models and subcircuits, so the real pass can tell
/// `R1 a b rmod` (a model) from `R1 a b rval` (a parameter).
pub fn collectDeclared(self: *Reader, declared: *Declared) Allocator.Error!void {
    const fold_case = !self.g.lex.case_sensitive;
    const win = self.m.win;
    // The first pass starts at the first line.
    assert(win.next == 0);
    // The statements built here are thrown away: build them in a
    // scratch arena. Only names that go into `declared` and the
    // spelling tables are kept, and those are made in `self.arena`.
    var scratch: std.heap.ArenaAllocator = .init(ir.big);
    defer scratch.deinit();
    self.m.arena = scratch.allocator();
    defer {
        self.m.arena = self.arena;
        self.m.log = .empty;
    }
    var ti: usize = 0;
    // Bounded by the lines: each pass reads one, until there are none.
    while (true) {
        win.drop(ti);
        ti = 0;
        _ = scratch.reset(.retain_capacity);
        self.m.log = .empty;
        if (!try win.has(0)) break;
        // A line with capitals is read in full, so the spelling table
        // learns its names and nodes, and not its keywords (`DC`).
        const caps = fold_case and hasCaps(self);
        var found = try declaring(self, caps);
        if (found) |*st| try learn(self, st, caps, declared, scratch.allocator());
        while (self.toks()[ti].tag != .nl) ti += 1;
        ti += 1;
        // Every name kept from the lines before is a copy.
        self.lines.recycle();
    }
}

/// Replace a dialect's model spelling (`nmos level=54`) with the canonical
/// family and polarity (`bsim4`, `n`).
pub fn mapModel(
    arena: Allocator,
    g: *const Grammar,
    st: *ir.Stmt,
    report: *ir.Report,
) Allocator.Error!void {
    assert(st.kind == .model);
    const ti = schema.slot(.model, "type");
    const pi = schema.slot(.model, "params");
    var buf: [schema.max_slots]Value = undefined;
    const vals = st.unpack(&buf);
    if (vals[ti] != .atom) return;
    const ty = vals[ti].atom;
    const params: []const ir.Param = if (vals[pi] == .params) vals[pi].params else &.{};
    const hit = bestSpelling(arena, g, ty, params) orelse {
        unknownType(g, st.line, ty, report);
        return;
    };
    for (hit.s.kv) |kv| if (kv.min) {
        for (params) |p| if (std.mem.eql(u8, p.key, kv.key)) {
            report.add(
                .warning,
                .caveat,
                st.line,
                "model type '{s}' with {s}={s}: {s} takes it as the {s} model (it warns that " ++
                    "the value is out of range)",
                .{ ty, kv.key, try describeNum(arena, p.val), g.name, hit.e.family },
            );
        };
    };
    vals[schema.slot(.model, "family")] = .{ .atom = hit.e.family };
    if (hit.e.polarity.len > 0) vals[schema.slot(.model, "polarity")] = .{ .atom = hit.e.polarity };
    vals[ti] = .none;
    const kept = withoutConsumed(params, hit);
    // Switch levels back to SPICE's midpoint and hysteresis.
    const th = try expr.thresholds(arena, g, hit.e.family, kept, false);
    vals[pi] = if (th.params.len > 0) .{ .params = th.params } else .none;
    try st.store(arena, vals);
}

// ---- private ----

fn canonEnums(self: *Reader, st: *const ir.Stmt, vals: []Value) void {
    for (self.g.enums) |*e| {
        if (e.kind != st.kind or vals[e.slot] != .atom) continue;
        const have = vals[e.slot].atom;
        const hit = for (e.pairs) |pr| {
            if (std.mem.eql(u8, pr.spelling, have)) break pr.canon;
        } else {
            self.report.add(.warning, .invalid, st.line, "{s}.{s} = {s} is not a value " ++
                "the {s} grammar lists; kept as written", .{
                @tagName(st.kind), schema.info(st.kind).slots[e.slot].name, have, self.g.name,
            });
            continue;
        };
        vals[e.slot] = .{ .atom = hit };
    }
}

/// A statement (not a device) whose keys this dialect lists, closed:
/// another key is one the simulator refuses (HSPICE drops an .FFT
/// with one it does not know).
fn checkKeys(self: *Reader, st: *const ir.Stmt, vals: []const Value) void {
    assert(vals.len == schema.info(st.kind).slots.len);
    if (schema.info(st.kind).class == .device) return;
    const table = self.g.paramsOf(st.kind) orelse return;
    if (grammar.paramsOpen(table)) return;
    const pi = schema.slotOf(st.kind, "params") orelse return;
    if (vals[pi] != .params) return;
    for (vals[pi].params) |p| {
        const known = blk: {
            for (table) |e|
                for (e.spellings) |sp|
                    if (std.ascii.eqlIgnoreCase(sp, p.key)) break :blk true;
            break :blk false;
        };
        if (!known)
            self.report.add(
                .@"error",
                .invalid,
                st.line,
                "{s}: '{s}' is not a key {s} takes there; {s} does not run " ++
                    "the statement with it",
                .{ @tagName(st.kind), p.key, self.g.name, self.g.name },
            );
    }
}

/// The values this dialect leaves unsaid, made explicit.
fn fillImplied(self: *Reader, st: *const ir.Stmt, vals: []Value) Allocator.Error!void {
    for (self.g.implied) |im| {
        // Options hold for the whole netlist, not per statement: the
        // writer says a default the target does not share (`defaultOptions`).
        if (im.kind == .options) continue;
        if (im.kind != st.kind or vals[im.slot] != .none) continue;
        if (im.when_slot != grammar.no_slot and (vals[im.when_slot] != .atom or
            !std.mem.eql(u8, vals[im.when_slot].atom, im.when_atom))) continue;
        vals[im.slot] = if (schema.info(st.kind).slots[im.slot].ty == .value)
            (if (lexer.parseNumber(self.arena, &self.g.lex, im.text)) |n|
                Value{ .num = n }
            else
                Value{ .expr = im.text })
        else
            Value{ .atom = im.text };
    }
}

/// An expression read in its canonical form, each operator the grammar
/// does not list reported.
fn finishExpr(self: *Reader, e: []const u8, line: u32) Allocator.Error![]const u8 {
    var problems: std.ArrayList(expr.Problem) = .empty;
    const names: expr.Resolver = if (self.g.lex.case_sensitive)
        .{}
    else
        .{ .ctx = &self.spell, .func = resolveName };
    const canon = try expr.read(self.arena, self.g, e, names, &problems);
    for (problems.items) |pb| self.report.add(.@"error", .invalid, line, "expression '{s}': " ++
        "{s} is not an operator the {s} grammar lists; copied as written", .{
        e, pb.text, self.g.name,
    });
    return canon;
}

/// The value of a signal slot where case is folded: each signal with the
/// one spelling of its names.
fn finishSignals(self: *Reader, v: Value, line: u32) Allocator.Error!Value {
    switch (v) {
        .atom => |a| return .{ .atom = try self.spell.signal(self.arena, a) },
        .list => |items| {
            const out = try self.arena.alloc(Value, items.len);
            for (items, 0..) |it, k|
                out[k] = if (it == .atom)
                    Value{ .atom = try self.spell.signal(self.arena, it.atom) }
                else
                    try self.finishValue(it, line);
            return .{ .list = out };
        },
        else => return v,
    }
}

/// Does the line in the window hold a word with capitals?
fn hasCaps(self: *const Reader) bool {
    var caps = false;
    var k: usize = 0;
    while (self.toks()[k].tag != .nl) : (k += 1) {
        const t = self.toks()[k];
        // The lexer folds a word into a fresh copy only if it has capitals.
        if (t.text.ptr != t.raw.ptr) caps = true;
    }
    return caps;
}

/// The statement of the line in the window that may declare a name: a
/// model, a parameter, a subcircuit; any statement where the line has
/// capitals, so their spellings are learnt.
fn declaring(self: *Reader, caps: bool) Allocator.Error!?ir.Stmt {
    assert(self.toks().len > 0);
    const head = self.toks()[0];
    for (self.g.readCandidates(if (head.tag == .word) head.text else null)) |ri| {
        const rule = &self.g.rules[ri];
        if (rule.dir == .write or rule.within != null) continue;
        if (!caps and rule.kind != .model and rule.kind != .param) continue;
        if (try self.m.run(rule.kind, rule.pat, 0)) return try self.m.build(0);
    }
    for (self.g.blocks) |*b| {
        if (!caps and b.kind != .subckt) continue;
        const close: []const []const Node = if (caps) &.{b.close} else &.{};
        for ([_][]const []const Node{ &.{b.open}, b.inner, close }) |pats| {
            for (pats) |pat| {
                if (try self.m.run(b.kind, pat, 0)) return try self.m.build(0);
            }
        }
    }
    return null;
}

/// What the first pass keeps of a statement: its names' spellings, and
/// the name it declares.
fn learn(
    self: *Reader,
    st: *ir.Stmt,
    caps: bool,
    declared: *Declared,
    scratch: Allocator,
) Allocator.Error!void {
    const fold_case = !self.g.lex.case_sensitive;
    if (caps) try self.spell.names(st);
    if (st.kind != .model and st.kind != .param and st.kind != .subckt) return;
    if (fold_case) try self.spell.statement(scratch, st);
    const n = st.get("name");
    if (st.kind != .param and n == .atom) {
        const name = if (fold_case)
            try Spelling.lowered(scratch, n.atom)
        else
            n.atom;
        const gop = try declared.getOrPut(self.spell.perm, name);
        if (!gop.found_existing) gop.key_ptr.* = try self.spell.keep(name);
    }
}

/// The spelling of the models table `ty` and `params` fit best: the one
/// that says the most.
fn bestSpelling(
    arena: Allocator,
    g: *const Grammar,
    ty: []const u8,
    params: []const ir.Param,
) ?Hit {
    var best: ?Hit = null;
    for (g.models) |*e| {
        for (e.spellings) |*s| {
            if (!std.mem.eql(u8, s.type, ty)) continue;
            if (!spellingFits(arena, g, s, params)) continue;
            if (best == null or s.kv.len > best.?.s.kv.len) best = .{ .e = e, .s = s };
        }
    }
    return best;
}

/// Do the parameters say what the spelling's `key=value` conditions ask?
fn spellingFits(
    arena: Allocator,
    g: *const Grammar,
    s: *const grammar.ModelSpelling,
    params: []const ir.Param,
) bool {
    var ok = true;
    for (s.kv) |kv| {
        var found: ?Value = null;
        for (params) |p| {
            if (std.mem.eql(u8, p.key, kv.key)) found = p.val;
        }
        if (kv.absent) {
            if (found != null) ok = false;
        } else if (kv.min) {
            const least = lexer.parseNumber(arena, &g.lex, kv.val) orelse unreachable;
            if (found == null or found.? != .num or found.?.num.toFloat() < least.toFloat())
                ok = false;
        } else if (found == null or !valueIsText(arena, g, found.?, kv.val)) ok = false;
    }
    return ok;
}

/// A type word the table knows, with a level it does not, is a gap in the
/// table. A word it has never seen is a Verilog-A module.
fn unknownType(g: *const Grammar, line: u32, ty: []const u8, report: *ir.Report) void {
    var known_word = false;
    for (g.models) |*e| {
        for (e.spellings) |*s| {
            if (std.mem.eql(u8, s.type, ty)) known_word = true;
        }
    }
    if (known_word)
        report.add(
            .warning,
            .unsupported,
            line,
            "model type '{s}' with these parameters is not in the {s} models table; kept " ++
                "as written",
            .{ ty, g.name },
        );
}

/// The parameters the spelling did not consume. The statement was just
/// built and owns its list: filter it in place. A PDK's models carry most
/// of its text in their parameters.
fn withoutConsumed(params: []const ir.Param, hit: Hit) []ir.Param {
    const kept: []ir.Param = @constCast(params);
    var n: usize = 0;
    for (params) |p| {
        var consumed = false;
        for (hit.s.kv) |kv| {
            if (!kv.absent and std.mem.eql(u8, p.key, kv.key)) consumed = true;
        }
        if (consumed) continue;
        kept[n] = p;
        n += 1;
    }
    return kept[0..n];
}

fn describeNum(arena: Allocator, v: Value) Allocator.Error![]const u8 {
    return switch (v) {
        .num => |n| try std.fmt.allocPrint(arena, "{d}", .{n.toFloat()}),
        else => "?",
    };
}

fn valueIsText(arena: Allocator, g: *const Grammar, v: Value, text: []const u8) bool {
    return switch (v) {
        .num => |n| blk: {
            const want = lexer.parseNumber(arena, &g.lex, text) orelse break :blk false;
            break :blk n.toFloat() == want.toFloat();
        },
        .atom => |s| sameText(g, s, text),
        .expr => |s| sameText(g, s, text),
        .str => |s| sameText(g, s, text),
        else => false,
    };
}

/// `modeltype=RLGC` is `rlgc` where case does not matter.
fn sameText(g: *const Grammar, a: []const u8, b: []const u8) bool {
    return if (g.lex.case_sensitive) std.mem.eql(u8, a, b) else std.ascii.eqlIgnoreCase(a, b);
}
