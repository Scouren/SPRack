//! Project: the work on the files of a run done ahead of where its results
//! are taken, by workers that are tasks of its `io`.
//!
//! Contents:
//! - `pub const File = struct`
//! - `pub const slot_keep`
//! - `pub fn Ahead(comptime T: type, comptime work: fn (*const Run, File, *T) void) type`,
//!   with `pub fn init`, `pub fn take`, `pub fn release`, `pub fn deinit`

const std = @import("std");
const run_ = @import("run.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Run = run_.Run;

/// A file of the run as a task works on it: nothing of the run that
/// changes while tasks run is reached through it.
pub const File = struct { path: []const u8, library: bool };

/// The most a slot keeps mapped from one file to the next. A file that
/// takes more gives the rest back when the slot is used again.
pub const slot_keep = 16 << 20;

/// Slots for each worker: a file that takes long holds back only the
/// files more than a turn of the slots after it.
const slots_a_worker = 4;

/// Work on the files of the run done ahead of where its results are
/// taken. `opts.jobs` workers, each a task of `io`, take the files in
/// order as the run comes to know them, as far ahead as there are
/// slots; the run takes each result in the order of the files. What it
/// does with them is then what it would do one file after the other,
/// whichever worker ends first.
///
/// `T`: the result, with `init(*T, gpa)`, `reset(*T)` before each file
/// and `deinit(*T)`. `work` fills it; it must write nothing else. A
/// slot keeps its memory from one file to the next (up to
/// `slot_keep`), so a file's text and statements land in pages that
/// are already there: 408 thousand page faults a run of sky130 were
/// one fresh mapping after the other.
///
/// With one job, or an `io` that runs nothing at once, there are no
/// workers: `take` does the work where it is called.
pub fn Ahead(comptime T: type, comptime work: fn (*const Run, File, *T) void) type {
    return struct {
        r: *const Run,
        slots: []Slot,
        workers: usize = 0,
        group: std.Io.Group = .init,
        /// Held by the run wherever it does not wait for a result, so
        /// the list of files and what follows change under it alone;
        /// a worker holds it to take a file and to give its result.
        mutex: std.Io.Mutex = .init,
        /// A result is there; or a file, or a slot, for a worker.
        changed: std.Io.Condition = .init,
        /// The file whose result is taken next, and the first no
        /// worker has taken.
        next: usize = 0,
        claimed: usize = 0,
        stop: bool = false,

        const Slot = struct { value: T, done: bool };
        const Self = @This();

        /// In place: the workers hold `a`.
        pub fn init(a: *Self, r: *const Run) Allocator.Error!void {
            const jobs = @max(1, r.opts.jobs);
            const slots = try r.arena.alloc(Slot, if (jobs > 1) jobs * slots_a_worker else 1);
            for (slots) |*slot| {
                slot.value.init(r.gpa);
                slot.done = false;
            }
            a.* = .{ .r = r, .slots = slots };
            if (jobs == 1) return;
            a.mutex.lockUncancelable(r.io);
            for (0..jobs) |_| {
                // rare: an `io` with nothing to run a task on at once.
                a.group.concurrent(r.io, worker, .{a}) catch break;
                a.workers += 1;
            }
            if (a.workers == 0) a.mutex.unlock(r.io);
        }

        /// The result of file `next`. Blocks until it is there.
        pub fn take(a: *Self) *T {
            const r = a.r;
            assert(a.next < r.files.items.len);
            const slot = &a.slots[a.next % a.slots.len];
            if (a.workers == 0) {
                slot.value.reset();
                work(r, a.fileAt(a.next), &slot.value);
                return &slot.value;
            }
            // The files the run has come to know since the last are
            // there to take.
            a.changed.broadcast(r.io);
            while (!slot.done) a.changed.waitUncancelable(r.io, &a.mutex);
            return &slot.value;
        }

        /// The result `take` gave is done with: the next file's is
        /// next, and the slot is free for the file a turn after it.
        pub fn release(a: *Self) void {
            a.slots[a.next % a.slots.len].done = false;
            a.next += 1;
        }

        /// Lets the workers end (each finishes the file it has), and
        /// frees the slots.
        pub fn deinit(a: *Self) void {
            const io = a.r.io;
            if (a.workers > 0) {
                a.stop = true;
                a.changed.broadcast(io);
                a.mutex.unlock(io);
                // Nothing asks the workers to stop but `stop`.
                a.group.await(io) catch |e| switch (e) {
                    error.Canceled => {},
                };
            }
            for (a.slots) |*slot| slot.value.deinit();
        }

        fn fileAt(a: *const Self, index: usize) File {
            const r = a.r;
            return .{
                .path = r.files.items[index],
                .library = r.opts.library or index >= r.opts.tops.len,
            };
        }

        fn worker(a: *Self) void {
            const r = a.r;
            a.mutex.lockUncancelable(r.io);
            // What ends it: `stop`, which `deinit` sets.
            while (true) {
                // Waits for a file no worker has, within a turn of the
                // slots from the one the run takes next.
                while (!a.stop and
                    (a.claimed >= r.files.items.len or a.claimed >= a.next + a.slots.len))
                    a.changed.waitUncancelable(r.io, &a.mutex);
                if (a.stop) break;
                const index = a.claimed;
                a.claimed += 1;
                const slot = &a.slots[index % a.slots.len];
                assert(!slot.done);
                const file = a.fileAt(index);
                a.mutex.unlock(r.io);
                slot.value.reset();
                work(r, file, &slot.value);
                a.mutex.lockUncancelable(r.io);
                slot.done = true;
                a.changed.broadcast(r.io);
            }
            a.mutex.unlock(r.io);
        }
    };
}
