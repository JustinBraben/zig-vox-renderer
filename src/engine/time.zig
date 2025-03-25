const std = @import("std");
const Allocator = std.mem.Allocator;
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const Window = @import("window.zig");

const Time = @This();
current_frame: f32,
last_frame: f32 = 0.0,
delta_time: f32 = 0.0,

pub fn init() Time {
    return .{
        .current_frame = @floatCast(glfw.getTime())
    };
}

pub fn updateDeltaTime(self: *Time) void {
    self.current_frame = @floatCast(glfw.getTime());
    self.delta_time = self.current_frame - self.last_frame;
    self.last_frame = self.current_frame;
}