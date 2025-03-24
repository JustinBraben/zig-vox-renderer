const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = .{
        .enable_ztracy = b.option(
            bool,
            "enable_ztracy",
            "Enable Tracy profile markers",
        ) orelse false,
        .enable_fibers = b.option(
            bool,
            "enable_fibers",
            "Enable Tracy fiber support",
        ) orelse false,
        .on_demand = b.option(
            bool,
            "on_demand",
            "Build tracy with TRACY_ON_DEMAND",
        ) orelse false,
    };

    const exe = b.addExecutable(.{
        .name = "zig-vox-renderer",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zglfw = b.dependency("zglfw", .{
        .target = target,
    });
    const zopengl = b.dependency("zopengl", .{});
    const zgui = b.dependency("zgui", .{
        .target = target,
        .backend = .glfw_opengl3,
    });
    const zstbi = b.dependency("zstbi", .{});
    const zmath = b.dependency("zmath", .{});
    const znoise = b.dependency("znoise", .{});
    const ztracy = b.dependency("ztracy", .{
        .enable_ztracy = options.enable_ztracy,
        .enable_fibers = options.enable_fibers,
        .on_demand = options.on_demand,
    });

    exe.root_module.addImport("zglfw", zglfw.module("root"));
    exe.linkLibrary(zglfw.artifact("glfw"));
    exe.root_module.addImport("zopengl", zopengl.module("root"));
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));
    exe.root_module.addImport("zstbi", zstbi.module("root"));
    exe.linkLibrary(zstbi.artifact("zstbi"));
    exe.root_module.addImport("zmath", zmath.module("root"));
    exe.root_module.addImport("znoise", znoise.module("root"));
    exe.linkLibrary(znoise.artifact("FastNoiseLite"));
    exe.root_module.addImport("ztracy", ztracy.module("root"));
    exe.linkLibrary(ztracy.artifact("tracy"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .test_runner = .{ 
            .path = b.path("test/test_runner.zig"),
            .mode = .simple,
        },
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.root_module.addImport("zopengl", zopengl.module("root"));
    exe_unit_tests.root_module.addImport("zstbi", zstbi.module("root"));
    exe_unit_tests.linkLibrary(zstbi.artifact("zstbi"));
    exe_unit_tests.root_module.addImport("znoise", znoise.module("root"));
    exe_unit_tests.linkLibrary(znoise.artifact("FastNoiseLite"));
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}