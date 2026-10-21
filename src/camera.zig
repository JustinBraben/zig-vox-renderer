//! Free-fly camera. The position is kept in f64 and everything is rendered
//! relative to it, so precision holds up far from the origin.

const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

const Self = @This();

pub const world_up: Vec3 = .{ 0, 1, 0 };
pub const near_plane = 0.05;

position: @Vector(3, f64) = .{ 0, 90, 0 },
/// degrees; 0 looks down -Z, increasing turns towards +X
yaw: f32 = 30,
/// degrees, clamped to +-89
pitch: f32 = -20,

pub fn forward(self: Self) Vec3 {
    return math.fromDirection(self.yaw, self.pitch);
}

pub fn right(self: Self) Vec3 {
    return math.normalize(math.cross(self.forward(), world_up));
}

/// Applies a mouse delta (in pixels).
pub fn look(self: *Self, dx: f32, dy: f32, sensitivity: f32) void {
    self.yaw = @mod(self.yaw + dx * sensitivity, 360);
    self.pitch = std.math.clamp(self.pitch - dy * sensitivity, -89, 89);
}

/// Moves by `amount` along (right, world up, forward).
pub fn move(self: *Self, amount: Vec3) void {
    const delta = math.scale(self.right(), amount[0]) + math.scale(world_up, amount[1]) + math.scale(self.forward(), amount[2]);
    self.position += @as(@Vector(3, f64), @floatCast(delta));
}

/// View matrix with the camera at the origin (camera-relative rendering).
pub fn view(self: Self) Mat4 {
    return Mat4.lookTo(.{ 0, 0, 0 }, self.forward(), world_up);
}

pub fn projection(fov_deg: f32, aspect: f32) Mat4 {
    return Mat4.perspectiveReverseZ(std.math.degreesToRadians(fov_deg), aspect, near_plane);
}

/// `p` relative to the camera, in f32.
pub fn relative(self: Self, p: @Vector(3, f64)) Vec3 {
    return @floatCast(p - self.position);
}
