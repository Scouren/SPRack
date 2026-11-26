//! Model cards: a `.model` read in one dialect → the card the target's
//! model of that family takes: its type word and level (the `models`
//! table), its parameters under the target's names (`modelparams`), and
//! what the target's model refuses or computes otherwise, said. Binned
//! cards (`nch.1`, `nch.2`) grouped under one model where the target
//! writes them so.

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const lexer = @import("lexer");
const expr = @import("expr");
const plugins = @import("plugins.zig");
const tables = @import("tables.zig");
const statement = @import("statement.zig");

const Allocator = std.mem.Allocator;
const Grammar = grammar.Grammar;
const Value = ir.Value;
const spellingsOf = tables.spellingsOf;
const spellingCanon = tables.spellingCanon;
const takes = tables.takes;
const Writer = statement.Writer;
const Error = Writer.Error;

/// The parameters of a model card, `ps` from `own` on, against the
/// `modelparams` tables of the two dialects for the family, when both
/// have one: each gets the target's spelling and number. One the
/// source's model does not take by the name written is not written, and
/// neither are those the target has one parameter for when they differ.
pub fn cardParams(
    w: *Writer,
    a: Allocator,
    st: *const ir.Stmt,
    family: []const u8,
    ps: *std.ArrayList(ir.Param),
    own: usize,
) Allocator.Error!void {
    const to = w.g.modelParamsOf(family) orelse return;
    const only = w.g.modelParamsOnly(family);
    const sg = w.sourceGrammar(st) orelse return;
    // A card the target refuses by one value (a diode's level=3) is
    // another model there: its other names are not checked against
    // this one's.
    const other_model = for (w.g.noparams) |np| {
        if (!np.err or np.value.len == 0 or !std.mem.eql(u8, np.family, family)) continue;
        const want = std.fmt.parseFloat(f64, np.value) catch continue;
        for (ps.items[own..]) |p| {
            if (std.ascii.eqlIgnoreCase(
                p.key,
                np.key,
            ) and p.val == .num and p.val.num.toFloat() == want) break;
        } else continue;
        break true;
    } else false;
    if (other_model) return;
    // A source with no table: every name as it is written, against a
    // table that lists all the target's card takes.
    const from = sg.modelParamsOf(family) orelse if (only) &.{} else return;
    const name = st.get("name").atom;
    var em = w.emitter(a, st);
    // Canonical names and values; `wrote` is the key each was written by.
    // `as_is`: the source's table does not list it, so it is copied.
    const Canon = struct { p: ir.Param, wrote: []const u8, as_is: bool = false, done: bool =
        false };
    var cs: std.ArrayList(Canon) = .empty;
    for (ps.items[own..]) |p| {
        var halves: std.ArrayList(ir.Param) = .empty;
        var taken = false;
        for (from) |*e| {
            for (e.spellings) |sp| {
                if (std.ascii.eqlIgnoreCase(sp, p.key)) break;
            } else continue;
            taken = true;
            // A number at an exponent a scale suffix can spell (500n).
            const half: Value = if (!e.halved)
                p.val
            else if (p.val == .num)
                try expr.arith(a, .mul, p.val, .{ .num = .init("5", -1) })
            else
                try expr.halve(a, p.val);
            const c: ir.Param = .{ .key = e.canon, .val = half };
            try cs.append(a, .{ .p = c, .wrote = if (e.halved) e.canon else p.key });
            if (e.halved) try halves.append(a, c);
        }
        if (halves.items.len > 0)
            w.report.add(.info, .rename, st.line, "model '{s}': {s} of {s} is {s}, each " ++
                "half its value", .{
                name, try em.describe(.{ .params = &.{p} }), sg.name, try em.describe(.{ .params = halves.items }),
            });
        if (taken) continue;
        if (spellingsOf(from, p.key)) |e| {
            w.report.add(
                .warning,
                .loss,
                st.line,
                "model '{s}': {s} not written: the {s} model of {s} does not take it; " ++
                    "that parameter is '{s}' there",
                .{ name, p.key, family, sg.name, e.spellings[0] },
            );
            continue;
        }
        try cs.append(a, .{ .p = p, .wrote = p.key, .as_is = true });
    }
    ps.shrinkRetainingCapacity(own);
    // A corner where one of the two computes something else, once a card.
    if (sg != w.g) for (cs.items) |c| {
        if (c.as_is) continue;
        const text = w.g.edgeText(
            family,
            c.p.key,
        ) orelse sg.edgeText(family, c.p.key) orelse continue;
        w.report.add(
            .warning,
            .caveat,
            st.line,
            "model '{s}': {s}: {s}",
            .{ name, c.p.key, text },
        );
        break;
    };
    for (cs.items, 0..) |*c, i| {
        if (c.done) continue;
        const e = (if (c.as_is) null else spellingsOf(to, c.p.key)) orelse {
            // A name the target's card does not take: not written. One
            // a `noparam` line names is left to that line.
            const named = for (w.g.noparams) |np| {
                if (std.mem.eql(u8, np.family, family) and (std.ascii.eqlIgnoreCase(np.key, c.p.key) or std.ascii.eqlIgnoreCase(np.key, c.wrote))) break true;
            } else false;
            // A card's level picks the simulator's model, in every dialect.
            const level = std.ascii.eqlIgnoreCase(c.p.key, "level");
            if (only and !named and !level and (if (c.as_is) spellingCanon(to, c.p.key) == null else true)) {
                var takes_list: std.ArrayList(u8) = .empty;
                for (to, 0..) |t, k| {
                    const dup = for (to[0..k]) |u| {
                        if (std.ascii.eqlIgnoreCase(u.spellings[0], t.spellings[0])) break true;
                    } else false;
                    if (!dup)
                        try takes_list.print(a, "{s}{s}", .{ if (takes_list.items.len > 0)
                            ", "
                        else
                            "", t.spellings[0] });
                }
                w.report.add(.@"error", .loss, st.line, "model '{s}': {s} not written: " ++
                    "the {s} card of {s} takes no such parameter; it takes {s}", .{
                    name,
                    try em.describe(
                        .{ .params = &.{.{ .key = c.wrote, .val = c.p.val }} },
                    ),
                    family,
                    w.g.name,
                    takes_list.items,
                });
                continue;
            }
            // Under the name it was written by: the canonical one may
            // mean something else to a target that does not list it,
            // unless a `noparam` line of the target names it.
            const refused = for (w.g.noparams) |np| {
                if (std.mem.eql(
                    u8,
                    np.family,
                    family,
                ) and std.ascii.eqlIgnoreCase(np.key, c.p.key)) break true;
            } else false;
            try ps.append(a, .{ .key = if (refused) c.p.key else c.wrote, .val = c.p.val });
            continue;
        };
        if (!e.halved) {
            if (!std.ascii.eqlIgnoreCase(e.spellings[0], c.wrote))
                w.report.add(
                    .info,
                    .rename,
                    st.line,
                    "model '{s}': the parameter '{s}' is spelled '{s}' in {s}",
                    .{ name, c.wrote, e.spellings[0], w.g.name },
                );
            try ps.append(a, .{ .key = if (std.ascii.eqlIgnoreCase(e.spellings[0], c.wrote))
                c.wrote
            else
                e.spellings[0], .val = c.p.val });
            continue;
        }
        // One parameter here for every canonical name of this spelling:
        // they must agree, one left out being 0.
        var value: ?Value = null;
        var same = true;
        var names: std.ArrayList(u8) = .empty;
        var shown: std.ArrayList(ir.Param) = .empty;
        for (to) |*t| {
            if (!t.halved or !std.mem.eql(u8, t.spellings[0], e.spellings[0])) continue;
            try names.print(a, "{s}{s}", .{ if (names.items.len > 0)
                " and "
            else
                "", t.canon });
            var v: Value = .{ .num = .init("0", 0) };
            // The last of a name, as the simulators take a card.
            for (cs.items[i..]) |*o|
                if (!o.as_is and std.ascii.eqlIgnoreCase(o.p.key, t.canon)) {
                    v = o.p.val;
                    o.done = true;
                    try shown.append(a, .{ .key = o.wrote, .val = v });
                };
            if (value) |first| same = same and v.eql(first) else value = v;
        }
        const was = try em.describe(.{ .params = shown.items });
        if (same) {
            const twice: ir.Param = .{
                .key = e.spellings[0],
                .val = try expr.arith(a, .mul, value.?, .{ .num = .init("2", 0) }),
            };
            const now = try em.describe(.{ .params = &.{twice} });
            if (!std.mem.eql(u8, was, now))
                w.report.add(
                    .info,
                    .rename,
                    st.line,
                    "model '{s}': {s} is written {s}, twice the value: {s} has the one " ++
                        "parameter for {s}",
                    .{ name, was, now, w.g.name, names.items },
                );
            try ps.append(a, twice);
            continue;
        }
        var why: std.ArrayList(u8) = .empty;
        if (w.g.computesText(family, e.canon)) |t|
            try why.print(a, ": {s} computes {s}", .{ w.g.name, t });
        if (sg.computesText(family, e.canon)) |t|
            try why.print(a, "; {s} computes {s}", .{ sg.name, t });
        w.report.add(.@"error", .loss, st.line, "model '{s}': {s} not written: {s} has " ++
            "the one parameter '{s}' for {s}, and they are not equal here (one left out " ++
            "is 0){s}", .{
            name, was, w.g.name, e.spellings[0], names.items, why.items,
        });
    }
}

