//! The report: every entry a translation makes where it was not exact, with
//! its severity, its code and the pass that made it.
//!
//! Contents:
//! - `pub const Severity = enum`
//! - `pub const Code = enum`
//! - `pub const Phase = struct`
//! - `pub const Diag = struct`
//! - `pub const Report = struct`

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Severity = enum { info, warning, @"error" };

/// What kind of inexactness a report entry records. Tools that consume the
/// report should switch on this, not on the message text.
pub const Code = enum {
    /// Written with a write-only rule: reading the output back gives
    /// something else (HSPICE noise is an .AC line plus a .NOISE line).
    oneway,
    /// A source line no rule matched; written as a comment.
    untranslated,
    /// The target has no statement or model spelling for this at all.
    unsupported,
    /// A value had no place in the target statement and was left out.
    loss,
    /// The target needed a value the source did not give; one was made up.
    synthesized,
    /// Written faithfully, but the two simulators read it a little differently.
    caveat,
    /// An instance was renamed to satisfy the target's naming rules.
    rename,
    /// A label or boilerplate line with no meaning in the target was omitted.
    cosmetic,
    /// Malformed input or a name clash.
    invalid,
    /// Valid in both dialects, but each reads it differently.
    ambiguous,
};

/// The passes of a translation that report, in the order a netlist read
/// and written whole runs them (`Report.phase`).
pub const Phase = struct {
    pub const read: u8 = 0;
    pub const finish: u8 = 1;
    pub const bodies: u8 = 2;
    pub const bins: u8 = 3;
    pub const segments: u8 = 4;
    pub const kinds: u8 = 5;
    /// `sprack project`'s rewriting of include paths.
    pub const project: u8 = 6;
    pub const case: u8 = 7;
    pub const params: u8 = 8;
    pub const renames: u8 = 9;
    pub const masters: u8 = 10;
    pub const topology: u8 = 11;
    pub const fill: u8 = 12;
    pub const checks: u8 = 13;
    pub const checks_source: u8 = 14;
    pub const options: u8 = 15;
    /// `stats.devLot`, then the rest of `stats.prepare`.
    pub const devlot: u8 = 16;
    pub const stats: u8 = 17;
    pub const pz: u8 = 18;
    pub const ceilings: u8 = 19;
    pub const write: u8 = 20;
    pub const caveat: u8 = 21;
};

/// `phase`: the pass that made the entry (`Report.phase`).
pub const Diag = struct { sev: Severity, code: Code, line: u32, msg: []const u8, phase: u8 = 0 };

/// Everything a translation did that was not exact. Nothing is dropped
/// without an entry here.
pub const Report = struct {
    arena: Allocator,
    items: std.ArrayList(Diag) = .empty,
    /// The pass adding entries now. A netlist read and written whole runs
    /// each pass over every statement in turn, so its entries come out in
    /// pass order; a stream runs every pass on one statement at a time and
    /// sorts by this at the end (`sortPhases`) to give the same order.
    phase: u8 = 0,
    /// A pass whose entries another makes again: nothing is recorded.
    mute: bool = false,
    /// An entry found no memory and is not in `items`. Reading and writing
    /// end in `error.OutOfMemory` then: no result is clean for want of it.
    lost: bool = false,

    pub fn init(arena: Allocator) Report {
        return .{ .arena = arena };
    }

    pub fn add(
        r: *Report,
        sev: Severity,
        code: Code,
        line: u32,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (r.mute) return;
        const msg = r.arena.print(fmt, args) catch {
            r.lost = true;
            return;
        };
        r.items.append(
            r.arena,
            .{ .sev = sev, .code = code, .line = line, .msg = msg, .phase = r.phase },
        ) catch {
            r.lost = true;
        };
    }

    /// Entries from `from` on in pass order, each pass's in the order made.
    pub fn sortPhases(r: *Report, from: usize) void {
        std.sort.block(Diag, r.items.items[from..], {}, struct {
            fn lt(_: void, a: Diag, b: Diag) bool {
                return a.phase < b.phase;
            }
        }.lt);
    }

    pub fn countCode(r: *const Report, code: Code) usize {
        var n: usize = 0;
        for (r.items.items) |d| n += @intFromBool(d.code == code);
        return n;
    }

    pub fn count(r: *const Report, sev: Severity) usize {
        var n: usize = 0;
        for (r.items.items) |d| n += @intFromBool(d.sev == sev);
        return n;
    }

    pub fn hasErrors(r: *const Report) bool {
        return r.count(.@"error") > 0;
    }

    pub fn contains(r: *const Report, sev: Severity, needle: []const u8) bool {
        for (r.items.items) |d| {
            if (d.sev == sev and std.mem.indexOf(u8, d.msg, needle) != null) return true;
        }
        return false;
    }

    pub fn print(r: *const Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (r.items.items) |d| {
            if (d.line > 0) {
                try w.print(
                    "{s}[{s}]: line {d}: {s}\n",
                    .{ @tagName(d.sev), @tagName(d.code), d.line, d.msg },
                );
            } else {
                try w.print("{s}[{s}]: {s}\n", .{ @tagName(d.sev), @tagName(d.code), d.msg });
            }
        }
    }
};
