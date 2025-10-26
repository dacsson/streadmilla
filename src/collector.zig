//! Mark and sweep garbage collector
//! algorithm implementation

const std = @import("std");
const util = @import("util.zig");
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
    gc_env.statistics.garbage_collections += 1;
    for (gc_env.roots.items) |*root| { // for each root v
        if (root.points_to != null) {
            try DFS(gc_env, root.points_to.?);
        }
    }
}

pub fn sweep(gc_env: *gc.GCEnv) !void {
    // var free_list = gc.List(*mem.MemoryBlock).empty;
    var free_list = &gc_env.free_list;
    // p <- first address in heap
    for (gc_env.blocks.items) |*block| {
        var p = block;
        if (p.is_marked()) {
            p.unmark();
        } else {
            gc_env.statistics.freed_memory += block.size;
            try free_list.append(gc_env.allocator, p);
        }
    }

    for (free_list.items) |block| {
        util.dbgs("  Free block: {*}  | ", .{block});
    }

    util.dbgs("[free_list] Free list len: {}", .{free_list.items.len});
}
