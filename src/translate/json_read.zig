//! JSON: the IR read from JSON. Problems are reported, never fatal.
//!
//! Contents:
//! - `pub const number_cfg: grammar.LexCfg`
//! - `pub const Pos = enum`
//! - `pub fn posOf(ty: schema.SlotType) Pos`
//! - `pub fn plainTag(pos: Pos, text: []const u8) std.meta.Tag(Value)`
//! - `pub fn parseNetlist(arena: Allocator, text: []const u8,
//!   report: *ir.Report) Allocator.Error!ir.Netlist`
//! - `pub fn parseDocument(arena: Allocator, text: []const u8,
//!   report: *ir.Report) Allocator.Error!?ir.Netlist`

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir");
const dialects = @import("dialects");
const grammar = @import("grammar");
const lexer = @import("lexer");
const reader = @import("reader");
const Allocator = std.mem.Allocator;
const Value = ir.Value;
const J = std.json.Value;

/// Scale suffixes accepted in JSON input. SI, case sensitive, with `meg`
/// for mega. A bare `M` is refused: it is milli to a SPICE user and mega
/// to everyone else.
pub const number_cfg: grammar.LexCfg = .{
    .case_sensitive = true,
    .scales = &.{
        .{
            .suffix = "meg",
            .exp10 = 6,
        },
        .{ .suffix = "Meg", .exp10 = 6 },
        .{ .suffix = "MEG", .exp10 = 6 },
        .{ .suffix = "T", .exp10 = 12 },
        .{ .suffix = "G", .exp10 = 9 },
        .{ .suffix = "k", .exp10 = 3 },
        .{ .suffix = "K", .exp10 = 3 },
        .{ .suffix = "m", .exp10 = -3 },
        .{ .suffix = "u", .exp10 = -6 },
        .{ .suffix = "n", .exp10 = -9 },
        .{ .suffix = "p", .exp10 = -12 },
        .{ .suffix = "f", .exp10 = -15 },
        .{ .suffix = "a", .exp10 = -18 },
    },
    .units_ignored = false,
};

/// Where a value stands, as far as reading a plain JSON string goes.
pub const Pos = enum { word, signal, path, value };

