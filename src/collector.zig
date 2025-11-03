const std = @import("std");
const gc = std.gc;
const runtime = @cImport({
    @cInclude("runtime.h");
});

const util = @import("util.zig");

pub const StellaObject = runtime.stella_object;
pub const StellaObjectPtr = *allowzero align(1) StellaObject;

pub const Event = enum {
    PUSH_ROOT,
    ALLOC,
    FLIP,
    NONE,
};

pub const GCObject = struct {
    node: std.DoublyLinkedList.Node,
    raw: ?[]u8,
    size: usize,

    pub fn data(self: *GCObject) ?StellaObjectPtr {
        // if (self.hint != null) {
        //     const obj = util.void_to_stella_object(self.hint.?.*);
        //     util.dbgs("  | GCObject header: {d} | From hint\n", .{runtime.STELLA_OBJECT_HEADER_TAG(obj.object_header)});
        //     return obj;
        // }
        if (self.raw == null) return null;
        var slice = self.raw.?[0..self.size];
        const st = util.memory_to_stella_object(&slice);
        util.dbgs("  | GCObject header: {d} | Byte size: {d}\n", .{ runtime.STELLA_OBJECT_HEADER_TAG(st.object_header), self.raw.?.len });
        return util.memory_to_stella_object(&slice);
    }

    pub fn field_count(self: *GCObject) ?usize {
        if (self.data() == null) return null;
        util.dbgs("  | GCObject field count: {d}\n", .{util.field_count(self.data().?)});
        return util.field_count(self.data().?);
    }

    pub fn field_at(self: *GCObject, index: usize, map: *std.AutoHashMap(**void, *GCObject)) ?*GCObject {
        // util.dbgs("\n [field_at] \n", .{});
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
        obj.size = 0;
        obj.node = .{};
        return obj;
    }
};

pub const Root = struct {
    ptr: **void,
    visited: bool,
};

