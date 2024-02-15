const std = @import("std");
const Allocator = std.mem.Allocator;
const Window = @import("window.zig").Window;

const log = std.log.scoped(.Application);

pub const Application = struct {
    const Self = @This();

    allocator: Allocator,
    window: Window,

    pub fn init(allocator: Allocator, appName: [:0]const u8, width: u32, height: u32) !Self {
        const window = try Window.init(allocator, appName, width, height);
        return Self{ .allocator = allocator, .window = window };
    }

    pub fn deinit(self: *Self) void {
        self.window.deinit();
    }

    pub fn run(self: *Self) void {
        while (!self.window.shouldClose()){
            self.window.pollEvents();
        }
    }
};