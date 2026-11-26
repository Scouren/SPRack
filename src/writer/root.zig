//! Writer: canonical statements and the target's grammar → the target's
//! text and the report of what did not cross.
//!
//! The pieces: `emit.zig` turns one statement and one pattern into text;
//! `statement.zig` chooses the pattern and writes the statement; the passes
//! (`names.zig`, `analyses.zig`, `rewrite.zig`) change the statements
//! before that; `whole.zig` and `stream.zig` run the passes in order, over
//! a netlist held in memory or a group of statements at a time (`refs.zig`
//! holds the names a streamed netlist meets before what they name).
//!
//! Contents:
//! - `pub const Caps`
//! - `pub const write`
//! - `pub const Refs`, `pub const Survey`, `pub const Stream`
//! - `pub const Terminals`
//! - `pub const defaultOptions`, `pub const collectReserved`, `pub const masterRenames`
//! - `pub const checkCase`, `pub const foldMaxord`

const emit = @import("emit.zig");
const tables = @import("tables.zig");
const rewrite = @import("rewrite.zig");
const names = @import("names.zig");
const analyses = @import("analyses.zig");
const statement = @import("statement.zig");
const whole = @import("whole.zig");
const stream = @import("stream.zig");
const refs = @import("refs.zig");

pub const Caps = emit.Caps;
pub const write = whole.write;
pub const Refs = refs.Refs;
pub const Survey = stream.Survey;
pub const Stream = stream.Stream;
pub const Terminals = statement.Terminals;
pub const defaultOptions = analyses.defaultOptions;
pub const collectReserved = names.collectReserved;
pub const masterRenames = names.masterRenames;
pub const checkCase = names.checkCase;
pub const foldMaxord = analyses.foldMaxord;

test {
    _ = emit;
    _ = tables;
    _ = rewrite;
    _ = names;
    _ = analyses;
    _ = statement;
    _ = whole;
    _ = stream;
    _ = refs;
}
