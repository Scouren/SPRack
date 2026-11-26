//! What the other files of a project declare (`Env`), gathered from their
//! statements.
//!
//! Contents:
//! - `pub const Env = struct`: `absorb`
//! - `pub fn markFamilies(stmts: []const Stmt, out: *[schema.families.len]bool) void`
//! - `pub fn holdsCond(subckt: *const Stmt) bool`

const std = @import("std");
const schema = @import("schema");
const ir = @import("ir.zig");
const Allocator = std.mem.Allocator;
const CaselessSet = ir.CaselessSet;
const Kind = ir.Kind;
const Stmt = ir.Stmt;
const binBase = ir.binBase;
const cloneStmt = ir.cloneStmt;

/// What the other files of a project declare. A PDK spreads its models,
/// subcircuits and functions over many files; a file is read correctly only
/// when the reader knows the names the others define.
pub const Env = struct {
    /// Names of models and subcircuits, as written and lower-cased.
    declared: std.StringHashMapUnmanaged(void) = .empty,
    /// Model name to the device kind its family belongs to.
    models: std.StringHashMapUnmanaged(Kind) = .empty,
    /// Parameter names that start with a name the target keeps for itself
    /// (`writer.collectReserved`): those to rename, and the names taken.
    params: CaselessSet = .empty,
    /// Model name to its family, for a writer's forms that depend on it.
    family_of: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Names of subcircuits.
    subckts: CaselessSet = .empty,
    /// Lower-cased names of user-defined functions.
    funcs: std.StringHashMapUnmanaged(void) = .empty,
    /// Statement kinds used anywhere in the project. The top netlist writes
    /// the boilerplate (`needs`) for all of them.
    used: [schema.kind_count]bool = @splat(false),
    /// Model families used anywhere in the project, by `schema.families` index.
    families: [schema.families.len]bool = @splat(false),
    /// The subcircuits that hold a conditional block, whole: where one is
    /// written once for each branch (`cond.split`), an instance in another
    /// file is written with the one its parameters select.
    // ponytail: the whole statement; only its parameters and blocks if a
    // PDK's are too many to hold.
    conditional: std.ArrayList(Stmt) = .empty,
    /// Files given to the translation by name (`--provide`): a Verilog-A
    /// module's Xyce plugin (`r3_cmc=r3_cmc.so`, loaded on Xyce's command
    /// line), or the compiled module of a family a dialect has no model of
    /// built in (`bsimcmg=bsimcmg.osdi`, a `provided` line of its models).
    provided: []const [2][]const u8 = &.{},
    /// Model name to the Verilog-A module its card names (a type no table
    /// lists), from every file of the project.
    modules: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// Everything is copied into `arena`, so `stmts` may be freed afterwards.
    pub fn absorb(env: *Env, arena: Allocator, stmts: []const Stmt) Allocator.Error!void {
        markFamilies(stmts, &env.families);
        for (stmts) |*s| {
            env.used[@backingInt(s.kind)] = true;
            const name = s.get("name");
            if (s.kind == .subckt and holdsCond(s))
                try env.conditional.append(arena, try cloneStmt(.{ .perm = arena, .src = "" }, s));
            if (name == .atom and (s.kind == .model or s.kind == .subckt)) {
                const own = try arena.dupe(u8, name.atom);
                try env.declared.put(arena, own, {});
                try env.declared.put(arena, try std.ascii.allocLowerString(arena, own), {});
                if (s.kind == .subckt) try env.subckts.put(arena, own, {});
                if (s.kind == .model) try env.absorbModel(arena, s, own);
                std.debug.assert(env.declared.contains(own));
            }
            if (name == .atom and s.kind == .func)
                try env.funcs.put(arena, try std.ascii.allocLowerString(arena, name.atom), {});
            try env.absorb(arena, s.body);
        }
    }

    /// What a model card `own` declares beyond its name: its family, its
    /// module, its kind, and the base name of a binned card.
    fn absorbModel(
        env: *Env,
        arena: Allocator,
        s: *const Stmt,
        own: []const u8,
    ) Allocator.Error!void {
        const fam = s.get("family");
        const kind: ?Kind = if (fam == .atom)
            schema.familyKind(fam.atom)
        else if (s.get("type") == .atom) .device else null;
        if (fam == .atom)
            try env.family_of.put(arena, own, try arena.dupe(u8, fam.atom));
        if (fam != .atom and s.get("type") == .atom)
            try env.modules.put(arena, own, try arena.dupe(u8, s.get("type").atom));
        const k = kind orelse return;
        try env.models.put(arena, own, k);
        const base = binBase(own) orelse return;
        try env.models.put(arena, base, k);
        try env.declared.put(arena, base, {});
        try env.declared.put(arena, try std.ascii.allocLowerString(arena, base), {});
    }
};

/// Note the model families that model cards in `stmts` (and their bodies) use.
// tidy: allow(recursion) bounded by the nesting of blocks, ir.max_depth
pub fn markFamilies(stmts: []const Stmt, out: *[schema.families.len]bool) void {
    for (stmts) |*s| {
        markFamilies(s.body, out);
        if (s.kind != .model) continue;
        const fam = s.get("family");
        if (fam != .atom) continue;
        for (schema.families, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, fam.atom)) out[i] = true;
        }
    }
}

/// A conditional block stands in the subcircuit's body.
pub fn holdsCond(subckt: *const Stmt) bool {
    for (subckt.body) |*s| if (s.kind == .cond_if) return true;
    return false;
}
