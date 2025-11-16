//! Implementation of the "Treadmill" garbage collector.

const std = @import("std");
const builtin = @import("builtin");
const util = @import("util.zig");
const runtime = @cImport({
    @cInclude("runtime.h");
});
const stat = @import("stats.zig");

const DEBUG = builtin.mode == .Debug;

pub const StellaObject = runtime.stella_object;
pub const StellaObjectPtr = *allowzero align(1) StellaObject;

// For debugging purposes
// and to detect root allocation
// to make them gray instead of black
pub const Event = enum {
    PUSH_ROOT,
    ALLOC_ROOT,
    ALLOC,
    FLIP,
    NONE,
};

pub const Color = enum {
    BLACK, // have been completely scanned together with the objects they point to
    GRAY, // have been scanned, but the objects they point to are not guaranteed to be scanned
    ECRU, // have not been scanned
    WHITE, // free
};

pub const GCObject = struct {
    /// Points to its position in memory
    node: std.DoublyLinkedList.Node,
    /// Data that this object owns
    raw: ?[]u8,
    /// Size of allocated data
    size: usize,
    color: Color,

    /// Translate raw data that this object owns into StellaObjectPtr
    pub fn data(self: *GCObject) ?StellaObjectPtr {
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

        const field = util.field_at(self.data().?, index);
        if (field == null) return null;

        const entry = map.get(@ptrCast(field.?));
        if (entry != null) return entry.?;

        return null;
    }

    /// Initialize zero-sized object
    pub fn init_raw(allocator: std.mem.Allocator) !*GCObject {
        const obj = try allocator.create(GCObject);
        obj.raw = null;
        obj.size = 0;
        obj.node = .{};
        obj.color = .WHITE;
        return obj;
    }
};

/// Maximum number of objects that can be allocated
/// and put into a doubly linked list, which acts as a
/// heap in this gc algorithm
pub const MAX_OBJECTS: usize = @import("gc_config").MAX_OBJECTS;

pub const Root = struct {
    /// Raw pointer to some objects
    ptr: **void,
    /// Whether we grayed out the object
    visited: bool,
};

