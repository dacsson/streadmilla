const std = @import("std");

pub const Statistics = struct {
    /// Overall allocated memory in bytes.
    allocated_memory: usize = 0,
    /// Allocated objects
    allocated_objects: usize = 0,
    /// Number of flips in treadmill.
    flips: usize = 0,
    /// Memory reads
    memory_reads: usize = 0,
    /// Memory writes
    memory_writes: usize = 0,
    /// Number of barrier reads
    barrier_reads: usize = 0,

    pub fn print(self: Statistics) void {
        std.debug.print("Statistics:\n", .{});
        std.debug.print("  Allocated Memory: {d} bytes | {d} objects\n", .{ self.allocated_memory, self.allocated_objects });
        std.debug.print("  Flips: {d}\n", .{self.flips});
        std.debug.print("  Memory Reads: {d}\n", .{self.memory_reads});
        std.debug.print("  Memory Writes: {d}\n", .{self.memory_writes});
        std.debug.print("  Barrier Reads: {d}\n", .{self.barrier_reads});
    }
};
