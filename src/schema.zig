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
    // b3: analyses
    pac,
    pnoise,
    pxf,
    psp,
    xf,
    dcmatch,
    trannoise,
    phasenoise,
    envelope,
    qpss,
    // b4: devices, sources, outputs
    lossyline,
    ctlsrc,
    relay,
    simctl,
    // b1: sweeps
    step,
    data,
    // b2: statistics and structure
    statistics,
    statgroup,
    vary,
    correlate,
    montecarlo,
    library,
    // c2: alter
    alter,
};

pub const KindInfo = struct { kind: Kind, class: Class, slots: []const Slot };

const Def = struct { Kind, Class, []const u8 };

const source_spec = "name pos:node neg:node dc:value acmag:value acphase:value wave:atom " ++
    "val0:value val1:value delay:value rise:value fall:value width:value period:value " ++
    "sinedc:value ampl:value freq:value damp:value sphase:value " ++
    "td1:value tau1:value td2:value tau2:value mdi:value fsig:value pwl:value* " ++
    // Small-signal distortion inputs and the RF port a source may stand for.
    "distof1:value distof1ph:value distof2:value distof2ph:value portnum:value z0:value " ++
    // b4: a pulse train's count, the arguments of the noise and random
    // sources (trnoise, trrandom), a pattern's bit strings (PAT), and the
    // modulation phase of AM (the carrier's is sphase).
    // Spectre: the periodic AC magnitude (pac) and the fundamental a source
    // belongs to (pss, hb).
    "count:value wargs:value* bits:atom* mphase:value pacmag:value fundname:atom params:params";

const sweep_spec = "sweep:atom points:value fstart:value fstop:value";

