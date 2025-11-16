const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const with_gc_stats = b.option(bool, "gc-stats", "Enable garbage collector statistics") orelse false;
    const with_rt_stats = b.option(bool, "rt-stats", "Enable runtime statistics") orelse false;
    const is_stella_debug = b.option(bool, "stella-debug", "Enable Stella debug mode") orelse false;

    const opts = b.addOptions();
    opts.addOption(usize, "MAX_OBJECTS", b.option(usize, "max_objects", "Maximum number of objects in a doubly-linked heap") orelse 1024);

    const library = b.addLibrary(.{
        .name = "streadmilla",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    library.root_module.addOptions("gc_config", opts);
    library.bundle_compiler_rt = true;

    b.installArtifact(library);

    library.linkLibC();

    library.root_module.addIncludePath(b.path("stella/"));

    if (is_stella_debug) {
        library.root_module.addCMacro("STELLA_DEBUG", "1");
    }
    if (with_gc_stats) {
        library.root_module.addCMacro("STELLA_GC_STATS", "1");
    }
    if (with_rt_stats) {
        library.root_module.addCMacro("STELLA_RUNTIME_STATS", "1");
    }

    library.root_module.addCSourceFile(.{ .file = b.path("stella/runtime.c") });
}
