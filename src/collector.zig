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

    pub fn field_at(self: *GCObject, index: usize, map: *std.AutoHashMap(**void, *GCObject)) ?*GCObject {
        util.dbgs("\n [field_at] \n", .{});
        if (self.data() == null) return null;

        // Search for the GCObject that owns
        // a StellaObjectPtr field
        // var next_node = self.node.next;
        // if (next_node == null) return null;
        // var next_obj: *GCObject = @fieldParentPtr("node", next_node.?);
        const field = util.field_at(self.data().?, index);
        if (field == null) return null;
        var it = map.iterator();

        while (it.next()) |entry| {
            // util.dbgs("\nFound object at address: {*} {*} | {*}\n", .{ entry.key_ptr.*.*, entry.key_ptr.*, field.? });
            if (@intFromPtr(field.?) == @intFromPtr(entry.key_ptr.*.*)) {
                return entry.value_ptr.*;
            }
        }
        // while (next_node != null) {
        //     const next_data = next_obj.data();
        //     if (next_data == null) continue;
        //     if (field == null) continue;
        //     if (@intFromPtr(next_data.?) == @intFromPtr(field.?)) {
        //         return next_obj;
        //     }
        //     next_node = next_node.?.next;
        //     next_obj = @fieldParentPtr("node", next_node.?);
        // }

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
    allocations: usize,
    memory_size: usize,

    pub fn init() !*Collector {
        const allocator = std.heap.page_allocator;
        const obj = try allocator.create(Collector);

        var memory: std.DoublyLinkedList = .{};
        // Pre-init memory
        for (0..4) |_| {
            var object = try GCObject.init_raw(allocator);
            memory.append(&object.node);
        }
        memory.first.?.prev = memory.last.?;
        memory.last.?.next = memory.first.?;

        obj.* = Collector{
            .memory = memory,
            .obj_to_void = std.AutoHashMap(**void, *GCObject).init(allocator),
            .root_queue = std.ArrayList(**void).empty,
            .allocator = allocator,
            .free = memory.first.?,
            .scan = memory.first.?,
            .top = memory.first.?,
            .bottom = memory.first.?,
            .allocations = 0,
            .memory_size = 0,
        };

        return obj;
    }

    fn is_ecru(self: *Collector, object: *GCObject) bool {
        util.dbgs("\n [is_ecru]", .{});
        const top_ptr = @as(*GCObject, @fieldParentPtr("node", self.top));
        const bottom_ptr = @as(*GCObject, @fieldParentPtr("node", self.bottom));
        util.dbgs("\n - top_ptr: {*}, bottom_ptr: {*}", .{ top_ptr, bottom_ptr });
        util.dbgs("\n - object: {*}", .{object});
        if ((@intFromPtr(object) >= @intFromPtr(bottom_ptr)) and (@intFromPtr(object) < @intFromPtr(top_ptr))) {
            std.process.exit(0);
            return true;
        }
        return false;
    }

    /// Remove the object from the treadmill list
    pub fn unlink(object: *GCObject) void {
        util.dbgs("\n[unlink]\n", .{});
        // In a cyclic list, prev and next are never null
        const prev = object.node.prev.?;
        const next = object.node.next.?;
        prev.next = next;
        next.prev = prev;

        // Optional: clear the node's own links
        object.node.prev = null;
        object.node.next = null;
    }

    /// Add the object to the treadmill list, before the head
    /// TODO: maybe at the tail?
    pub fn link(head: *GCObject, object: *GCObject) void {
        util.dbgs("\n[link]\n", .{});
        const next = head.node.next.?; // Node currently after `after`

        object.node.prev = &head.node; // New node points back to `after`
        object.node.next = next; // New node points forward to `next`

        head.node.next = &object.node; // `after` now points to new node
        next.prev = &object.node; // `next` now points back to new node
    }

    pub fn check_roots(self: *Collector) void {
        // util.dbgs("\n[check_roots]\n", .{});
        for (self.root_queue.items) |root| {
            // util.dbgs("\n [check_roots] size: {d}\n", .{self.root_queue.items.len});
            var it = self.obj_to_void.iterator();
            while (it.next()) |entry| {
                // util.dbgs("\nFound object at address: {*} {*} | {*}\n", .{ entry.key_ptr.*.*, entry.key_ptr.*, root.* });
                if (@intFromPtr(root.*) == @intFromPtr(entry.key_ptr.*.*)) {
                    // const obj = entry.value_ptr.*;
                    // self.darken(obj);
                    self.scan = self.free;
                    self.print();
                }
            }
        }
    }

    /// Make an ecru object gray
    pub fn darken(self: *Collector, object: *GCObject) void {
        const before_top: *GCObject = @fieldParentPtr("node", self.top);
        util.dbgs("\n[darken] | {*} {*}\n", .{ object, before_top });
        unlink(object);
        const top: *GCObject = @fieldParentPtr("node", self.top);
        util.dbgs("\n[darken] top: {} | object: {}\n", .{ top, object });
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
    }

    pub fn alloca(self: *Collector, size: usize) ![]u8 {
        if ((@intFromPtr(self.free) == @intFromPtr(self.bottom)) and self.allocations > 0) {
            self.flip();
            // std.process.exit(1);
        }

        util.dbgs("\n[alloca]\n", .{});
        const obj: *GCObject = @fieldParentPtr("node", self.free);
        if (obj.raw == null) {
            obj.raw = self.allocator.alloc(u8, size) catch |err| {
                // self.free = self.free.next.?;
                return err;
            };
        } else {
            util.dbgs("\n[realloc]\n", .{});
            obj.raw = self.allocator.realloc(obj.raw.?, size) catch |err| {
                // self.free = self.free.next.?;
                return err;
            };
        }

        self.allocations += 1;
        self.free = self.free.next.?;

        self.advance();

        try self.obj_to_void.put(@ptrCast(&obj.raw.?), obj);

        self.print();

        return obj.raw.?;
    }

    pub fn queue_roots(self: *Collector, object: **void) void {
        util.dbgs("\n[queue_roots]\n", .{});
        self.root_queue.append(self.allocator, object) catch unreachable;
    }

    pub fn advance(self: *Collector) void {
        util.dbgs("\n[advance]\n", .{});
        const scan: *GCObject = @fieldParentPtr("node", self.scan);
        const count = scan.field_count() orelse return;
        util.dbgs("\n[advance] count: {}\n", .{count});
        for (0..count) |i| {
            const field = scan.field_at(i, &self.obj_to_void);
            if (field != null) {
                if (self.is_ecru(field.?)) {
                    self.darken(field.?);
                }
            }
        }
        util.dbgs("advance: scan = {} | {*}\n", .{ self.scan, self.scan });
        self.scan = self.scan.prev orelse @panic("No previous object");
        util.dbgs("advance: scan = {} | {*}\n", .{ self.scan, self.scan });
    }

    pub fn flip(self: *Collector) void {
        const temp = self.top;
        self.top = self.bottom;
        self.scan = self.top;
        self.bottom = temp;
    }

    pub fn pop_root(self: *Collector, object: **void) !void {
        for (self.root_queue.items, 0..self.root_queue.items.len) |root, i| {
            if (root == object) {
                _ = self.root_queue.orderedRemove(i);
                return;
            }
        }
        return error.ObjectNotFound;
    }

    pub fn print(self: *Collector) void {
        util.dbgs("\n--------- Current state -------\n", .{});
        util.dbgs("- top: {} \n", .{@as(*GCObject, @fieldParentPtr("node", self.top))});
        util.dbgs("  - ptr: {*} \n", .{self.top});
        util.dbgs("  - distance to bottom: {d} \n", .{util.node_distance(self.top, self.bottom)});
        util.dbgs("- bottom: {}\n", .{@as(*GCObject, @fieldParentPtr("node", self.bottom))});
        util.dbgs("  - ptr: {*} \n", .{self.bottom});
        util.dbgs("  - distance to scan: {d} \n", .{util.node_distance(self.bottom, self.scan)});
        util.dbgs("- scan: {}\n", .{@as(*GCObject, @fieldParentPtr("node", self.scan))});
        util.dbgs("  - ptr: {*} \n", .{self.scan});
        util.dbgs("  - distance to free: {d} \n", .{util.node_distance(self.scan, self.free)});
        util.dbgs("- free: {}\n", .{@as(*GCObject, @fieldParentPtr("node", self.free))});
        util.dbgs("  - ptr: {*} \n", .{self.free});
        util.dbgs("  - distance to top: {d} \n", .{util.node_distance(self.free, self.top)});
        util.dbgs("\n-------------------------------\n", .{});
        util.dbgs("\n--------- Start of list -------\n", .{});
        var current = self.bottom;
        for (0..1024) |_| {
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
                // util.dbgs(" * Empty object\n", .{});
            }
            if (current.next == null) {
                util.dbgs("End of list\n", .{});
            }
            current = current.next.?;
        }
        // Print last object
        const obj: *GCObject = @fieldParentPtr("node", current);
        if (@intFromPtr(current) == @intFromPtr(self.free)) {
            if (obj.data() != null) {
                util.dbgs(" * Free object {x}\n", .{@intFromPtr(obj.data().?)});
            } else {
                util.dbgs(" * Empty free object\n", .{});
            }
        }
        util.dbgs("--------- End of list -------\n", .{});
    }
};
