const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "mach-glfw-vulkan-example",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const vulkan_dep = b.dependency("vulkan", .{});
    exe.root_module.addImport("vulkan", vulkan_dep.module("vulkan-zig-generated"));

    const glfw_dep = b.dependency("mach_glfw", .{});
    exe.root_module.addImport("mach_glfw", glfw_dep.module("mach-glfw"));

    b.installArtifact(exe);

    const compile_vert_shader = b.addSystemCommand(&.{
        "glslc",
        "shaders/triangle.vert",
        "--target-env=vulkan1.1",
        "-o",
        "shaders/triangle_vert.spv",
    });

    const compile_frag_shader = b.addSystemCommand(&.{
        "glslc",
        "shaders/triangle.frag",
        "--target-env=vulkan1.1",
        "-o",
        "shaders/triangle_frag.spv",
    });

    exe.step.dependOn(&compile_vert_shader.step);
    exe.step.dependOn(&compile_frag_shader.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}