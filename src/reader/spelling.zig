//! Spelling: the one spelling of each name in a dialect that ignores
//! case, learnt in the first pass and given to every statement read after.

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir");
const expr = @import("expr");
const signals = @import("signals.zig");
const signalParts = signals.signalParts;
const signalSpace = signals.signalSpace;
const Allocator = std.mem.Allocator;
const Space = schema.Space;
const Value = ir.Value;

/// The names of a spelling table some lookup was answered with a spelling
/// of their own, for each space.
pub const Needed = struct {
    sets: std.EnumArray(Space, ir.CaselessSet) = .initFill(.empty),
    failed: bool = false,

    pub fn deinit(n: *Needed) void {
        for (&n.sets.values) |*set| set.deinit(ir.big);
    }
};

/// In a dialect that ignores case, `Vdd`, `VDD` and `vdd` are one name. The
/// output preserves what the author wrote, and must still be consistent when
/// the target does distinguish case, so every name gets one spelling among
/// the names of its space (`schema.Space`): the first one written with a
/// capital letter, or the lower-case one if it is never written with any. A
/// node and a device are different things that may share a name: the node
/// `vdd` of a source `Vdd` keeps its own spelling.
///
/// Only names that appear capitalised somewhere are stored. A netlist written
/// entirely in lower case, as large generated ones are, costs nothing here.
pub const Spelling = struct {
    const Map = std.StringHashMapUnmanaged([]const u8);
    /// The capitalised spelling of each name of a space, found by any spelling.
    mixed: std.EnumArray(Space, ir.NameSet),
    /// While set, the names of `mixed` some lookup was answered with a
    /// spelling other than the one it would fall back to (`prune`).
    needed: ?*Needed = null,
    /// Lower-cased names of the parameters the netlist itself defines.
    /// Built-in parameter names (`w`, `l`, `tc1`) are not in it and are
    /// written in lower case, which is what a case-sensitive target expects.
    params: Map = .empty,
    /// Where names that outlive the line they were read from are copied,
    /// unless they are in `src`, the netlist's own text.
    perm: Allocator,
    src: []const u8,

    /// `s` as long as the table lives.
    pub fn keep(sp: *const Spelling, s: []const u8) Allocator.Error![]const u8 {
        return ir.keepText(sp.perm, sp.src, s);
    }

    pub fn lowered(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
        for (s) |c| if (std.ascii.isUpper(c)) return std.ascii.allocLowerString(arena, s);
        return s;
    }

    // The table can be large and is rebuilt as it grows, so it lives
    // outside the arena and is freed when reading is done.

    /// The capitalised names of a statement read in the first pass, each
    /// in the space of its slot: the values of its name, node, model and
    /// reference slots, the names of its signals, the nodes of `.ic` keys
    /// and the parameters an instance sets. Keywords and other parameter
    /// keys are not names, so `DC` on a source does not respell a node `dc`.
    pub fn names(sp: *Spelling, st: *const ir.Stmt) Allocator.Error!void {
        for (schema.info(st.kind).slots, 0..) |sl, i| {
            const v = st.at(i);
            const one = [1]Value{v};
            const items: []const Value = switch (v) {
                .atom => &one,
                .list => |l| l,
                .params => |ps| {
                    if (st.kind == .ic or st.kind == .nodeset)
                        for (ps) |p| try sp.learn(.node, p.key);
                    if (st.kind == .instance) for (ps) |p| try sp.learn(.param, p.key);
                    for (ps) |p| try sp.exprNames(p.val);
                    continue;
                },
                .expr => {
                    try sp.exprNames(v);
                    continue;
                },
                else => continue,
            };
            // An expression among the items of a list (`.print v(a) {VCM*2}`).
            try sp.exprNames(v);
            if (st.kind == .func) continue;
            for (items) |it| {
                if (it != .atom) continue;
                if (sl.ty != .signal) {
                    try sp.learn(sl.space orelse break, it.atom);
                    continue;
                }
                var args: [3][]const u8 = undefined;
                const form, const n = signalParts(it.atom, &args) orelse continue;
                for (args[0..n], 0..) |a, k| try sp.learn(signalSpace(form, k) orelse continue, a);
            }
        }
    }

    /// The names an expression refers to (`{VCM}`, `rload*2`): a parameter
    /// defined in another file, or in another block of a Python deck, keeps
    /// the spelling it is written with here. Calls are functions, not names;
    /// what `v(` and `i(` name is a node and a device (`expr.argSpace`).
    pub fn exprNames(sp: *Spelling, v: Value) Allocator.Error!void {
        const items: []const Value = switch (v) {
            .expr => &.{v},
            .list => |l| l,
            else => return,
        };
        for (items) |it| {
            if (it != .expr) continue;
            const text = it.expr;
            var i: usize = 0;
            var space: Space = .param;
            while (i < text.len) {
                const c = text[i];
                if (c == '"' or c == '\'') {
                    i = (std.mem.indexOfScalarPos(u8, text, i + 1, c) orelse text.len) + 1;
                    continue;
                }
                const word_char = std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c == '.';
                if (!word_char) {
                    if (c == ')') space = .param;
                    i += 1;
                    continue;
                }
                var j = i;
                while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_' or text[j] == '$' or text[j] == '.')) j += 1;
                var k = j;
                while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
                const call = k < text.len and text[k] == '(';
                // A number (`1.5k`, `2e-3`) starts with a digit or a point.
                if (call) {
                    space = expr.argSpace(text[i..j]);
                } else if (std.ascii.isAlphabetic(c) or c == '_') try sp.learn(if (i > 0 and
                    text[i - 1] == '@') .instance else space, text[i..j]);
                i = j;
            }
        }
    }

    /// A name built for its statement, or read from a line that goes away,
    /// is copied: the table outlives both.
    pub fn learn(sp: *Spelling, space: Space, name: []const u8) Allocator.Error!void {
        for (name) |c| {
            if (!std.ascii.isUpper(c)) continue;
            return sp.mixed.getPtr(space).put(name);
        }
    }

    pub fn deinit(sp: *Spelling) void {
        for (&sp.mixed.values) |*set| set.deinit();
    }

    /// The one spelling of the name `raw` of `space`. A parameter the
    /// netlist defines is spelled the way its first definition spells it.
    pub fn spell(
        sp: *const Spelling,
        arena: Allocator,
        space: Space,
        raw: []const u8,
    ) Allocator.Error![]const u8 {
        if (raw.len > 256) return raw;
        if (space != .param) return sp.lookup(space, raw, raw);
        const low = try lowered(arena, raw);
        return sp.params.get(low) orelse sp.lookup(.param, low, raw);
    }

    /// The capitalised spelling of `name` among those of `space`, else `fallback`.
    pub fn lookup(
        sp: *const Spelling,
        space: Space,
        name: []const u8,
        fallback: []const u8,
    ) []const u8 {
        const k = sp.mixed.getPtrConst(space).getKey(name) orelse return fallback;
        if (sp.needed) |n| if (!std.mem.eql(u8, k, fallback)) {
            n.sets.getPtr(space).put(ir.big, k, {}) catch {
                n.failed = true;
            };
        };
        return k;
    }

    /// Keep only the names `needed` recorded: a pass that reads the same
    /// statements again gets the same answers from the smaller tables.
    pub fn prune(sp: *Spelling) void {
        const n = sp.needed orelse return;
        sp.needed = null;
        if (n.failed) return;
        for (&sp.mixed.values, &n.sets.values) |*mixed, *set| {
            var small: ir.NameSet = .{ .src = sp.src, .perm = sp.perm };
            var it = set.keyIterator();
            while (it.next()) |k| small.put(k.*) catch {
                small.deinit();
                return;
            };
            mixed.deinit();
            mixed.* = small;
        }
    }

    pub fn atom(sp: *const Spelling, arena: Allocator, space: Space, v: Value) Allocator.Error!Value {
        switch (v) {
            .atom => |a| return .{ .atom = try sp.spell(arena, space, a) },
            .list => |items| {
                const out: []Value = @constCast(items);
                for (out) |*it| if (it.* == .atom) {
                    it.* = .{ .atom = try sp.spell(arena, space, it.atom) };
                };
                return v;
            },
            else => return v,
        }
    }

    /// Names, nodes and keys of one freshly read statement.
    pub fn statement(sp: *Spelling, arena: Allocator, st: *ir.Stmt) Allocator.Error!void {
        const defines_params = st.kind == .param or st.kind == .subckt;
        const node_keys = st.kind == .ic or st.kind == .nodeset;
        for (schema.info(st.kind).slots, 0..) |sl, i| {
            switch (sl.ty) {
                .name, .node, .ident => {
                    const was = st.at(i);
                    // Functions are called in any case, and a model's type
                    // word is a keyword, not a name: their one spelling is
                    // the lower-case one.
                    const now: Value = if (st.kind == .func or sl.space == null)
                        (if (was == .atom) .{ .atom = try lowered(arena, was.atom) } else was)
                    else
                        try sp.atom(arena, sl.space.?, was);
                    // A list is respelled where it stands; most atoms are
                    // spelled as they were, and the statement is left alone.
                    if (now == .atom and (was != .atom or now.atom.ptr != was.atom.ptr or
                        now.atom.len != was.atom.len)) try st.set(arena, i, now);
                },
                .params => {
                    if (st.at(i) != .params) continue;
                    // The statement owns its parameter list: edit it in place.
                    const out: []ir.Param = @constCast(st.at(i).params);
                    for (out) |*p| {
                        if (defines_params) {
                            // A parameter is spelled the way its first definition spells it.
                            const gop = try sp.params.getOrPut(sp.perm, try lowered(arena, p.key));
                            if (gop.found_existing) p.key = gop.value_ptr.* else {
                                gop.key_ptr.* = try sp.keep(gop.key_ptr.*);
                                gop.value_ptr.* = try sp.keep(p.key);
                            }
                        } else if (node_keys) {
                            p.key = try sp.spell(arena, .node, p.key);
                        } else if (st.kind == .instance) {
                            // A subcircuit's parameter, which may be defined
                            // in another file: spelled as the source does.
                            p.key = try sp.spell(arena, .param, p.key);
                        } else p.key = sp.params.get(try lowered(arena, p.key)) orelse
                            try lowered(arena, p.key);
                    }
                },
                else => {},
            }
        }
    }

    /// A word of an expression: a call (`space` null), or a name of `space`.
    pub fn identifier(
        sp: *const Spelling,
        arena: Allocator,
        word: []const u8,
        space: ?Space,
    ) Allocator.Error![]const u8 {
        const low = try lowered(arena, word);
        const in = space orelse return low;
        if (in == .param) if (sp.params.get(low)) |p| return p;
        return sp.lookup(in, low, low);
    }

    pub fn signal(sp: *const Spelling, arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
        var args: [3][]const u8 = undefined;
        const form, const n = signalParts(text, &args) orelse return text;
        if (n == 0) return text;
        var out: std.ArrayList(u8) = .empty;
        try out.print(arena, "{s}(", .{text[0..std.mem.indexOfScalar(u8, text, '(').?]});
        for (args[0..n], 0..) |a, i| {
            if (i > 0) try out.append(arena, ',');
            try out.appendSlice(arena, if (signalSpace(form, i)) |space|
                try sp.spell(arena, space, a)
            else
                a);
        }
        try out.append(arena, ')');
        return out.items;
    }
};

