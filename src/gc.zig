const std = @import("std");
const mem = std.mem;

pub const List = std.array_list.Managed;

pub const GCEnv = struct {
    memory: []u8,
    roots: List(**void),
    next_free: usize,

    /// Initialize a new garbage collector environment.
    pub fn init(buffer: []u8, roots: List(**void)) !GCEnv {
        return GCEnv{
            .memory = buffer,
            .roots = roots,
            .next_free = 0,
        };
    }

    /// Simple bump‑allocation from the internal buffer.
    pub fn alloc(self: *GCEnv, size: usize) ![]u8 {
        // TODO: align
        const start = std.mem.alignForward(usize, self.next_free, 8);
        if (start + size > self.memory.len) return error.OutOfMemory;
        self.next_free = start + size;
        return self.memory[start..][0..size];
    }
};

// pub fn get_env(env: ?*GCEnv) !*GCEnv {
//     if (env) |e| {
//         return e;
//     } else {
//         const allocator = std.heap.page_allocator;
//         const buffer = try allocator.alloc(u8, 1024 * 1024);
//         const roots = List(**void).init(allocator);
//         const new_env = try GCEnv.init(buffer, roots);
//         return &new_env;
//     }
// }