pub const Collector = struct {
    /// Memory is a doubly linked list of objects
    /// where the state of the object is determined
    /// by what pointers are above and below it
    /// a.k.a it's color
    memory: std.DoublyLinkedList,
    /// Map of objects to their pointers for fast lookup
    obj_to_void: std.AutoHashMap(*void, *GCObject),
    /// For properly allocating root objects
    root_queue: std.ArrayList(Root),
    allocator: std.mem.Allocator,
    /// Allocation of new objects happens at free
    free: *std.DoublyLinkedList.Node,
    /// Moves counter clock-wise and darkens objects
    scan: *std.DoublyLinkedList.Node,
    /// Still non-scanned objects are between bottom and top
    top: *std.DoublyLinkedList.Node,
    bottom: *std.DoublyLinkedList.Node,
    memory_size: usize,
    event_queue: std.ArrayList(Event),
    stats: stat.Statistics,

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
            // Large enough to fit a stella object
            object.size = 64;
            @memset(object.raw.?, 0);
            memory.append(&object.node);
        }

        // Link bottom and top
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
            .memory_size = 0,
            .event_queue = std.ArrayList(Event).empty,
            .stats = .{},
        };

        obj.event_queue.append(allocator, Event.NONE) catch {
            std.process.exit(1);
        };

        return obj;
    }

    fn is_ecru(self: *Collector, object: *GCObject) bool {
        util.dbgs("\n [is_ecru]", .{});
        if (@intFromPtr(self.bottom) == @intFromPtr(self.top)) return false;

        return object.color == Color.ECRU;
    }

    /// Remove the object from the treadmill list
    pub fn unlink(self: *Collector, object: *GCObject) void {
        util.dbgs("\n[unlink]\n", .{});

        const before_top: *GCObject = @fieldParentPtr("node", self.top);
        const before_scan: *GCObject = @fieldParentPtr("node", self.scan);
        const before_bottom: *GCObject = @fieldParentPtr("node", self.bottom);
        const before_free: *GCObject = @fieldParentPtr("node", self.free);

        if (object == before_free) {
            self.free = object.node.next.?;
        }
        if (object == before_top) {
            self.top = object.node.next.?;
        }
        if (object == before_bottom) {
            self.bottom = object.node.next.?;
        }
        if (object == before_scan) {
            self.scan = object.node.next.?;
        }

        self.memory.remove(&object.node);
    }

    /// Add the object to the treadmill list, before the head
    pub fn link(self: *Collector, head: *GCObject, object: *GCObject) void {
        util.dbgs("\n[link] {}\n", .{self.stats.allocated_memory});
        const before_top: *GCObject = @fieldParentPtr("node", self.top);
        const before_scan: *GCObject = @fieldParentPtr("node", self.scan);
        const before_bottom: *GCObject = @fieldParentPtr("node", self.bottom);
        const before_free: *GCObject = @fieldParentPtr("node", self.free);

        self.memory.insertBefore(head.node.next.?, &object.node);

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

    pub fn make_gray(self: *Collector, object: *GCObject) void {
        object.color = .GRAY;
        self.insert_in(@fieldParentPtr("node", self.top), object);

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
        object.color = .ECRU;
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

    // This barrier guarantees that the mutator cannot violate
    // the invariant simply because the mutator never sees ecru objects
    // (which are grayed by the barrier) and hence cannot store pointers
    // to them anywhere
    // If the read barrier is present, the write barrier is not necessary
    pub fn read_barrier(self: *Collector, object: *void) void {
        self.stats.barrier_reads += 1;
        util.dbgs("Searching object at address: {*} | {d}\n", .{ object, self.obj_to_void.count() });
        // Find corresponding GCObject
        const obj = self.obj_to_void.get(object);
        if (obj != null) {
            if (self.is_ecru(obj.?)) {
                self.make_gray(obj.?);
            }
        }
    }

    /// Take object at `free` and return pre-allocated row bytes.
    /// Then either make it black or if it's a root - gray.
    pub fn alloca(self: *Collector, size: usize) ![]u8 {
        if ((@intFromPtr(self.free.next.?) == @intFromPtr(self.bottom))) {
            util.dbgs("\n\n -----------------before flip \n\n", .{});
            self.print();
            self.flip();
            util.dbgs("\n\n ----------------- after flip \n\n", .{});
            self.print();
        }

        util.dbgs("\n[alloca] {}\n", .{self.event_queue.getLast()});
        const obj: *GCObject = @fieldParentPtr("node", self.free);
        obj.size = size;

        self.stats.allocated_memory += size;
        self.stats.allocated_objects += 1;

        self.free = self.free.next.?;

        // Allocating a root object means putting it
        // in the "gray" section to make it live and not
        // turn it black immediatly
        const last_event = self.event_queue.getLast();
        if ((last_event == Event.PUSH_ROOT)) {
            // Make it gray
            util.dbgs("\n[allocating root]\n", .{});
            self.make_gray(obj);
            self.event_queue.append(self.allocator, Event.ALLOC_ROOT) catch unreachable;
        } else {
            self.advance();
        }

        // Associate object with its raw pointer
        var entry = try self.obj_to_void.getOrPut(@ptrCast(obj.raw.?));
        if (!entry.found_existing) {
            entry.value_ptr.* = obj;
        }

        util.dbgs("\n  [allocated object] {*}\n", .{obj});

        self.print();
        const msg = std.fmt.allocPrint(self.allocator, "// From [alloca] with last event {} \n", .{last_event}) catch unreachable;
        defer self.allocator.free(msg);
        self.state_graph(msg);
        self.event_queue.append(self.allocator, Event.ALLOC) catch unreachable;
        return obj.raw.?[0..size];
    }

    // a.k.a. push_root
    pub fn queue_roots(self: *Collector, object: **void) void {
        self.event_queue.append(self.allocator, Event.PUSH_ROOT) catch unreachable;
        util.dbgs("\n[queue_roots]\n", .{});
        const root = Root{ .ptr = object, .visited = false };
        self.root_queue.append(self.allocator, root) catch unreachable;
    }

    // `advance` takes the gray object pointed to by scan, which is
    // the head of the FRONT list, and grays all ecru objects that
    // this object points to. After that, scan is advanced (counterclockwise),
    // effectively moving the scanned object into the SCANNED section
    // and making it black.
    pub fn advance(self: *Collector) void {
        if (self.scan == self.top) return;
        util.dbgs("\n[advance]\n", .{});
        const scan: *GCObject = @fieldParentPtr("node", self.scan);
        const count = scan.field_count() orelse return;
        util.dbgs("\n[advance] count: {}\n", .{count});
        for (0..count) |i| {
            const field = scan.field_at(i, &self.obj_to_void);
            if (field != null) {
                self.stats.memory_reads += 1;
                if (self.is_ecru(field.?)) {
                    self.make_gray(field.?);
                }
            }
        }

        scan.color = .BLACK;

        if (self.scan == self.scan.prev.?) {
            @panic("No previous object");
        }
        util.dbgs("advance: scan = {} | {*}\n", .{ self.scan, self.scan });
        self.scan = self.scan.prev orelse @panic("No previous object");
        util.dbgs("advance: scan = {} | {*}\n", .{ self.scan, self.scan });
    }

    // Swap top and bottom pointers and redefine colours: the old black objects
    // are now ecru and the old ecru objects (they are garbage) are now white
    pub fn flip(self: *Collector) void {
        self.stats.flips += 1;
        self.state_graph("// From before [flip] \n");
        self.event_queue.append(self.allocator, Event.FLIP) catch unreachable;

        // Finish scanning current grey region
        while (self.scan != self.top) {
            self.advance();
        }

        self.state_graph("// In [flip] after advance \n");

        // Zero the ecru region (garbage)
        var ecru = std.ArrayList(*GCObject).empty;
        var curr = self.bottom;
        while (@intFromPtr(curr) != @intFromPtr(self.top)) {
            self.stats.memory_writes += 1;
            ecru.append(self.allocator, @fieldParentPtr("node", curr)) catch unreachable;
            curr = curr.next.?;
        }
        for (ecru.items) |obj| {
            @memset(obj.raw.?, 0);
            _ = self.obj_to_void.remove(@ptrCast(obj.raw.?));
            obj.color = .WHITE;
        }

        self.state_graph("// In [flip] after ecru zeroing \n");

        // Slide bottom and reclassify remaining region to ecru
        self.bottom = self.top;

        // black -> ecru
        var black_objs = std.ArrayList(*GCObject).empty;
        curr = self.scan;
        while (curr != self.free) {
            black_objs.append(self.allocator, @fieldParentPtr("node", curr)) catch unreachable;
            curr = curr.next.?;
        }
        for (black_objs.items) |obj| self.make_ecru(obj);

        self.state_graph("// In [flip] after changing black to ecru \n");
        util.dbgs("\n    [flip] to be greayed {d} roots\n", .{self.root_queue.items.len});

        // Gray out roots before new cycle
        for (self.root_queue.items, 0..self.root_queue.items.len) |root, _| {
            const ptr = root.ptr;
            const obj = self.obj_to_void.get(ptr.*);
            if (obj != null) {
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
        if (!DEBUG) return;
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
        util.dbgs("--------- End of list -------\n", .{});
    }

    pub fn print_fields(self: *Collector, obj: *GCObject) void {
        if (!DEBUG) return;
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

    /// Save a graphviz file with the current state of the collector
    pub fn state_graph(self: *Collector, msg: []const u8) void {
        if (!DEBUG) return;
        var graphviz = std.fs.cwd().openFile("state_graph.dot", .{ .mode = .write_only }) catch @panic("Failed to open state_graph.dot");
        defer graphviz.close();

        graphviz.seekFromEnd(0) catch @panic("Failed to seek in state_graph.dot");

        const allocator = std.heap.page_allocator;
        var content = std.ArrayList(u8).empty;
        defer content.deinit(allocator);

        const info = std.fmt.allocPrint(allocator, "// Last event: {}\n", .{self.event_queue.getLast()}) catch unreachable;
        defer allocator.free(info);
        const name = std.fmt.allocPrint(allocator, "digraph Treadmill{d} {{\n", .{self.stats.allocated_memory}) catch unreachable;
        defer allocator.free(name);

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
            defer allocator.free(ptrToStr);
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
            defer allocator.free(ptrAsStr);
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
            defer allocator.free(ptrAsStr);
            content.appendSlice(allocator, "n") catch unreachable;
            content.appendSlice(allocator, ptrAsStr) catch unreachable;
            content.appendSlice(allocator, " -> ") catch unreachable;
            const nextPtrAsStr = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(next)}) catch unreachable;
            defer allocator.free(nextPtrAsStr);
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
                    defer allocator.free(objPtrAsStr);
                    const fieldPtrAsStr = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(field.?)}) catch unreachable;
                    defer allocator.free(fieldPtrAsStr);

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
        defer allocator.free(bottomAsStr);
        content.appendSlice(allocator, "n") catch unreachable;
        content.appendSlice(allocator, bottomAsStr) catch unreachable;
        content.appendSlice(allocator, "\n") catch unreachable;
        const scan_obj: *GCObject = @fieldParentPtr("node", self.scan);
        content.appendSlice(allocator, "scan -> ") catch unreachable;
        const scanAsStr = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(scan_obj)}) catch unreachable;
        defer allocator.free(scanAsStr);
        content.appendSlice(allocator, "n") catch unreachable;
        content.appendSlice(allocator, scanAsStr) catch unreachable;
        content.appendSlice(allocator, "\n") catch unreachable;
        const top_obj: *GCObject = @fieldParentPtr("node", self.top);
        content.appendSlice(allocator, "top -> ") catch unreachable;
        const topAsStr = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(top_obj)}) catch unreachable;
        defer allocator.free(topAsStr);
        content.appendSlice(allocator, "n") catch unreachable;
        content.appendSlice(allocator, topAsStr) catch unreachable;
        content.appendSlice(allocator, "\n") catch unreachable;
        const free_obj: *GCObject = @fieldParentPtr("node", self.free);
        content.appendSlice(allocator, "free -> ") catch unreachable;
        const freeAsStr = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(free_obj)}) catch unreachable;
        defer allocator.free(freeAsStr);
        content.appendSlice(allocator, "n") catch unreachable;
        content.appendSlice(allocator, freeAsStr) catch unreachable;
        content.appendSlice(allocator, "\n}\n") catch unreachable;

        const concated = content.toOwnedSlice(allocator) catch unreachable;
        defer allocator.free(concated);

        graphviz.writeAll(concated) catch unreachable;
    }
};