const Parser = struct {
    arena: Allocator,
    report: *ir.Report,
    /// How deep the `body` or list being read is (`ir.max_depth`).
    depth: usize = 0,
    too_deep: bool = false,

    /// Deeper than `ir.max_depth`: reported once, and not read.
    fn deep(p: *Parser, line: u32) bool {
        if (p.depth < ir.max_depth) return false;
        if (!p.too_deep)
            p.fail(line, "nested more than {d} deep: what is deeper is not read", .{ir.max_depth});
        p.too_deep = true;
        return true;
    }

    fn fail(p: *Parser, line: u32, comptime fmt: []const u8, args: anytype) void {
        p.report.add(.@"error", .invalid, line, fmt, args);
    }

    fn scalar(p: *Parser, text: []const u8, line: u32) Allocator.Error!Value {
        if (lexer.parseNumber(p.arena, &number_cfg, text)) |n| return .{ .num = n };
        // `version=3.3.0` is a word, as every reader takes it.
        if (reader.isVersion(text)) return .{ .atom = text };
        if (text.len > 1 and std.ascii.isDigit(text[0])) {
            const digits = std.mem.trimEnd(u8, text, "M");
            if (digits.len + 1 == text.len and lexer.parseNumber(
                p.arena,
                &number_cfg,
                digits,
            ) != null) {
                p.fail(
                    line,
                    "'{s}' is ambiguous: M is milli in SPICE and mega in SI. Write {s}m or {s}meg",
                    .{ text, digits, digits },
                );
                return .none;
            }
            // Digits followed by letters only is a number with a suffix this
            // notation does not have, not an expression.
            var i: usize = 0;
            while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '.')) i += 1;
            var letters = i < text.len;
            for (text[i..]) |c| {
                if (!std.ascii.isAlphabetic(c)) letters = false;
            }
            if (letters) {
                p.fail(
                    line,
                    "'{s}' is not a number: the scale suffixes are T G meg k m u n p f a, and " ++
                        "case matters",
                    .{text},
                );
                return .none;
            }
        }
        return .{ .expr = text };
    }

    fn any(p: *Parser, j: J, line: u32) Allocator.Error!Value {
        switch (j) {
            .null => return .none,
            .bool => |b| return .{ .atom = if (b) "yes" else "no" },
            .integer => |i| return .{ .num = .init(try p.arena.print("{d}", .{i}), 0) },
            .float => |f| return p.scalar(try p.arena.print("{d}", .{f}), line),
            .number_string => |s| return p.scalar(s, line),
            .string => |s| return p.scalar(s, line),
            .array => |arr| {
                if (p.deep(line)) return .none;
                p.depth += 1;
                defer p.depth -= 1;
                const out = try p.arena.alloc(Value, arr.items.len);
                for (arr.items, 0..) |it, i| out[i] = try p.any(it, line);
                return .{ .list = out };
            },
            .object => |obj| {
                if (p.deep(line)) return .none;
                p.depth += 1;
                defer p.depth -= 1;
                return typed(j) orelse p.params(obj, line);
            },
        }
    }

    /// `{"str": s}`, `{"raw": s}` and `{"expr": s}`: a value of the type named.
    fn typed(j: J) ?Value {
        if (j != .object or j.object.count() != 1) return null;
        if (j.object.get("str")) |s| if (s == .string) return .{ .str = s.string };
        if (j.object.get("raw")) |s| if (s == .string) return .{ .atom = s.string };
        if (j.object.get("expr")) |s| if (s == .string) return .{ .expr = s.string };
        return null;
    }

    fn params(p: *Parser, obj: std.json.ObjectMap, line: u32) Allocator.Error!Value {
        var out: std.ArrayList(ir.Param) = .empty;
        var it = obj.iterator();
        while (it.next()) |kv|
            try out.append(
                p.arena,
                .{ .key = kv.key_ptr.*, .val = try p.any(kv.value_ptr.*, line) },
            );
        return if (out.items.len > 0) .{ .params = out.items } else .none;
    }

    /// Parameters as `[[key, value], ...]`: the form that can repeat a key.
    fn pairs(p: *Parser, sl: schema.Slot, items: []const J, line: u32) Allocator.Error!Value {
        var out: std.ArrayList(ir.Param) = .empty;
        for (items) |it| {
            if (it != .array or it.array.items.len != 2 or it.array.items[0] != .string) {
                p.fail(line, "'{s}' as an array must hold [name, value] pairs", .{sl.name});
                return .none;
            }
            try out.append(
                p.arena,
                .{ .key = it.array.items[0].string, .val = try p.any(it.array.items[1], line) },
            );
        }
        return if (out.items.len > 0) .{ .params = out.items } else .none;
    }

    fn nameOf(p: *Parser, j: J, line: u32, slot: []const u8) Allocator.Error!?[]const u8 {
        switch (j) {
            .string => |s| return s,
            .integer => |i| return try p.arena.print("{d}", .{i}),
            .number_string => |s| return s,
            else => {},
        }
        p.fail(line, "'{s}' must be a name", .{slot});
        return null;
    }

    fn slotValue(p: *Parser, sl: schema.Slot, j: J, line: u32) Allocator.Error!Value {
        if (j == .null) return .none;
        if (sl.list) {
            const items: []const J = if (j == .array) j.array.items else &.{j};
            const out = try p.arena.alloc(Value, items.len);
            var one = sl;
            one.list = false;
            for (items, 0..) |it, i| out[i] = try p.slotValue(one, it, line);
            return .{ .list = out };
        }
        if (sl.ty != .params) if (typed(j)) |v| return v;
        switch (sl.ty) {
            .name, .node, .ident, .ref, .atom, .signal, .text => {
                if (j == .bool) return .{ .atom = if (j.bool) "yes" else "no" };
                const text = (try p.nameOf(j, line, sl.name)) orelse return .none;
                return if (plainTag(posOf(sl.ty), text) == .expr)
                    .{ .expr = text }
                else
                    .{ .atom = text };
            },
            .path => return .{ .str = (try p.nameOf(j, line, sl.name)) orelse return .none },
            .value => return p.any(j, line),
            .params => {
                if (j == .array) return p.pairs(sl, j.array.items, line);
                if (j != .object) {
                    p.fail(line, "'{s}' must be an object of name: value pairs", .{sl.name});
                    return .none;
                }
                return p.params(j.object, line);
            },
        }
    }

    fn stmtList(p: *Parser, j: J) Allocator.Error![]ir.Stmt {
        var out: std.ArrayList(ir.Stmt) = .empty;
        if (j != .array) {
            p.fail(0, "'stmts' and 'body' must be arrays", .{});
            return out.items;
        }
        for (j.array.items, 1..) |item, n| {
            const line: u32 = @intCast(n);
            if (item != .object) {
                p.fail(line, "a statement must be an object", .{});
                continue;
            }
            const obj = item.object;
            const kind_name = if (obj.get("kind")) |k| (if (k == .string) k.string else "") else "";
            const kind = schema.kindFromName(kind_name) orelse {
                p.fail(line, "unknown statement kind '{s}'", .{kind_name});
                continue;
            };
            var st = try ir.newStmt(p.arena, kind, line);
            var it = obj.iterator();
            while (it.next()) |kv| {
                const key = kv.key_ptr.*;
                const val = kv.value_ptr.*;
                if (std.mem.eql(u8, key, "kind")) continue;
                if (std.mem.eql(u8, key, "line")) {
                    if (val == .integer and val.integer >= 0) st.line = @intCast(val.integer);
                } else if (std.mem.eql(u8, key, "raw")) {
                    if (val == .string) st.raw = val.string;
                } else if (std.mem.eql(u8, key, "blank")) {
                    if (val == .bool and val.bool) st.raw = ir.blank_line;
                } else if (std.mem.eql(u8, key, "tail")) {
                    if (val == .string) st.tail = val.string;
                } else if (std.mem.eql(u8, key, "dialect")) {
                    if (val == .string and val.string.len > 0) {
                        st.dialect = (try dialects.intern(val.string)) orelse blk: {
                            p.fail(
                                st.line,
                                "dialect '{s}' is one more than the 255 dialect names a " ++
                                    "process can hold",
                                .{val.string},
                            );
                            break :blk 0;
                        };
                    }
                } else if (std.mem.eql(u8, key, "body")) {
                    if (!p.deep(st.line)) {
                        p.depth += 1;
                        defer p.depth -= 1;
                        st.body = try p.stmtList(val);
                    }
                } else if (schema.slotIndex(kind, key)) |si| {
                    try st.set(
                        p.arena,
                        si,
                        try p.slotValue(schema.info(kind).slots[si], val, st.line),
                    );
                } else {
                    var known: std.ArrayList(u8) = .empty;
                    for (schema.info(kind).slots) |sl| try known.print(p.arena, " {s}", .{sl.name});
                    p.fail(
                        st.line,
                        "'{s}' has no '{s}'; it has:{s}",
                        .{ kind_name, key, known.items },
                    );
                }
            }
            try out.append(p.arena, st);
        }
        return out.items;
    }
};

