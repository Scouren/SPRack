//! The canonical vocabulary every dialect grammar maps onto.
//!
//! A `.spgrammar` file may only name kinds and slots listed here; anything
//! else is a compile error. This is what makes any-to-any translation work:
//! two grammars that both bind `tran.stop` are talking about the same thing.

const std = @import("std");

pub const SlotType = enum {
    /// Instance or definition name.
    name,
    /// Circuit node.
    node,
    /// Model, subcircuit or type name. Never numeric.
    ident,
    /// The name of an instance elsewhere in the netlist (`.dc V1 ...`).
    ref,
    /// Number or expression.
    value,
    /// One word out of a closed set (`dec`, `pulse`, `yes`).
    atom,
    /// File path. Case is preserved even in case-folding dialects.
    path,
    /// The untouched remainder of a line.
    text,
    /// Open-ended `key=value` list.
    params,
    /// Something a simulator can record: `v(out)`, `v(a,b)`, `i(v1)`.
    /// Stored in that canonical spelling; each grammar's `signals` section
    /// says how the dialect writes it.
    signal,
};

pub const Slot = struct { name: []const u8, ty: SlotType, list: bool };

/// `control` statements steer the simulator (options, what to save, initial
/// conditions). Like analyses, their open-ended `params` belong to the
/// dialect that wrote them and are never copied into another one.
pub const Class = enum { device, structure, analysis, control, other };

pub const Kind = enum(u8) {
    resistor,
    capacitor,
    inductor,
    mutual,
    vsource,
    isource,
    bsource,
    vcvs,
    vccs,
    cccs,
    ccvs,
    diode,
    bjt,
    mosfet,
    jfet,
    mesfet,
    vswitch,
    cswitch,
    tline,
    device,
    xspice,
    instance,
    subckt,
    libsection,
    cond_if,
    cond_elif,
    cond_else,
    model,
    param,
    func,
    global,
    include,
    lib,
    hdl,
    verilog,
    options,
    save,
    print,
    ic,
    nodeset,
    measure,
    op,
    dc,
    ac,
    tran,
    noise,
    tf,
    pz,
    sens,
    disto,
    four,
    hb,
    sp,
    pss,
    stb,
    @"opaque",
    comment,
};

pub const KindInfo = struct { kind: Kind, class: Class, slots: []const Slot };

const Def = struct { Kind, Class, []const u8 };

const source_spec = "name pos:node neg:node dc:value acmag:value acphase:value wave:atom " ++
    "val0:value val1:value delay:value rise:value fall:value width:value period:value " ++
    "sinedc:value ampl:value freq:value damp:value sphase:value " ++
    "td1:value tau1:value td2:value tau2:value mdi:value fsig:value pwl:value* " ++
    // Small-signal distortion inputs and the RF port a source may stand for.
    "distof1:value distof1ph:value distof2:value distof2ph:value portnum:value z0:value params:params";

const sweep_spec = "sweep:atom points:value fstart:value fstop:value";

