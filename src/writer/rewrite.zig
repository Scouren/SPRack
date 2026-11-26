//! Rewrite: a statement that gives an instance parameter the target's device
//! does not take → the statements the target's grammar says it with (a
//! `rewrite` block), and the report entries the block calls for.
//!
//! The engine names no device and no parameter here: which statement is
//! rewritten, into what, and in which words it is reported are the lines of
//! the block (docs/src/grammar-reference.md, `rewrite`).
//!
//! Contents:
//! - `pub const Context = struct`
//! - `pub const Hit = struct`
//! - `pub fn apply(a: Allocator, st: *const ir.Stmt, ctx: Context) Allocator.Error!?[]ir.Stmt`
//! - `pub fn rewriteOf(g: *const Grammar, sg: ?*const Grammar, st: *const ir.Stmt) ?Hit`
//! - `pub fn readIn(dialect: []const u8, st: *const ir.Stmt) ?*const Grammar`
//! - `pub fn markUsed(g, dialect, stmts, used) void`
//! - `pub fn collectClashKeys(a, g, stmts, out, src) Allocator.Error!void`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const dialects = @import("dialects");
const expr = @import("expr");
const emit = @import("emit.zig");
const tables = @import("tables.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Kind = schema.Kind;
const Value = ir.Value;
const Emit = emit.Emit;
const spellingsOf = tables.spellingsOf;
const spellingCanon = tables.spellingCanon;
const takes = tables.takes;

/// What a rewrite is applied in: the two dialects, where its entries go,
/// and what the netlist says elsewhere.
pub const Context = struct {
    /// The dialect being written.
    g: *const Grammar,
    /// The dialect the statement was read in, if this binary has its grammar.
    sg: ?*const Grammar,
    /// An emitter for the statement, to show its values as the target writes them.
    em: *Emit,
    /// The name of the dialect the statement was read in, for `{from}`.
    source: []const u8,
    report: *ir.Report,
    /// The keys the grammar's `clash` lines watch (`collectClashKeys`).
    clash_keys: *const ir.CaselessSet,
    /// The statement is inside a subcircuit: a key of the netlist names one
    /// of its nodes by a path, whose last part is the node.
    nested: bool,
};

/// A rewrite that applies to a statement, and the value of the parameter
/// that calls for it.
pub const Hit = struct { rule: *const grammar.Rewrite, value: Value };

/// What a rewrite's templates and messages are filled from: the statement
/// being rewritten and the statements made for it so far.
const Fill = struct {
    a: Allocator,
    st: *const ir.Stmt,
    rule: *const grammar.Rewrite,
    /// The source dialect's parameter table for the kind, if it has one.
    from: ?[]const grammar.Spellings,
    em: *Emit,
    /// The dialect the statement was read in, for `{from}`.
    source: []const u8,
    /// The parameters no template names: they stay on a kept statement,
    /// and have no place on one that replaces it.
    rest: std.ArrayList(ir.Param) = .empty,
    /// The node a `clash` message is about, for `{node}`.
    node: []const u8 = "",
    /// The statements made, for a message that names one of their slots.
    made: []const ir.Stmt = &.{},

    /// The canonical name of a parameter key of the statement.
    fn canon(fill: *const Fill, key: []const u8) []const u8 {
        return if (fill.from) |t| spellingCanon(t, key) orelse key else key;
    }

    /// Does some template of the rewrite name `name`?
    fn uses(fill: *const Fill, name: []const u8) bool {
        for (fill.rule.parts) |part| for (part.sets) |set| {
            var rest = set.template;
            while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
                const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse break;
                if (std.ascii.eqlIgnoreCase(rest[open + 1 .. close], name)) return true;
                rest = rest[close + 1 ..];
            }
        };
        return false;
    }

    /// Fills `rest`: the parameters that are neither the rewrite's own nor
    /// named by a template.
    fn sortParams(fill: *Fill) Allocator.Error!void {
        for (fill.st.get("params").params) |p| {
            const name = fill.canon(p.key);
            if (std.ascii.eqlIgnoreCase(name, fill.rule.param) or fill.uses(name)) continue;
            try fill.rest.append(fill.a, p);
        }
    }

    /// Slot or parameter `name` of the statement; the last one given of a
    /// parameter said twice. Null: the statement gives neither.
    fn lookup(fill: *const Fill, name: []const u8) ?Value {
        if (schema.slotIndex(fill.st.kind, name)) |slot| {
            if (!std.mem.eql(u8, name, "params")) {
                const v = fill.st.at(slot);
                return if (v == .none) null else v;
            }
        }
        var found: ?Value = null;
        for (fill.st.get("params").params) |p| {
            if (std.ascii.eqlIgnoreCase(fill.canon(p.key), name)) found = p.val;
        }
        return found;
    }

    /// The value a template gives a slot of a statement of `kind`: the
    /// value itself where the template is one name, else a name made of
    /// its text, or for a value slot an expression.
    fn value(fill: *Fill, kind: Kind, set: grammar.Rewrite.Set) Allocator.Error!Value {
        const t = set.template;
        if (t.len > 2 and t[0] == '{' and std.mem.indexOfScalar(u8, t, '}') == t.len - 1)
            return fill.lookup(t[1 .. t.len - 1]) orelse .none;
        const text = try fill.expand(t, schema.info(kind).slots[set.slot].ty == .value);
        return if (schema.info(kind).slots[set.slot].ty == .value)
            .{ .expr = text }
        else
            .{ .atom = text };
    }

    /// `template` with each `{name}` replaced by that slot or parameter in
    /// canonical text, and each `[...]` left out when a name in it has no
    /// value. `arithmetic`: the text is an expression, so a value that is
    /// one is put in parentheses unless it stands alone as an argument.
    fn expand(fill: *Fill, template: []const u8, arithmetic: bool) Allocator.Error![]const u8 {
        // `grammar.compile` refuses a template whose brackets do not pair.
        assert(std.mem.count(u8, template, "{") == std.mem.count(u8, template, "}"));
        assert(std.mem.count(u8, template, "[") == std.mem.count(u8, template, "]"));
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        var group_start: ?usize = null;
        var group_empty = false;
        while (i < template.len) : (i += 1) {
            const c = template[i];
            if (c == '[') {
                group_start = out.items.len;
                group_empty = false;
            } else if (c == ']') {
                if (group_empty) out.shrinkRetainingCapacity(group_start.?);
                group_start = null;
            } else if (c == '{') {
                const close = std.mem.indexOfScalarPos(u8, template, i, '}') orelse template.len;
                const v = fill.lookup(template[i + 1 .. close]);
                if (v == null) group_empty = true;
                const text = if (v) |found| try expr.canonText(fill.a, found) else "";
                // An argument on its own, `f({x})` or `f(a,{x})`, needs no parentheses.
                const before: u8 = if (i > 0) template[i - 1] else 0;
                const after: u8 = if (close + 1 < template.len) template[close + 1] else 0;
                const alone = (before == '(' or before == ',') and (after == ')' or after == ',');
                if (arithmetic and v != null and v.? == .expr and !alone) {
                    try out.print(fill.a, "({s})", .{text});
                } else try out.appendSlice(fill.a, text);
                i = close;
            } else try out.append(fill.a, c);
        }
        return out.items;
    }

    /// A message of the rewrite: `{to}` is the dialect written, `{from}`
    /// the one read, `{what}` and `{node}` what the caller says; any other
    /// name is that slot or parameter of the statement as the target
    /// writes it, or a slot of the first statement made.
    fn message(fill: *Fill, template: []const u8, what: []const u8) Allocator.Error![]const u8 {
        assert(template.len > 0);
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < template.len) : (i += 1) {
            if (template[i] != '{') {
                try out.append(fill.a, template[i]);
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, template, i, '}') orelse template.len;
            const name = template[i + 1 .. close];
            i = close;
            const text: []const u8 = if (std.mem.eql(u8, name, "to"))
                fill.em.g.name
            else if (std.mem.eql(u8, name, "from"))
                fill.source
            else if (std.mem.eql(u8, name, "what"))
                what
            else if (std.mem.eql(u8, name, "node"))
                fill.node
            else if (fill.lookup(name)) |v|
                try fill.em.describe(v)
            else if (fill.made.len > 0 and schema.slotIndex(fill.made[0].kind, name) != null)
                try expr.canonText(
                    fill.a,
                    fill.made[0].at(schema.slotIndex(fill.made[0].kind, name).?),
                )
            else
                "";
            try out.appendSlice(fill.a, text);
        }
        return out.items;
    }
};

