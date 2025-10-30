const std = @import("std");
const gc = std.gc;
const runtime = @cImport({
    @cInclude("runtime.h");
});

const util = @import("util.zig");

pub const StellaObject = runtime.stella_object;
pub const StellaObjectPtr = *allowzero align(1) StellaObject;

pub const GCObject = struct {
    node: std.DoublyLinkedList.Node,
    raw: ?[]u8,
    hint: ?**void,

    pub fn data(self: *GCObject) ?StellaObjectPtr {
        // if (self.hint != null) {
        //     const obj = util.void_to_stella_object(self.hint.?.*);
        //     util.dbgs("  | GCObject header: {d} | From hint\n", .{runtime.STELLA_OBJECT_HEADER_TAG(obj.object_header)});
        //     return obj;
        // }
        if (self.raw == null) return null;
        const st = util.memory_to_stella_object(&self.raw.?);
        util.dbgs("  | GCObject header: {d} | Byte size: {d}\n", .{ runtime.STELLA_OBJECT_HEADER_TAG(st.object_header), self.raw.?.len });
        return util.memory_to_stella_object(&self.raw.?);
    }

    pub fn field_count(self: *GCObject) ?usize {
        if (self.data() == null) return null;
        util.dbgs("  | GCObject field count: {d}\n", .{util.field_count(self.data().?)});
        return util.field_count(self.data().?);
    }

    pub fn field_at(self: *GCObject, index: usize) ?*GCObject {
        if (self.data() == null) return null;

        // Search for the GCObject that owns
        // a StellaObjectPtr field
        var next_node = self.node.next;
        if (next_node == null) return null;
        var next_obj: *GCObject = @fieldParentPtr("node", next_node.?);
        const field = util.field_at(self.data().?, index);
        while (next_node != null) {
            const next_data = next_obj.data();
            if (next_data == null) continue;
            if (field == null) continue;
            if (@intFromPtr(next_data.?) == @intFromPtr(field.?)) {
                return next_obj;
            }
            next_node = next_node.?.next;
            next_obj = @fieldParentPtr("node", next_node.?);
        }

        return null;
    }

    pub fn init_raw(allocator: std.mem.Allocator) !*GCObject {
        const obj = try allocator.create(GCObject);
        obj.raw = null;
        obj.hint = null;
        obj.node = .{};
        return obj;
    }
};