/// Where a dialect says initial guesses on the analysis itself (VACASK
/// `nodeset=`), the reader moves them back to a `nodeset` statement.
const ns = " nodeset:params";

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
    .{ .subckt, .structure, "name ports:node* params:params inline:atom" },
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
    // `gmin` acts in every analysis; `gmindc` in DC ones only (HSPICE GMINDC).
    // `gshunt` and `cshunt` load every node to ground; `delmax` caps the
    // transient step where `.tran` gives none; `search` is where an include
    // not found beside the file is looked up (HSPICE).
    .{ .options, .control, "package:atom reltol:value abstol:value vntol:value gmin:value temp:value tnom:value " ++
        "scale:value method:atom maxord:value chgtol:value trtol:value params:params " ++
        "gshunt:value cshunt:value delmax:value search:path gmindc:value" },
    .{ .save, .control, "signals:signal*" },
    // `style` tells a table (.print) from a plot (.plot) from a probe (.probe).
    .{ .print, .control, "style:atom analysis:atom signals:signal* params:params" },
    .{ .ic, .control, "values:params" },
    .{ .nodeset, .control, "values:params" },
    // `op` is trig (from trig to targ), find (out at `at` or when `when`
    // crosses whenval), when, avg/rms/max/min/pp/integ (of out, from..to),
    // deriv (of out, at or when) or param (expr). An edge is rise, fall or
    // cross; its count says which crossing. `spec` is the text of a
    // measurement none of these forms reads.
    .{ .measure, .control, "analysis:atom name op:atom out:signal at:value from:value to:value " ++
        "trig:signal trigval:value trigtd:value trigedge:atom trign:value " ++
        "targ:signal targval:value targtd:value targedge:atom targn:value " ++
        "when:signal whenval:value whentd:value whenedge:atom whenn:value expr:value spec:text params:params" },
    .{ .op, .analysis, "name params:params" ++ ns },
    // src2 is the outer loop of a nested sweep; src is swept for each of its values.
    // What is swept is an instance (`src`), a netlist parameter (`param`) or
    // the temperature (`var`); the outer loop likewise. `devparam` is the
    // instance parameter swept when it is not the instance's own value (a
    // source's dc, a resistor's r). Without `sweep` the range is start, stop
    // and step; with it `points` per decade or octave, or in all (`lin`).
    // `values` lists the points instead; `data` names a `data` table whose
    // rows are swept.
    .{ .dc, .analysis, "name src:ref var:atom start:value stop:value step:value " ++
        "src2:ref start2:value stop2:value step2:value params:params" ++ ns ++
        " param:ident devparam:atom sweep:atom points:value values:value* " ++
        "param2:ident var2:atom sweep2:atom points2:value data:ident" },
    // `values` holds the one frequency of a sweep whose start and stop are equal
    // where the dialect writes it so (a `convert`).
    .{ .ac, .analysis, "name " ++ sweep_spec ++ " params:params" ++ ns ++ " values:value*" },
    // `segments`: the step and stop pairs after the first of a multi-segment
    // HSPICE .TRAN; the reader folds them into step and stop, so no writer sees them.
    .{ .tran, .analysis, "name step:value stop:value start:value maxstep:value skip_dc:atom method:atom params:params ic:params" ++ ns ++ " segments:value*" },
    // `interval`: a noise summary every this many frequency points.
    .{ .noise, .analysis, "name out:node ref:node src:ref " ++ sweep_spec ++ " interval:value params:params" ++ ns ++ " values:value*" },
    .{ .tf, .analysis, "name out:node ref:node src:ref params:params" ++ ns },
    // Either the input and output ports by node (SPICE), or an output
    // signal and the input source (HSPICE, Spectre).
    .{ .pz, .analysis, "name in_pos:node in_neg:node out_pos:node out_neg:node transfer:atom find:atom out:signal src:ref params:params" },
    .{ .sens, .analysis, "name out:signal params:params" },
    .{ .disto, .analysis, "name " ++ sweep_spec ++ " f2overf1:value params:params" },
    .{ .four, .analysis, "name freq:value signals:signal* params:params" },
    .{ .hb, .analysis, "name freqs:value* harms:value* params:params" ++ ns },
    .{ .sp, .analysis, "name " ++ sweep_spec ++ " params:params" ++ ns },
    .{ .pss, .analysis, "name fund:value harms:value tstab:value points:value params:params ic:params" ++ ns },
    .{ .stb, .analysis, "name " ++ sweep_spec ++ " probe:ref params:params" ++ ns },
    .{ .@"opaque", .other, "" },
    .{ .comment, .other, "" },
    // b3: analyses
    // Small-signal analyses around a periodic steady state. `engine` is `hb`
    // when that state is the harmonic balance one (Spectre hbac, HSPICE
    // .HBAC); unset, it is the shooting one (pss). Spectre and HSPICE take
    // the state from the pss or hb statement before; VACASK solves it on the
    // same statement, from `fund`, `harms` and `tstab`.
    .{ .pac, .analysis, "name engine:atom " ++ sweep_spec ++ " fund:value harms:value tstab:value params:params" },
    .{ .pnoise, .analysis, "name engine:atom out:node ref:node src:ref " ++ sweep_spec ++ " fund:value harms:value tstab:value params:params" },
    .{ .pxf, .analysis, "name engine:atom out:node ref:node " ++ sweep_spec ++ " params:params" },
    .{ .psp, .analysis, "name engine:atom " ++ sweep_spec ++ " params:params" },
    // The AC transfer function to one output from every source.
    .{ .xf, .analysis, "name out:node ref:node " ++ sweep_spec ++ " params:params" },
    // The DC output spread from device mismatch, from sensitivities.
    .{ .dcmatch, .analysis, "name out:node ref:node params:params" },
    // Device noise sampled during the transient analysis of the netlist.
    .{ .trannoise, .analysis, "name out:node ref:node method:atom samples:value seed:value fmin:value fmax:value scale:value time:value params:params" },
    // Oscillator phase noise about an autonomous steady state.
    .{ .phasenoise, .analysis, "name out:node ref:node " ++ sweep_spec ++ " params:params" },
    // Envelope following: the carrier is named by its fundamental.
    .{ .envelope, .analysis, "name clock:atom stop:value params:params" },
    // Quasi-periodic steady state by shooting, the tones named by fundamental.
    .{ .qpss, .analysis, "name funds:atom* harms:value* params:params" },
    // b4: devices, sources, outputs
    // A lossy or coupled transmission line. With n conductors the nodes are
    // the n inputs and their reference, then the n outputs and theirs. The
    // model's family is the line model (ltra, txl, cpl, rlgc).
    .{ .lossyline, .device, "name nodes:node* master:ident params:params" },
    // A controlled source in a special form; the element letter of the name
    // says what it drives (E, G, F, H). `form` is poly (dim inputs,
    // coefficients), table (expr, xs to ys), laplace (coeffs over den, in
    // ascending powers of s), pole (gain and zeros zr+j*zi over gain2 and
    // poles pr+j*pi), vcr (a resistance of gain ohms per volt) or vccap (a
    // capacitance of gain farads per volt).
    .{ .ctlsrc, .device, "name pos:node neg:node form:atom dim:value cpos:node* cneg:node* vsrcs:ref* " ++
        "expr:value coeffs:value* den:value* xs:value* ys:value* gain:value zr:value* zi:value* gain2:value pr:value* pi:value* params:params" },
    // A switch whose contacts open and close on a control voltage
    // (Spectre's relay).
    .{ .relay, .device, "name pos:node neg:node cpos:node cneg:node params:params" },
    // A command of a simulator's own control language that is not a netlist
    // statement (VACASK print, postprocess, abort, elaborate).
    .{ .simctl, .control, "cmd:atom args:text" },
    // b1: sweeps
    // Every analysis in `body` is run once per point. What is swept and the
    // range are as for `dc`. Read from a dialect that writes the sweep as one
    // line for the whole netlist (`.step`), the body is every analysis beside it.
    .{ .step, .analysis, "name src:ref param:ident var:atom devparam:atom sweep:atom start:value stop:value step:value " ++
        "points:value values:value* data:ident params:params" },
    // A table of values, one column per name in `cols`, rows one after the
    // other in `values`; swept by `data=` on an analysis or a step.
    .{ .data, .structure, "name cols:ident* values:value*" },
    // b2: statistics and structure
    // Statistical variation: a block whose body holds `statgroup` blocks
    // (and `correlate` statements); each group holds `vary` statements.
    .{ .statistics, .structure, "params:params" },
    // `process` varies once per run (SPICE: agauss in a top-level .param),
    // `mismatch` once per instance (agauss inside a subcircuit).
    .{ .statgroup, .structure, "scope:atom" },
    // One varied parameter: `param`, or parameter `param` of model `model`
    // (whose type word is `mtype`). `std` is the standard deviation (`rel`
    // = yes: in percent of the nominal); `range` the half width of a
    // uniform distribution.
    .{ .vary, .structure, "param:ident model:ident mtype:ident dist:atom std:value range:value rel:atom params:params" },
    .{ .correlate, .structure, "names:ident* cc:value params:params" },
    // A Monte Carlo run of the analyses in its body.
    .{ .montecarlo, .analysis, "name runs:value seed:value params:params" },
    // A named group of library sections; nothing refers to the name.
    .{ .library, .structure, "name" },
    // c2: alter
    // A rerun of every analysis of the netlist with the edits in `body`
    // (parameters, models, instances, library sections, options), on top of
    // those of the alters before it. Alters come last, in order. Spectre's
    // one-change form reads into `dev`/`mod`, `param` and `value`; a dialect
    // that says parameters and the temperature only writes them flat, from
    // `keys`, `vals` and `temp`.
    .{ .alter, .analysis, "name dev:ref mod:ident param:ident value:value keys:ident* vals:value* temp:value" },
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
    // b4: devices, sources, outputs
    .{ .name = "ltra", .kind = .lossyline },
    .{ .name = "txl", .kind = .lossyline },
    .{ .name = "cpl", .kind = .lossyline },
    .{ .name = "rlgc", .kind = .lossyline },
};

