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
    ALLOC_ROOT,
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

    pub fn field_at(self: *GCObject, index: usize, map: *std.AutoHashMap(*void, *GCObject)) ?*GCObject {
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

        // if (field.? == self.data().?) @panic("field is self");

        while (it.next()) |entry| {
            if (@intFromPtr(field.?) == @intFromPtr(entry.key_ptr.*)) {
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

pub const MAX_OBJECTS = 1024;

pub const Root = struct {
    ptr: **void,
    visited: bool,
};

pub const Collector = struct {
    memory: std.DoublyLinkedList,
    obj_to_void: std.AutoHashMap(*void, *GCObject),
    root_queue: std.ArrayList(Root),
    allocator: std.mem.Allocator,
    free: *std.DoublyLinkedList.Node, // Allocation of new objects happens at free
    scan: *std.DoublyLinkedList.Node, // Scan advances at scan
    top: *std.DoublyLinkedList.Node, // Still non-scanned objects are between bottom and top
    bottom: *std.DoublyLinkedList.Node,
    allocations: usize,
    memory_size: usize,
    event_queue: std.ArrayList(Event),

    pub fn init() !*Collector {
        const allocator = std.heap.page_allocator;
        const obj = try allocator.create(Collector);

        var memory: std.DoublyLinkedList = .{};
        // Pre-init memory
        for (0..MAX_OBJECTS) |_| {
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
            .obj_to_void = std.AutoHashMap(*void, *GCObject).init(allocator),
            .root_queue = std.ArrayList(Root).empty,
            .allocator = allocator,
            .free = memory.first.?,
            .scan = memory.first.?,
            .top = memory.first.?,
            .bottom = memory.first.?,
            .allocations = 0,
            .memory_size = 0,
            .event_queue = std.ArrayList(Event).empty,
        };

        obj.event_queue.append(allocator, Event.NONE) catch {
            std.process.exit(1);
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

        // if (self.event_queue.items.len > 1) {
        //     const last_event = self.event_queue.items[self.event_queue.items.len - 2];
        //     if (last_event == Event.PUSH_ROOT) {
        //         self.scan = self.scan.next.?;
        //     }
        // }

        if (self.scan == self.top) {
            self.scan = object.node.next.?;
        }

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
        // var it = self.obj_to_void.iterator();
        // while (it.next()) |entry| {
        //     if (@intFromPtr(object) == @intFromPtr(entry.key_ptr.*)) {
        //         util.dbgs("\n    [read_barrier] success\n", .{});
        //         const obj = entry.value_ptr.*;
        //         if (self.is_ecru(obj)) {
        //             self.darken(obj);
        //         } else {
        //             break;
        //         }
        //     }
        // }
        const obj = self.obj_to_void.get(object);
        if (obj == null) {
            if (self.is_ecru(obj.?)) {
                self.darken(obj.?);
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

        util.dbgs("\n[alloca] {}\n", .{self.event_queue.getLast()});
        const obj: *GCObject = @fieldParentPtr("node", self.free);
        obj.size = size;

        self.allocations += 1;
        self.free = self.free.next.?;

        // Allocating a root object
        const last_event = self.event_queue.getLast();
        if ((last_event == Event.PUSH_ROOT)) {
            // Make it gray
            util.dbgs("\n[allocating root]\n", .{});
            // self.darken(obj);
            self.make_gray(obj);
            self.event_queue.append(self.allocator, Event.ALLOC_ROOT) catch unreachable;
            // self.scan = self.scan.next.?;
            // self.scan = self.free;
        } else {
            self.advance();
        }

        // try self.obj_to_void.put(@ptrCast(obj.raw.?.ptr), obj);

        var entry = try self.obj_to_void.getOrPut(@ptrCast(obj.raw.?.ptr));
        if (!entry.found_existing) {
            entry.value_ptr.* = obj;
        }

        util.dbgs("\n  [allocated object] {*}\n", .{obj});

        self.print();

        const msg = std.fmt.allocPrint(self.allocator, "// From [alloca] with last event {} \n", .{last_event}) catch unreachable;
        self.state_graph(msg);
        self.event_queue.append(self.allocator, Event.ALLOC) catch unreachable;
        return obj.raw.?[0..size];
    }

    pub fn queue_roots(self: *Collector, object: **void) void {
        self.event_queue.append(self.allocator, Event.PUSH_ROOT) catch unreachable;
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

        // if (self.event_queue.items.len > 1) {
        //     const last_event = self.event_queue.items[self.event_queue.items.len - 2];
        //     if (last_event == Event.ALLOC_ROOT) {
        //         self.scan = self.scan.next.?;
        //     }
        // }

        if (self.scan == self.scan.prev.?) {
            @panic("No previous object");
        }
        util.dbgs("advance: scan = {} | {*}\n", .{ self.scan, self.scan });
        self.scan = self.scan.prev orelse @panic("No previous object");
        util.dbgs("advance: scan = {} | {*}\n", .{ self.scan, self.scan });
    }

    pub fn flip(self: *Collector) void {
        self.state_graph("// From before [flip] \n");
        self.event_queue.append(self.allocator, Event.FLIP) catch unreachable;
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
        // 1) Finish scanning current grey region
        while (self.scan != self.top) {
            self.advance();
        }

        self.state_graph("// In [flip] after advance \n");

        // 2) Grey all roots BEFORE zeroing, to protect reachable data

        // 3) Scan any newly grey objects introduced by roots
        // while (self.scan != self.top) {
        //     self.advance();
        // }

        // 4) Zero the ecru region safely now that live objs are grey/black
        var curr = self.bottom;
        while (curr != self.top) {
            const obj: *GCObject = @fieldParentPtr("node", curr);
            // var it = self.obj_to_void.iterator();
            // while (it.next()) |entry| {
            //     if (@intFromPtr(obj.raw.?.ptr) == @intFromPtr(entry.key_ptr.*)) {
            //         if (!self.obj_to_void.remove(entry.key_ptr.*)) {
            //             @panic("self.obj_to_void.remove");
            //         }
            //     }
            // }
            @memset(obj.raw.?, 0);
            curr = curr.next.?;
        }

        self.state_graph("// In [flip] after ecru zeroing \n");

        // 5) Slide bottom and reclassify remaining region to ecru
        self.bottom = self.top;

        curr = self.scan;
        while (curr != self.free) {
            const next = curr.next.?;
            const obj: *GCObject = @fieldParentPtr("node", curr);
            self.make_ecru(obj);
            curr = next;
        }

        self.state_graph("// In [flip] after changing black to ecru \n");

        util.dbgs("\n    [flip] to be greayed {d} roots\n", .{self.root_queue.items.len});

        for (self.root_queue.items, 0..self.root_queue.items.len) |root, _| {
            const ptr = root.ptr;
            // var it = self.obj_to_void.iterator();
            // while (it.next()) |entry| {
            //     if (@intFromPtr(ptr.*) == @intFromPtr(entry.key_ptr.*)) {
            //         util.dbgs("\n    [flip] greying root\n", .{});
            //         const obj = entry.value_ptr.*;
            //         self.make_gray(obj);
            //     }
            // }
            const obj = self.obj_to_void.get(ptr.*);
            if (obj == null) {
                self.make_gray(obj.?);
            }
        }

        self.state_graph("// In [flip] after graying out roots \n");

        self.state_graph("// From after [flip] \n");
    }

    pub fn pop_root(self: *Collector, object: **void) !void {
        for (self.root_queue.items, 0..self.root_queue.items.len) |root, i| {
            if (root.ptr == object) {
                _ = self.root_queue.swapRemove(i);
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
        for (0..MAX_OBJECTS) |_| {
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

        // self.state_graph();
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

    pub fn state_graph(self: *Collector, msg: []const u8) void {
        // var graphviz = std.fs.cwd().createFile("state_graph.dot", .{}) catch |e|
        //     switch (e) {
        //         error.PathAlreadyExists => {
        //             std.log.info("state_graph.dot already exists", .{});
        //             return;
        //         },
        //         else => @panic("Failed to create state_graph.dot"),
        //     };
        var graphviz = std.fs.cwd().openFile("state_graph.dot", .{ .mode = .write_only }) catch @panic("Failed to open state_graph.dot");
        defer graphviz.close();

        graphviz.seekFromEnd(0) catch @panic("Failed to seek in state_graph.dot");

        const allocator = std.heap.page_allocator;
        var content = std.ArrayList(u8).empty;
        defer content.deinit(allocator);

        const info = std.fmt.allocPrint(allocator, "// Last event: {}\n", .{self.event_queue.getLast()}) catch unreachable;
        const name = std.fmt.allocPrint(allocator, "digraph Treadmill{d} {{\n", .{self.allocations}) catch unreachable;

        content.appendSlice(allocator, info) catch unreachable;
        content.appendSlice(allocator, name) catch unreachable;
        content.appendSlice(allocator, msg) catch unreachable;

        const string: []const u8 =
            "layout=\"twopi\";\n" ++
            "ranksep=10; // radius\n" ++
            "root=CENTER;\n" ++
            "edge [style=invis];\n" ++
            "CENTER [style=invis];\n";

        content.appendSlice(allocator, string) catch unreachable;

        // First write all adresses in CENTER
        content.appendSlice(allocator, "CENTER -> {\n") catch unreachable;
        var current = self.bottom;
        for (0..MAX_OBJECTS) |_| {
            const obj: *GCObject = @fieldParentPtr("node", current);
            content.appendSlice(allocator, "\t") catch unreachable;
            const ptrToStr = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(obj)}) catch unreachable;
            content.appendSlice(allocator, "n") catch unreachable;
            content.appendSlice(allocator, ptrToStr) catch unreachable;
            content.appendSlice(allocator, "\n") catch unreachable;
            current = current.next.?;
        }
        content.appendSlice(allocator, "}\n") catch unreachable;

        // Node style
        content.appendSlice(allocator, "node [shape=circle, style=filled, fontname=\"monospace\", fontsize=10];\n") catch unreachable;
        current = self.bottom;
        var last_color: i32 = -1; // 0 - black, 1 - gray, 2 - white, 3 - ecru
        for (0..MAX_OBJECTS) |_| {
            const obj: *GCObject = @fieldParentPtr("node", current);
            const ptrAsStr = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(obj)}) catch unreachable;
            content.appendSlice(allocator, "n") catch unreachable;
            content.appendSlice(allocator, ptrAsStr) catch unreachable;
            content.appendSlice(allocator, " [label=\"") catch unreachable;
            content.appendSlice(allocator, ptrAsStr) catch unreachable;
            content.appendSlice(allocator, "\", ") catch unreachable;
            if (@intFromPtr(current) == @intFromPtr(self.free)) {
                last_color = 2;
            }
            if (@intFromPtr(current) == @intFromPtr(self.scan)) {
                last_color = 0;
            }
            if (@intFromPtr(current) == @intFromPtr(self.bottom)) {
                last_color = 3;
            }
            if (@intFromPtr(current) == @intFromPtr(self.top)) {
                last_color = 1;
            }
            if (last_color == 0) {
                // black
                content.appendSlice(allocator, "fillcolor=\"#000000\", ") catch unreachable;
            }
            if (last_color == 1) {
                content.appendSlice(allocator, "fillcolor=\"#888888\", ") catch unreachable;
            }
            if (last_color == 2) {
                content.appendSlice(allocator, "fillcolor=\"#ffffff\", ") catch unreachable;
            }
            if (last_color == 3) {
                content.appendSlice(allocator, "fillcolor=\"#00ff00\", ") catch unreachable;
            }

            // if ((@intFromPtr(current) >= @intFromPtr(self.bottom)) and (@intFromPtr(current) < @intFromPtr(self.top))) {
            //     // ecru color
            //     content.appendSlice(allocator, "fillcolor=\"#ff0000\", ") catch unreachable;
            // }
            // if ((@intFromPtr(current) >= @intFromPtr(self.top)) and (@intFromPtr(current) < @intFromPtr(self.scan))) {
            //     // gray color
            //     content.appendSlice(allocator, "fillcolor=\"#888888\", ") catch unreachable;
            // }
            // if ((@intFromPtr(current) >= @intFromPtr(self.scan)) and (@intFromPtr(current) < @intFromPtr(self.free))) {
            //     // black color
            //     content.appendSlice(allocator, "fillcolor=\"#000000\", ") catch unreachable;
            // }
            // if ((@intFromPtr(current) >= @intFromPtr(self.free)) and (@intFromPtr(current) < @intFromPtr(self.bottom))) {
            //     // white color
            //     content.appendSlice(allocator, "fillcolor=\"#ffffff\", ") catch unreachable;
            // }
            content.appendSlice(allocator, "];\n") catch unreachable;
            current = current.next.?;
        }
        content.appendSlice(allocator, "edge [style=solid, color=\"#888888\"];\n") catch unreachable;

        // Doubly-link them
        current = self.bottom;
        for (0..MAX_OBJECTS) |_| {
            const obj: *GCObject = @fieldParentPtr("node", current);
            const next: *GCObject = @fieldParentPtr("node", current.next.?);
            const ptrAsStr = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(obj)}) catch unreachable;
            content.appendSlice(allocator, "n") catch unreachable;
            content.appendSlice(allocator, ptrAsStr) catch unreachable;
            content.appendSlice(allocator, " -> ") catch unreachable;
            const nextPtrAsStr = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(next)}) catch unreachable;
            content.appendSlice(allocator, "n") catch unreachable;
            content.appendSlice(allocator, nextPtrAsStr) catch unreachable;
            content.appendSlice(allocator, "\n") catch unreachable;
            current = current.next.?;
        }

        // Field references
        content.appendSlice(allocator, "edge [color=\"#009900\", style=dashed, penwidth=2];\n") catch unreachable;
        for (0..MAX_OBJECTS) |_| {
            const obj: *GCObject = @fieldParentPtr("node", current);
            const count = obj.field_count() orelse return;
            for (0..count) |i| {
                const field = obj.field_at(i, &self.obj_to_void);
                if (field != null) {
                    const objPtrAsStr = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(obj)}) catch unreachable;
                    const fieldPtrAsStr = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(field.?)}) catch unreachable;
                    content.appendSlice(allocator, "n") catch unreachable;
                    content.appendSlice(allocator, objPtrAsStr) catch unreachable;
                    content.appendSlice(allocator, " -> ") catch unreachable;
                    content.appendSlice(allocator, "n") catch unreachable;
                    content.appendSlice(allocator, fieldPtrAsStr) catch unreachable;
                    content.appendSlice(allocator, "\n") catch unreachable;
                }
            }
            current = current.next.?;
        }

        // Treadmill pointers
        content.appendSlice(allocator, "bottom [label=\"bottom\", shape=plaintext];\n") catch unreachable;
        content.appendSlice(allocator, "scan [label=\"scan\", shape=plaintext];\n") catch unreachable;
        content.appendSlice(allocator, "top [label=\"top\", shape=plaintext];\n") catch unreachable;
        content.appendSlice(allocator, "free [label=\"free\", shape=plaintext];\n") catch unreachable;
        content.appendSlice(allocator, "edge [style=dotted, color=\"#555555\"];\n") catch unreachable;

        const bottom_obj: *GCObject = @fieldParentPtr("node", self.bottom);
        content.appendSlice(allocator, "bottom -> ") catch unreachable;
        const bottomAsStr = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(bottom_obj)}) catch unreachable;
        content.appendSlice(allocator, "n") catch unreachable;
        content.appendSlice(allocator, bottomAsStr) catch unreachable;
        content.appendSlice(allocator, "\n") catch unreachable;
        const scan_obj: *GCObject = @fieldParentPtr("node", self.scan);
        content.appendSlice(allocator, "scan -> ") catch unreachable;
        const scanAsStr = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(scan_obj)}) catch unreachable;
        content.appendSlice(allocator, "n") catch unreachable;
        content.appendSlice(allocator, scanAsStr) catch unreachable;
        content.appendSlice(allocator, "\n") catch unreachable;
        const top_obj: *GCObject = @fieldParentPtr("node", self.top);
        content.appendSlice(allocator, "top -> ") catch unreachable;
        const topAsStr = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(top_obj)}) catch unreachable;
        content.appendSlice(allocator, "n") catch unreachable;
        content.appendSlice(allocator, topAsStr) catch unreachable;
        content.appendSlice(allocator, "\n") catch unreachable;
        const free_obj: *GCObject = @fieldParentPtr("node", self.free);
        content.appendSlice(allocator, "free -> ") catch unreachable;
        const freeAsStr = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(free_obj)}) catch unreachable;
        content.appendSlice(allocator, "n") catch unreachable;
        content.appendSlice(allocator, freeAsStr) catch unreachable;
        content.appendSlice(allocator, "\n}\n") catch unreachable;

        const concated = content.toOwnedSlice(allocator) catch unreachable;
        defer allocator.free(concated);

        graphviz.writeAll(concated) catch unreachable;
    }
};
