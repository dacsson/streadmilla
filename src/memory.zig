//! Metadata for memory tracking and
//! collecting

const std = @import("std");
const __helpers = @import("TranslateC");
const util = @import("util.zig");

const runtime = @cImport({
    @cInclude("runtime.h");
});

pub const List = std.ArrayList;

pub const StellaObject = runtime.stella_object;
pub const StellaObjectPtr = *allowzero align(1) runtime.stella_object;

/// GC metadata for memory blocks
pub const Header = struct {
    marked: bool,
    done: usize,
};

/// Doesn't contain actual data,
/// only meta
pub const MemoryBlock = struct {
    header: Header,
    start: usize,
    size: usize,
    id: usize, // id of block in memory

    /// Search in memory buffer for data
    /// associated with this block
    pub fn data(self: *MemoryBlock, memory: *List([]u8)) []u8 {
        // const d = memory.*[self.start .. self.start + self.size];
        // TODO: validate end address
        const d = memory.items[self.id];
        util.dbgs("      [data] Found data for block {d} \n", .{self.id});
        // for (d) |byte| {
        //     util.dbgs("      | Byte: {x} ", .{byte});
        // }
        util.dbgs("\n", .{});
        return d;
    }

    pub fn free(self: *MemoryBlock, allocator: std.mem.Allocator, memory: *List([]u8)) void {
        allocator.free(memory.items[self.id]);
        // allocator.de
    }

    pub fn to_stella_object(self: *MemoryBlock, memory: *List([]u8)) *align(1) StellaObject {
        util.dbgs("  [to_stella_object] Converting block to object: {d} \n", .{self.id});
        const d = self.data(memory);
        const obj = std.mem.bytesAsValue(StellaObject, d);
        util.dbgs("  [to_stella_object] Success \n", .{});
        // runtime.print_stella_object(@alignCast(obj));
        return obj;
    }

    pub fn does_own(self: *MemoryBlock, memory: *List([]u8), object: *void) bool {
        util.dbgs(" [does_own] Checking object: {d} vs {d} \n", .{ @intFromPtr(object), @intFromPtr(self.to_stella_object(memory)) });
        const slice = self.data(memory);
        const start = @intFromPtr(&slice[0]);
        const end = start + slice.len;
        const obj = @intFromPtr(object);
        return obj >= start and obj < end;
        // util.dbgs(" [does_own] Checking object: {d} vs {d} \n", .{ @intFromPtr(object), @intFromPtr(self.to_stella_object(memory)) });
        // const stella_obj: *align(1) StellaObject = std.mem.bytesAsValue(StellaObject, object);
        // if (is_equal(stella_obj, self.to_stella_object(memory))) {
        //     return true;
        // }
        // return false;
    }

    pub fn is_marked(self: *MemoryBlock) bool {
        return self.header.marked;
    }

    pub fn mark(self: *MemoryBlock) void {
        self.header.marked = true;
    }

    pub fn unmark(self: *MemoryBlock) void {
        self.header.marked = false;
    }

    pub fn incr_done(self: *MemoryBlock) void {
        self.header.done += 1;
    }

    pub fn decr_done(self: *MemoryBlock) void {
        self.header.done -= 1;
    }
};

// Interesting fact: i found a real bug in zig translate-c
// library during this project: https://github.com/ziglang/translate-c/issues/211
// hence this function helper.
/// Helper function to get the fields of a StellaObject
/// as a flexible array type from c
pub fn object_fields(self: StellaObjectPtr) __helpers.FlexibleArrayType(@TypeOf(self), @typeInfo(@TypeOf(self.*._object_fields)).array.child) {
    return @ptrCast(@alignCast(&self.*._object_fields));
}

pub fn is_equal(this: StellaObjectPtr, other: StellaObjectPtr) bool {
    util.dbgs("[is_equal] Comparing headers: {d} vs {d} \n", .{ this.object_header, other.object_header });
    if (this.object_header == other.object_header) {
        // TODO: will this work?
        util.dbgs("[is_equal] Comparing fields: {d} vs {d} \n", .{ @intFromPtr(object_fields(this)), @intFromPtr(object_fields(other)) });
        return object_fields(this) == object_fields(other);
    }
    return false;
}
