//! The `rewrite kind param ... end` and `plugin ... end` blocks.
//!
//! Contents:
//! - `pub fn rewrite(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void`
//! - `pub fn plugin(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void`

const std = @import("std");
const schema = @import("schema");
const Kind = schema.Kind;
const context = @import("context.zig");
const tables = @import("tables.zig");
const types = @import("types.zig");
const C = context.C;
const Error = context.Error;
const Lines = context.Lines;
const args = context.args;
const kindOf = context.kindOf;
const slotNamed = context.slotNamed;
const Grammar = tables.Grammar;
const Plugin = types.Plugin;
const Rewrite = types.Rewrite;

/// `rewrite kind param`, then its lines up to `end`.
pub fn rewrite(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void {
    const no = lines.no;
    const rule = try rewriteBlock(c, lines, rest);
    // The keys every clash line watches are held in one table.
    for (g.rewrites) |other| {
        const a = other.clash orelse continue;
        const b = rule.clash orelse continue;
        if (a.kind != b.kind or a.slot != b.slot)
            return c.fail(no, "every clash line of a grammar names one kind.slot", .{});
    }
    g.rewrites = try c.add(Rewrite, g.rewrites, rule);
}

/// `plugin`, then its lines up to `end`; a grammar has one.
pub fn plugin(c: *C, g: *Grammar, lines: *Lines, rest: []const u8) Error!void {
    if (g.plugin != null) return c.fail(lines.no, "a grammar has one plugin block", .{});
    g.plugin = try pluginBlock(c, lines, rest);
}

// ---- private ----

/// The lines of a `plugin` block, up to its `end`.
fn pluginBlock(c: *C, lines: *Lines, header: []const u8) Error!Plugin {
    const head_line = lines.no;
    if (header.len > 0) return c.fail(head_line, "plugin takes nothing on its own line", .{});
    var missing: []const u8 = "";
    var given: []const u8 = "";
    var drops: []const Plugin.Drop = &.{};
    while (lines.next()) |line| {
        const no = lines.no;
        if (std.mem.eql(u8, line, "end")) {
            if (missing.len == 0 or given.len == 0)
                return c.fail(no, "plugin needs a `missing : text` and a `given : text` line", .{});
            return .{ .missing = missing, .given = given, .drops = drops };
        }
        const colon = std.mem.indexOf(u8, line, " : ") orelse
            return c.fail(no, "a line of plugin is `what : text`", .{});
        // `Lines.next` trims the line, so it does not start with the blank of " : ".
        std.debug.assert(colon > 0);
        const text = std.mem.trim(u8, line[colon + 3 ..], " \t");
        if (text.len == 0) return c.fail(no, "a line of plugin needs its text", .{});
        const words = try args(c, no, line[0..colon]);
        if (words.len == 1 and std.mem.eql(u8, words[0], "missing")) {
            missing = text;
        } else if (words.len == 1 and std.mem.eql(u8, words[0], "given")) {
            given = text;
        } else {
            drops = try c.add(Plugin.Drop, drops, try pluginDrop(c, no, words, text));
        }
    }
    return c.fail(head_line, "plugin is missing 'end'", .{});
}

/// `card key error|warning` or `instance key[=value] error|warning`, and its text.
fn pluginDrop(c: *C, no: u32, words: []const []const u8, text: []const u8) Error!Plugin.Drop {
    std.debug.assert(text.len > 0);
    const card = words.len == 3 and std.mem.eql(u8, words[0], "card");
    if (!card and !(words.len == 3 and std.mem.eql(u8, words[0], "instance")))
        return c.fail(
            no,
            "plugin: `missing`, `given`, `card key error|warning` or " ++
                "`instance key[=value] error|warning`, each with ` : text`",
            .{},
        );
    const err = std.mem.eql(u8, words[2], "error");
    if (!err and !std.mem.eql(u8, words[2], "warning"))
        return c.fail(no, "plugin: '{s}' is neither error nor warning", .{words[2]});
    const eq = std.mem.indexOfScalar(u8, words[1], '=') orelse words[1].len;
    const neutral = if (eq < words[1].len) words[1][eq + 1 ..] else "";
    if (eq == 0) return c.fail(no, "plugin: a parameter name is missing", .{});
    if (card and eq < words[1].len)
        return c.fail(no, "plugin: a card's parameter is left out whatever its value", .{});
    if (eq < words[1].len and (std.fmt.parseFloat(f64, neutral) catch null) == null)
        return c.fail(no, "plugin: '{s}' is not a number", .{neutral});
    return .{ .card = card, .key = words[1][0..eq], .neutral = neutral, .err = err, .text = text };
}

/// The lines of a `rewrite kind param` block, up to its `end`.
fn rewriteBlock(c: *C, lines: *Lines, header: []const u8) Error!Rewrite {
    const head_line = lines.no;
    const words = try args(c, head_line, header);
    if (words.len != 2) return c.fail(head_line, "rewrite is `rewrite kind parameter`", .{});
    var rule: Rewrite = .{ .kind = try kindOf(c, head_line, words[0]), .param = words[1] };
    std.debug.assert(rule.param.len > 0);
    while (lines.next()) |line| {
        const no = lines.no;
        if (std.mem.eql(u8, line, "end")) {
            if (rule.parts.len == 0)
                return c.fail(no, "rewrite needs a keep or a become line", .{});
            // What a statement put in the original's place has no room for
            // must be said: nothing is dropped in silence.
            if (!rule.parts[0].keep and rule.loss.len == 0)
                return c.fail(no, "a rewrite with `become` needs a `loss : text` line", .{});
            return rule;
        }
        const verb_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const verb = line[0..verb_end];
        const rest = std.mem.trim(u8, line[verb_end..], " \t");
        if (std.mem.eql(u8, verb, "when")) {
            var names = std.mem.tokenizeAny(u8, rest, " \t");
            while (names.next()) |name| {
                if (schema.kindFromName(name)) |kind| {
                    rule.kinds = try c.add(Kind, rule.kinds, kind);
                } else if (schema.isFunction(name)) {
                    rule.functions = try c.add([]const u8, rule.functions, name);
                } else return c.fail(no, "when: '{s}' is neither a kind nor a function", .{name});
            }
        } else if (std.mem.eql(u8, verb, "loss") or std.mem.eql(u8, verb, "oneway")) {
            if (!std.mem.startsWith(u8, rest, ": "))
                return c.fail(no, "{s} is `{s} : text`", .{ verb, verb });
            if (rest.len == 2) return c.fail(no, "{s} needs its text", .{verb});
            if (verb[0] == 'l') rule.loss = rest[2..] else rule.note = rest[2..];
        } else if (std.mem.eql(u8, verb, "clash")) {
            rule.clash = try rewriteClash(c, no, rule.kind, rest);
        } else {
            const part = try rewritePart(c, no, rule.kind, verb, rest);
            const first = rule.parts.len == 0;
            if (first == std.mem.eql(u8, verb, "add"))
                return c.fail(
                    no,
                    "a rewrite starts with keep or become, and goes on with add",
                    .{},
                );
            rule.parts = try c.add(Rewrite.Part, rule.parts, part);
        }
    }
    return c.fail(head_line, "rewrite is missing 'end'", .{});
}

/// `keep slot=template ...`, or `become kind slot=template ...`, or `add` likewise.
fn rewritePart(
    c: *C,
    no: u32,
    original: Kind,
    verb: []const u8,
    rest: []const u8,
) Error!Rewrite.Part {
    std.debug.assert(verb.len > 0);
    const keep = std.mem.eql(u8, verb, "keep");
    if (!keep and !std.mem.eql(u8, verb, "become") and !std.mem.eql(u8, verb, "add"))
        return c.fail(no, "rewrite: unknown line `{s}`", .{verb});
    var words = std.mem.tokenizeAny(u8, rest, " \t");
    const kind = if (keep)
        original
    else
        try kindOf(c, no, words.next() orelse return c.fail(no, "{s} needs a kind", .{verb}));
    var sets: []const Rewrite.Set = &.{};
    while (words.next()) |word| {
        const eq = std.mem.indexOfScalar(u8, word, '=') orelse
            return c.fail(no, "expected slot=template, found '{s}'", .{word});
        const slot = try slotNamed(c, no, kind, word[0..eq]);
        const template = word[eq + 1 ..];
        if (!pairedBrackets(template))
            return c.fail(no, "the {{ }} and [ ] of template '{s}' do not pair", .{template});
        sets = try c.add(Rewrite.Set, sets, .{ .slot = slot, .template = template });
    }
    // A kept statement may stay as it is: the rewrite then only adds to it.
    if (sets.len == 0 and !keep) return c.fail(no, "{s} needs at least one slot=template", .{verb});
    return .{ .kind = kind, .keep = keep, .sets = sets };
}

/// Does every `{` of a template close before the next opens, and every
/// `[` likewise, with no `[` inside another?
fn pairedBrackets(template: []const u8) bool {
    var in_name = false;
    var in_group = false;
    for (template) |ch| {
        const ok = switch (ch) {
            '{' => !in_name,
            '}' => in_name,
            '[' => !in_group and !in_name,
            ']' => in_group and !in_name,
            else => true,
        };
        if (!ok) return false;
        if (ch == '{' or ch == '}') in_name = ch == '{';
        if (ch == '[' or ch == ']') in_group = ch == '[';
    }
    return !in_name and !in_group;
}

/// `kind.slot node ... : text`.
fn rewriteClash(c: *C, no: u32, original: Kind, rest: []const u8) Error!Rewrite.Clash {
    const colon = std.mem.indexOf(u8, rest, " : ") orelse
        return c.fail(no, "clash is `clash kind.slot node ... : text`", .{});
    var words = std.mem.tokenizeAny(u8, rest[0..colon], " \t");
    const where = words.next() orelse return c.fail(no, "clash needs a kind.slot", .{});
    const dot = std.mem.indexOfScalar(u8, where, '.') orelse
        return c.fail(no, "clash needs a kind.slot, found '{s}'", .{where});
    const kind = try kindOf(c, no, where[0..dot]);
    const slot = try slotNamed(c, no, kind, where[dot + 1 ..]);
    if (schema.info(kind).slots[slot].ty != .params)
        return c.fail(no, "clash: '{s}' is not a key=value slot", .{where});
    var nodes: []const u8 = &.{};
    while (words.next()) |name| nodes = try c.add(u8, nodes, try slotNamed(c, no, original, name));
    if (nodes.len == 0) return c.fail(no, "clash needs the slots whose names it looks for", .{});
    if (rest[colon + 3 ..].len == 0) return c.fail(no, "clash needs its text", .{});
    return .{ .kind = kind, .slot = slot, .nodes = nodes, .text = rest[colon + 3 ..] };
}
