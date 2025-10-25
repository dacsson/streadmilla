//! Mark and sweep garbage collector
//! algorithm implementation

const std = @import("std");
const gc = @import("gc.zig");
const mem = @import("memory.zig");
const runtime = @cImport({
    @cInclude("runtime.h");
});

fn DFS(gc_env: *gc.GCEnv, p: *mem.MemoryBlock) !void {
    if (!p.is_marked()) {
        p.mark();
        var obj: mem.StellaObjectPtr = p.to_stella_object(&gc_env.memory);
        const len: usize = @intCast(runtime.STELLA_OBJECT_HEADER_FIELD_COUNT(obj.object_header));
        const fields = mem.object_fields(obj);
        for (0..len) |i| {
            const field: *align(1) mem.StellaObject = @as(*align(1) mem.StellaObject, @ptrCast(@alignCast(fields[i])));
            const f: *align(1) mem.StellaObject = @as(*align(1) mem.StellaObject, @ptrCast(@alignCast(field)));
            const next = try gc_env.find_owner(@ptrCast(f));
            if (next != null) {
                try DFS(gc_env, next.?);
            }
        }
    }
}

pub fn mark(gc_env: *gc.GCEnv) !void {
    for (gc_env.roots.items) |*root| { // for each root v
        if (root.points_to != null) {
            try DFS(gc_env, root.points_to.?);
        }
    }
}

pub fn sweep(gc_env: *gc.GCEnv) !void {
    var free_list = gc.List(*mem.MemoryBlock).empty;
    // p <- first address in heap
    for (gc_env.blocks.items) |*block| {
        var p = block;
        if (p.is_marked()) {
            p.unmark();
        } else {
            const stella_object = p.to_stella_object(&gc_env.memory);
            var fields = mem.object_fields(stella_object);
            // var first_field: *void = fields[0];
            var first_field: mem.StellaObjectPtr = @as(mem.StellaObjectPtr, @ptrCast(@alignCast(fields[0])));
            first_field = if (free_list.items.len == 0)
                @ptrFromInt(0x0)
            else
                @alignCast(free_list.getLast().to_stella_object(&gc_env.memory));
            try free_list.append(gc_env.allocator, p);
        }
    }

    for (free_list.items, 0..) |block, i| {
        _ = free_list.orderedRemove(i);
        block.free(gc_env.allocator, &gc_env.memory);
    }
}