pub fn posOf(ty: schema.SlotType) Pos {
    return switch (ty) {
        .name, .node, .ident, .ref, .atom, .text => .word,
        .signal => .signal,
        .path => .path,
        .value, .params => .value,
    };
}

/// What a plain string reads back as where it stands: the one place that
/// says so. The parser goes by it, and the writer tags what it would not
/// give back.
pub fn plainTag(pos: Pos, text: []const u8) std.meta.Tag(Value) {
    switch (pos) {
        .word => return .atom,
        .signal => return if (isSignal(text)) .atom else .expr,
        .path => return .str,
        .value => {
            // `scalar` allocates for a report entry only, not wanted here.
            var fba: std.heap.FixedBufferAllocator = .init(&.{});
            var sink: ir.Report = .init(fba.allocator());
            var p: Parser = .{ .arena = fba.allocator(), .report = &sink };
            return std.meta.activeTag(p.scalar(text, 0) catch return .none);
        },
    }
}

/// Parse the JSON form. Problems are reported, never fatal: what could be
/// understood is returned.
pub fn parseNetlist(
    arena: Allocator,
    text: []const u8,
    report: *ir.Report,
) Allocator.Error!ir.Netlist {
    return try parseDocument(arena, text, report) orelse .{};
}

/// As `parseNetlist`, but null when nothing was read at all: the text is
/// not JSON, or its top level is not an object.
pub fn parseDocument(
    arena: Allocator,
    text: []const u8,
    report: *ir.Report,
) Allocator.Error!?ir.Netlist {
    const root = std.json.parseFromSliceLeaky(J, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            report.add(.@"error", .invalid, 0, "not valid JSON: {s}", .{@errorName(err)});
            if (report.lost) return error.OutOfMemory;
            return null;
        },
    };
    if (root != .object) {
        report.add(.@"error", .invalid, 0, "the top level must be an object with 'stmts'", .{});
        if (report.lost) return error.OutOfMemory;
        return null;
    }
    var p: Parser = .{ .arena = arena, .report = report };
    var nl: ir.Netlist = .{ .dialect = "sprack" };
    if (root.object.get("title")) |t| if (t == .string) {
        nl.title = t.string;
    };
    if (root.object.get("dialect")) |t| if (t == .string) {
        nl.dialect = t.string;
    };
    if (root.object.get("defaults")) |t| if (t == .string) {
        nl.defaults = t.string;
    };
    if (root.object.get("folds_case")) |t| nl.folds_case = t == .bool and t.bool;
    if (root.object.get("stmts")) |s| nl.stmts = try p.stmtList(s);
    if (root.object.get("env")) |e| nl.env = try parseEnv(&p, e);
    if (report.lost) return error.OutOfMemory;
    return nl;
}