/// The statements `st` is written as where a rewrite of the target applies,
/// with the rewrite's entries added to the report; null where none applies.
pub fn apply(a: Allocator, st: *const ir.Stmt, ctx: Context) Allocator.Error!?[]ir.Stmt {
    const hit = rewriteOf(ctx.g, ctx.sg, st) orelse return null;
    const rule = hit.rule;
    assert(rule.kind == st.kind);
    assert(rule.parts.len > 0);
    var filled: Fill = .{
        .a = a,
        .st = st,
        .rule = rule,
        .from = if (ctx.sg) |g| g.paramsOf(st.kind) else null,
        .em = ctx.em,
        .source = ctx.source,
    };
    try filled.sortParams();
    if (!rule.parts[0].keep) try reportUnplaced(ctx.report, &filled);
    if (rule.clash) |clash| try reportClashes(ctx, &filled, clash);

    const parts = try a.alloc(ir.Stmt, rule.parts.len);
    for (rule.parts, parts, 0..) |part, *out, i| {
        out.* = if (part.keep) st.* else try ir.newStmt(a, part.kind, st.line);
        if (part.keep) {
            try out.own(a);
            const rest: Value = if (filled.rest.items.len > 0)
                .{ .params = filled.rest.items }
            else
                .none;
            try out.set(a, schema.slotOf(st.kind, "params").?, rest);
        } else {
            out.dialect = st.dialect;
            if (i == 0) out.tail = st.tail;
        }
        for (part.sets) |set| try out.set(a, set.slot, try filled.value(part.kind, set));
    }
    filled.made = parts;
    if (rule.note.len > 0)
        ctx.report.add(.info, .oneway, st.line, "{s}", .{try filled.message(rule.note, "")});
    return parts;
}

