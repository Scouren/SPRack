//! The IR as JSON, in both directions.
//!
//! This is how programs other than the translator get at a netlist: the
//! Python package builds a circuit as a list of statements in this form and
//! hands it to a writer, and `sprack read` prints any netlist in it.
//!
//!     {"title": "...", "dialect": "ngspice", "stmts": [
//!        {"kind": "resistor", "name": "R1", "pos": "a", "neg": "0", "r": "1e3"},
//!        {"kind": "subckt", "name": "inv", "ports": ["in", "out"], "body": [...]}]}
//!
//! A value is a string: a number (`"1.5e-12"`, or with a scale suffix
//! `"10n"`), otherwise an expression in the canonical spelling. `{"str": s}`
//! is a quoted string, a list is an array, parameters are an object, and a
//! flag without a value is `null`.

const std = @import("std");
const schema = @import("schema.zig");
const ir = @import("ir.zig");
/// The dialect table (`internDialect`, `dialectName`).
const sprack = @import("root.zig");
const grammar = @import("grammar.zig");
const lexer = @import("lexer.zig");

const Allocator = std.mem.Allocator;
const Value = ir.Value;
const Writer = std.Io.Writer;

/// Scale suffixes accepted in JSON input. SI, case sensitive, with `meg`
/// for mega. A bare `M` is refused: it is milli to a SPICE user and mega
/// to everyone else.
pub const number_cfg: grammar.LexCfg = .{
    .case_sensitive = true,
    .scales = &.{
        .{ .suffix = "meg", .exp10 = 6 }, .{ .suffix = "Meg", .exp10 = 6 }, .{ .suffix = "MEG", .exp10 = 6 },
        .{ .suffix = "T", .exp10 = 12 },  .{ .suffix = "G", .exp10 = 9 },   .{ .suffix = "k", .exp10 = 3 },
        .{ .suffix = "K", .exp10 = 3 },   .{ .suffix = "m", .exp10 = -3 },  .{ .suffix = "u", .exp10 = -6 },
        .{ .suffix = "n", .exp10 = -9 },  .{ .suffix = "p", .exp10 = -12 }, .{ .suffix = "f", .exp10 = -15 },
        .{ .suffix = "a", .exp10 = -18 },
    },
    .units_ignored = false,
};