/// One line per kind: `slot[:type][*]`. A bare slot named `name` has type `name`.
const defs = [_]Def{
    .{ .resistor, .device, "name pos:node neg:node r:value master:ident params:params" },
    .{ .capacitor, .device, "name pos:node neg:node c:value master:ident params:params" },
    .{ .inductor, .device, "name pos:node neg:node l:value params:params" },
    .{ .mutual, .device, "name l1:ref l2:ref k:value" },
    .{ .vsource, .device, source_spec },
    .{ .isource, .device, source_spec },
    // Behavioural source: exactly one of `v` and `i` is an expression.
    .{ .bsource, .device, "name pos:node neg:node v:value i:value params:params" },
    .{ .vcvs, .device, "name pos:node neg:node cpos:node cneg:node gain:value params:params" },
    .{ .vccs, .device, "name pos:node neg:node cpos:node cneg:node gm:value params:params" },
    .{ .cccs, .device, "name pos:node neg:node vsrc:ref gain:value params:params" },
    .{ .ccvs, .device, "name pos:node neg:node vsrc:ref gain:value params:params" },
    .{ .diode, .device, "name pos:node neg:node master:ident area:value params:params" },
    .{ .bjt, .device, "name c:node b:node e:node s:node tj:node master:ident area:value params:params" },
    .{ .mosfet, .device, "name d:node g:node s:node b:node master:ident params:params" },
    .{ .jfet, .device, "name d:node g:node s:node master:ident area:value params:params" },
    .{ .mesfet, .device, "name d:node g:node s:node master:ident area:value params:params" },
    .{ .vswitch, .device, "name pos:node neg:node cpos:node cneg:node master:ident state:atom" },
    .{ .cswitch, .device, "name pos:node neg:node vsrc:ref master:ident state:atom" },
    .{ .tline, .device, "name p1:node n1:node p2:node n2:node z0:value td:value f:value nl:value params:params" },
    // An instance of a compact model that is not one of the families below,
    // typically a Verilog-A module. Any number of terminals.
    .{ .device, .device, "name nodes:node* master:ident params:params" },
    // An ngspice XSPICE code-model instance (`A1 [ a b ] y model`). A vector
    // port's `[` and `]` are items of `nodes` of their own.
    .{ .xspice, .device, "name nodes:node* master:ident params:params" },
    .{ .instance, .device, "name nodes:node* master:ident params:params" },
    .{ .subckt, .structure, "name ports:node* params:params" },
    .{ .libsection, .structure, "name" },
    // A conditional block. `cond_elif` and `cond_else` are markers inside
    // the body of a `cond_if`; what follows each belongs to that branch.
    .{ .cond_if, .structure, "cond:value" },
    .{ .cond_elif, .structure, "cond:value" },
    .{ .cond_else, .structure, "" },
    .{ .model, .structure, "name type:ident family:atom polarity:atom params:params" },
    .{ .param, .structure, "params:params" },
    .{ .func, .structure, "name args:atom* expr:value" },
    .{ .global, .structure, "nodes:node*" },
    .{ .include, .structure, "path:path" },
    .{ .lib, .structure, "path:path section:ident" },
    .{ .hdl, .structure, "path:path" },
    // A digital Verilog design, loaded as source (ESPice's `.verilog`).
    .{ .verilog, .structure, "path:path" },
    // `package` is for dialects that file options under headings (Xyce).
    .{ .options, .control, "package:atom reltol:value abstol:value vntol:value gmin:value temp:value tnom:value " ++
        "scale:value method:atom maxord:value chgtol:value trtol:value params:params" },
    .{ .save, .control, "signals:signal*" },
    // `style` tells a table (.print) from a plot (.plot) from a probe (.probe).
    .{ .print, .control, "style:atom analysis:atom signals:signal* params:params" },
    .{ .ic, .control, "values:params" },
    .{ .nodeset, .control, "values:params" },
    .{ .measure, .control, "analysis:atom name spec:text" },
    .{ .op, .analysis, "name params:params" },
    // src2 is the outer loop of a nested sweep; src is swept for each of its values.
    // `var` is set instead of `src` when the sweep is over temperature.
    .{ .dc, .analysis, "name src:ref var:atom start:value stop:value step:value " ++
        "src2:ref start2:value stop2:value step2:value params:params" },
    .{ .ac, .analysis, "name " ++ sweep_spec ++ " params:params" },
    .{ .tran, .analysis, "name step:value stop:value start:value maxstep:value skip_dc:atom method:atom params:params" },
    .{ .noise, .analysis, "name out:node ref:node src:ref " ++ sweep_spec ++ " params:params" },
    .{ .tf, .analysis, "name out:node ref:node src:ref params:params" },
    .{ .pz, .analysis, "name in_pos:node in_neg:node out_pos:node out_neg:node transfer:atom find:atom params:params" },
    .{ .sens, .analysis, "name out:signal params:params" },
    .{ .disto, .analysis, "name " ++ sweep_spec ++ " f2overf1:value params:params" },
    .{ .four, .analysis, "name freq:value signals:signal* params:params" },
    .{ .hb, .analysis, "name freqs:value* harms:value* params:params" },
    .{ .sp, .analysis, "name " ++ sweep_spec ++ " params:params" },
    .{ .pss, .analysis, "name fund:value harms:value tstab:value points:value params:params" },
    .{ .stb, .analysis, "name " ++ sweep_spec ++ " probe:ref params:params" },
    .{ .@"opaque", .other, "" },
    .{ .comment, .other, "" },
};

pub const kind_count = defs.len;
pub const max_slots = 40;

pub const table: [kind_count]KindInfo = blk: {
    @setEvalBranchQuota(100_000);
    var out: [kind_count]KindInfo = undefined;
    for (defs, 0..) |d, i| {
        if (@backingInt(d[0]) != i) @compileError("schema.defs must follow the order of Kind");
        var slots: []const Slot = &.{};
        var it = std.mem.tokenizeScalar(u8, d[2], ' ');
        while (it.next()) |word| {
            var w = word;
            const list = w[w.len - 1] == '*';
            if (list) w = w[0 .. w.len - 1];
            var ty: SlotType = .name;
            var nm = w;
            if (std.mem.indexOfScalar(u8, w, ':')) |c| {
                nm = w[0..c];
                ty = std.meta.stringToEnum(SlotType, w[c + 1 ..]) orelse @compileError("schema: bad slot type in " ++ word);
            }
            slots = slots ++ &[_]Slot{.{ .name = nm, .ty = ty, .list = list }};
        }
        if (slots.len > max_slots) @compileError("schema: too many slots");
        out[i] = .{ .kind = d[0], .class = d[1], .slots = slots };
    }
    break :blk out;
};