/// The first rewrite of `g` for a statement read in another dialect (`sg`)
/// that gives the rewrite's parameter, where `g`'s device does not take the
/// parameter and `g` can write and spell what the rewrite needs.
pub fn rewriteOf(g: *const Grammar, sg: ?*const Grammar, st: *const ir.Stmt) ?Hit {
    if (g.rewrites.len == 0) return null;
    if (sg) |s| if (s == g or std.mem.eql(u8, s.name, g.name)) return null;
    const table = g.paramsOf(st.kind) orelse return null;
    const v = st.get("params");
    if (v != .params) return null;
    const from = if (sg) |s| s.paramsOf(st.kind) else null;
    rules: for (g.rewrites) |*rule| {
        assert(rule.param.len > 0);
        if (rule.kind != st.kind or takes(table, rule.param)) continue;
        for (rule.kinds) |kind| if (!g.canWrite(kind)) continue :rules;
        for (rule.functions) |name| if (spellingsOf(g.functions, name) == null) continue :rules;
        var value: ?Value = null;
        for (v.params) |p| {
            const canon = if (from) |t| spellingCanon(t, p.key) orelse p.key else p.key;
            if (std.ascii.eqlIgnoreCase(canon, rule.param)) value = p.val;
        }
        if (value) |found| return .{ .rule = rule, .value = found };
    }
    return null;
}

/// The grammar a statement was read in: its own tag, else the netlist's.
pub fn readIn(dialect: []const u8, st: *const ir.Stmt) ?*const Grammar {
    return dialects.find(if (st.dialect != 0) dialects.nameOf(st.dialect) else dialect);
}