fn str(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn value(w: *Writer, v: Value) Writer.Error!void {
    switch (v) {
        .none => try w.writeAll("null"),
        .atom => |s| try str(w, s),
        .expr => |s| try str(w, s),
        .num => |n| {
            try w.writeByte('"');
            try w.writeAll(n.digits());
            if (n.exp10 != 0) try w.print("e{d}", .{n.exp10});
            try w.writeByte('"');
        },
        .str => |s| {
            try w.writeAll("{\"str\":");
            try str(w, s);
            try w.writeByte('}');
        },
        .list => |items| {
            try w.writeByte('[');
            for (items, 0..) |it, i| {
                if (i > 0) try w.writeByte(',');
                try value(w, it);
            }
            try w.writeByte(']');
        },
        .params => |ps| {
            try w.writeByte('{');
            for (ps, 0..) |p, i| {
                if (i > 0) try w.writeByte(',');
                try str(w, p.key);
                try w.writeByte(':');
                try value(w, p.val);
            }
            try w.writeByte('}');
        },
    }
}

fn stmts(w: *Writer, list: []const ir.Stmt) Writer.Error!void {
    try w.writeByte('[');
    for (list, 0..) |*s, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.print("{{\"kind\":\"{s}\"", .{@tagName(s.kind)});
        if (s.line > 0) try w.print(",\"line\":{d}", .{s.line});
        if (s.kind == .@"opaque" or s.kind == .comment) {
            try w.writeAll(",\"raw\":");
            try str(w, if (std.mem.eql(u8, s.raw, ir.blank_line)) "" else s.raw);
            if (s.kind == .comment and std.mem.eql(u8, s.raw, ir.blank_line)) try w.writeAll(",\"blank\":true");
        }
        if (s.tail.len > 0) {
            try w.writeAll(",\"tail\":");
            try str(w, s.tail);
        }
        if (s.dialect != 0) {
            try w.writeAll(",\"dialect\":");
            try str(w, sprack.dialectName(s.dialect));
        }
        for (schema.info(s.kind).slots, 0..) |sl, k| {
            if (s.at(k) == .none) continue;
            try w.writeByte(',');
            try str(w, sl.name);
            try w.writeByte(':');
            try value(w, s.at(k));
        }
        if (s.body.len > 0 or s.kind == .subckt or s.kind == .libsection) {
            try w.writeAll(",\"body\":");
            try stmts(w, s.body);
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

pub fn writeNetlist(w: *Writer, nl: *const ir.Netlist) Writer.Error!void {
    try w.writeAll("{\"title\":");
    try str(w, nl.title);
    try w.writeAll(",\"dialect\":");
    try str(w, nl.dialect);
    try w.writeAll(",\"stmts\":");
    try stmts(w, nl.stmts);
    try w.writeAll("}\n");
}

pub fn writeReport(w: *Writer, report: *const ir.Report) Writer.Error!void {
    try w.writeByte('[');
    for (report.items.items, 0..) |d, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"severity\":\"{s}\",\"code\":\"{s}\",\"line\":{d},\"message\":", .{ @tagName(d.sev), @tagName(d.code), d.line });
        try str(w, d.msg);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

/// What every dialect can write, the canonical schema and the report
/// vocabulary: everything a front end needs to stay in step with the core.
pub fn writeInfo(w: *Writer, grammars: []const grammar.Grammar) Writer.Error!void {
    try w.writeAll("{\"dialects\":[");
    for (grammars, 0..) |g, i| {
        if (i > 0) try w.writeByte(',');
        try str(w, g.name);
    }
    try w.writeAll("],\"kinds\":{");
    for (schema.table, 0..) |info, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"{s}\":{{\"class\":\"{s}\",\"slots\":[", .{ @tagName(info.kind), @tagName(info.class) });
        for (info.slots, 0..) |sl, k| {
            if (k > 0) try w.writeByte(',');
            try w.print("{{\"name\":\"{s}\",\"type\":\"{s}\",\"list\":{}}}", .{ sl.name, @tagName(sl.ty), sl.list });
        }
        try w.writeAll("],\"writers\":[");
        var first = true;
        for (grammars) |*g| {
            if (!g.canWrite(info.kind)) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try str(w, g.name);
        }
        try w.writeAll("],\"absent\":{");
        first = true;
        for (grammars) |*g| {
            const why = g.absentReason(info.kind) orelse continue;
            if (!first) try w.writeByte(',');
            first = false;
            try str(w, g.name);
            try w.writeByte(':');
            try str(w, why);
        }
        // Instance parameters per dialect, every spelling it reads.
        try w.writeAll("},\"params\":{");
        first = true;
        for (grammars) |*g| {
            const table = g.paramsOf(info.kind) orelse continue;
            if (!first) try w.writeByte(',');
            first = false;
            try str(w, g.name);
            try w.writeAll(":[");
            var n: usize = 0;
            for (table) |e| for (e.spellings) |sp| {
                if (n > 0) try w.writeByte(',');
                n += 1;
                try str(w, sp);
            };
            try w.writeByte(']');
        }
        try w.writeAll("}}");
    }
    try w.writeAll("},\"functions\":[");
    for (schema.functions, 0..) |f, i| {
        if (i > 0) try w.writeByte(',');
        try str(w, f);
    }
    try w.writeAll("],\"variables\":[");
    for (schema.variables, 0..) |f, i| {
        if (i > 0) try w.writeByte(',');
        try str(w, f);
    }
    try w.writeAll("]}\n");
}

// ----------------------------------------------------------------- reading

const J = std.json.Value;

const Parser = struct {
    arena: Allocator,
    report: *ir.Report,

    fn fail(p: *Parser, line: u32, comptime fmt: []const u8, args: anytype) void {
        p.report.add(.@"error", .invalid, line, fmt, args);
    }

    fn scalar(p: *Parser, text: []const u8, line: u32) Allocator.Error!Value {
        if (lexer.parseNumber(p.arena, &number_cfg, text)) |n| return .{ .num = n };
        if (text.len > 1 and std.ascii.isDigit(text[0])) {
            const digits = std.mem.trimEnd(u8, text, "M");
            if (digits.len + 1 == text.len and lexer.parseNumber(p.arena, &number_cfg, digits) != null) {
                p.fail(line, "'{s}' is ambiguous: M is milli in SPICE and mega in SI. Write {s}m or {s}meg", .{ text, digits, digits });
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
                p.fail(line, "'{s}' is not a number: the scale suffixes are T G meg k m u n p f a, and case matters", .{text});
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
                const out = try p.arena.alloc(Value, arr.items.len);
                for (arr.items, 0..) |it, i| out[i] = try p.any(it, line);
                return .{ .list = out };
            },
            .object => |obj| {
                if (obj.count() == 1) {
                    if (obj.get("str")) |s| if (s == .string) return .{ .str = s.string };
                    if (obj.get("raw")) |s| if (s == .string) return .{ .atom = s.string };
                }
                return p.params(obj, line);
            },
        }
    }

    fn params(p: *Parser, obj: std.json.ObjectMap, line: u32) Allocator.Error!Value {
        var out: std.ArrayList(ir.Param) = .empty;
        var it = obj.iterator();
        while (it.next()) |kv| try out.append(p.arena, .{ .key = kv.key_ptr.*, .val = try p.any(kv.value_ptr.*, line) });
        return if (out.items.len > 0) .{ .params = out.items } else .none;
    }

    fn nameOf(p: *Parser, j: J, line: u32, slot: []const u8) Allocator.Error!?[]const u8 {
        switch (j) {
            .string => |s| return s,
            .integer => |i| return try p.arena.print("{d}", .{i}),
            .number_string => |s| return s,
            // A path as `writeNetlist` writes it (a quoted string).
            .object => |obj| if (obj.count() == 1) {
                if (obj.get("str")) |s| if (s == .string) return s.string;
            },
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
        switch (sl.ty) {
            .name, .node, .ident, .ref, .atom, .signal, .text => {
                if (j == .bool) return .{ .atom = if (j.bool) "yes" else "no" };
                return .{ .atom = (try p.nameOf(j, line, sl.name)) orelse return .none };
            },
            .path => return .{ .str = (try p.nameOf(j, line, sl.name)) orelse return .none },
            .value => return p.any(j, line),
            .params => {
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
                        st.dialect = (try sprack.internDialect(val.string)) orelse blk: {
                            p.fail(st.line, "dialect '{s}' is one more than the 255 dialect names a process can hold", .{val.string});
                            break :blk 0;
                        };
                    }
                } else if (std.mem.eql(u8, key, "body")) {
                    st.body = try p.stmtList(val);
                } else if (schema.slotIndex(kind, key)) |si| {
                    try st.set(p.arena, si, try p.slotValue(schema.info(kind).slots[si], val, st.line));
                } else {
                    var known: std.ArrayList(u8) = .empty;
                    for (schema.info(kind).slots) |sl| try known.print(p.arena, " {s}", .{sl.name});
                    p.fail(st.line, "'{s}' has no '{s}'; it has:{s}", .{ kind_name, key, known.items });
                }
            }
            try out.append(p.arena, st);
        }
        return out.items;
    }
};

