//! C glue code, exposing GC environment

const std = @import("std");

const runtime = @cImport({
    @cInclude("runtime.h");
});

const gc = @import("gc.zig");
const util = @import("util.zig");

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
        return e;
    }
    const allocator = std.heap.page_allocator;

    // Allocate ENV
    const gc_ptr = try allocator.create(gc.GCEnv);

    // Initialise ENV
    gc_ptr.* = try gc.GCEnv.init();

    // Store the pointer in global
    env = gc_ptr;
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
    const slice = gc_env.alloc(size) catch unreachable;
    return @ptrCast(slice);
}

export fn gc_read_barrier(object: *void, field_index: i32) void {
    var gc_env = get_env() catch {
        @panic("Cannot initialize environment");
    };
    gc_env.read_barrier(object);
    util.dbgs("Zig: gc_read_barrier {*} {d}\n", .{ object, field_index });
}

export fn gc_write_barrier(object: *void, field_index: i32, content: *void) void {
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
    const allocs = gc_env.collector.allocations;
    const flips = gc_env.collector.flips;
    std.debug.print("Stats: Allocations: {d}, Flips: {d}\n", .{ allocs, flips });
    // gc_env.statistics.print();
}