/// The kinds statements are written as where a rewrite applies, whose
/// boilerplate (`needs`) the netlist then needs.
// tidy: allow-fn(recursion) as deep as blocks nest, which the reader caps at ir.max_depth
pub fn markUsed(
    g: *const Grammar,
    dialect: []const u8,
    stmts: []const ir.Stmt,
    used: *[schema.kind_count]bool,
) void {
    if (g.rewrites.len == 0) return;
    for (stmts) |*s| {
        if (rewriteOf(g, readIn(dialect, s), s)) |hit| {
            for (hit.rule.parts) |part| {
                if (!part.keep) used[@backingInt(part.kind)] = true;
            }
        }
        markUsed(g, dialect, s.body, used);
    }
}

/// The keys the `clash` lines of `g`'s rewrites watch (the nodes an `.ic`
/// statement sets), anywhere in `stmts`.
// tidy: allow-fn(recursion) as deep as blocks nest, which the reader caps at ir.max_depth
pub fn collectClashKeys(
    a: Allocator,
    g: *const Grammar,
    stmts: []const ir.Stmt,
    out: *ir.CaselessSet,
    src: ?[]const u8,
) Allocator.Error!void {
    const clash = for (g.rewrites) |rule| {
        if (rule.clash) |c| break c;
    } else return;
    for (stmts) |*s| {
        if (s.kind == clash.kind and s.at(clash.slot) == .params) {
            for (s.at(clash.slot).params) |p| try ir.putName(out, a, src, p.key);
        }
        try collectClashKeys(a, g, s.body, out, src);
    }
}

// ---- private ----

/// For a rewrite that puts another statement in the original's place:
/// every slot and parameter of the original the new one has no
/// template for, each a loss in the rewrite's words.
fn reportUnplaced(report: *ir.Report, filled: *Fill) Allocator.Error!void {
    const st = filled.st;
    assert(!filled.rule.parts[0].keep);
    assert(filled.rule.loss.len > 0);
    const params_slot = schema.slotOf(st.kind, "params");
    for (schema.info(st.kind).slots, 0..) |slot, i| {
        if (st.at(i) == .none or filled.uses(slot.name)) continue;
        if (params_slot != null and params_slot.? == i) continue;
        const shown = try filled.em.describe(st.at(i));
        // A model is named, not given: `the model 'x'`, not `'master=x'`.
        const what = if (std.mem.eql(u8, slot.name, "master"))
            try filled.a.print("the model '{s}'", .{shown})
        else
            try filled.a.print("'{s}={s}'", .{ slot.name, shown });
        report.add(
            .@"error",
            .loss,
            st.line,
            "{s}",
            .{try filled.message(filled.rule.loss, what)},
        );
    }
    for (filled.rest.items) |p| {
        const what = if (p.val == .none)
            try filled.a.print("'{s}'", .{p.key})
        else
            try filled.a.print("'{s}={s}'", .{ p.key, try filled.em.describe(p.val) });
        report.add(
            .@"error",
            .loss,
            st.line,
            "{s}",
            .{try filled.message(filled.rule.loss, what)},
        );
    }
}

/// A statement elsewhere that says the rewritten parameter for one of
/// the original's nodes too (`clash`): an error for each such node.
/// Inside a subcircuit a key of the netlist names the node by its path,
/// so its last part is compared.
fn reportClashes(ctx: Context, filled: *Fill, clash: grammar.Rewrite.Clash) Allocator.Error!void {
    assert(clash.nodes.len > 0);
    for (clash.nodes) |slot| {
        assert(slot < schema.info(filled.st.kind).slots.len);
        const node = filled.st.at(slot);
        if (node != .atom) continue;
        const hit = if (!ctx.nested) ctx.clash_keys.contains(node.atom) else blk: {
            var keys = ctx.clash_keys.keyIterator();
            while (keys.next()) |key| {
                const dot = std.mem.lastIndexOfScalar(u8, key.*, '.') orelse continue;
                if (std.ascii.eqlIgnoreCase(key.*[dot + 1 ..], node.atom)) break :blk true;
            }
            break :blk false;
        };
        if (!hit) continue;
        filled.node = node.atom;
        ctx.report.add(
            .@"error",
            .invalid,
            filled.st.line,
            "{s}",
            .{try filled.message(clash.text, "")},
        );
    }
}

