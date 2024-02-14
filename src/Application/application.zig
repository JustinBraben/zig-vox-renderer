const std = @import("std");
const glfw = @import("mach-glfw");
const vk = @import("vulkan");
const GameWindow = @import("game_window.zig").GameWindow;

const Allocator = std.mem.Allocator;

pub const Application = struct {
    const Self = @This();

    allocator: Allocator,
    game_window: GameWindow,

    pub fn init(allocator: Allocator, app_name: [:0]const u8, width: u32, height: u32) !Self {
        const game_window = try GameWindow.init(allocator, app_name, width, height);

        return Self{ 
            .allocator = allocator, 
            .game_window = game_window,
        };
    }

    pub fn deinit(self: *Application) void {
        self.game_window.deinit();
    }

    pub fn run(self: *Application) void {
        while (!self.game_window.shouldClose()) {
            glfw.pollEvents();
        }
    }

    fn updateAndRender(self: *Application) void {
        _ = self;
    }
};