// ---- private ----

/// A plain string in a signal slot: a signal in the canonical spelling
/// (`v(out)`, `all`) or a bare name; anything else there is an expression.
fn isSignal(text: []const u8) bool {
    if (lexer.isIdent(text)) return true;
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return false;
    if (text[text.len - 1] != ')') return false;
    for (schema.signal_forms) |f| if (std.mem.eql(u8, f, text[0..open])) return true;
    return false;
}

/// The strings of the array `obj[key]`; none where it is not one.
fn strings(arena: Allocator, obj: J, key: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const list = obj.object.get(key) orelse return out.items;
    if (list == .array) for (list.array.items) |v| {
        if (v == .string) try out.append(arena, v.string);
    };
    return out.items;
}

/// The reverse of `writeEnv`. What it does not know (a kind of another
/// version of the core) is left out.
fn parseEnv(p: *Parser, j: J) Allocator.Error!?*const ir.Env {
    const arena = p.arena;
    if (j != .object) return null;
    const env = try arena.create(ir.Env);
    env.* = .{};
    if (j.object.get("conditional")) |c| env.conditional = .fromOwnedSlice(try p.stmtList(c));
    if (j.object.get("models")) |m| if (m == .object) {
        var it = m.object.iterator();
        while (it.next()) |kv| {
            const kind = if (kv.value_ptr.* == .string)
                schema.kindFromName(kv.value_ptr.string)
            else
                null;
            if (kind) |k| try env.models.put(arena, kv.key_ptr.*, k);
        }
    };
    for (try strings(arena, j, "declared")) |s| try env.declared.put(arena, s, {});
    for (try strings(arena, j, "subckts")) |s| try env.subckts.put(arena, s, {});
    for (try strings(arena, j, "funcs")) |s| try env.funcs.put(arena, s, {});
    for (try strings(arena, j, "used")) |s| {
        if (schema.kindFromName(s)) |k| env.used[@backingInt(k)] = true;
    }
    for (try strings(arena, j, "families")) |s| {
        for (schema.families, &env.families) |f, *used| {
            if (std.mem.eql(u8, f.name, s)) used.* = true;
        }
    }
    for (try strings(arena, j, "params")) |s| try env.params.put(arena, s, {});
    inline for (.{ "family_of", "modules" }) |field|
        if (j.object.get(field)) |m| if (m == .object) {
            var it = m.object.iterator();
            while (it.next()) |kv|
                if (kv.value_ptr.* == .string)
                    try @field(env, field).put(arena, kv.key_ptr.*, kv.value_ptr.string);
        };
    // Read, never written: a PDK's manifest gives the files its libraries
    // were translated with, and the top netlist loads them (issue 53).
    if (j.object.get("provided")) |m| if (m == .object) {
        var given: std.ArrayList([2][]const u8) = .empty;
        var it = m.object.iterator();
        while (it.next()) |kv|
            if (kv.value_ptr.* == .string)
                try given.append(arena, .{ kv.key_ptr.*, kv.value_ptr.string });
        env.provided = given.items;
    };
    return env;
}
