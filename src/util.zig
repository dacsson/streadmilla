//! Utility functions and constants

const std = @import("std");
const builtin = @import("builtin");
const mem = @import("memory.zig");

const DEBUG = builtin.mode == .Debug;

// debug logs that are removed from Release builds
pub inline fn dbgs(fmt: []const u8, args: anytype) void {
    // std.debug.print("Mode: {s}\n", .{builtin.mode});
    if (DEBUG) {
        std.debug.print(fmt, args);
    }
}

// pub inline fn print_heap(gc_env: *) void {
//     std.debug.print("Heap:\n", .{});
//     for (memory) |byte| {
//         std.debug.print("{x} ", .{byte});
//     }
//     std.debug.print("\n", .{});
// }
