//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

const runtime = @cImport({
    @cInclude("runtime.h");
});

const gc = @import("gc.zig");

//###==============================###
//
// Environment setup section
//
// Because zig has more strict
// rules for globals, we need
// to call `gc_env` on each call
// to make sure it's initialized
//
//###==============================###

/// Global GC environment
/// that is initialized on first use.
var env: ?*gc.GCEnv = null;

/// Returns the global GC environment
/// or initializes it if it hasn't been (on heap)
fn get_env() !*gc.GCEnv {
    if (env) |e| return e;
    const allocator = std.heap.page_allocator;

    // 1 MiB buffer for the GC.
    const buffer = try allocator.alloc(u8, 1024 * 1024);
    const roots = gc.List(**void).init(allocator);

    // Allocate ENV
    const gc_ptr = try allocator.create(gc.GCEnv);

    // Initialise ENV
    gc_ptr.* = try gc.GCEnv.init(buffer, roots);

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
    std.debug.print("Zig: gc_push_root\n", .{});
    gc_env.roots.append(object) catch unreachable;
}

export fn gc_alloc(size: usize) *void {
    var gc_env = get_env() catch {
        @panic("Cannot initialize environment");
    };
    std.debug.print("Zig: gc_alloc {d}\n", .{size});
    const slice = gc_env.alloc(size) catch unreachable;
    return @ptrCast(slice);
}

export fn gc_read_barrier(object: *void, field_index: i32) void {
    std.debug.print("Zig: gc_read_barrier {*} {d}\n", .{ object, field_index });
}

export fn gc_write_barrier(object: *void, field_index: i32, content: *void) void {
    std.debug.print("Zig: gc_write_barrier {*} {d} {*}\n", .{ object, field_index, content });
}

export fn gc_pop_root(object: **void) void {
    std.debug.print("Zig: gc_pop_root {*}\n", .{object});
}

export fn not_implemented() void {
    std.debug.print("Zig: Not implemented\n", .{});
}
