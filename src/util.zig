const std = @import("std");
const builtin = @import("builtin");
const gc = @import("gc.zig");
const collector = @import("collector.zig");
const helpers = @import("std").zig.c_translation.helpers;
const runtime = @cImport({
    @cInclude("runtime.h");
});

const DEBUG = builtin.mode == .Debug;

// debug logs that are removed from Release builds
pub inline fn dbgs(fmt: []const u8, args: anytype) void {
    // std.debug.print("Mode: {s}\n", .{builtin.mode});
    if (DEBUG) {
        std.debug.print(fmt, args);
    }
}

/// Converts a void pointer to a StellaObjectPtr.
pub inline fn void_to_stella_object(obj: *void) collector.StellaObjectPtr {
    return @as(collector.StellaObjectPtr, @ptrCast(@alignCast(obj)));
}

/// Converts a memory slice to a StellaObjectPtr.
pub inline fn memory_to_stella_object(mem: *[]u8) collector.StellaObjectPtr {
    return @as(collector.StellaObjectPtr, @ptrCast(@alignCast(mem.ptr)));
}

const COLOUR = enum(usize) {
    BLACK, // have been completely scanned together with the objects they point to
    GREY, // have been scanned, but the objects they point to are not guaranteed to be scanned
    ECRU, // have not been scanned
    WHITE,
};

pub fn get_colour(obj: collector.StellaObjectPtr) COLOUR {
    return @enumFromInt(runtime.STELLA_OBJECT_GET_COLOUR(obj));
}

// Interesting fact: i found a real bug in zig translate-c
// library during this project: https://github.com/ziglang/translate-c/issues/211
// hence this function helper.
/// Helper function to get the fields of a StellaObject
/// as a flexible array type from c
pub fn object_fields(self: collector.StellaObjectPtr) helpers.FlexibleArrayType(@TypeOf(self), @typeInfo(@TypeOf(self.*._object_fields)).array.child) {
    return @ptrCast(@alignCast(&self.*._object_fields));
}

pub fn field_count(self: collector.StellaObjectPtr) usize {
    return @intCast(runtime.STELLA_OBJECT_HEADER_FIELD_COUNT(self.object_header));
}

pub fn field_at(self: collector.StellaObjectPtr, index: usize) ?collector.StellaObjectPtr {
    const fields = object_fields(self);
    const count = field_count(self);
    if (index >= count) {
        return null;
    }
    if (fields[index] == null) return null;
    return void_to_stella_object(@ptrCast(fields[index].?));
}

pub fn node_distance(node: *std.DoublyLinkedList.Node, other: *std.DoublyLinkedList.Node) usize {
    var current = node;
    var distance: usize = 0;
    while (@intFromPtr(current) != @intFromPtr(other)) {
        current = current.next orelse break;
        distance += 1;
        if (distance > 1024) {
            dbgs("Error: Maximum distance exceeded for {*} and {*} \n", .{ current, other });
            @panic("Maximum distance exceeded");
        }
    }
    return distance;
}