/// Parse the JSON form. Problems are reported, never fatal: what could be
/// understood is returned.
pub fn parseNetlist(arena: Allocator, text: []const u8, report: *ir.Report) Allocator.Error!ir.Netlist {
    const root = std.json.parseFromSliceLeaky(J, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            report.add(.@"error", .invalid, 0, "not valid JSON: {s}", .{@errorName(err)});
            return .{};
        },
    };
    if (root != .object) {
        report.add(.@"error", .invalid, 0, "the top level must be an object with 'stmts'", .{});
        return .{};
    }
    var p: Parser = .{ .arena = arena, .report = report };
    var nl: ir.Netlist = .{ .dialect = "sprack" };
    if (root.object.get("title")) |t| if (t == .string) {
        nl.title = t.string;
    };
    if (root.object.get("dialect")) |t| if (t == .string) {
        nl.dialect = t.string;
    };
    if (root.object.get("stmts")) |s| nl.stmts = try p.stmtList(s);
    return nl;
}

test "IR to JSON and back" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var report: ir.Report = .init(a);
    const text =
        \\{"title":"t","stmts":[
        \\ {"kind":"resistor","name":"R1","pos":"a","neg":0,"r":"4.7k","params":{"tc1":"1m","noisy":null}},
        \\ {"kind":"tran","step":"10p","stop":2e-8,"skip_dc":true},
        \\ {"kind":"subckt","name":"x","ports":["a","b"],"params":{"w":"2*wmin"},"body":[
        \\   {"kind":"capacitor","name":"C1","pos":"a","neg":"b","c":"1p"}]}]}
    ;
    const nl = try parseNetlist(a, text, &report);
    try std.testing.expectEqual(0, report.items.items.len);
    try std.testing.expectEqual(3, nl.stmts.len);
    try std.testing.expectEqualStrings("4.7", nl.stmts[0].get("r").num.digits());
    try std.testing.expectEqual(@as(i32, 3), nl.stmts[0].get("r").num.exp10);
    try std.testing.expectEqualStrings("0", nl.stmts[0].get("neg").atom);
    try std.testing.expectEqualStrings("yes", nl.stmts[1].get("skip_dc").atom);
    try std.testing.expectEqualStrings("2*wmin", nl.stmts[2].get("params").params[0].val.expr);

    var aw: std.Io.Writer.Allocating = .init(a);
    try writeNetlist(&aw.writer, &nl);
    const again = try parseNetlist(a, aw.written(), &report);
    try std.testing.expect(ir.sameCircuit(&nl, &again));

    // The one trap in the number notation is refused, not guessed.
    var r2: ir.Report = .init(a);
    _ = try parseNetlist(a, "{\"stmts\":[{\"kind\":\"resistor\",\"name\":\"R1\",\"pos\":\"a\",\"neg\":\"0\",\"r\":\"1M\"}]}", &r2);
    try std.testing.expect(r2.contains(.@"error", "'1M' is ambiguous"));
    var r3: ir.Report = .init(a);
    _ = try parseNetlist(a, "{\"stmts\":[{\"kind\":\"resistor\",\"nmae\":\"R1\"},{\"kind\":\"zener\"}]}", &r3);
    try std.testing.expect(r3.contains(.@"error", "'resistor' has no 'nmae'; it has: name pos neg r master params"));
    try std.testing.expect(r3.contains(.@"error", "unknown statement kind 'zener'"));
}