pub fn info(kind: Kind) *const KindInfo {
    return &table[@backingInt(kind)];
}

pub fn slotIndex(kind: Kind, name: []const u8) ?u8 {
    for (info(kind).slots, 0..) |s, i| if (std.mem.eql(u8, s.name, name)) return @intCast(i);
    return null;
}

pub fn kindFromName(name: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, name);
}

/// Model families the canonical IR knows, and the device kind each one is.
/// A grammar's `models` section may only name these.
pub const Family = struct { name: []const u8, kind: Kind };
pub const families = [_]Family{
    .{ .name = "resistor", .kind = .resistor },
    .{ .name = "capacitor", .kind = .capacitor },
    .{ .name = "inductor", .kind = .inductor },
    .{ .name = "vsource", .kind = .vsource },
    .{ .name = "isource", .kind = .isource },
    .{ .name = "diode", .kind = .diode },
    .{ .name = "bjt", .kind = .bjt },
    .{ .name = "vbic", .kind = .bjt },
    .{ .name = "hicum2", .kind = .bjt },
    .{ .name = "jfet", .kind = .jfet },
    .{ .name = "mesfet", .kind = .mesfet },
    .{ .name = "hfet", .kind = .mesfet },
    .{ .name = "mos1", .kind = .mosfet },
    .{ .name = "mos2", .kind = .mosfet },
    .{ .name = "mos3", .kind = .mosfet },
    .{ .name = "bsim3", .kind = .mosfet },
    .{ .name = "bsim4", .kind = .mosfet },
    .{ .name = "bsimsoi", .kind = .mosfet },
    .{ .name = "bsimcmg", .kind = .mosfet },
    .{ .name = "bsimbulk", .kind = .mosfet },
    .{ .name = "psp103", .kind = .mosfet },
    .{ .name = "hisim2", .kind = .mosfet },
    .{ .name = "hisimhv", .kind = .mosfet },
    .{ .name = "vdmos", .kind = .mosfet },
    .{ .name = "vswitch", .kind = .vswitch },
    .{ .name = "cswitch", .kind = .cswitch },
};

/// Functions an expression may call, by canonical name. A grammar's
/// `functions` section gives the dialect's spelling of each one it has.
pub const functions = [_][]const u8{
    "abs",   "sgn",   "sign2", "min",   "max",   "sqrt",  "sqr",    "exp",   "ln",    "log10",
    "pow",   "pwr",   "floor", "ceil",  "int",   "nint",  "fmod",   "hypot", "db",    "sin",
    "cos",   "tan",   "asin",  "acos",  "atan",  "atan2", "sinh",   "cosh",  "tanh",  "asinh",
    "acosh", "atanh", "limit", "if",    "stp",   "uramp", "agauss", "gauss", "aunif", "unif",
    "v",     "i",
};

/// Variables the simulator provides.
pub const variables = [_][]const u8{ "temper", "time", "hertz" };

/// Operators that are not spelled the same everywhere.
pub const operators = [_][]const u8{ "pow", "xor", "ternary" };

/// Signal forms a `signals` section may spell.
pub const signal_forms = [_][]const u8{ "v", "vdiff", "i", "vdb", "vm", "vp", "vr", "vi", "all" };

fn inList(comptime list: []const []const u8, name: []const u8) bool {
    inline for (list) |f| if (std.mem.eql(u8, f, name)) return true;
    return false;
}

pub fn isFunction(name: []const u8) bool {
    return inList(&functions, name);
}

pub fn isVariable(name: []const u8) bool {
    return inList(&variables, name);
}

pub fn familyKind(name: []const u8) ?Kind {
    for (families) |f| if (std.mem.eql(u8, f.name, name)) return f.kind;
    return null;
}

test "schema table" {
    try std.testing.expectEqual(Kind.tran, info(.tran).kind);
    try std.testing.expectEqual(@as(?u8, 2), slotIndex(.tran, "stop"));
    try std.testing.expect(slotIndex(.tran, "tstop") == null);
    try std.testing.expect(info(.vsource).slots[slotIndex(.vsource, "pwl").?].list);
    try std.testing.expect(isFunction("ln") and !isFunction("log"));
}