/// A function's arguments and their uses in its body share one spelling,
/// the argument's (#72): `.func f(X) {X*2}` folded is `f(x) {x*2}`.
pub fn funcArgs(arena: Allocator, vals: []Value) Allocator.Error!void {
    const ai = schema.slot(.func, "args");
    const ei = schema.slot(.func, "expr");
    if (vals[ei] != .expr) return;
    const Args = struct {
        args: []const Value,
        pub fn get(a: @This(), word: []const u8) ?[]const u8 {
            const list: []const Value = if (a.args.len == 1 and a.args[0] == .list)
                a.args[0].list
            else
                a.args;
            for (list) |v|
                if (v == .atom and std.ascii.eqlIgnoreCase(v.atom, word) and !std.mem.eql(
                    u8,
                    v.atom,
                    word,
                )) return v.atom;
            return null;
        }
    };
    var hit: std.ArrayList([]const u8) = .empty;
    const body = try expr.rename(arena, vals[ei].expr, Args{ .args = (&vals[ai])[0..1] }, &hit);
    vals[ei] = .{ .expr = body };
}

pub fn resolveName(
    ctx: ?*const anyopaque,
    arena: Allocator,
    word: []const u8,
    space: ?Space,
) Allocator.Error![]const u8 {
    const sp: *const Spelling = @ptrCast(@alignCast(ctx.?));
    return sp.identifier(arena, word, space);
}
