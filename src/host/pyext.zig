//! The CPython extension module `sprack._core`.
//!
//! Written against the limited C API by hand (Zig 0.17 has no @cImport), so
//! one binary serves CPython 3.10 and later. Everything crosses the
//! boundary as text: netlists as they are, the IR and the reports as JSON.
//! The Python package on top of this holds no knowledge of any dialect.

const std = @import("std");
const sprack = @import("sprack");
const ir = sprack.ir;
const Allocator = std.mem.Allocator;

const PyObject = opaque {};

const PyMethodDef = extern struct {
    name: ?[*:0]const u8,
    meth: ?*const fn (?*PyObject, ?*PyObject) callconv(.c) ?*PyObject,
    flags: c_int,
    doc: ?[*:0]const u8,
};

const PyModuleDef = extern struct {
    // PyModuleDef_Base
    ob_refcnt: isize = 1,
    ob_type: ?*anyopaque = null,
    m_init: ?*anyopaque = null,
    m_index: isize = 0,
    m_copy: ?*anyopaque = null,
    // PyModuleDef
    m_name: [*:0]const u8,
    m_doc: ?[*:0]const u8,
    m_size: isize = -1,
    m_methods: [*]PyMethodDef,
    m_slots: ?*anyopaque = null,
    m_traverse: ?*anyopaque = null,
    m_clear: ?*anyopaque = null,
    m_free: ?*anyopaque = null,
};

extern fn PyModule_Create2(def: *PyModuleDef, api_version: c_int) ?*PyObject;
extern fn PyTuple_Size(t: *PyObject) isize;
extern fn PyTuple_GetItem(t: *PyObject, i: isize) ?*PyObject;
extern fn PyTuple_New(n: isize) ?*PyObject;
extern fn PyTuple_SetItem(t: *PyObject, i: isize, o: *PyObject) c_int;
extern fn PyUnicode_AsUTF8AndSize(o: *PyObject, size: *isize) ?[*]const u8;
extern fn PyUnicode_FromStringAndSize(s: [*]const u8, n: isize) ?*PyObject;
extern fn PyErr_SetString(ty: *PyObject, msg: [*:0]const u8) void;
extern fn PyErr_NoMemory() ?*PyObject;
extern fn PyObject_IsTrue(o: *PyObject) c_int;

const METH_VARARGS = 1;

const Fail = error{ Raised, OutOfMemory, WriteFailed };

var threaded: std.Io.Threaded = .init_single_threaded;

var methods = [_]PyMethodDef{
    .{
        .name = "info",
        .meth = pyInfo,
        .flags = METH_VARARGS,
        .doc = "info() -> JSON: dialects, statement kinds and their slots, who can write what.",
    },
    .{
        .name = "translate",
        .meth = pyTranslate,
        .flags = METH_VARARGS,
        .doc = "translate(from, to, source) -> (netlist, report JSON)",
    },
    .{
        .name = "read",
        .meth = pyRead,
        .flags = METH_VARARGS,
        .doc = "read(from, source[, library[, JSON with env]]) -> (IR JSON, report JSON)",
    },
    .{
        .name = "write",
        .meth = pyWrite,
        .flags = METH_VARARGS,
        .doc = "write(to, IR JSON[, library]) -> (netlist, report JSON)",
    },
    .{
        .name = "project",
        .meth = pyProject,
        .flags = METH_VARARGS,
        .doc = "project(from, to, files, out_dir, vars, library[, sections[, errata[, " ++
            "provided]]]) -> (summary or catalogue JSON, log)",
    },
    .{ .name = null, .meth = null, .flags = 0, .doc = null },
};

var module: PyModuleDef = .{
    .m_name = "_core",
    .m_doc = "SPRack core: SPICE dialect readers and writers generated from .spgrammar files.",
    .m_methods = &methods,
};

// ---- private ----

/// `PyExc_ValueError`. A Windows DLL's data is reached through its
/// import-table slot.
fn valueError() *PyObject {
    if (@import("builtin").os.tag == .windows) return struct {
        extern var __imp_PyExc_ValueError: **PyObject;
    }.__imp_PyExc_ValueError.*;
    return struct {
        extern var PyExc_ValueError: *PyObject;
    }.PyExc_ValueError;
}

