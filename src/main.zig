const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("mach_glfw");
const Allocator = std.mem.Allocator;

const app_name = "mach-glfw + vulkan-zig = triangle";

/// Default GLFW error handling callback
fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    glfw.setErrorCallback(errorCallback);

    if (!glfw.init(.{})) {
        std.log.err("Failed to init GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    var extent = vk.Extent2D {.width = 600, .height = 600};
    extent.width = 800;

    const window = glfw.Window.create(extent.width, extent.height, app_name, null, null, .{
        .client_api = .no_api,
    }) orelse {
        std.log.err("Failed to create window: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    };
    defer window.destroy();

    const allocator = std.heap.page_allocator;
    _ = allocator;
}