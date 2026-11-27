//! Generic reader: matches token lines against a grammar's patterns and
//! binds what it finds to canonical slots.
//!
//! Patterns are ordered choices with real backtracking, which is what SPICE
//! needs: `Q1 c b e [s] model [area]` cannot be split into nodes, model and
//! value without trying the alternatives.
//!
//! The reading itself is in the files beside this one: `source.zig` (a
//! netlist being read, and `read`), `step.zig` (one statement at a time),
//! `split.zig` and `kept.zig` (lines that are more than one statement, or
//! kept as text), `matcher.zig` with `values.zig`, `capture.zig` and
//! `bag.zig` (one line against one pattern), `canon.zig` (what a matched
//! statement is turned into, and the first pass), `spelling.zig` (one
//! spelling for each name), `signals.zig`, and `passes.zig`, `forms.zig`
//! and `alters.zig` (the passes over the statements read).
//!
//! Contents:
//! - `pub const Source`, `pub const Tables`, `pub const read`, `pub const resolveGroup`
//!   (`source.zig`)
//! - `pub const Needed` (`spelling.zig`)
//! - `pub const mergeOptions`, `pub const lastAnalysis` (`passes.zig`)
//! - `pub const signalCanon`, `pub const signalParts`, `pub const isVersion` (`signals.zig`)

const source = @import("source.zig");
const spelling = @import("spelling.zig");
const passes = @import("passes.zig");
const signals = @import("signals.zig");

pub const Source = source.Source;
pub const Tables = source.Tables;
pub const Needed = spelling.Needed;
pub const read = source.read;
pub const resolveGroup = source.resolveGroup;
pub const mergeOptions = passes.mergeOptions;
pub const lastAnalysis = passes.lastAnalysis;
pub const signalCanon = signals.signalCanon;
pub const signalParts = signals.signalParts;
pub const isVersion = signals.isVersion;
