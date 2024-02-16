const std = @import("std");
const Allocator = std.mem.Allocator;
const Scene = @import("../Scene/scene.zig").Scene;
const Window = @import("window.zig").Window;

const log = std.log.scoped(.Application);

pub const Application = struct {
    const Self = @This();

    allocator: Allocator,
    window: Window,
    scene: *Scene,

    pub fn init(allocator: Allocator, appName: [:0]const u8, width: u32, height: u32) !Self {
        const window = try Window.init(allocator, appName, width, height);
        var scene = try Scene.init(allocator, "save_path");
        return Self{ .allocator = allocator, .window = window, .scene = &scene};
    }

    pub fn deinit(self: *Self) void {
        self.window.deinit();
    }

    pub fn run(self: *Self) void {
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
        if (self.window.shouldRender()) {
            self.window.beginFrame();
            // TODO: render scene
            self.scene.render();
            self.window.finalizeFrame();

            // TODO: render GUI

            self.window.swapBuffers();
        }
    }
};