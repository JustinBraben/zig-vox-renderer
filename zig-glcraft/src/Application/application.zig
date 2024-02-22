const std = @import("std");
const Allocator = std.mem.Allocator;
const Scene = @import("../Scene/scene.zig").Scene;
const Window = @import("window.zig").Window;

const log = std.log.scoped(.Application);

pub const Application = struct {
    const Self = @This();

    allocator: Allocator,
    timer: std.time.Timer,
    last_tick: u64,

    window: Window,
    scene: *Scene,

    pub fn init(allocator: Allocator, appName: [:0]const u8, width: u32, height: u32) !Self {
        const window = try Window.init(allocator, appName, width, height);
        var scene = try Scene.init(allocator, "save_path");
        return Self{ 
            .allocator = allocator, 
            .timer = try std.time.Timer.start(),
            .last_tick = 0,
            .window = window, 
            .scene = &scene
        };
    }

    pub fn deinit(self: *Self) void {
        self.window.deinit();
    }

    pub fn run(self: *Self) void {
        self.last_tick = self.timer.lap();
        log.info("first lap of run: {}\n", .{self.last_tick});
        while (!self.window.shouldClose()){
            self.window.pollEvents();
            self.updateAndRender();
        }

        log.info("Window now closing...\n", .{});
    }

    pub fn setScene(self: *Self, scene: *Scene) void {
        self.scene = scene;
    }

    fn updateAndRender(self: *Self) void {
        self.last_tick = self.timer.lap();

        // log.info("lap of updateAndRender: {}\n", .{self.last_tick});
        const delta_time = @as(f32, @floatFromInt(self.last_tick)) / 100_000_000.0;
        self.scene.update(delta_time);

        if (self.window.shouldRender()) {
            // TODO: render scene
            self.window.beginFrame();
            self.scene.render();
            self.window.finalizeFrame();

            // TODO: render GUI

            self.window.swapBuffers();
        }
    }
};