/// A capacitor `C1 a 0 1p ic=0.5 m=2`, as a reader of another dialect leaves it.
fn testCapacitor(a: Allocator) Allocator.Error!ir.Stmt {
    var st = try ir.newStmt(a, .capacitor, 2);
    try st.set(a, schema.slot(.capacitor, "name"), .{ .atom = "C1" });
    try st.set(a, schema.slot(.capacitor, "pos"), .{ .atom = "a" });
    try st.set(a, schema.slot(.capacitor, "neg"), .{ .atom = "0" });
    try st.set(a, schema.slot(.capacitor, "c"), .{ .num = .init("1", -12) });
    const params = try a.dupe(ir.Param, &.{
        .{ .key = "ic", .val = .{ .num = .init("0.5", 0) } },
        .{ .key = "m", .val = .{ .num = .init("2", 0) } },
    });
    try st.set(a, schema.slot(.capacitor, "params"), .{ .params = params });
    return st;
}

test "a rewrite block alone: statement in, statements and report entries out" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: grammar.Diag = .{};
    const g = try grammar.compile(a,
        \\dialect tiny
        \\lexer
        \\  title yes
        \\end
        \\rule capacitor = name~"C" pos neg c {...params}
        \\rule vsource   = name~"V" pos neg dc
        \\rule ic        = ".ic" { v(*)=values }
        \\params capacitor
        \\  same m
        \\end
        \\rewrite capacitor ic
        \\  when   vsource
        \\  keep   neg={name}__ic
        \\  add    vsource name=V{name}__ic pos={name}__ic neg={neg} dc={ic}
        \\  clash  ic.values pos neg : '{name}' and an .ic both set {node} ({from} to {to})
        \\  oneway : '{name}' starts at {ic} through {name}__ic
        \\end
    , "", &diag);
    const st = try testCapacitor(a);
    var report: ir.Report = .init(a);
    var em: Emit = .{ .g = &g, .arena = a, .st = &st, .report = &report };
    var clash_keys: ir.CaselessSet = .empty;
    const ctx: Context = .{
        .g = &g,
        .sg = null,
        .em = &em,
        .source = "other",
        .report = &report,
        .clash_keys = &clash_keys,
        .nested = false,
    };

    const parts = (try apply(a, &st, ctx)).?;
    try std.testing.expectEqual(2, parts.len);
    // The capacitor itself, to a node of its own, without the parameter.
    try std.testing.expectEqual(Kind.capacitor, parts[0].kind);
    try std.testing.expectEqualStrings("C1__ic", parts[0].get("neg").atom);
    try std.testing.expectEqual(1, parts[0].get("params").params.len);
    try std.testing.expectEqualStrings("m", parts[0].get("params").params[0].key);
    // The source the block adds.
    try std.testing.expectEqual(Kind.vsource, parts[1].kind);
    try std.testing.expectEqualStrings("VC1__ic", parts[1].get("name").atom);
    try std.testing.expectEqualStrings("C1__ic", parts[1].get("pos").atom);
    try std.testing.expectEqualStrings("0", parts[1].get("neg").atom);
    try std.testing.expectEqualStrings("0.5", parts[1].get("dc").num.digits());
    try std.testing.expectEqual(1, report.items.items.len);
    try std.testing.expectEqualStrings(
        "'C1' starts at 0.5 through C1__ic",
        report.items.items[0].msg,
    );

    // An `.ic` on one of its nodes is the block's clash, in the block's words.
    try ir.putName(&clash_keys, a, null, "a");
    var second: ir.Report = .init(a);
    var again = ctx;
    again.report = &second;
    _ = try apply(a, &st, again);
    try std.testing.expectEqual(2, second.items.items.len);
    try std.testing.expectEqualStrings(
        "'C1' and an .ic both set a (other to tiny)",
        second.items.items[0].msg,
    );

    // A statement of the dialect being written is not rewritten.
    var own = ctx;
    own.sg = &g;
    try std.testing.expectEqual(null, try apply(a, &st, own));
}
