const std = @import("std");
const Application = @import("../Application/application.zig").Application;
const Allocator = std.mem.Allocator;

pub const Scene = struct {
    const Self = @This();

    allocator: Allocator,

    z_near: f32 = 0.1,
    z_far: f32 = 1000.0,
    delta_time: f32,

    is_menu_open: bool,
    show_intermediate_textures: bool,

    pub fn init() !Self {
        return Self{
            .allocator = std.heap.allocator,
            .is_menu_open = false,
            .show_intermediate_textures = false,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        std.debug.print("Deinitializing scene\n");
    }
};