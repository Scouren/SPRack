//! Generic reader: matches token lines against a grammar's patterns and
//! binds what it finds to canonical slots.
//!
//! Patterns are ordered choices with real backtracking, which is what SPICE
//! needs: `Q1 c b e [s] model [area]` cannot be split into nodes, model and
//! value without trying the alternatives.

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