/// Functions an expression may call, by canonical name. A grammar's
/// `functions` section gives the dialect's spelling of each one it has.
pub const functions = [_][]const u8{
    "abs",   "sgn",   "sign2", "min",  "max",  "sqrt",  "sqr",    "exp",   "ln",    "log10",
    "pow",   "pwr",   "floor", "ceil", "int",  "nint",  "fmod",   "hypot", "db",    "sin",
    "cos",   "tan",   "asin",  "acos", "atan", "atan2", "sinh",   "cosh",  "tanh",  "asinh",
    "acosh", "atanh", "limit", "if",   "stp",  "uramp", "agauss", "gauss", "aunif", "unif",
    "v",     "i",
};

/// Variables the simulator provides.
pub const variables = [_][]const u8{ "temper", "time", "hertz" };

/// Operators that are not spelled the same everywhere.
/// `negpow` has no spelling: it names, for `differs`, a minus right after
/// another operator before a power (`1+-2**2`). `ne` is `!=`, listed by a
/// dialect that wants it spelled with blanks around it. `minuspow` and
/// `andor` have no spelling either: a minus on the base of a power wherever
/// it stands (`-2**2`), and a `&&` or `||`.
pub const operators = [_][]const u8{ "pow", "xor", "ternary", "negpow", "minuspow", "andor", "not", "mod", "ne" };

/// Signal forms a `signals` section may spell.
pub const signal_forms = [_][]const u8{
    "v",   "vdiff", "i",  "vdb", "vm", "vp", "vr",   "vi", "all",
    // b4: devices, sources, outputs. A branch current in dB, magnitude,
    // phase, real and imaginary part; a terminal current (`M1:d`, two
    // names); `expr` writes an expression recorded as a signal (`-i(vc)`).
    "idb", "im",    "ip", "ir",  "ii", "ix", "expr",
};

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