pub const Collector = struct {
    memory: std.DoublyLinkedList,
    obj_to_void: std.AutoHashMap(**void, *GCObject),
    root_queue: std.ArrayList(**void),
    allocator: std.mem.Allocator,
    free: *std.DoublyLinkedList.Node, // Allocation of new objects happens at free
    scan: *std.DoublyLinkedList.Node, // Scan advances at scan
    top: *std.DoublyLinkedList.Node, // Still non-scanned objects are between bottom and top
    bottom: *std.DoublyLinkedList.Node,

    pub fn init() !*Collector {
        const allocator = std.heap.page_allocator;
        const obj = try allocator.create(Collector);

        var memory: std.DoublyLinkedList = .{};
        // Pre-init memory
        for (0..1024) |_| {
            var object = try GCObject.init_raw(allocator);
            memory.append(&object.node);
        }

        obj.* = Collector{
            .memory = memory,
            .obj_to_void = std.AutoHashMap(**void, *GCObject).init(allocator),
            .root_queue = std.ArrayList(**void).empty,
            .allocator = allocator,
            .free = memory.first.?,
            .scan = memory.first.?,
            .top = memory.first.?,
            .bottom = memory.first.?,
        };

        return obj;
    }

    fn is_ecru(self: *Collector, object: *GCObject) bool {
        if ((@intFromPtr(object) >= @intFromPtr(self.bottom)) and (@intFromPtr(object) < @intFromPtr(self.top))) {
            return true;
        }
        return false;
    }

    /// Remove the object from the treadmill list
    pub fn unlink(object: *GCObject) void {
        if (object.node.prev != null) {
            object.node.prev.?.next = object.node.next;
        }
        if (object.node.next != null) {
            object.node.next.?.prev = object.node.prev;
        }
    }

    /// Add the object to the treadmill list, before the head
    /// TODO: maybe at the tail?
    pub fn link(head: *GCObject, object: *GCObject) void {
        // object.node.prev = head.node.prev;
        // object.node.next = &head.node;
        // const prev: *GCObject = @fieldParentPtr("node", head.node.prev.?);
        // prev.* = object.*;
        // if (object.node.prev != null) {
        //     object.node.prev.?.next = &object.node;
        // }
        // Step 1: object points to the new tail
        object.node.prev = head.node.prev;
        object.node.next = &head.node;

        // Step 2: If there was a previous node, update its next pointer
        if (head.node.prev) |prev| {
            prev.next = &object.node;
        } else {
            // If head is the only node, then object becomes the new head
            // But we don’t need to update head — it’s a sentinel
        }

        // Step 3: Update head's prev to point to object
        head.node.prev = &object.node;
    }

    pub fn check_roots(self: *Collector) void {
        for (self.root_queue.items) |root| {
            // Check if it has been allocated at this point
            // const current = self.bottom;
            // while (@intFromPtr(current) != @intFromPtr(self.free)) {
            //     const obj: *GCObject = @fieldParentPtr("node", current);
            //     if (obj.data() == null) continue;
            //     if (@intFromPtr(obj.data().?) == @intFromPtr(root.*)) {
            //         // Yes, make it gray
            //         util.dbgs("Root found at address: {*}\n", .{root});
            //         self.darken(obj);
            //     }
            //     current = current.next;
            // }

            var it = self.obj_to_void.iterator();
            while (it.next()) |entry| {
                // util.dbgs("\nFound object at address: {*} {*}\n", .{ entry.key_ptr.*.*, entry.key_ptr.* });
                if (@intFromPtr(root.*) == @intFromPtr(entry.key_ptr.*.*)) {
                    // util.dbgs("Found ecru object at address", .{});
                    const obj = entry.value_ptr.*;
                    if (self.is_ecru(obj)) {
                        self.darken(obj);
                    } else {
                        break;
                    }
                }
            }
        }
    }

    /// Make an ecru object gray
    pub fn darken(self: *Collector, object: *GCObject) void {
        unlink(object);
        const top: *GCObject = @fieldParentPtr("node", self.top);
        link(top, object); // Put it back at the tail of the gray list
    }

    /// Read barrier for the object
    pub fn read_barrier(self: *Collector, object: *void) void {
        // Find corresponding GCObject
        util.dbgs("Searching object at address: {*}\n", .{object});
        var it = self.obj_to_void.iterator();
        while (it.next()) |entry| {
            // util.dbgs("\nFound object at address: {*} {*}\n", .{ entry.key_ptr.*.*, entry.key_ptr.* });
            if (@intFromPtr(object) == @intFromPtr(entry.key_ptr.*.*)) {
                // util.dbgs("Found ecru object at address", .{});
                const obj = entry.value_ptr.*;
                if (self.is_ecru(obj)) {
                    self.darken(obj);
                } else {
                    break;
                }
            }
        }

        // const obj = self.obj_to_void.get(object) orelse {
        //     @panic("Object not found");
        // };
        // if (self.is_ecru(obj)) {
        //     self.darken(obj);
        // }
        // var next = self.memory.first;
        // while (next != self.memory.last) {
        //     util.dbgs("Checking object at address: {x}\n", .{@intFromPtr(next)});
        //     const obj: *GCObject = @fieldParentPtr("node", next.?);
        //     if (@intFromPtr(object) == @intFromPtr(obj)) {
        //         if (self.is_ecru(obj)) {
        //             self.darken(obj);
        //         }
        //     }
        //     next = next.?.next;
        //     if (next == next.?.next) {
        //         @panic("Circular reference detected");
        //     }
        // }
    }

    pub fn alloca(self: *Collector, size: usize) ![]u8 {
        const next_free = self.free.next;
        if (next_free == null) {
            return error.OutOfMemory;
        }

        const obj: *GCObject = @fieldParentPtr("node", next_free.?);
        obj.raw = self.allocator.alloc(u8, size) catch |err| {
            self.free = self.free.next.?;
            return err;
        };

        self.free = self.free.next.?;

        self.advance();

        try self.obj_to_void.put(@ptrCast(&obj.raw.?), obj);

        return obj.raw.?;
    }

    pub fn queue_roots(self: *Collector, object: **void) void {
        self.root_queue.append(self.allocator, object) catch unreachable;
        // util.dbgs("New entry: {} <-> {} | {}\n", .{ object.*, obj, object });
        // self.obj_to_void.put(object, obj) catch unreachable;
    }

    // pub fn mark_root(self: *Collector, object: **void) void {

    // const obj: *GCObject = @fieldParentPtr("node", self.scan);
    // obj.hint = object;
    // self.scan = self.scan.next orelse self.scan; // Make it gray
    // util.dbgs("New entry: {} <-> {} | {}\n", .{ object.*, obj, object });
    // self.obj_to_void.put(object, obj) catch unreachable;
    // const new_scan: *GCObject = @fieldParentPtr("node", self.scan);
    // link(new_scan, obj);
    // self.free = self.scan;
    // // self.darken(obj);
    // self.print();
    // self.scan = &obj.node;
    // self.free = &obj.node;
    // link(scan, obj);
    // }

    pub fn advance(self: *Collector) void {
        const scan: *GCObject = @fieldParentPtr("node", self.scan);
        const count = scan.field_count() orelse return;
        for (0..count) |i| {
            const field = scan.field_at(i);
            if (field != null) {
                if (self.is_ecru(field.?)) {
                    self.darken(field.?);
                }
            }
        }
        self.scan = self.scan.prev orelse self.scan; // Make it black
    }

    pub fn print(self: *Collector) void {
        var current = self.bottom;
        while (@intFromPtr(current) != @intFromPtr(self.free)) {
            if (@intFromPtr(current) == @intFromPtr(self.bottom)) {
                util.dbgs("--------- Bottom of list -------\n", .{});
            }
            if (@intFromPtr(current) == @intFromPtr(self.scan)) {
                util.dbgs("--------- Scanning object -------\n", .{});
            }
            if (@intFromPtr(current) == @intFromPtr(self.top)) {
                util.dbgs("--------- Top of list -------\n", .{});
            }
            const obj: *GCObject = @fieldParentPtr("node", current);
            if (obj.data() != null) {
                util.dbgs(" * Object at {x}\n", .{@intFromPtr(obj.data().?)});
            } else {
                util.dbgs(" * Empty object\n", .{});
            }
            if (current.next == null) {
                util.dbgs("End of list\n", .{});
            }
            current = current.next.?;
        }
        util.dbgs("--------- End of list -------\n", .{});
    }
};
