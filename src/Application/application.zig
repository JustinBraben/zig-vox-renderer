const std = @import("std");
const glfw = @import("mach-glfw");
const vk = @import("vulkan");
const Scene = @import("../Scene/scene.zig").Scene;
const GameWindow = @import("game_window.zig").GameWindow;

const Allocator = std.mem.Allocator;

pub const Application = struct {
    const Self = @This();

    allocator: Allocator,
    game_window: GameWindow,
    last_tick: std.time.Timer,

    pub fn init(allocator: Allocator, app_name: [:0]const u8, width: u32, height: u32) !Self {
        const game_window = try GameWindow.init(allocator, app_name, width, height);

        return Self{ 
            .allocator = allocator, 
            .game_window = game_window,
            .last_tick = try std.time.Timer.start(),
        };
    }

    pub fn deinit(self: *Application) void {
        self.game_window.deinit();
    }

    pub fn run(self: *Application) void {
        self.last_tick.reset();
        while (!self.game_window.shouldClose()) {
            self.game_window.pollEvents();
            self.updateAndRender();
        }
    }

    fn updateAndRender(self: *Application) void {
        const delta_time = @as(f32, @floatFromInt(self.last_tick.read()));
        self.last_tick.reset();

        // TODO: Use delta_time for updating the scene
        _ = delta_time;
        //self.scene.update(delta_time);

        if (self.game_window.shouldRender()) {

            // TODO: Render the scene
            self.game_window.beginFrame();
            // self.scene.render();
            self.game_window.finalizeFrame();

            // TODO: Render Gui
            // self.gui.beginFrame();
            // self.scene.renderGui();
            // self.gui.finalizeFrame();

            self.game_window.swapBuffers();
        }
    }
};