pub const Collector = struct {
    memory: std.DoublyLinkedList,
    obj_to_void: std.AutoHashMap(**void, *GCObject),
    root_queue: std.ArrayList(Root),
    allocator: std.mem.Allocator,
    free: *std.DoublyLinkedList.Node, // Allocation of new objects happens at free
    scan: *std.DoublyLinkedList.Node, // Scan advances at scan
    top: *std.DoublyLinkedList.Node, // Still non-scanned objects are between bottom and top
    bottom: *std.DoublyLinkedList.Node,
    allocations: usize,
    memory_size: usize,
    event: Event,

    pub fn init() !*Collector {
        const allocator = std.heap.page_allocator;
        const obj = try allocator.create(Collector);

        var memory: std.DoublyLinkedList = .{};
        // Pre-init memory
        for (0..16) |_| {
            var object = try GCObject.init_raw(allocator);
            object.raw = allocator.alloc(u8, 64) catch |err| {
                return err;
            };
            object.size = 64;
            @memset(object.raw.?, 0);
            memory.append(&object.node);
        }
        memory.first.?.prev = memory.last.?;
        memory.last.?.next = memory.first.?;

        obj.* = Collector{
            .memory = memory,
            .obj_to_void = std.AutoHashMap(**void, *GCObject).init(allocator),
            .root_queue = std.ArrayList(Root).empty,
            .allocator = allocator,
            .free = memory.first.?,
            .scan = memory.first.?,
            .top = memory.first.?,
            .bottom = memory.first.?,
            .allocations = 0,
            .memory_size = 0,
            .event = Event.NONE,
        };

        return obj;
    }

    fn is_ecru(self: *Collector, object: *GCObject) bool {
        util.dbgs("\n [is_ecru]", .{});
        // const top_ptr = @as(*GCObject, @fieldParentPtr("node", self.top));
        // const bottom_ptr = @as(*GCObject, @fieldParentPtr("node", self.bottom));
        // util.dbgs("\n - top_ptr: {*}, bottom_ptr: {*}", .{ top_ptr, bottom_ptr });
        // util.dbgs("\n - object: {*}", .{object});
        // if ((@intFromPtr(object) >= @intFromPtr(bottom_ptr)) and (@intFromPtr(object) < @intFromPtr(top_ptr))) {
        //     std.process.exit(0);
        //     return true;
        // }
        // return false;
        // empty ecru region if top == bottom
        if (@intFromPtr(self.bottom) == @intFromPtr(self.top)) return false;

        var cur = self.bottom;
        while (@intFromPtr(cur) != @intFromPtr(self.top)) {
            if (@as(*GCObject, @fieldParentPtr("node", cur)) == object) return true;
            cur = cur.next.?; // safe in cyclic list
        }
        return false;
    }

    /// Remove the object from the treadmill list
    pub fn unlink(self: *Collector, object: *GCObject) void {
        util.dbgs("\n[unlink]\n", .{});
        const before_top: *GCObject = @fieldParentPtr("node", self.top);
        const before_scan: *GCObject = @fieldParentPtr("node", self.scan);
        const before_bottom: *GCObject = @fieldParentPtr("node", self.bottom);
        const before_free: *GCObject = @fieldParentPtr("node", self.free);

        // In a cyclic list, prev and next are never null
        const prev = object.node.prev.?;
        const next = object.node.next.?;

        if (object == before_free) {
            self.free = next;
        }
        if (object == before_top) {
            self.top = next;
        }
        if (object == before_bottom) {
            self.bottom = next;
        }
        if (object == before_scan) {
            self.scan = next;
        }

        // Optional: clear the node's own links
        object.node.prev = null;
        object.node.next = null;

        prev.next = next;
        next.prev = prev;
    }

    /// Add the object to the treadmill list, before the head
    /// TODO: maybe at the tail?
    pub fn link(self: *Collector, head: *GCObject, object: *GCObject) void {
        util.dbgs("\n[link] {}\n", .{self.allocations});
        const before_top: *GCObject = @fieldParentPtr("node", self.top);
        const before_scan: *GCObject = @fieldParentPtr("node", self.scan);
        const before_bottom: *GCObject = @fieldParentPtr("node", self.bottom);
        const before_free: *GCObject = @fieldParentPtr("node", self.free);

        const next = head.node.next.?; // Node currently after `after`

        object.node.prev = &head.node; // New node points back to `after`
        object.node.next = next; // New node points forward to `next`

        head.node.next = &object.node; // `after` now points to new node
        next.prev = &object.node; // `next` now points back to new node

        if (object == before_free) {
            self.free = &object.node;
        }
        if (object == before_top) {
            self.top = &object.node;
        }
        if (object == before_bottom) {
            self.bottom = &object.node;
        }
        if (object == before_scan) {
            self.scan = &object.node;
        }
    }

    pub fn insert_in(self: *Collector, head: *GCObject, object: *GCObject) void {
        if (object == head) {
            return;
        }
        self.unlink(object);
        self.link(head, object);
    }

    //================ COLORING ==============

    pub fn make_gray(self: *Collector, object: *GCObject) void {
        // self.unlink(object);
        // self.link(@fieldParentPtr("node", self.top), object);
        self.insert_in(@fieldParentPtr("node", self.top), object);

        if (object == @as(*GCObject, @fieldParentPtr("node", self.scan))) {
            self.scan = object.node.next.?;
        }
        if (object == @as(*GCObject, @fieldParentPtr("node", self.free))) {
            self.free = object.node.next.?;
        }
    }

    pub fn make_ecru(self: *Collector, object: *GCObject) void {
        if (object == @as(*GCObject, @fieldParentPtr("node", self.bottom))) {
            if (object == @as(*GCObject, @fieldParentPtr("node", self.top))) {
                self.top = object.node.next.?;
            }
            if (object == @as(*GCObject, @fieldParentPtr("node", self.scan))) {
                self.scan = object.node.next.?;
            }
            if (object == @as(*GCObject, @fieldParentPtr("node", self.free))) {
                self.free = object.node.next.?;
            }
        } else {
            self.insert_in(@fieldParentPtr("node", self.bottom), object);
        }
    }

    // Check if allocated object is root and make it gray
    // insted of black
    pub fn check_roots(self: *Collector) void {
        util.dbgs("\n[check_roots] {d}\n", .{self.allocations});
        // for (self.root_queue.items) |*root| {
        //     // util.dbgs("\n [check_roots] size: {d}\n", .{self.root_queue.items.len});
        //     var it = self.obj_to_void.iterator();
        //     while (it.next()) |entry| {
        //         // util.dbgs("\nFound object at address: {*} {*} | {*}\n", .{ entry.key_ptr.*.*, entry.key_ptr.*, root.* });
        //         if ((@intFromPtr(root.ptr.*) == @intFromPtr(entry.key_ptr.*.*)) and (root.visited == false)) {
        //             util.dbgs("\n  [check_roots] success\n", .{});
        //             const obj = entry.value_ptr.*;
        //             self.darken(obj);
        //             // util.dbgs("\nFound root at address: {*} | {*}\n", .{ root.*, entry.key_ptr.* });

        //             // self.scan = self.scan.next.?;
        //             root.visited = true;
        //             self.print();
        //             // if (self.scan == self.bottom) {
        //             //     self.scan = self.free;
        //             // }
        //             // if ()
        //             // std.process.exit(0);
        //         }
        //     }
        // }
    }

    /// Make an ecru object gray
    pub fn darken(self: *Collector, object: *GCObject) void {
        // const before_top: *GCObject = @fieldParentPtr("node", self.top);
        // util.dbgs("\n[darken] | {*} {*}\n", .{ object, before_top });
        // self.unlink(object);
        // const top: *GCObject = @fieldParentPtr("node", self.top);
        // util.dbgs("\n[darken] top: {} | object: {}\n", .{ top, object });
        // self.link(top, object); // Put it back at the tail of the gray list
        // self.insert_in(@fieldParentPtr("node", self.top), object);
        self.make_gray(object);
    }

    /// Read barrier for the object
    pub fn read_barrier(self: *Collector, object: *void) void {
        // Find corresponding GCObject
        util.dbgs("Searching object at address: {*} | {d}\n", .{ object, self.obj_to_void.count() });
        var it = self.obj_to_void.iterator();
        while (it.next()) |entry| {
            // util.dbgs("\nFound object at address: {*} {*}\n", .{ entry.key_ptr.*.*, entry.key_ptr.* });
            if (@intFromPtr(object) == @intFromPtr(entry.key_ptr.*.*)) {
                util.dbgs("\n    [read_barrier] success\n", .{});
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
        if ((@intFromPtr(self.free.next.?) == @intFromPtr(self.bottom))) {
            util.dbgs("\n\n -----------------before flip \n\n", .{});
            self.print();
            self.flip();
            util.dbgs("\n\n ----------------- after flip \n\n", .{});
            self.print();
            // std.process.exit(1);
        }

        util.dbgs("\n[alloca] {}\n", .{self.event});
        const obj: *GCObject = @fieldParentPtr("node", self.free);
        obj.size = size;

        self.allocations += 1;
        self.free = self.free.next.?;

        // Allocating a root object
        if (self.event == Event.PUSH_ROOT) {
            // Make it gray
            util.dbgs("\n[allocating root]\n", .{});
            // self.darken(obj);
            self.make_gray(obj);
            // self.scan = self.scan.next.?;
            // self.scan = self.free;
        } else {
            self.advance();
        }

        try self.obj_to_void.put(@ptrCast(&obj.raw.?), obj);

        util.dbgs("\n  [allocated object] {*}\n", .{obj});

        self.print();
        self.event = Event.ALLOC;
        return obj.raw.?[0..size];
    }

    pub fn queue_roots(self: *Collector, object: **void) void {
        self.event = Event.PUSH_ROOT;
        util.dbgs("\n[queue_roots]\n", .{});
        const root = Root{ .ptr = object, .visited = false };
        self.root_queue.append(self.allocator, root) catch unreachable;
    }

    pub fn advance(self: *Collector) void {
        if (self.scan == self.top) return;
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
        self.event = Event.FLIP;
        // const curr = self.scan;
        // while (curr != self.free) {
        //     if (curr == self.bottom) {
        //         if (curr == self.top) {
        //             self.top = self.top.next.?;
        //         } else if (curr == self.scan) {
        //             self.scan = self.scan.next.?;
        //         } else if (curr == self.free) {
        //             self.free = self.free.next.?;
        //         }
        //     } else {
        //         const bottom_obj = @as(*GCObject, @fieldParentPtr("node", self.bottom));
        //         const curr_obj = @as(*GCObject, @fieldParentPtr("node", curr));
        //         unlink(curr_obj);
        //         link(bottom_obj, curr_obj);
        //         self.top = self.top.next.?;
        //     }
        // }
        // ----
        // self.allocations = 0;
        // const temp = self.top;
        // self.top = self.bottom;
        // // self.scan = self.top;
        // self.bottom = temp;

        // self.scan = self.top;
        // self.free = self.top;

        // for (self.root_queue.items, 0..self.root_queue.items.len) |root, _| {
        //     const ptr = root.ptr;
        //     var it = self.obj_to_void.iterator();
        //     while (it.next()) |entry| {
        //         // util.dbgs("\nFound object at address: {*} {*}\n", .{ entry.key_ptr.*.*, entry.key_ptr.* });
        //         if (@intFromPtr(ptr.*) == @intFromPtr(entry.key_ptr.*.*)) {
        //             util.dbgs("\n    [read_barrier] success\n", .{});
        //             const obj = entry.value_ptr.*;
        //             self.make_gray(obj);
        //             self.free = self.free.next.?;
        //             self.scan = self.scan.next.?;
        //         }
        //     }
        // }

        // self.check_roots();
        // ----
        while (self.scan != self.top) {
            self.advance();
        }

        var curr = self.bottom;
        while (curr != self.top) {
            const obj: *GCObject = @fieldParentPtr("node", curr);
            @memset(obj.raw.?, 0);
            curr = curr.next.?;
        }

        self.bottom = self.top;

        curr = self.scan;
        while (curr != self.free) {
            const next = curr.next.?;
            const obj: *GCObject = @fieldParentPtr("node", curr);
            self.make_ecru(obj);
            curr = next;
        }

        for (self.root_queue.items, 0..self.root_queue.items.len) |root, _| {
            const ptr = root.ptr;
            var it = self.obj_to_void.iterator();
            while (it.next()) |entry| {
                // util.dbgs("\nFound object at address: {*} {*}\n", .{ entry.key_ptr.*.*, entry.key_ptr.* });
                if (@intFromPtr(ptr.*) == @intFromPtr(entry.key_ptr.*.*)) {
                    util.dbgs("\n    [read_barrier] success\n", .{});
                    const obj = entry.value_ptr.*;
                    self.make_gray(obj);
                }
            }
        }
    }

    pub fn pop_root(self: *Collector, object: **void) !void {
        for (self.root_queue.items, 0..self.root_queue.items.len) |root, i| {
            if (root.ptr == object) {
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
        for (0..16) |_| {
            if (@intFromPtr(current) == @intFromPtr(self.bottom)) {
                util.dbgs("--------- Bottom of list -------\n", .{});
            }
            if (@intFromPtr(current) == @intFromPtr(self.scan)) {
                util.dbgs("--------- Scanning object -------\n", .{});
            }
            if (@intFromPtr(current) == @intFromPtr(self.top)) {
                util.dbgs("--------- Top of list -------\n", .{});
            }
            if (@intFromPtr(current) == @intFromPtr(self.free)) {
                util.dbgs("--------- Free list -------\n", .{});
            }
            const obj: *GCObject = @fieldParentPtr("node", current);
            if (obj.data() != null) {
                util.dbgs(" * Object at {x}\n", .{@intFromPtr(obj)});
                self.print_fields(obj);
                // runtime.print_stella_object(@ptrCast(@alignCast(obj.data().?)));
            } else {
                util.dbgs(" * Empty object\n", .{});
            }
            if (current.next == null) {
                util.dbgs("End of list\n", .{});
            }
            current = current.next.?;
        }
        // // Print last object
        // const obj: *GCObject = @fieldParentPtr("node", current);
        // if (@intFromPtr(current) == @intFromPtr(self.free)) {
        //     if (obj.data() != null) {
        //         util.dbgs(" * Free object {x}\n", .{@intFromPtr(obj.data().?)});
        //     } else {
        //         util.dbgs(" * Empty free object\n", .{});
        //     }
        // }
        util.dbgs("--------- End of list -------\n", .{});
    }

    pub fn print_fields(self: *Collector, obj: *GCObject) void {
        const count = obj.field_count() orelse return;
        for (0..count) |i| {
            const field = obj.field_at(i, &self.obj_to_void);
            if (field != null) {
                util.dbgs("     * Field {d}: {x}\n", .{ i, @intFromPtr(field.?) });
            } else {
                util.dbgs("     * Field {d}: Empty\n", .{i});
            }
        }
    }
};
