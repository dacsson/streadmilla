const std = @import("std");
const stats = @import("stats.zig");
const mem = std.mem;

pub const List = std.ArrayList;

/// GC Environment keeps necessary information for garbage collection
/// such as memory, roots, next free index, allocator, and statistics.
/// It owns the memory and allocator, [pointer to a slice of it] is
/// given on request
/// C glue code will generally call it's methods.
pub const GCEnv = struct {
    memory: []u8,
    roots: List(**void),
    next_free: usize,
    allocator: std.mem.Allocator,
    statistics: stats.Statistics,

    /// Initialize a new garbage collector environment.
    pub fn init() !GCEnv {
        const allocator = std.heap.page_allocator;

        return GCEnv{
            .memory = allocator.alloc(u8, 1024) catch unreachable,
            .roots = List(**void).empty,
            .next_free = 0,
            .allocator = allocator,
            .statistics = stats.Statistics{},
        };
    }

    /// Simple bump‑allocation from the internal buffer.
    /// Returns a slice of the allocated memory (which points
    /// to memory of gc env) you should take a pointer to it.
    pub fn alloc(self: *GCEnv, size: usize) ![]u8 {
        // TODO: align
        const start = std.mem.alignForward(usize, self.next_free, 8);
        if (start + size > self.memory.len) return error.OutOfMemory;

        self.statistics.allocated_memory += size;

        self.next_free = start + size;
        return self.memory[start..][0..size];
    }

    pub fn push_root(self: *GCEnv, object: **void) !void {
        try self.roots.append(self.allocator, object);
    }

    pub fn pop_root(self: *GCEnv, object: **void) !**void {
        for (self.roots.items, 0..) |root, i| {
            if (root == object) {
                return self.roots.orderedRemove(i);
            }
        }
        return error.NotFound;
    }
};