fn arg(args: ?*PyObject, i: isize) Fail![]const u8 {
    const t = args orelse return error.Raised;
    const o = PyTuple_GetItem(t, i) orelse return error.Raised;
    var n: isize = 0;
    const p = PyUnicode_AsUTF8AndSize(o, &n) orelse return error.Raised;
    return p[0..@intCast(n)];
}

fn flag(args: ?*PyObject, i: isize) bool {
    const t = args orelse return false;
    if (PyTuple_Size(t) <= i) return false;
    const o = PyTuple_GetItem(t, i) orelse return false;
    return PyObject_IsTrue(o) == 1;
}

/// A built-in dialect name or a path to a `.spgrammar` file.
fn dialect(arena: Allocator, name: []const u8) Fail!*const sprack.Grammar {
    var diag: sprack.grammar.Diag = .{};
    return sprack.resolve(arena, threaded.io(), name, &diag) catch |e| {
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
        switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownDialect => {
                w.print(
                    "unknown dialect '{s}'. Built in:",
                    .{name[0..@min(name.len, 40)]},
                ) catch {};
                for (sprack.grammars) |*g| w.print(" {s}", .{g.name}) catch {};
                w.writeAll("; or a path to a .spgrammar file") catch {};
            },
            error.CannotRead, error.BadGrammar, error.TooManyDialects => w.writeAll(diag.msg) catch
                {},
        }
        buf[w.end] = 0;
        PyErr_SetString(valueError(), @ptrCast(&buf));
        return error.Raised;
    };
}

fn text(s: []const u8) Fail!*PyObject {
    return PyUnicode_FromStringAndSize(s.ptr, @intCast(s.len)) orelse error.Raised;
}

fn pair(a: []const u8, b: []const u8) Fail!*PyObject {
    const t = PyTuple_New(2) orelse return error.Raised;
    _ = PyTuple_SetItem(t, 0, try text(a));
    _ = PyTuple_SetItem(t, 1, try text(b));
    return t;
}

fn reportJson(arena: Allocator, report: *const ir.Report) Fail![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try sprack.json.writeReport(&aw.writer, report);
    return aw.written();
}

/// Run one entry point with its own arena and turn Zig errors into Python ones.
fn call(comptime body: fn (Allocator, ?*PyObject) Fail!*PyObject, args: ?*PyObject) ?*PyObject {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    return body(arena_state.allocator(), args) catch |err| switch (err) {
        error.Raised => null,
        error.OutOfMemory, error.WriteFailed => PyErr_NoMemory(),
    };
}

fn infoBody(arena: Allocator, _: ?*PyObject) Fail!*PyObject {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try sprack.json.writeInfo(&aw.writer, sprack.grammars);
    return text(aw.written());
}

fn translateBody(arena: Allocator, args: ?*PyObject) Fail!*PyObject {
    const gf = try dialect(arena, try arg(args, 0));
    const gt = try dialect(arena, try arg(args, 1));
    var report: ir.Report = .init(arena);
    // A statement at a time, as the command does (issue 67): the same
    // output, without the whole netlist held at once.
    var aw: std.Io.Writer.Allocating = .init(arena);
    _ = sprack.stream.translate(
        arena,
        gf,
        gt,
        try arg(args, 2),
        &aw.writer,
        &report,
        &sprack.caps,
        .{},
    ) catch return error.OutOfMemory;
    return pair(aw.written(), try reportJson(arena, &report));
}

fn readBody(arena: Allocator, args: ?*PyObject) Fail!*PyObject {
    const gf = try dialect(arena, try arg(args, 0));
    var report: ir.Report = .init(arena);
    // Optional: a netlist's JSON form whose `env` says what other files declare.
    const env = if (args != null and PyTuple_Size(args.?) > 3)
        (try sprack.json.parseNetlist(arena, try arg(args, 3), &report)).env
    else
        null;
    const nl = try sprack.reader.read(
        gf,
        arena,
        try arg(args, 1),
        &report,
        .{ .env = env, .library = flag(args, 2) },
    );
    var aw: std.Io.Writer.Allocating = .init(arena);
    try sprack.json.writeNetlist(&aw.writer, &nl);
    return pair(aw.written(), try reportJson(arena, &report));
}

