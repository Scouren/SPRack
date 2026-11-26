//! Instance parameters: the parameters a device is given → those the
//! target's device takes, under its names (the `params` table of the
//! kind), the rest reported; and the parameters defined inside a
//! subcircuit moved to its header where the target wants them there
//! (`hoist`).

const std = @import("std");
const grammar = @import("grammar");
const schema = @import("schema");
const ir = @import("ir");
const tables = @import("tables.zig");
const statement = @import("statement.zig");

const Allocator = std.mem.Allocator;
const spellingCanon = tables.spellingCanon;
const takes = tables.takes;
const Writer = statement.Writer;
const Error = Writer.Error;

/// A parameter statement of a dialect the grammar's `hoist param` lists.
pub fn hoists(w: *const Writer, st: *const ir.Stmt) bool {
    if (st.kind != .param or st.get("params") != .params) return false;
    for (w.g.hoist_param) |d| {
        if (std.mem.eql(u8, d, w.sourceOf(st))) return true;
    }
    return false;
}

/// `hoist param`: subcircuit `st` with the parameter statements of its
/// body on its header, the only place an instance sets one for itself
/// alone here. A later value of a name replaces an earlier one, the
/// header's too, as the listed dialects take it (docs/verification.md
/// 4.14). Null: nothing moves.
pub fn hoistParams(w: *Writer, st: *const ir.Stmt) Allocator.Error!?ir.Stmt {
    if (st.kind != .subckt or w.g.hoist_param.len == 0) return null;
    var any = false;
    var unmeasured: ?[]const u8 = null;
    for (st.body) |*c| {
        if (hoists(w, c))
            any = true
        else if (c.kind == .param and !std.mem.eql(u8, w.sourceOf(c), w.g.name))
            unmeasured = w.sourceOf(c);
    }
    const h = if (any) &w.hoisted else &w.unhoisted;
    if (any or unmeasured != null) {
        if (h.n == 0)
            h.* = .{ .name = if (st.get("name") == .atom)
                try w.perm.dupe(u8, st.get("name").atom)
            else
                "", .source = unmeasured orelse "", .line = st.line };
        h.n += 1;
    }
    if (!any) return null;
    const a = w.arena;
    const pi = schema.slot(.subckt, "params");
    var ps: std.ArrayList(ir.Param) = .empty;
    if (st.at(pi) == .params) try ps.appendSlice(a, st.at(pi).params);
    var body: std.ArrayList(ir.Stmt) = try .initCapacity(a, st.body.len);
    for (st.body) |*c| {
        if (!hoists(w, c)) {
            body.appendAssumeCapacity(c.*);
            continue;
        }
        next: for (c.get("params").params) |p| {
            for (ps.items) |*q| if (std.ascii.eqlIgnoreCase(q.key, p.key)) {
                q.val = p.val;
                continue :next;
            };
            try ps.append(a, p);
        }
        if (c.tail.len > 0)
            body.appendAssumeCapacity(.{ .kind = .comment, .raw = c.tail, .line = c.line });
    }
    var out = st.*;
    try out.own(a);
    try out.set(a, pi, .{ .params = ps.items });
    out.body = body.items;
    return out;
}

