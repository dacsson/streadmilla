const std = @import("std");
const builtin = @import("builtin");

const DEBUG = builtin.mode == .Debug;

// debug logs that are removed from Release builds
pub inline fn dbgs(fmt: []const u8, args: anytype) void {
    // std.debug.print("Mode: {s}\n", .{builtin.mode});
    if (DEBUG) {
        std.debug.print(fmt, args);
    }
}