fn writeBody(arena: Allocator, args: ?*PyObject) Fail!*PyObject {
    const gt = try dialect(arena, try arg(args, 0));
    var report: ir.Report = .init(arena);
    var nl = try sprack.json.parseNetlist(arena, try arg(args, 1), &report);
    nl.library = flag(args, 2);
    var aw: std.Io.Writer.Allocating = .init(arena);
    sprack.write(arena, gt, &aw.writer, &nl, &report) catch return error.OutOfMemory;
    return pair(aw.written(), try reportJson(arena, &report));
}

/// `tops` and `vars` arrive as lines: one path per line, one NAME=VALUE per line.
fn lines(arena: Allocator, s: []const u8) Fail![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, s, '\n');
    while (it.next()) |l| try out.append(arena, l);
    return out.items;
}

fn vars(arena: Allocator, s: []const u8) Fail![]const [2][]const u8 {
    var out: std.ArrayList([2][]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, s, '\n');
    while (it.next()) |l| {
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
        try out.append(arena, .{ l[0..eq], l[eq + 1 ..] });
    }
    return out.items;
}

/// project(from, to, tops, out_dir, vars, library) -> (summary_json, log)
/// catalog: the same with to == "" and out_dir == "" -> (catalog_json, log)
fn projectBody(arena: Allocator, args: ?*PyObject) Fail!*PyObject {
    const gf = try dialect(arena, try arg(args, 0));
    const to = try arg(args, 1);
    const gt: ?*const sprack.Grammar = if (to.len > 0) try dialect(arena, to) else null;
    var log: std.Io.Writer.Allocating = .init(arena);
    var cat: std.Io.Writer.Allocating = .init(arena);
    var expanded: std.Io.Writer.Allocating = .init(arena);
    const sum = sprack.project.run(threaded.io(), std.heap.page_allocator, .{
        .from = gf,
        .to = gt,
        .tops = try lines(arena, try arg(args, 2)),
        .out_dir = try arg(args, 3),
        .vars = try vars(arena, try arg(args, 4)),
        .library = flag(args, 5),
        // Optional: the library sections to follow, one per line.
        .sections = if (args != null and PyTuple_Size(args.?) > 6)
            try lines(arena, try arg(args, 6))
        else
            &.{},
        // Optional: a manifest's errata, as JSON.
        .errata = if (args != null and PyTuple_Size(args.?) > 7)
            sprack.project.parseErrata(arena, try arg(args, 7)) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadErrata => {
                    PyErr_SetString(valueError(), "errata: a list of {file, was, read, why}");
                    return error.Raised;
                },
            }
        else
            &.{},
        // Optional: files given by name (`--provide`), NAME=FILE lines.
        .provided = if (args != null and PyTuple_Size(args.?) > 8)
            try vars(arena, try arg(args, 8))
        else
            &.{},
        .log = &log.writer,
        .catalog = if (gt == null) &cat.writer else null,
        .expanded = &expanded.writer,
        .caps = &sprack.caps,
    }) catch return error.OutOfMemory;
    if (gt == null) return pair(cat.written(), log.written());
    const summary = try std.fmt.allocPrint(
        arena,
        "{{\"files\":{d},\"errors\":{d},\"warnings\":{d},\"missing\":{d},\"root\":{f},\"vars\":{s}}}",
        .{
            sum.files,          sum.errors, sum.warnings, sum.missing,
            std.json.fmt(
                sum.root(),
                .{},
            ),
            expanded.written(),
        },
    );
    return pair(summary, log.written());
}

fn pyInfo(_: ?*PyObject, a: ?*PyObject) callconv(.c) ?*PyObject {
    return call(infoBody, a);
}
fn pyTranslate(_: ?*PyObject, a: ?*PyObject) callconv(.c) ?*PyObject {
    return call(translateBody, a);
}
fn pyRead(_: ?*PyObject, a: ?*PyObject) callconv(.c) ?*PyObject {
    return call(readBody, a);
}
fn pyWrite(_: ?*PyObject, a: ?*PyObject) callconv(.c) ?*PyObject {
    return call(writeBody, a);
}
fn pyProject(_: ?*PyObject, a: ?*PyObject) callconv(.c) ?*PyObject {
    return call(projectBody, a);
}

export fn PyInit__core() ?*PyObject {
    return PyModule_Create2(&module, 3);
}
