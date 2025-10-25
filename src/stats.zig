//! Statistics for garbage collection

const std = @import("std");

pub const Statistics = struct {
    /// Overall allocated memory in bytes.
    allocated_memory: usize = 0,
    /// Overall number of garbage collections.
    garbage_collections: usize = 0,
    /// Maximum memory usage in bytes.
    max_memory_usage: usize = 0,
    /// Memory reads
    memory_reads: usize = 0,
    /// Memory writes
    memory_writes: usize = 0,
    /// Number of barrier writes
    barrier_writes: usize = 0,
    /// Number of barrier reads
    barrier_reads: usize = 0,

    pub fn print(self: Statistics) void {
        std.debug.print("Statistics:\n", .{});
        std.debug.print("  Allocated Memory: {d} bytes\n", .{self.allocated_memory});
        std.debug.print("  Garbage Collections: {d}\n", .{self.garbage_collections});
        std.debug.print("  Max Memory Usage: {d} bytes\n", .{self.max_memory_usage});
        std.debug.print("  Memory Reads: {d}\n", .{self.memory_reads});
        std.debug.print("  Memory Writes: {d}\n", .{self.memory_writes});
        std.debug.print("  Barrier Writes: {d}\n", .{self.barrier_writes});
        std.debug.print("  Barrier Reads: {d}\n", .{self.barrier_reads});
    }
};
