//! Writer: canonical statements and the target's grammar → the target's
//! text and the report of what did not cross.
//!
//! The pieces: `emit.zig` turns one statement and one pattern into text;
//! `statement.zig` chooses the pattern and writes the statement; the passes
//! (`names.zig`, `analyses.zig`, `rewrite.zig`) change the statements
//! before that; `frame.zig` writes what stands around them; `driver.zig`
//! runs the passes in order, over a netlist held in memory or a group of
//! statements at a time (`refs.zig` holds the names a netlist written in
//! groups meets before what they name).
//!
//! Contents:
//! - `pub const Caps`
//! - `pub const write`, `pub const needsAll`
//! - `pub const Refs`, `pub const Survey`, `pub const Driver`, `pub const Target`
//! - `pub const Terminals`
//! - `pub const defaultOptions`, `pub const collectReserved`
//! - `pub const checkCase`, `pub const foldMaxord`

const emit = @import("emit.zig");
const tables = @import("tables.zig");
const rewrite = @import("rewrite.zig");
const names = @import("names.zig");
const analyses = @import("analyses.zig");
const statement = @import("statement.zig");
const driver = @import("driver.zig");
const refs = @import("refs.zig");
const frame = @import("frame.zig");

pub const Caps = emit.Caps;
pub const write = driver.write;
pub const needsAll = driver.needsAll;
pub const Refs = refs.Refs;
pub const Survey = driver.Survey;
pub const Driver = driver.Driver;
pub const Target = driver.Target;
pub const Terminals = statement.Terminals;
pub const defaultOptions = analyses.defaultOptions;
pub const collectReserved = names.collectReserved;
pub const checkCase = names.checkCase;
pub const foldMaxord = analyses.foldMaxord;

test {
    _ = emit;
    _ = tables;
    _ = rewrite;
    _ = names;
    _ = analyses;
    _ = statement;
    _ = driver;
    _ = refs;
    _ = frame;
}
