//! The pattern parser: the text after `rule kind =` (and a block's
//! `open`/`inner`/`close`) into `Node`s, groups nested at most `P.max_depth`
//! deep and at most `P.max_nodes` nodes, defines expanded.
//!
//! Contents:
//! - `pub const Def = struct`
//! - `pub const P = struct`
//! - `pub fn canBeEmpty(items: []const Node) bool`
//! - `pub fn pattern(c: *C, line: u32, kind: Kind, fold: bool, text: []const u8,
//!   defs: []const Def) Error![]const Node`

const std = @import("std");
const schema = @import("schema");
const Kind = schema.Kind;
const context = @import("context.zig");
const types = @import("types.zig");
const C = context.C;
const Error = context.Error;
const BagEntry = types.BagEntry;
const Node = types.Node;
const wild_slot = types.wild_slot;

/// `define name = pattern`: a named fragment, kept as text and parsed
/// where it is used, so its slot names resolve against the using rule's kind.
pub const Def = struct { name: []const u8, text: []const u8 };

pub const P = struct {
    s: []const u8,
    i: usize = 0,
    kind: Kind,
    fold: bool,
    c: *C,
    line: u32,
    defs: []const Def = &.{},
    /// Inside a repeated group: list slots are taken one item at a time.
    in_rep: bool = false,
    /// Groups and defines open around `p.i`. Each is a level of recursion,
    /// so a mutated grammar of a few thousand `(` overflowed the stack.
    depth: u32 = 0,

    const max_depth = 100;
    /// A define used twice in a define used twice ... doubles at each
    /// level: 40 levels of a 1 KB grammar asked for 2^40 nodes.
    const max_nodes = 10_000;

    fn err(p: *P, comptime fmt: []const u8, a: anytype) Error {
        return p.c.fail(
            p.line,
            "{s} in pattern `{s}`",
            .{ try std.fmt.allocPrint(p.c.gpa, fmt, a), p.s },
        );
    }

    fn ws(p: *P) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t')) p.i += 1;
    }

    fn peek(p: *P) u8 {
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    fn startsWith(p: *P, what: []const u8) bool {
        return std.mem.startsWith(u8, p.s[p.i..], what);
    }

    fn string(p: *P) Error![]const u8 {
        const q = p.s[p.i];
        const end = std.mem.indexOfScalarPos(u8, p.s, p.i + 1, q) orelse return p.err(
            "unterminated string",
            .{},
        );
        const out = p.s[p.i + 1 .. end];
        p.i = end + 1;
        return out;
    }

    fn ident(p: *P) Error![]const u8 {
        const start = p.i;
        while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or p.s[p.i] == '_')) p.i += 1;
        if (p.i == start) return p.err("expected a name", .{});
        return p.s[start..p.i];
    }

    /// Characters up to the next blank or closing bracket.
    fn bare(p: *P) []const u8 {
        const start = p.i;
        while (p.i < p.s.len and std.mem.indexOfScalar(u8, " \t]})|", p.s[p.i]) == null) p.i += 1;
        return p.s[start..p.i];
    }

    fn quoted(p: *P) bool {
        return p.peek() == '"' or p.peek() == '\'';
    }

    /// A named slot of the rule's kind. `_` is not one: only a capture
    /// may be the wildcard, and the capture checks for it first.
    fn slotOf(p: *P, name: []const u8) Error!u8 {
        return schema.slotIndex(p.kind, name) orelse {
            var known: []const u8 = "";
            for (schema.info(p.kind).slots) |s|
                known = try p.c.cat(try p.c.cat(known, " "), s.name);
            return p.err(
                "unknown slot '{s}' for kind '{s}' (known:{s})",
                .{ name, @tagName(p.kind), known },
            );
        };
    }

    fn slotInfo(p: *P, slot: u8) schema.Slot {
        return schema.info(p.kind).slots[slot];
    }

    fn lit(p: *P, text: []const u8) Error![]const u8 {
        return p.c.foldIf(p.fold, text);
    }

    fn seq(p: *P) Error![]const Node {
        if (p.depth == max_depth) return p.err("groups nested more than {d} deep", .{max_depth});
        p.depth += 1;
        defer p.depth -= 1;
        var out: []const Node = &.{};
        while (true) {
            p.ws();
            const ch = p.peek();
            if (ch == 0 or ch == ']' or ch == ')' or ch == '|') break;
            if (ch == '<') {
                const more = try p.use();
                try p.count(more.len);
                for (more) |n| out = try p.c.add(Node, out, n);
                continue;
            }
            const n = try p.item();
            try p.count(1);
            out = try p.c.add(Node, out, n);
        }
        return out;
    }

    fn count(p: *P, n: usize) Error!void {
        p.c.nodes += @intCast(n);
        if (p.c.nodes > max_nodes)
            return p.err("more than {d} nodes, defines expanded", .{max_nodes});
    }

    /// `<name>`: the nodes of a `define`, spliced in place.
    fn use(p: *P) Error![]const Node {
        p.i += 1;
        const name = try p.ident();
        if (p.peek() != '>') return p.err("missing '>' after '<{s}'", .{name});
        p.i += 1;
        for (p.defs, 0..) |d, di| {
            if (!std.mem.eql(u8, d.name, name)) continue;
            // A define sees only the ones before it, so it cannot refer to itself.
            var sub: P = .{
                .s = d.text,
                .kind = p.kind,
                .fold = p.fold,
                .c = p.c,
                .line = p.line,
                .defs = p.defs[0..di],
                .depth = p.depth,
            };
            const out = try sub.seq();
            if (sub.i < sub.s.len) return sub.err("unexpected '{c}'", .{sub.s[sub.i]});
            return out;
        }
        return p.err("no `define {s}` before this rule", .{name});
    }

    /// Is the group opened just before `p.i` followed by `*` or `+`?
    fn repeats(p: *P) bool {
        var depth: usize = 1;
        var j = p.i;
        while (j < p.s.len) : (j += 1) {
            switch (p.s[j]) {
                '"', '\'' => j = std.mem.indexOfScalarPos(
                    u8,
                    p.s,
                    j + 1,
                    p.s[j],
                ) orelse return false,
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0)
                        return j + 1 < p.s.len and (p.s[j + 1] == '*' or p.s[j + 1] == '+' or p.s[j + 1] == '#');
                },
                else => {},
            }
        }
        return false;
    }

    fn item(p: *P) Error!Node {
        switch (p.peek()) {
            '"', '\'' => return .{ .tag = .lit, .text = try p.lit(try p.string()) },
            '[' => {
                p.i += 1;
                const kids = try p.seq();
                if (p.peek() != ']') return p.err("missing ']'", .{});
                p.i += 1;
                return .{ .tag = .opt, .kids = kids };
            },
            '(' => {
                p.i += 1;
                const rep = p.repeats();
                if (rep and p.in_rep) return p.err("a repeated group cannot hold another", .{});
                const outer = p.in_rep;
                p.in_rep = outer or rep;
                var alts: []const Node = &.{};
                while (true) {
                    alts = try p.c.add(Node, alts, .{ .tag = .seq, .kids = try p.seq() });
                    if (p.peek() == '|') {
                        p.i += 1;
                        continue;
                    }
                    break;
                }
                p.in_rep = outer;
                if (p.peek() != ')') return p.err("missing ')'", .{});
                p.i += 1;
                const group: Node = .{ .tag = .alt, .kids = alts };
                if (!rep) return group;
                // `( ... )*` or `( ... )+`, a separator glued on: `( ... )*","`.
                var n: Node = .{
                    .tag = .rep,
                    .plus = p.peek() != '*',
                    .kids = try p.c.add(Node, &.{}, group),
                };
                p.i += 1;
                if (p.s[p.i - 1] == '#') n.count = try p.countSlot();
                if (p.quoted()) {
                    n.sep = try p.c.add(
                        Node,
                        &.{},
                        .{ .tag = .lit, .text = try p.lit(try p.string()) },
                    );
                } else if (p.peek() == '~') {
                    p.i += 1;
                    if (!p.quoted()) return p.err("expected a quoted separator after '~'", .{});
                    n.sep = try p.c.add(Node, &.{}, .{ .tag = .glue, .text = try p.string() });
                }
                if (canBeEmpty(n.kids))
                    return p.err("a repeated group must take at least one word each time", .{});
                return n;
            },
            '{' => {
                if (p.in_rep) return p.err("a repeated group cannot hold '{{ }}'", .{});
                return p.bag();
            },
            '/' => {
                p.i += 1;
                return .{ .tag = .nl };
            },
            '-' => {
                p.i += 1;
                return .{ .tag = .drop, .slot = try p.slotOf(try p.ident()) };
            },
            '~' => {
                p.i += 1;
                if (!p.quoted()) return p.err("expected a quoted literal after '~'", .{});
                return .{ .tag = .glue, .text = try p.string() };
            },
            '.' => if (p.startsWith("...")) {
                if (p.in_rep)
                    return p.err("a repeated group cannot take the rest of the line", .{});
                p.i += 3;
                return .{ .tag = .rest, .slot = wild_slot };
            },
            else => {},
        }
        const name = try p.ident();
        if (p.in_rep and p.startsWith("..."))
            return p.err("a repeated group cannot take the rest of the line", .{});
        if (p.startsWith("...")) {
            p.i += 3;
            const slot = try p.slotOf(name);
            const rt = p.slotInfo(slot).ty;
            if (rt != .text and rt != .value)
                return p.err("'{s}...' needs a text or a value slot", .{name});
            return .{ .tag = .rest, .slot = slot };
        }
        if (p.peek() == ':') {
            p.i += 1;
            if (!p.quoted()) return p.err("expected a quoted literal after ':'", .{});
            const text = try p.string();
            var atom: []const u8 = text;
            if (p.peek() == '=') {
                p.i += 1;
                atom = try p.ident();
            }
            const slot = try p.slotOf(name);
            // On a value slot (`acmag:"ac"=1`) the literal stands for a number.
            const vty = p.slotInfo(slot).ty;
            if (vty != .atom and !(vty == .value and !p.slotInfo(slot).list))
                return p.err("tagged literal needs an atom slot, '{s}' is not one", .{name});
            if (p.in_rep and !p.slotInfo(slot).list)
                return p.err("'{s}' is in a repeated group but is not a list slot", .{name});
            var soft = false;
            if (p.peek() == '?') {
                p.i += 1;
                soft = true;
            }
            return .{
                .tag = .taglit,
                .slot = slot,
                .text = try p.lit(text),
                .atom = atom,
                .soft = soft,
            };
        }
        var n: Node = .{ .tag = .cap, .slot = if (std.mem.eql(u8, name, "_"))
            wild_slot
        else
            try p.slotOf(name) };
        while (true) {
            switch (p.peek()) {
                '~' => {
                    p.i += 1;
                    if (!p.quoted()) return p.err("expected a quoted prefix after '~'", .{});
                    n.prefix = try p.lit(try p.string());
                },
                '*' => {
                    p.i += 1;
                    n.star = true;
                },
                '+' => {
                    p.i += 1;
                    n.plus = true;
                },
                '?' => {
                    p.i += 1;
                    n.default = if (p.quoted()) try p.string() else p.bare();
                },
                '!' => {
                    p.i += 1;
                    if (n.slot == wild_slot or p.slotInfo(n.slot).ty != .path)
                        return p.err("'{s}!' needs a path slot", .{name});
                    n.bare = true;
                },
                '#' => {
                    p.i += 1;
                    if (n.slot == wild_slot or !p.slotInfo(n.slot).list)
                        return p.err("'{s}#' needs a list slot", .{name});
                    if (p.peek() == '1') {
                        p.i += 1;
                        n.one = true;
                    } else {
                        n.count = try p.countSlot();
                        n.plus = true;
                    }
                },
                else => break,
            }
        }
        if (n.slot != wild_slot) {
            const si = p.slotInfo(n.slot);
            if ((n.star or n.plus) and !si.list) return p.err("'{s}' is not a list slot", .{name});
            if (p.in_rep) {
                if (!si.list)
                    return p.err("'{s}' is in a repeated group but is not a list slot", .{name});
                if (n.star or n.plus)
                    return p.err(
                        "in a repeated group, '{s}' takes one item per pass; drop the '*' or '+'",
                        .{name},
                    );
            } else if (!(n.star or n.plus or n.one) and
                si.list) return p.err("list slot '{s}' needs '*' or '+'", .{name});
            if (si.ty == .params or si.ty == .text)
                return p.err("slot '{s}' cannot be captured as a single token", .{name});
        }
        return n;
    }

    /// The slot after `#` that holds a count: a single value.
    fn countSlot(p: *P) Error!u8 {
        const name = try p.ident();
        const slot = try p.slotOf(name);
        const si = p.slotInfo(slot);
        if (si.ty != .value or si.list)
            return p.err("'#{s}' needs a value slot holding a count", .{name});
        return slot;
    }

    fn bag(p: *P) Error!Node {
        p.i += 1;
        var entries: []const BagEntry = &.{};
        while (true) {
            p.ws();
            if (p.peek() == 0) return p.err("missing '}}'", .{});
            if (p.peek() == '}') {
                p.i += 1;
                break;
            }
            if (p.startsWith("...")) {
                p.i += 3;
                const slot = try p.slotOf(try p.ident());
                if (p.slotInfo(slot).ty != .params)
                    return p.err("'...' in a bag needs a params slot", .{});
                var flags = false;
                if (p.peek() == '?') {
                    p.i += 1;
                    flags = true;
                }
                entries = try p.c.add(
                    BagEntry,
                    entries,
                    .{ .slot = slot, .form = .rest, .flags = flags },
                );
                continue;
            }
            const kstart = p.i;
            while (p.i < p.s.len and std.mem.indexOfScalar(u8, " \t=}(", p.s[p.i]) == null)
                p.i += 1;
            var e: BagEntry = .{ .key = try p.lit(p.s[kstart..p.i]) };
            if (p.startsWith("(*)=")) {
                // `v(*)=slot`: entries are written `v(key)=value`.
                p.i += 4;
                e.form = .call;
                e.slot = try p.slotOf(try p.ident());
                if (p.peek() == '+') {
                    p.i += 1;
                    e.bare_pairs = true;
                }
                if (p.slotInfo(e.slot).ty != .params)
                    return p.err("'key(*)=' needs a params slot", .{});
                entries = try p.c.add(BagEntry, entries, e);
                continue;
            }
            if (e.key.len == 0 or p.peek() != '=')
                return p.err("expected key=slot inside '{{ }}'", .{});
            p.i += 1;
            switch (p.peek()) {
                '=' => {
                    p.i += 1;
                    e.form = .fixed;
                    e.fixed = p.bare();
                    // `param==temp!@var:temp`: the fixed pair stands for an atom.
                    if (std.mem.indexOfAny(u8, e.fixed, "!@")) |at| {
                        p.i -= e.fixed.len - at;
                        e.fixed = e.fixed[0..at];
                    }
                },
                '"' => {
                    e.form = .quoted;
                    // `out="iout:flow(br)"`: the slot's name, then text
                    // written after its value (VACASK's branch current).
                    const s = try p.string();
                    var n: usize = 0;
                    while (n < s.len and (std.ascii.isAlphanumeric(s[n]) or s[n] == '_')) n += 1;
                    e.slot = try p.slotOf(s[0..n]);
                    e.suffix = s[n..];
                },
                '{' => {
                    p.i += 1;
                    e.form = .pairs;
                    e.slot = try p.slotOf(try p.ident());
                    if (p.peek() != '}') return p.err("missing '}}'", .{});
                    p.i += 1;
                    if (p.slotInfo(e.slot).ty != .params)
                        return p.err("'{{slot}}' needs a params slot", .{});
                },
                '[' => {
                    p.i += 1;
                    e.form = .vector;
                    e.slot = try p.slotOf(try p.ident());
                    if (p.peek() == ' ') {
                        // `[a b]`: two slots, a node and the one it is
                        // measured against.
                        p.i += 1;
                        e.form = .pair;
                        e.slot2 = try p.slotOf(try p.ident());
                        if (p.slotInfo(e.slot).list or p.slotInfo(e.slot2).list)
                            return p.err("'[a b]' needs two slots of one value each", .{});
                    }
                    if (p.peek() != ']') return p.err("missing ']'", .{});
                    p.i += 1;
                    if (e.form == .vector and !p.slotInfo(e.slot).list)
                        return p.err("'[slot]' needs a list slot", .{});
                },
                else => {
                    e.slot = try p.slotOf(try p.ident());
                    if (p.peek() == '+') {
                        p.i += 1;
                        e.also = true;
                    }
                },
            }
            if (p.peek() == '!') {
                p.i += 1;
                e.required = true;
            }
            if (p.peek() == '?') {
                p.i += 1;
                if (e.form != .plain) return p.err("only a plain key=slot takes a default", .{});
                e.default = p.bare();
            }
            if (p.peek() == '@') {
                p.i += 1;
                e.tag_slot = try p.slotOf(try p.ident());
                if (p.peek() != ':') return p.err("expected ':' after '@slot'", .{});
                p.i += 1;
                e.tag_atom = try p.ident();
            }
            entries = try p.c.add(BagEntry, entries, e);
        }
        return .{ .tag = .bag, .bag = entries };
    }
};

/// Can these nodes match no word at all?
pub fn canBeEmpty(items: []const Node) bool {
    for (items) |n| {
        switch (n.tag) {
            .lit, .taglit => return false,
            .cap => if (!n.star) return false,
            .seq => if (!canBeEmpty(n.kids)) return false,
            .alt => {
                var all = true;
                for (n.kids) |k| all = all and !canBeEmpty(k.kids);
                if (all) return false;
            },
            .rep => if (n.plus and !canBeEmpty(n.kids)) return false,
            else => {},
        }
    }
    return true;
}

pub fn pattern(
    c: *C,
    line: u32,
    kind: Kind,
    fold: bool,
    text: []const u8,
    defs: []const Def,
) Error![]const Node {
    var p: P = .{ .s = text, .kind = kind, .fold = fold, .c = c, .line = line, .defs = defs };
    c.nodes = 0;
    const out = try p.seq();
    if (p.i < p.s.len) return p.err("unexpected '{c}'", .{p.s[p.i]});
    if (out.len == 0) return p.err("empty pattern", .{});
    return out;
}
