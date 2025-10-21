const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const library = b.addLibrary(.{
        .name = "streadmilla",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .link_libc = true,
        }),
    });

    b.installArtifact(library);

    library.root_module.addIncludePath(b.path("stella/"));
    library.root_module.addCSourceFile(.{ .file = b.path("stella/runtime.c") });
    // library.root_module.addCSourceFile(.{ .file = b.path("stella/gc.c") });
}
