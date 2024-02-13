const std = @import("std");
const glfw = @import("mach-glfw");
const vk = @import("vulkan");

pub const Application = struct {
    window: *glfw.Window,

    /// Default GLFW error handling callback
    fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
        std.log.err("glfw: {}: {s}\n", .{ error_code, description });
    }

    pub fn init(self: *Application) !void {
        glfw.setErrorCallback(errorCallback);

        if (!glfw.init(.{})) {
            std.log.err("Failed to init GLFW: {?s}", .{glfw.getErrorString()});
            std.process.exit(1);
        }

        var extent = vk.Extent2D {.width = 600, .height = 600};
        extent.width = 800;

        const window = glfw.Window.create(extent.width, extent.height, app_name, null, null, .{
            .client_api = .no_api,
        }) orelse {
            std.log.err("Failed to create window: {?s}", .{glfw.getErrorString()});
            std.process.exit(1);
        };
    }

    pub fn deinit(self: *Application) void {
        defer glfw.terminate();
        defer self.window.destroy();
    }

    pub fn run(self: *Application) void {
        while (!self.window.shouldClose()) {
            glfw.pollEvents();
        }
    }

    fn updateAndRender(self: *Application) void {
        
    }
};