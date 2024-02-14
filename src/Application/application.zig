const std = @import("std");
const glfw = @import("mach-glfw");
const vk = @import("vulkan");
const GameWindow = @import("game_window.zig").GameWindow;

const Allocator = std.mem.Allocator;

pub const Application = struct {
    const Self = @This();

    allocator: Allocator,
    window: glfw.Window,

    pub fn init(allocator: Allocator, app_name: [:0]const u8, width: u32, height: u32) !Self {
        if (!glfw.init(.{})) {
            std.log.err("Failed to init GLFW: {?s}", .{glfw.getErrorString()});
            std.process.exit(1);
        }

        const window = glfw.Window.create(width, height, app_name, null, null, .{
            .client_api = .no_api,
        }) orelse {
            std.log.err("Failed to create window: {?s}", .{glfw.getErrorString()});
            return error.GLFWWindowCreationFailed;
        };

        return Self{ 
            .allocator = allocator, 
            .window = window,
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
        _ = self;
    }
};