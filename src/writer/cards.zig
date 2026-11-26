//! Model cards: a `.model` read in one dialect → the card the target's
//! model of that family takes: its type word and level (the `models`
//! table), its parameters under the target's names (`cardparams.zig`),
//! and what the target's model refuses or computes otherwise, said.
//! Binned cards are `bins.zig`'s.
//!
//! Contents:
//! - `pub fn unmapModel(w: *Writer, a: Allocator, st: *const ir.Stmt)
//!   (Error || error{Skip})!?ir.Stmt`

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const expr = @import("expr");
const plugins = @import("plugins.zig");
const cardparams = @import("cardparams.zig");
const statement = @import("statement.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Grammar = grammar.Grammar;
const Value = ir.Value;
const Writer = statement.Writer;
const Error = Writer.Error;

/// A model card read in one dialect → the card of the target's model of
/// its family. Null where the target has no such model (said);
/// `error.Skip` where nothing is to be written.
pub fn unmapModel(w: *Writer, a: Allocator, st: *const ir.Stmt) (Error || error{Skip})!?ir.Stmt {
    assert(st.kind == .model);
    const fam = st.get("family");
    const same = std.mem.eql(u8, w.sourceOf(st), w.g.name);
    if (fam != .atom) return typeOnly(w, a, st, same);
    if (std.mem.eql(u8, fam.atom, ir.unlisted_builtin)) return try unlistedBuiltin(w, a, st, same);
    const pol: []const u8 = if (st.get("polarity") == .atom) st.get("polarity").atom else "";
    const entry = findEntry(w.g, fam.atom, pol) orelse {
        try noEntry(w, st, fam.atom, pol);
        return null;
    };
    if (entry.provided and !try sayProvided(w, st, entry)) return null;
    const sp = try chooseSpelling(w, a, st, entry, fam.atom);
    var out = try newCard(a, st, sp);
    var ps: std.ArrayList(ir.Param) = .empty;
    try selectorParams(w, a, sp, &ps);
    const selectors = ps.items.len;
    try ownParams(w, a, st, sp, same, &ps);
    if (!same) {
        try cardparams.cardParams(w, a, st, fam.atom, &ps, selectors);
        dropDuplicates(w, st, &ps, selectors);
        try dropRefused(w, st, fam.atom, &ps);
    }
    const th = try expr.thresholds(a, w.g, fam.atom, ps.items, true);
    sayThresholds(w, st, th);
    try out.set(a, schema.slot(.model, "params"), if (th.params.len > 0)
        .{ .params = th.params }
    else
        .none);
    if (!same and st.get("params") == .params) try noteCopied(w, st, fam.atom);
    return out;
}

// ---- private ----

/// A card with a type word and no family: a gap in the source dialect's
/// models table, or a Verilog-A module, said; written as it was.
fn typeOnly(
    w: *Writer,
    a: Allocator,
    st: *const ir.Stmt,
    same: bool,
) (Error || error{Skip})!?ir.Stmt {
    assert(st.get("family") != .atom);
    if (same or st.get("type") != .atom) return st.*;
    const ty = st.get("type").atom;
    const name = st.get("name").atom;
    if (try sourceLists(w, a, st, ty)) {
        w.report.add(.@"error", .unsupported, st.line, "model '{s}': type '{s}' " ++
            "with these parameters is not in the {s} models table, so its {s} " ++
            "name is unknown; written as it was", .{
            name, ty, w.sourceOf(st), w.g.name,
        });
    } else if (plugins.needsPlugin(w, ty)) {
        w.report.add(
            .@"error",
            .unsupported,
            st.line,
            "model '{s}' is of the Verilog-A module '{s}': {s} takes it only from " ++
                "a plugin of the module; {s}",
            .{ name, ty, w.g.name, try plugins.pluginText(w, a, .missing, ty, "") },
        );
    } else if (w.g.plugin != null and st.get("params") == .params) {
        w.report.add(
            .warning,
            .caveat,
            st.line,
            "model '{s}' is of the Verilog-A module '{s}': {s} must load the same " ++
                "module",
            .{ name, ty, w.g.name },
        );
        if (try plugins.pluginDrops(w, a, st, ty, true)) |out| return out;
    } else if (w.g.absentReason(.device)) |why| {
        w.report.add(
            .@"error",
            .unsupported,
            st.line,
            "model '{s}' is of the Verilog-A module '{s}': {s}",
            .{ name, ty, why },
        );
    } else {
        w.report.add(
            .warning,
            .caveat,
            st.line,
            "model '{s}' is of the Verilog-A module '{s}': {s} must load the same " ++
                "module",
            .{ name, ty, w.g.name },
        );
    }
    return st.*;
}

/// Whether the type word `ty` is one the source dialect's models table
/// lists, at a level it does not: a gap in that table. Any other word is
/// the name of a Verilog-A module, which is the same everywhere. A type
/// the source's table gives a reason for is said and skipped.
fn sourceLists(
    w: *Writer,
    a: Allocator,
    st: *const ir.Stmt,
    ty: []const u8,
) (Error || error{Skip})!bool {
    assert(!std.mem.eql(u8, w.sourceOf(st), w.g.name));
    var builtin = w.caps == null;
    if (w.caps) |c| for (c.grammars) |*sg| {
        if (!std.mem.eql(u8, sg.name, w.sourceOf(st))) continue;
        if (sg.ownModelReason(ty)) |why| {
            w.report.add(
                .@"error",
                .unsupported,
                st.line,
                "model '{s}' of type '{s}' cannot be written for {s}: {s}",
                .{ st.get("name").atom, ty, w.g.name, why },
            );
            try w.comment(
                try a.print(
                    "[sprack] not written: model '{s}' ({s})",
                    .{ st.get("name").atom, ty },
                ),
            );
            return error.Skip;
        }
        for (sg.models) |*m| for (m.spellings) |*sp| {
            if (std.ascii.eqlIgnoreCase(sp.type, ty)) builtin = true;
        };
    };
    return builtin;
}

/// A built-in type the source's models table does not list: written as
/// it was, without its family.
fn unlistedBuiltin(w: *Writer, a: Allocator, st: *const ir.Stmt, same: bool) Error!ir.Stmt {
    var plain = st.*;
    try plain.own(a);
    try plain.set(a, schema.slot(.model, "family"), .none);
    if (!same) {
        const src = w.sourceOf(st);
        w.report.add(.@"error", .unsupported, st.line, "model '{s}': '{s}' is a " ++
            "built-in {s} model type that the {s} models table does not list, so its " ++
            "{s} name is unknown; written as it was", .{
            st.get("name").atom, st.get("type").atom, src, src, w.g.name,
        });
    }
    return plain;
}

/// The target's `models` line for a family and polarity, or null.
fn findEntry(g: *const Grammar, fam: []const u8, pol: []const u8) ?*const grammar.ModelEntry {
    for (g.models) |*m|
        if (std.mem.eql(u8, m.family, fam) and std.mem.eql(u8, m.polarity, pol)) return m;
    return null;
}

/// A family the target's `models` table has no line for: a card it needs
/// no line for is skipped (said), any other is said and not written.
fn noEntry(w: *Writer, st: *const ir.Stmt, fam: []const u8, pol: []const u8) error{Skip}!void {
    assert(findEntry(w.g, fam, pol) == null);
    const name = st.get("name").atom;
    if (st.get("params") == .none) {
        if (schema.familyKind(fam)) |k| {
            // Only a kind whose instances name no model can do without
            // the card; a MESFET still points at its (HFET) model.
            if (w.g.canWrite(k) and schema.slotOf(k, "master") == null) {
                w.report.add(
                    .info,
                    .cosmetic,
                    st.line,
                    "model '{s}' only names a built-in {s}; {s} needs no such line",
                    .{ name, fam, w.g.name },
                );
                return error.Skip;
            }
        }
    }
    const who = if (w.caps) |c| c.family(fam, pol) else "";
    const defined = if (who.len > 0) who else "none";
    const gap = if (pol.len > 0) " " else "";
    // No model cards at all here (CDL): the grammar's reason, not a gap in its table.
    if (w.g.absentReason(.model)) |why| {
        w.report.add(.@"error", .unsupported, st.line, "model '{s}' cannot be written " ++
            "for {s}: {s}. Dialects that define the family: {s}", .{
            name, w.g.name, why, defined,
        });
        return;
    }
    if (w.g.noFamilyReason(fam)) |why| {
        w.report.add(.@"error", .unsupported, st.line, "model '{s}' ({s}{s}{s}) " ++
            "cannot be written for {s}: {s}. Defined by: {s}", .{
            name, fam, gap, pol, w.g.name, why, defined,
        });
        return;
    }
    w.report.add(.@"error", .unsupported, st.line, "model '{s}': {s}.spgrammar has no " ++
        "spelling for model family '{s}{s}{s}'. Defined by: {s}", .{
        name, w.g.name, fam, gap, pol, defined,
    });
}

/// A family the target runs only as a compiled module given to the
/// translation: false where none is given (said), the first card of the
/// family said once a file.
fn sayProvided(w: *Writer, st: *const ir.Stmt, entry: *const grammar.ModelEntry) Error!bool {
    assert(entry.provided);
    const fam = entry.family;
    const file = plugins.providedFile(w, fam) orelse {
        w.report.add(.@"error", .unsupported, st.line, "model '{s}' ({s}): {s} has no " ++
            "built-in {s}; it runs one as a compiled module given to the translation: " ++
            "--provide {s}=FILE", .{
            st.get("name").atom, fam, w.g.name, fam, fam,
        });
        return false;
    };
    if (w.plugins_said.get(fam) != null) return true;
    // Kept for the file: w.arena is the statement's when streamed.
    try w.plugins_said.put(w.perm, try w.perm.dupe(u8, fam), {});
    w.report.add(
        .warning,
        .caveat,
        st.line,
        "model '{s}' ({s}): written for the module {s} given to the translation; " ++
            "{s} has no built-in one",
        .{ st.get("name").atom, fam, file, w.g.name },
    );
    return true;
}

/// The target's card for `st`, of the spelling `sp`'s type, with no
/// parameters yet.
fn newCard(a: Allocator, st: *const ir.Stmt, sp: grammar.ModelSpelling) Error!ir.Stmt {
    var out = try ir.newStmt(a, .model, st.line);
    out.tail = st.tail;
    out.mask = st.mask;
    out.bound = st.bound;
    try out.own(a);
    try out.set(a, schema.slot(.model, "type"), .{ .atom = sp.type });
    try out.set(a, schema.slot(.model, "family"), .none);
    try out.set(a, schema.slot(.model, "polarity"), .none);
    return out;
}

/// The parameters the spelling `sp` writes to pick the model (`level=3`).
fn selectorParams(
    w: *Writer,
    a: Allocator,
    sp: grammar.ModelSpelling,
    ps: *std.ArrayList(ir.Param),
) Error!void {
    for (sp.kv) |kv| {
        if (kv.absent or kv.min) continue;
        const v: Value = if (lexer.parseNumber(a, &w.g.lex, kv.val)) |n|
            .{ .num = n }
        else
            .{ .atom = kv.val };
        try ps.append(a, .{ .key = kv.key, .val = v });
    }
}

/// The card's own parameters, after the selectors; one the level says
/// (`version=107` as `level=107`) is not written, and said.
fn ownParams(
    w: *Writer,
    a: Allocator,
    st: *const ir.Stmt,
    sp: grammar.ModelSpelling,
    same: bool,
    ps: *std.ArrayList(ir.Param),
) Error!void {
    assert(ps.items.len <= sp.kv.len);
    if (st.get("params") != .params) return;
    for (st.get("params").params) |p| {
        const said = !same and for (sp.when) |c| {
            if (!c.isNodes() and std.ascii.eqlIgnoreCase(c.key, p.key)) break true;
        } else false;
        if (said) {
            w.report.add(.info, .oneway, st.line, "model '{s}': {s}={s} is said by the " ++
                "{s} {s} spelling and is not written: {s} has no such parameter; it reads " ++
                "back without it", .{
                st.get("name").atom,          p.key,
                try expr.canonText(a, p.val), w.g.name,
                try spellingText(a, sp),      w.g.name,
            });
            continue;
        }
        try ps.append(a, p);
    }
}

/// A key given twice: SPICE keeps the last, Xyce rejects the card. But a
/// key that names the model here (`level=103`) stays, and the card's own
/// parameter of that name (PSP's LEVEL) goes.
fn dropDuplicates(
    w: *Writer,
    st: *const ir.Stmt,
    ps: *std.ArrayList(ir.Param),
    selectors: usize,
) void {
    assert(selectors <= ps.items.len);
    var i: usize = ps.items.len;
    while (i > 0) {
        i -= 1;
        const k = ps.items[i].key;
        for (ps.items[i + 1 ..], i + 1..) |later, j|
            if (std.ascii.eqlIgnoreCase(later.key, k)) {
                if (i < selectors) {
                    w.report.add(
                        .warning,
                        .loss,
                        st.line,
                        "model '{s}': its own '{s}' is not written: in {s} that " ++
                            "parameter names the model",
                        .{ st.get("name").atom, later.key, w.g.name },
                    );
                    _ = ps.orderedRemove(j);
                } else {
                    w.report.add(
                        .warning,
                        .invalid,
                        st.line,
                        "model '{s}': '{s}' is given twice; the last value is kept",
                        .{ st.get("name").atom, k },
                    );
                    _ = ps.orderedRemove(i);
                }
                break;
            };
    }
}

/// Parameters this dialect's module for the family refuses (`noparam`):
/// not written; an error said here, a warning counted for the end.
fn dropRefused(
    w: *Writer,
    st: *const ir.Stmt,
    fam: []const u8,
    ps: *std.ArrayList(ir.Param),
) Error!void {
    assert(!std.mem.eql(u8, w.sourceOf(st), w.g.name));
    const name = st.get("name").atom;
    for (w.g.noparams) |*np| {
        if (!std.mem.eql(u8, np.family, fam)) continue;
        var j: usize = 0;
        while (j < ps.items.len) : (j += 1) {
            const p = ps.items[j];
            if (!std.ascii.eqlIgnoreCase(p.key, np.key)) continue;
            if (np.value.len > 0) {
                // The grammar reader refuses a value that is not a number.
                const want = std.fmt.parseFloat(f64, np.value) catch continue;
                if (p.val != .num or p.val.num.toFloat() != want) continue;
            }
            if (np.err) {
                w.report.add(
                    .@"error",
                    .loss,
                    st.line,
                    "model '{s}': {s} not written: {s}",
                    .{ name, p.key, np.text },
                );
            } else {
                const r = try w.refused.getOrPut(w.perm, np);
                if (r.found_existing)
                    r.value_ptr.n += 1
                else
                    r.value_ptr.* = .{
                        .n = 1,
                        .name = try w.perm.dupe(u8, name),
                        .line = st.line,
                    };
            }
            _ = ps.orderedRemove(j);
            break;
        }
    }
}

/// What writing a switch's threshold and hysteresis as on and off levels
/// changes, said.
fn sayThresholds(w: *Writer, st: *const ir.Stmt, th: expr.Thresholds) void {
    if (th.no_half) assert(th.changed);
    const name = st.get("name").atom;
    if (th.changed and !th.no_half)
        w.report.add(
            .warning,
            .caveat,
            st.line,
            "model '{s}': the threshold and hysteresis are written as on and off levels; " ++
                "{s} moves smoothly between them where SPICE switches with hysteresis",
            .{ name, w.g.name },
        );
    if (th.changed) for (th.params) |p| if (p.val == .expr and isLevel(w.g, p.key)) {
        w.report.add(
            .info,
            .oneway,
            st.line,
            "model '{s}': levels computed from expressions read back as equal expressions " ++
                "of another shape",
            .{name},
        );
        break;
    };
    if (th.no_half)
        w.report.add(
            .@"error",
            .loss,
            st.line,
            "model '{s}': a switch with no hysteresis has no {s} form; its on and off " ++
                "levels would be equal",
            .{ name, w.g.name },
        );
}

/// A card whose parameters were copied by name, counted for the one
/// caveat that names the first.
fn noteCopied(w: *Writer, st: *const ir.Stmt, fam: []const u8) Error!void {
    if (w.copied.n == 0)
        w.copied = .{
            .name = try w.perm.dupe(u8, st.get("name").atom),
            .family = fam,
            .source = w.sourceOf(st),
            .line = st.line,
        };
    w.copied.n += 1;
}

/// The spelling of the family `entry` a card is written with: the first
/// whose `when` conditions hold, on the card's own parameters or on the
/// terminals of the instances that name it. A condition that cannot be
/// told, or instances of more than one count, is said.
fn chooseSpelling(
    w: *Writer,
    a: Allocator,
    st: *const ir.Stmt,
    entry: *const grammar.ModelEntry,
    fam: []const u8,
) Allocator.Error!grammar.ModelSpelling {
    assert(entry.spellings.len > 0);
    const name = st.get("name").atom;
    const ps: []const ir.Param = if (st.get("params") == .params)
        st.get("params").params
    else
        &.{};
    const used = w.terminals.get(name);
    var unknown: ?[]const u8 = null;
    var mixed = false;
    for (entry.spellings) |sp| {
        const holds = for (sp.when) |c| {
            // The grammar reader refuses a `when` value that is not a number.
            const want = std.fmt.parseFloat(f64, c.val) catch break false;
            if (c.isNodes()) {
                const t = used orelse {
                    unknown = unknown orelse "no instance in this file names it";
                    break false;
                };
                if (t.min < @as(
                    u32,
                    @intFromFloat(want),
                ) and t.max >= @as(u32, @intFromFloat(want))) mixed = true;
                if (@as(f64, @floatFromInt(t.min)) < want) break false;
                continue;
            }
            const v = for (ps) |p| {
                if (std.ascii.eqlIgnoreCase(p.key, c.key)) break p.val;
            } else {
                unknown = unknown orelse try a.print("it gives no {s}", .{c.key});
                break false;
            };
            if (v != .num) {
                unknown = unknown orelse try a.print("its {s} is not a number", .{c.key});
                break false;
            }
            if (v.num.toFloat() != want) {
                unknown = unknown orelse try a.print(
                    "{s}={s} is none of the values the spellings name",
                    .{ c.key, try expr.canonText(a, v) },
                );
                break false;
            }
        } else true;
        if (!holds) continue;
        if (std.mem.eql(u8, w.sourceOf(st), w.g.name)) return sp;
        if (mixed)
            w.report.add(.warning, .ambiguous, st.line, "model '{s}' ({s}): instances " ++
                "with {d} and with {d} terminals name it, and {s} has a model of its own " ++
                "for each; it is written as {s}", .{
                name, fam, used.?.min, used.?.max, w.g.name, try spellingText(a, sp),
            })
        else if (unknown) |why|
            if (sp.when.len == 0)
                w.report.add(.warning, .caveat, st.line, "model '{s}' ({s}): {s} writes " ++
                    "another model by its conditions, and {s}; it is written as {s}", .{
                    name, fam, w.g.name, why, try spellingText(a, sp),
                });
        return sp;
    }
    return entry.spellings[0];
}

/// A switch on or off level named by one of the grammar's `threshold` lines.
fn isLevel(g: *const Grammar, key: []const u8) bool {
    for (g.thresholds) |t|
        if (std.ascii.eqlIgnoreCase(key, t.on) or std.ascii.eqlIgnoreCase(key, t.off)) return true;
    return false;
}

/// A spelling as the grammar's models table gives it, without its conditions.
fn spellingText(a: Allocator, sp: grammar.ModelSpelling) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, sp.type);
    for (sp.kv) |kv| if (!kv.absent) try out.print(a, " {s}={s}", .{ kv.key, kv.val });
    return out.items;
}
