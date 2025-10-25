//! C glue code, exposing GC environment

const std = @import("std");

// const runtime = @cImport({
//     @cInclude("runtime.h");
// });

const gc = @import("gc.zig");
const util = @import("util.zig");
const collector = @import("collector.zig");

//###==============================###
//
// Environment setup section
//
// Because zig has more strict
// rules for globals, we need
// to call `gc_env` on each call
// to make sure it's initialized
// (either that, or i am dumb)
//
//###==============================###

/// Global GC environment
/// that is initialized on first use.
var env: ?*gc.GCEnv = null;

/// Returns the global GC environment
/// or initializes it if it hasn't been (on heap)
fn get_env() !*gc.GCEnv {
    if (env) |e| {
        if (e.free_list.items.len == 0) {
            collector.mark(e) catch unreachable;
            collector.sweep(e) catch unreachable;
        }
        return e;
    }
    const allocator = std.heap.page_allocator;

    // Allocate ENV
    const gc_ptr = try allocator.create(gc.GCEnv);

    // Initialise ENV
    gc_ptr.* = try gc.GCEnv.init();

    // Store the pointer in global
    env = gc_ptr;

    if (gc_ptr.free_list.items.len == 0) {
        collector.mark(gc_ptr) catch unreachable;
        collector.sweep(gc_ptr) catch unreachable;
    }

    return gc_ptr;
}

//###==============================###
//
// Functions to export to C, they
// follow `gc.h` interface
//
//###==============================###

export fn gc_push_root(object: **void) void {
    var gc_env = get_env() catch {
        @panic("Cannot initialize environment");
    };
    util.dbgs("Zig: gc_push_root {*}\n", .{object});

    gc_env.push_root(object) catch unreachable;
}

export fn gc_alloc(size: usize) *void {
    var gc_env = get_env() catch {
        @panic("Cannot initialize environment");
    };
    util.dbgs("Zig: gc_alloc {d}\n", .{size});

    gc_env.print_heap();
    // TODO: capacity or len ?
    if (gc_env.memory.items.len != 0 and gc_env.next_free >= gc_env.memory.items.len) {
        util.dbgs("[gc_alloc] Starting garbage collection\n", .{});
        // std.process.exit(0);
        collector.mark(gc_env) catch unreachable;
        collector.sweep(gc_env) catch unreachable;
    }

    const slice = gc_env.alloc(size) catch unreachable;
    return @ptrCast(slice);
}

export fn gc_read_barrier(object: *void, field_index: i32) void {
    var gc_env = get_env() catch {
        @panic("Cannot initialize environment");
    };
    // util.dbgs("Zig: gc_alloc {d}\n", .{size});
    gc_env.statistics.memory_reads += 1;
    // TODO: capacity or len ?
    // if (gc_env.memory.items.len != 0 and gc_env.next_free >= gc_env.memory.items.len) {
    //     util.dbgs("[gc_alloc] Starting garbage collection\n", .{});
    //     // std.process.exit(0);
    //     collector.mark(gc_env) catch unreachable;
    //     collector.sweep(gc_env) catch unreachable;
    // }
    util.dbgs("Zig: gc_read_barrier {*} {d}\n", .{ object, field_index });
}

export fn gc_write_barrier(object: *void, field_index: i32, content: *void) void {
    var gc_env = get_env() catch {
        @panic("Cannot initialize environment");
    };
    gc_env.statistics.memory_writes += 1;
    // util.dbgs("Zig: gc_alloc {d}\n", .{size});

    // TODO: capacity or len ?
    // if (gc_env.memory.items.len != 0 and gc_env.next_free >= gc_env.memory.items.len) {
    //     util.dbgs("[gc_alloc] Starting garbage collection\n", .{});
    //     // std.process.exit(0);
    //     collector.mark(gc_env) catch unreachable;
    //     collector.sweep(gc_env) catch unreachable;
    // }
    util.dbgs("Zig: gc_write_barrier {*} {d} {*}\n", .{ object, field_index, content });
}

export fn gc_pop_root(object: **void) void {
    var gc_env = get_env() catch {
        @panic("Cannot initialize environment");
    };
    util.dbgs("Zig: gc_pop_root {*}\n", .{object});
    _ = gc_env.pop_root(object) catch unreachable;
}

export fn not_implemented() void {
    util.dbgs("Zig: Not implemented\n", .{});
}

//###==============================###
//
// Debug and statistics utility
//
//###==============================###

export fn print_gc_alloc_stats() void {
    var gc_env = get_env() catch {
        @panic("Cannot initialize environment");
    };
    util.dbgs("Zig: print_gc_alloc_stats\n", .{});
    gc_env.statistics.print();
}
