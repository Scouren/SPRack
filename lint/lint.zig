//! Lint step: the files of `clean_paths` → a `lint` build step that fails
//! when one of them breaks a rule. Four layers, each a failure on its own:
//!   1. `zig fmt --check` over every Zig file of the tree.
//!   2. `perf_tidy.py`: the rules of the performance guide the compiler does
//!      not check (function and line length, assertions, recursion,
//!      allocation and I/O in loops, struct layout, swallowed errors).
//!   3. `check_style.py`: the order of a file (header and Contents, imports,
//!      public before private, tests last) and its size.
//!   4. `no_dialect_names.py`, over every source file: no string of the
//!      engine is a dialect's name (docs/dev/ARCHITECTURE.md, the rule).
//!
//! A file joins `clean_paths` when its module is moved to the house style
//! (docs/dev/ARCHITECTURE.md, block 3); from then on it cannot slide back.
//!
//! Contents:
//! - `pub const clean_paths`
//! - `pub fn addTo(b: *std.Build) *std.Build.Step`

const std = @import("std");

/// Files and directories held to layers 2 and 3, relative to the build root.
pub const clean_paths = [_][]const u8{
    "lint/lint.zig",
    "src/host/capi.zig",
    "src/core/dialects.zig",
    "src/host/main.zig",
    "src/root.zig",
    "src/passes/variations.zig",
    "src/passes/topology.zig",
    "src/passes/stats.zig",
    "src/passes/split.zig",
    "src/passes/findings.zig",
    "src/passes/cond.zig",
    "src/passes/alter.zig",
    "src/core/schema.zig",
    "src/writer/rewrite.zig",
    "src/writer/tables.zig",
    "src/writer/variants.zig",
    "src/writer/blocks.zig",
    "src/writer/leaf.zig",
    "src/writer/notes.zig",
    "src/writer/output.zig",
    "src/writer/spread.zig",
    "src/writer/statement.zig",
    "src/writer/unwritten.zig",
    "src/writer/analyses.zig",
    "src/writer/bins.zig",
    "src/writer/cardparams.zig",
    "src/writer/cards.zig",
    "src/writer/defaults.zig",
    "src/writer/emit.zig",
    "src/writer/emit_bag.zig",
    "src/writer/emit_losses.zig",
    "src/writer/emit_text.zig",
    "src/writer/facts.zig",
    "src/writer/driver.zig",
    "src/writer/frame.zig",
    "src/writer/instparams.zig",
    "src/writer/names.zig",
    "src/writer/plugins.zig",
    "src/writer/refs.zig",
    "src/writer/root.zig",
    "tools/grammar_gen.zig",
};

/// Everything `zig fmt --check` covers.
const format_paths = [_][]const u8{ "build.zig", "src", "tools", "lint" };

/// Adds the `lint` step and returns it, so other steps can depend on it.
pub fn addTo(b: *std.Build) *std.Build.Step {
    // A gate that holds no file passes whatever is written.
    std.debug.assert(clean_paths.len > 0);
    const step = b.step("lint", "Check formatting, the performance rules and the file order");

    var formatted: [format_paths.len]std.Build.LazyPath = undefined;
    for (&formatted, format_paths) |*lazy, path| lazy.* = b.path(path);
    step.dependOn(&b.addFmt(.{ .paths = &formatted, .check = true }).step);

    inline for (.{ "lint/perf_tidy.py", "lint/check_style.py" }) |script| {
        const run = b.addSystemCommand(&.{ "python3", "-I" });
        run.addFileArg(b.path(script));
        for (clean_paths) |path| run.addArg(path);
        run.setCwd(b.path("."));
        run.has_side_effects = true; // the sources are not declared inputs: check on every build
        step.dependOn(&run.step);
    }
    const names = b.addSystemCommand(&.{ "python3", "-I" });
    names.addFileArg(b.path("lint/no_dialect_names.py"));
    names.addArgs(&.{ "grammars", "src" });
    names.setCwd(b.path("."));
    names.has_side_effects = true;
    step.dependOn(&names.step);
    return step;
}
