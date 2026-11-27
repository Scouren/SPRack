//! Project: the catalogue, a JSON list of every subcircuit and model a
//! tree of files defines.
//!
//! Contents:
//! - `pub fn catalogStmts(r: *Run, w: *Writer, path: []const u8, section: []const u8,
//!   stmts: []const ir.Stmt) Writer.Error!void`
//! - `pub fn noteOpaque(r: *Run, path: []const u8, stmts: []const ir.Stmt) void`
//! - `pub fn catalogEnd(r: *const Run, w: *Writer, present: []const []const u8,
//!   root_dir: []const u8) Writer.Error!void`

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir");
const json = @import("json");
const run_ = @import("run.zig");
const Writer = std.Io.Writer;
const assert = std.debug.assert;
const Run = run_.Run;

// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn catalogStmts(
    r: *Run,
    w: *Writer,
    path: []const u8,
    section: []const u8,
    stmts: []const ir.Stmt,
) Writer.Error!void {
    // A file the run could not read is "", and is not listed.
    assert(path.len > 0);
    for (stmts) |*st| {
        const name = st.get("name");
        switch (st.kind) {
            .libsection => {
                try r.catalogStmts(w, path, if (name == .atom) name.atom else "", st.body);
                continue;
            },
            .subckt, .model => {},
            else => continue,
        }
        if (name != .atom) continue;
        if (!r.first_device) try w.writeAll(",\n");
        r.first_device = false;
        try w.print(
            "{{\"name\":{f},\"file\":{f},\"section\":{f}",
            .{
                std.json.fmt(name.atom, .{}),
                std.json.fmt(path, .{}),
                std.json.fmt(section, .{}),
            },
        );
        if (st.kind == .subckt) {
            try w.writeAll(",\"kind\":\"subckt\",\"ports\":[");
            const ports = st.get("ports");
            if (ports == .list) for (ports.list, 0..) |p, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{f}", .{std.json.fmt(if (p == .atom) p.atom else "", .{})});
            };
            try w.writeAll("],\"params\":{");
            // The header's parameters, then `.param` lines in the body:
            // PDKs converted from Spectre declare instance parameters there.
            var n_params: usize = 0;
            try catalogParams(w, st.get("params"), &n_params);
            for (st.body) |*child| {
                if (child.kind == .param) try catalogParams(w, child.get("params"), &n_params);
            }
            try w.writeAll("}}");
        } else {
            const fam = st.get("family");
            const pol = st.get("polarity");
            const ty = st.get("type");
            const dev: []const u8 = if (fam == .atom)
                @tagName(schema.familyKind(fam.atom) orelse .device)
            else
                "device";
            try w.print(
                ",\"kind\":\"model\",\"device\":\"{s}\",\"family\":{f}," ++
                    "\"polarity\":{f},\"type\":{f}}}",
                .{
                    dev,
                    std.json.fmt(if (fam == .atom) fam.atom else "", .{}),
                    std.json.fmt(if (pol == .atom) pol.atom else "", .{}),
                    std.json.fmt(if (ty == .atom) ty.atom else "", .{}),
                },
            );
        }
    }
}

/// Reading alone reports nothing about lines no rule understood; a
/// catalogue should say how much of the library it could not read.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn noteOpaque(r: *Run, path: []const u8, stmts: []const ir.Stmt) void {
    // A file the run could not read is "", and is not walked.
    assert(path.len > 0);
    for (stmts) |*st| {
        if (st.kind == .@"opaque") {
            var buf: [160]u8 = undefined;
            const first = std.mem.sliceTo(st.raw, '\n');
            const msg = std.fmt.bufPrint(
                &buf,
                "not understood: {s}",
                .{first[0..@min(first.len, 120)]},
            ) catch "not understood";
            r.logLine(
                path,
                .{ .sev = .warning, .code = .untranslated, .line = st.line, .msg = msg },
            );
        }
        r.noteOpaque(path, st.body);
    }
}

/// The rest of the catalogue, after its devices: the files read, the
/// sections they define, the declarations, the `$NAME`s and the counts.
pub fn catalogEnd(
    r: *const Run,
    w: *Writer,
    present: []const []const u8,
    root_dir: []const u8,
) Writer.Error!void {
    // Only files that were read are listed.
    for (present) |p| assert(p.len > 0);
    try w.writeAll("\n],\"files\":[");
    for (present, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{f}", .{std.json.fmt(p, .{})});
    }
    try w.writeAll("],\"sections\":[");
    for (r.sections.items, 0..) |sec, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(
            "{{\"file\":{f},\"name\":{f}}}",
            .{ std.json.fmt(sec.path, .{}), std.json.fmt(sec.section, .{}) },
        );
    }
    try w.writeAll("],\"env\":");
    try json.writeEnv(w, &r.env);
    try w.writeAll(",\"vars\":");
    try r.writeExpanded(w);
    try w.print(",\"root\":{f},\"errors\":{d},\"warnings\":{d},\"missing\":{d}}}\n", .{
        std.json.fmt(root_dir, .{}), r.sum.errors, r.sum.warnings, r.sum.missing,
    });
}

// ---- private ----

fn catalogParams(w: *Writer, ps: ir.Value, count: *usize) Writer.Error!void {
    if (ps != .params) return;
    for (ps.params) |p| {
        if (count.* > 0) try w.writeByte(',');
        count.* += 1;
        try w.print("{f}:", .{std.json.fmt(p.key, .{})});
        switch (p.val) {
            .num => |n| if (n.exp10 == 0)
                try w.print("\"{s}\"", .{n.digits()})
            else
                try w.print("\"{s}e{d}\"", .{ n.digits(), n.exp10 }),
            .expr => |e| try w.print("{f}", .{std.json.fmt(e, .{})}),
            else => try w.writeAll("null"),
        }
    }
}
