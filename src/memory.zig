//! Metadata for memory tracking and
//! collecting

const std = @import("std");
const __helpers = @import("TranslateC");

const runtime = @cImport({
    @cInclude("runtime.h");
});

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

    /// Search in memory buffer for data
    /// associated with this block
    pub fn data(self: *MemoryBlock, memory: *[]u8) []u8 {
        const d = memory.*[self.start .. self.start + self.size];
        return d;
    }

    pub fn free(self: *MemoryBlock, allocator: std.mem.Allocator, memory: *[]u8) void {
        allocator.free(memory.*[self.start .. self.start + self.size]);
        // allocator.de
    }

    pub fn to_stella_object(self: *MemoryBlock, memory: *[]u8) *align(1) StellaObject {
        const d = self.data(memory);
        return std.mem.bytesAsValue(StellaObject, d);
    }

    pub fn does_own(self: *MemoryBlock, memory: *[]u8, object: *void) bool {
        const stella_obj = std.mem.bytesAsValue(StellaObject, object);
        if (stella_obj == self.to_stella_object(memory)) {
            return true;
        }
        return false;
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
