const std = @import("std");
const glfw = @import("mach-glfw");
const vk = @import("vulkan");
const GameWindow = @import("game_window.zig").GameWindow;

pub const Application = struct {
    game_window: *GameWindow,

    pub fn init(self: *Application) !void {
        var game_window: GameWindow = undefined;
        try game_window.init("Vulkan Engine", 1200, 900);
        self.game_window = &game_window;
    }

    pub fn deinit(self: *Application) void {
        self.game_window.deinit();
    }

    pub fn run(self: *Application) void {
        while (!self.game_window.shouldClose()) {
            self.game_window.pollEvents();
            self.updateAndRender();
        }
    }

    fn updateAndRender(self: *Application) void {
        _ = self;
    }
};