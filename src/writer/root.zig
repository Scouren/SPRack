//! Writer: canonical statements and the target's grammar → the target's
//! text and the report of what did not cross.
//!
//! The pieces: `emit.zig` turns one statement and one pattern into text;
//! `statement.zig` holds the writer's state; `blocks.zig` writes a statement
//! and what it holds, `leaf.zig` chooses the pattern of one without a body,
//! `spread.zig` writes the sweeps over analyses, `unwritten.zig` what the
//! target cannot write, `output.zig` the lines, `notes.zig` what is said once
//! a file; what a statement is turned into first is a file a subject (`cards.zig`,
//! `cardparams.zig`, `bins.zig`, `instparams.zig`, `plugins.zig`, `variants.zig`,
//! `rewrite.zig`; `facts.zig` what a card's spelling learns of the netlist); the
//! passes over a netlist (`names.zig`, `analyses.zig`, `defaults.zig`)
//! change the statements before that; `frame.zig` writes what stands
//! around them; `driver.zig` runs the passes in order, over a netlist held
//! in memory or a group of statements at a time (`refs.zig` holds the names
//! a netlist written in groups meets before what they name).
//!
//! Contents:
//! - `pub const Caps`
//! - `pub const write`, `pub const needsAll`
//! - `pub const Refs`, `pub const Survey`, `pub const Driver`, `pub const Target`
//! - `pub const Terminals`
//! - `pub const defaultOptions`, `pub const collectReserved`
//! - `pub const checkCase`, `pub const foldMaxord`

const cards = @import("cards.zig");
const bins = @import("bins.zig");
const cardparams = @import("cardparams.zig");
const facts = @import("facts.zig");
const emit = @import("emit.zig");
const tables = @import("tables.zig");
const rewrite = @import("rewrite.zig");
const names = @import("names.zig");
const analyses = @import("analyses.zig");
const statement = @import("statement.zig");
const blocks = @import("blocks.zig");
const leaf = @import("leaf.zig");
const spread = @import("spread.zig");
const unwritten = @import("unwritten.zig");
const output = @import("output.zig");
const notes = @import("notes.zig");
const plugins = @import("plugins.zig");
const instparams = @import("instparams.zig");
const variants = @import("variants.zig");
const defaults = @import("defaults.zig");
const driver = @import("driver.zig");
const refs = @import("refs.zig");
const frame = @import("frame.zig");
const annotations = @import("annotations.zig");

pub const Caps = emit.Caps;
pub const write = driver.write;
pub const needsAll = driver.needsAll;
pub const Refs = refs.Refs;
pub const Survey = driver.Survey;
pub const Driver = driver.Driver;
pub const Target = driver.Target;
pub const Terminals = facts.Terminals;
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
    _ = blocks;
    _ = leaf;
    _ = spread;
    _ = unwritten;
    _ = output;
    _ = notes;
    _ = plugins;
    _ = instparams;
    _ = variants;
    _ = defaults;
    _ = cards;
    _ = bins;
    _ = cardparams;
    _ = facts;
    _ = driver;
    _ = refs;
    _ = frame;
    _ = annotations;
}
