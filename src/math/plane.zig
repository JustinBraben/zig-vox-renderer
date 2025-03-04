const std = @import("std");
const Allocator = std.mem.Allocator;
const zm = @import("zmath");

const Plane = @This();

distance_to_origin: f32,
normal: zm.F32x4 = undefined,

pub const PlaneType = enum(usize) {
    Near = 0,
    Far = 1,
    Left = 2,
    Right = 3,
    Top = 4,
    Bottom = 5,
};

pub fn distanceToPoint(self: *Plane, point: *zm.F32x4) f32 {
    return zm.mulAdd(point, self.normal, self.distance_to_origin);
}