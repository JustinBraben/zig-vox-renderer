const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // dvui with our own (custom) backend; the Vulkan renderer is exposed as a separate module.
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .custom,
        .renderer = .vulkan,
        .libc = true,
        .@"stb-image" = true,
        .freetype = false,
        .@"tree-sitter" = false,
    });
    const dvui_mod = dvui_dep.module("dvui");
    const vk_renderer_mod = dvui_dep.module("dvui_vulkan_renderer");

    // SDL3 built from source
    const sdl3_dep = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    });
    const sdl3_lib = sdl3_dep.artifact("SDL3");

    const sdl_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/sdl3-c.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_translate_c.addIncludePath(sdl3_lib.getEmittedIncludeTree());
    const sdl_c_mod = sdl_translate_c.createModule();
    sdl_c_mod.linkLibrary(sdl3_lib);

    // custom dvui backend: SDL3 for platform/events, dvui's Vulkan renderer for drawing
    const backend_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/dvui_sdl_vk_backend.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dvui", .module = dvui_mod },
            .{ .name = "dvui_vulkan_renderer", .module = vk_renderer_mod },
            .{ .name = "sdl3-c", .module = sdl_c_mod },
        },
    });
    dvui_mod.addImport("backend", backend_mod);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dvui", .module = dvui_mod },
            .{ .name = "dvui_vulkan_renderer", .module = vk_renderer_mod },
            .{ .name = "sdl3-c", .module = sdl_c_mod },
            .{ .name = "sdl_vk_backend", .module = backend_mod },
        },
    });
    addShader(b, exe_mod, "triangle_vert", "src/shaders/triangle.vert");
    addShader(b, exe_mod, "triangle_frag", "src/shaders/triangle.frag");

    const exe = b.addExecutable(.{
        .name = "zig_vox_renderer",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

/// Compiles a GLSL shader to SPIR-V with glslc (from the Vulkan SDK) and makes it
/// available to `module` as `@embedFile(import_name)`.
fn addShader(b: *std.Build, module: *std.Build.Module, import_name: []const u8, source: []const u8) void {
    const glslc = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.3" });
    if (module.optimize != .Debug) glslc.addArg("-O") else glslc.addArg("-g");
    glslc.addArg("-o");
    const spv = glslc.addOutputFileArg(b.fmt("{s}.spv", .{import_name}));
    glslc.addFileArg(b.path(source));
    module.addAnonymousImport(import_name, .{ .root_source_file = spv });
}
