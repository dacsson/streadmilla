//! GC Environment keeps necessary information for garbage collection
//! such as memory, roots, next free index, allocator, and statistics.
//! It owns the memory and allocator, *pointer to a slice of it* is
//! given on request
//! C glue code will generally call it's methods.

const std = @import("std");
const stats = @import("stats.zig");
const mem = @import("memory.zig");
const util = @import("util.zig");

pub const List = std.ArrayList;
pub const Root = struct {
    object: **void,
    points_to: ?*mem.MemoryBlock,
};

/// Necessary information for garbage collection
/// Owns memory
pub const GCEnv = struct {
    /// Memory buffer to send chunks from
    memory: []u8,
    /// Current roots
    roots: List(Root),
    /// Metadata tracking of memory blocks
    blocks: List(mem.MemoryBlock),
    /// Next free index in memory buffer
    next_free: usize,
    allocator: std.mem.Allocator,
    statistics: stats.Statistics,

    /// Initialize a new garbage collector environment.
    pub fn init() !GCEnv {
        const allocator = std.heap.page_allocator;

        return GCEnv{
            .memory = allocator.alloc(u8, 1024) catch unreachable,
            .roots = List(Root).empty,
            .blocks = List(mem.MemoryBlock).empty,
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

        const block = mem.MemoryBlock{
            .header = mem.Header{
                .marked = false,
                .done = 0,
            },
            .start = start,
            .size = size,
        };
        try self.blocks.append(self.allocator, block);

        return self.memory[start..][0..size];
    }

    pub fn find_owner(self: *GCEnv, object: *void) !?*mem.MemoryBlock {
        for (self.blocks.items) |*block| {
            if (block.does_own(&self.memory, object)) {
                return block;
            }
        }
        return null;
    }

    pub fn find_block(self: *GCEnv, block: *mem.MemoryBlock) !?usize {
        for (self.blocks.items, 0..) |*other_block, i| {
            if (other_block == block) {
                return i;
            }
        }
        return null;
    }

    pub fn push_root(self: *GCEnv, object: **void) !void {
        const root = Root{
            .object = object,
            .points_to = try self.find_owner(object.*),
        };
        try self.roots.append(self.allocator, root);
    }

    pub fn pop_root(self: *GCEnv, object: **void) !void {
        for (self.roots.items, 0..) |root, i| {
            // util.dbgs("[pop_root] Checking root: {d} vs {d} \n", .{ @intFromPtr(root.object), @intFromPtr(object) });
            if (@intFromPtr(root.object) == @intFromPtr(object)) {
                _ = self.roots.orderedRemove(i);
                return;
            }
        }
        return error.NotFound;
    }

    // pub fn read_barrier(self: *GCEnv, object: *void, field_index: i32) !void {
    //     const stella_object =
    // }

    /// Given an index of data in heap, returns
    /// the corresponding memory block.
    pub fn block_at(self: *GCEnv, index: usize) !*mem.MemoryBlock {
        if (index >= self.blocks.items.len) return error.NotFound;
        for (self.blocks.items) |*block| {
            if (block.start >= index or (block.start + block.size) <= index) {
                return block;
            }
        }
        return error.NotFound;
    }

    pub fn print_heap(self: *GCEnv) void {
        std.debug.print("Heap:\n", .{});
        for (self.blocks.items) |*block| {
            std.debug.print("| Start {d}, Size {d} ", .{ block.start, block.size });
        }
        // for (self.memory) |byte| {
        //     std.debug.print("{x} ", .{byte});
        // }
        std.debug.print("\n", .{});
    }
};
