const std = @import("std");

export fn not_implemented() void {
    std.debug.print("Not implemented\n", .{});
}

pub fn main() !void {
    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
}