/// The spelling of the family `entry` a card is written with: the first
/// whose `when` conditions hold, on the card's own parameters or on the
/// terminals of the instances that name it. A condition that cannot be
/// told, or instances of more than one count, is said.
pub fn chooseSpelling(
    w: *Writer,
    a: Allocator,
    st: *const ir.Stmt,
    entry: *const grammar.ModelEntry,
    fam: []const u8,
) Allocator.Error!grammar.ModelSpelling {
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
            const want = std.fmt.parseFloat(f64, c.val) catch unreachable;
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

pub fn unmapModel(w: *Writer, a: Allocator, st: *const ir.Stmt) (Error || error{Skip})!?ir.Stmt {
    const fam = st.get("family");
    const same = std.mem.eql(u8, w.sourceOf(st), w.g.name);
    if (fam != .atom) {
        if (!same and st.get("type") == .atom) {
            const ty = st.get("type").atom;
            // A type word the source dialect's table lists, at a level it
            // does not, is a gap in that table. Any other word is the
            // name of a Verilog-A module, which is the same everywhere.
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
            if (builtin) {
                w.report.add(.@"error", .unsupported, st.line, "model '{s}': type '{s}' " ++
                    "with these parameters is not in the {s} models table, so its {s} " ++
                    "name is unknown; written as it was", .{
                    st.get("name").atom, ty, w.sourceOf(st), w.g.name,
                });
            } else if (plugins.needsPlugin(w, ty)) {
                w.report.add(
                    .@"error",
                    .unsupported,
                    st.line,
                    "model '{s}' is of the Verilog-A module '{s}': {s} takes it only from " ++
                        "a plugin of the module; {s}",
                    .{ st.get("name").atom, ty, w.g.name, try plugins.pluginText(w, a, .missing, ty, "") },
                );
            } else if (w.g.plugin != null and st.get("params") == .params) {
                w.report.add(
                    .warning,
                    .caveat,
                    st.line,
                    "model '{s}' is of the Verilog-A module '{s}': {s} must load the same " ++
                        "module",
                    .{ st.get("name").atom, ty, w.g.name },
                );
                if (try plugins.pluginDrops(w, a, st, ty, true)) |out| return out;
            } else if (w.g.absentReason(.device)) |why| {
                w.report.add(
                    .@"error",
                    .unsupported,
                    st.line,
                    "model '{s}' is of the Verilog-A module '{s}': {s}",
                    .{ st.get("name").atom, ty, why },
                );
            } else {
                w.report.add(
                    .warning,
                    .caveat,
                    st.line,
                    "model '{s}' is of the Verilog-A module '{s}': {s} must load the same " ++
                        "module",
                    .{ st.get("name").atom, ty, w.g.name },
                );
            }
        }
        return st.*;
    }
    if (std.mem.eql(u8, fam.atom, ir.unlisted_builtin)) {
        var plain = st.*;
        try plain.own(a);
        try plain.set(a, schema.slot(.model, "family"), .none);
        if (!same)
            w.report.add(.@"error", .unsupported, st.line, "model '{s}': '{s}' is a " ++
                "built-in {s} model type that the {s} models table does not list, so its " ++
                "{s} name is unknown; written as it was", .{
                st.get("name").atom, st.get("type").atom, w.sourceOf(st), w.sourceOf(st), w.g.name,
            });
        return plain;
    }
    const pol: []const u8 = if (st.get("polarity") == .atom) st.get("polarity").atom else "";
    const entry = for (w.g.models) |*m| {
        if (std.mem.eql(u8, m.family, fam.atom) and std.mem.eql(u8, m.polarity, pol)) break m;
    } else {
        if (st.get("params") == .none) {
            if (schema.familyKind(fam.atom)) |k| {
                // Only a kind whose instances name no model can do without
                // the card; a MESFET still points at its (HFET) model.
                if (w.g.canWrite(k) and schema.slotOf(k, "master") == null) {
                    w.report.add(
                        .info,
                        .cosmetic,
                        st.line,
                        "model '{s}' only names a built-in {s}; {s} needs no such line",
                        .{ st.get("name").atom, fam.atom, w.g.name },
                    );
                    return error.Skip;
                }
            }
        }
        const who = if (w.caps) |c| c.family(fam.atom, pol) else "";
        // No model cards at all here (CDL): the grammar's reason, not a gap in its table.
        if (w.g.absentReason(.model)) |why| {
            w.report.add(.@"error", .unsupported, st.line, "model '{s}' cannot be written " ++
                "for {s}: {s}. Dialects that define the family: {s}", .{
                st.get("name").atom, w.g.name, why, if (who.len > 0) who else "none",
            });
            return null;
        }
        if (w.g.noFamilyReason(fam.atom)) |why| {
            w.report.add(.@"error", .unsupported, st.line, "model '{s}' ({s}{s}{s}) " ++
                "cannot be written for {s}: {s}. Defined by: {s}", .{
                st.get("name").atom, fam.atom,
                if (pol.len > 0)
                    " "
                else
                    "",
                pol,                 w.g.name,
                why,                 if (who.len > 0) who else "none",
            });
            return null;
        }
        w.report.add(.@"error", .unsupported, st.line, "model '{s}': {s}.spgrammar has no " ++
            "spelling for model family '{s}{s}{s}'. Defined by: {s}", .{
            st.get("name").atom, w.g.name,                         fam.atom,
            if (pol.len > 0)
                " "
            else
                "",
            pol,                 if (who.len > 0) who else "none",
        });
        return null;
    };
    if (entry.provided) {
        const file = plugins.providedFile(w, fam.atom) orelse {
            w.report.add(.@"error", .unsupported, st.line, "model '{s}' ({s}): {s} has no " ++
                "built-in {s}; it runs one as a compiled module given to the translation: " ++
                "--provide {s}=FILE", .{
                st.get("name").atom, fam.atom, w.g.name, fam.atom, fam.atom,
            });
            return null;
        };
        if (w.plugins_said.get(fam.atom) == null) {
            // Kept for the file: w.arena is the statement's when streamed.
            try w.plugins_said.put(w.perm, try w.perm.dupe(u8, fam.atom), {});
            w.report.add(
                .warning,
                .caveat,
                st.line,
                "model '{s}' ({s}): written for the module {s} given to the translation; " ++
                    "{s} has no built-in one",
                .{ st.get("name").atom, fam.atom, file, w.g.name },
            );
        }
    }
    const sp = try chooseSpelling(w, a, st, entry, fam.atom);
    var out = try ir.newStmt(a, .model, st.line);
    out.tail = st.tail;
    out.mask = st.mask;
    out.bound = st.bound;
    try out.own(a);
    try out.set(a, schema.slot(.model, "type"), .{ .atom = sp.type });
    try out.set(a, schema.slot(.model, "family"), .none);
    try out.set(a, schema.slot(.model, "polarity"), .none);
    var ps: std.ArrayList(ir.Param) = .empty;
    for (sp.kv) |kv| {
        if (kv.absent or kv.min) continue;
        const v: Value = if (lexer.parseNumber(a, &w.g.lex, kv.val)) |n|
            .{ .num = n }
        else
            .{ .atom = kv.val };
        try ps.append(a, .{ .key = kv.key, .val = v });
    }
    const selectors = ps.items.len;
    if (st.get("params") == .params) for (st.get("params").params) |p| {
        // A parameter the level says (`version=107` as `level=107`).
        const said = !same and for (sp.when) |c| {
            if (!c.isNodes() and std.ascii.eqlIgnoreCase(c.key, p.key)) break true;
        } else false;
        if (said) {
            w.report.add(.info, .oneway, st.line, "model '{s}': {s}={s} is said by the " ++
                "{s} {s} spelling and is not written: {s} has no such parameter; it reads " ++
                "back without it", .{
                st.get("name").atom, p.key,
                try expr.canonText(
                    a,
                    p.val,
                ),
                w.g.name,            try spellingText(a, sp),
                w.g.name,
            });
            continue;
        }
        try ps.append(a, p);
    };
    if (!same) {
        try cardParams(w, a, st, fam.atom, &ps, selectors);
        // A key given twice: SPICE keeps the last, Xyce rejects the card.
        // But a key that names the model here (`level=103`) stays, and
        // the card's own parameter of that name (PSP's LEVEL) goes.
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
        // Parameters this dialect's module for the family refuses.
        for (w.g.noparams) |*np| {
            if (!std.mem.eql(u8, np.family, fam.atom)) continue;
            var j: usize = 0;
            while (j < ps.items.len) : (j += 1) {
                const p = ps.items[j];
                if (!std.ascii.eqlIgnoreCase(p.key, np.key)) continue;
                if (np.value.len > 0 and (p.val != .num or p.val.num.toFloat() != (std.fmt.parseFloat(f64, np.value) catch unreachable))) continue;
                const name = st.get("name").atom;
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
    const th = try expr.thresholds(a, w.g, fam.atom, ps.items, true);
    if (th.changed and !th.no_half)
        w.report.add(
            .warning,
            .caveat,
            st.line,
            "model '{s}': the threshold and hysteresis are written as on and off levels; " ++
                "{s} moves smoothly between them where SPICE switches with hysteresis",
            .{ st.get("name").atom, w.g.name },
        );
    if (th.changed) for (th.params) |p| if (p.val == .expr and isLevel(w.g, p.key)) {
        w.report.add(
            .info,
            .oneway,
            st.line,
            "model '{s}': levels computed from expressions read back as equal expressions " ++
                "of another shape",
            .{st.get("name").atom},
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
            .{ st.get("name").atom, w.g.name },
        );
    try out.set(a, schema.slot(.model, "params"), if (th.params.len > 0)
        .{ .params = th.params }
    else
        .none);
    if (!same and st.get("params") == .params) {
        if (w.copied.n == 0)
            w.copied = .{
                .name = try w.perm.dupe(u8, st.get("name").atom),
                .family = fam.atom,
                .source = w.sourceOf(st),
                .line = st.line,
            };
        w.copied.n += 1;
    }
    return out;
}

/// Model cards `nch.1`, `nch.2`, ... grouped under `nch` by
/// `groupBins`: the block's header names the type, each bin is a line.
pub fn binnedModel(w: *Writer, st: *const ir.Stmt) Error!void {
    const b = w.g.blockOf(.model).?;
    const a = w.arena;
    const ti = schema.slot(.model, "type");
    const ni = schema.slot(.model, "name");
    var bins: std.ArrayList(ir.Stmt) = .empty;
    var head = st.*;
    head.body = &.{};
    try head.own(a);
    for (st.body) |*child| {
        if (child.kind != .model) {
            try bins.append(a, child.*);
            continue;
        }
        const m = (unmapModel(w, a, child) catch |err| switch (err) {
            error.Skip => continue,
            else => |e| return e,
        }) orelse continue;
        var bin = m;
        try bin.own(a);
        if (head.at(ti) == .none) try head.set(a, ti, m.at(ti));
        const full = child.get("name").atom;
        const dot = std.mem.lastIndexOfScalar(u8, full, '.').?;
        try bin.set(a, ni, .{ .atom = try std.fmt.allocPrint(a, "{s}:", .{full[dot + 1 ..]}) });
        try bin.set(a, ti, .none);
        try bins.append(a, bin);
    }
    var e = w.emitter(a, &head);
    if (!try e.seq(b.open)) {
        w.report.add(
            .@"error",
            .invalid,
            st.line,
            "model: required values missing for the {s} form",
            .{w.g.name},
        );
        return;
    }
    try w.lineTail(e.buf.items, st.tail);
    for (bins.items) |*bin| try w.stmt(bin);
    e.buf.clearRetainingCapacity();
    if (try e.seq(b.close)) try w.line(e.buf.items);
}

/// `nch` of the model card `nch.12`, or null.
pub fn binBase(st: *const ir.Stmt) ?[]const u8 {
    if (st.kind != .model or st.get("name") != .atom) return null;
    return ir.binBase(st.get("name").atom);
}

/// For a dialect that writes binned models as one block (Spectre), the
/// model cards `nch.1`, `nch.2`, ... of a list become one model `nch`
/// whose body holds them, where the first of them stood.
pub fn groupBins(arena: Allocator, stmts: []const ir.Stmt) Allocator.Error![]const ir.Stmt {
    var groups: std.StringArrayHashMapUnmanaged(std.ArrayList(ir.Stmt)) = .empty;
    for (stmts) |*s| {
        const base = binBase(s) orelse continue;
        const gop = try groups.getOrPut(arena, base);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, s.*);
    }
    var any_body = false;
    for (stmts) |s| any_body = any_body or s.body.len > 0;
    if (groups.count() == 0 and !any_body) return stmts;
    var out: std.ArrayList(ir.Stmt) = .empty;
    var done: std.StringHashMapUnmanaged(void) = .empty;
    for (stmts) |*s| {
        if (binBase(s)) |base| {
            if ((try done.getOrPut(arena, base)).found_existing) continue;
            var parent = try ir.newStmt(arena, .model, s.line);
            try parent.set(arena, schema.slot(.model, "name"), .{ .atom = base });
            parent.body = groups.get(base).?.items;
            try out.append(arena, parent);
            continue;
        }
        var copy = s.*;
        if (s.body.len > 0) copy.body = @constCast(try groupBins(arena, s.body));
        try out.append(arena, copy);
    }
    return out.items;
}

/// A switch on or off level named by one of the grammar's `threshold` lines.
pub fn isLevel(g: *const Grammar, key: []const u8) bool {
    for (g.thresholds) |t|
        if (std.ascii.eqlIgnoreCase(key, t.on) or std.ascii.eqlIgnoreCase(key, t.off)) return true;
    return false;
}

/// A spelling as the grammar's models table gives it, without its conditions.
pub fn spellingText(a: Allocator, sp: grammar.ModelSpelling) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, sp.type);
    for (sp.kv) |kv| if (!kv.absent) try out.print(a, " {s}={s}", .{ kv.key, kv.val });
    return out.items;
}

/// For every model an instance of `stmts` names, the fewest and the most
/// terminals of those instances (`when nodes>=n`).
pub fn collectTerminals(
    a: Allocator,
    stmts: []const ir.Stmt,
    out: *TerminalMap,
    src: ?[]const u8,
) Allocator.Error!void {
    for (stmts) |*s| {
        if (schema.info(s.kind).class == .device)
            if (schema.slotOf(s.kind, "master")) |mi| if (s.at(mi) == .atom) {
                const n = terminalCount(s);
                const gop = try out.getOrPut(a, s.at(mi).atom);
                if (gop.found_existing) {
                    gop.value_ptr.min = @min(gop.value_ptr.min, n);
                    gop.value_ptr.max = @max(gop.value_ptr.max, n);
                } else {
                    if (src) |t| gop.key_ptr.* = try ir.keepText(a, t, s.at(mi).atom);
                    gop.value_ptr.* = .{ .min = n, .max = n };
                }
            };
        try collectTerminals(a, s.body, out, src);
    }
}

/// How many terminals a device statement connects.
pub fn terminalCount(st: *const ir.Stmt) u32 {
    var n: u32 = 0;
    for (schema.info(st.kind).slots, 0..) |sl, i| {
        if (sl.ty != .node) continue;
        switch (st.at(i)) {
            .list => |l| n += @intCast(l.len),
            .none => {},
            else => n += 1,
        }
    }
    return n;
}

/// The fewest and the most terminals of the instances that name a model.
pub const Terminals = struct { min: u32, max: u32 };

pub const TerminalMap = std.HashMapUnmanaged(
    []const u8,
    Terminals,
    ir.Caseless,
    std.hash_map.default_max_load_percentage,
);

pub fn collectModules(
    arena: Allocator,
    stmts: []const ir.Stmt,
    out: *std.StringHashMapUnmanaged([]const u8),
) Allocator.Error!void {
    for (stmts) |*s| {
        if (s.kind == .model and s.get("family") == .none and s.get("type") == .atom and
            s.get("name") == .atom)
            try out.put(arena, s.get("name").atom, s.get("type").atom);
        try collectModules(arena, s.body, out);
    }
}