/// A device's instance parameters against the target's `params` table:
/// each is renamed to the target's spelling, and one the target's
/// device does not take is a loss, not copied. Null: nothing changes.
pub fn instParams(w: *Writer, a: Allocator, st: *const ir.Stmt) Allocator.Error!?ir.Stmt {
    if (std.mem.eql(u8, w.sourceOf(st), w.g.name)) return null;
    const idx = schema.slotOf(st.kind, "params") orelse return null;
    const v = st.at(idx);
    if (v != .params) return null;
    const from = if (w.sourceGrammar(st)) |sg| sg.paramsOf(st.kind) else null;
    // Without a table here, the source's own spellings still go back to canonical names.
    const open: []const grammar.Spellings = &.{.{ .canon = "...", .spellings = &.{"..."} }};
    const table = w.g.paramsOf(st.kind) orelse if (from != null) open else return null;
    var em = w.emitter(a, st);
    var out: std.ArrayList(ir.Param) = .empty;
    // The spellings parameters of other names were written under.
    var renamed: std.ArrayList([]const u8) = .empty;
    var changed = false;
    for (v.params) |p| {
        const canon = if (from) |t| spellingCanon(t, p.key) orelse p.key else p.key;
        const entry = for (table) |*e| {
            if (std.ascii.eqlIgnoreCase(e.canon, canon)) break e;
        } else {
            // `same ...`: the table renames; what it does not list passes as written.
            // In the canonical spelling, when the source's table had its own.
            if (grammar.paramsOpen(table)) {
                try out.append(a, .{ .key = if (std.ascii.eqlIgnoreCase(canon, p.key))
                    p.key
                else
                    canon, .val = p.val });
                if (!std.ascii.eqlIgnoreCase(canon, p.key)) {
                    w.report.add(
                        .info,
                        .rename,
                        st.line,
                        "{s}: the instance parameter '{s}' is spelled '{s}' in {s}",
                        .{ @tagName(st.kind), p.key, canon, w.g.name },
                    );
                    changed = true;
                }
                continue;
            }
            const shown = if (p.val == .none)
                p.key
            else
                try a.print("{s}={s}", .{ p.key, try em.describe(p.val) });
            if (try em.inert(p.key)) |why| {
                // A loss all the same: the statement reads back without it.
                w.report.add(
                    .info,
                    .loss,
                    st.line,
                    "{s}: '{s}' is not written: {s}",
                    .{ @tagName(st.kind), shown, why },
                );
            } else w.report.add(.@"error", .loss, st.line, "{s}: '{s}' has no spelling in " ++
                "{s}, whose {s} takes no such {s}", .{
                @tagName(st.kind), shown, w.g.name, @tagName(st.kind),
                if (schema.info(st.kind).class == .device)
                    "instance parameter"
                else
                    "parameter",
            });
            changed = true;
            continue;
        };
        if (entry.positive and p.val == .num and p.val.num.toFloat() <= 0) {
            w.report.add(.@"error", .invalid, st.line, "{s}: {s}={s}: {s} refuses {s} of " ++
                "zero or less", .{
                @tagName(st.kind), p.key, try em.describe(p.val), w.g.name, entry.canon,
            });
        }
        const same = for (entry.spellings) |sp| {
            if (std.ascii.eqlIgnoreCase(sp, p.key)) break true;
        } else false;
        const key = if (same) p.key else entry.spellings[0];
        // Two parameters this dialect says with one name (a capacitor's
        // `scale` and `m` in Xyce): their product has no place here.
        const clash = if (same) for (renamed.items) |k| {
            if (std.ascii.eqlIgnoreCase(k, key)) break true;
        } else false else for (out.items) |o| {
            if (std.ascii.eqlIgnoreCase(o.key, key)) break true;
        } else false;
        if (clash) {
            w.report.add(
                .@"error",
                .loss,
                st.line,
                "{s}: '{s}={s}' is '{s}' in {s}, which the instance gives as well",
                .{ @tagName(st.kind), p.key, try em.describe(p.val), key, w.g.name },
            );
            changed = true;
            continue;
        }
        if (!same) {
            w.report.add(
                .info,
                .rename,
                st.line,
                "{s}: the instance parameter '{s}' is spelled '{s}' in {s}",
                .{ @tagName(st.kind), p.key, key, w.g.name },
            );
            try renamed.append(a, key);
            changed = true;
        }
        try out.append(a, .{ .key = key, .val = p.val });
    }
    if (!changed) return null;
    var copy = st.*;
    try copy.own(a);
    try copy.set(a, idx, if (out.items.len > 0) .{ .params = out.items } else .none);
    return copy;
}
