const std = @import("std");
const GameWindow = @import("game_window.zig").GameWindow;
const Allocator = std.mem.Allocator;

pub const FirstApp = struct {
    const Self = @This();

    allocator: Allocator,
    width: u32,
    height: u32,
    game_window: GameWindow,

    pub fn init(allocator: Allocator, app_name: [:0]const u8, width: u32, height: u32) !Self {
        return Self {
            .allocator = allocator,
            .width = width,
            .height = height,
            .game_window = try GameWindow.init(allocator, app_name, width, height),
        };
    }

    pub fn deinit(self: *Self) void {
        self.game_window.deinit();
    }

    pub fn run(self: *Self) void {
        while (!self.game_window.shouldClose()) {
            self.game_window.pollEvents();
        }
    }
};