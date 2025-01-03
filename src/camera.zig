const std = @import("std");
const math = std.math;
const Utils = @import("utils.zig");
const zm = @import("zmath");

const Camera = @This();

pub const CameraMovement = enum {
    FORWARD,
    BACKWARD,
    LEFT,
    RIGHT,
};

const WORLD_UP = zm.loadArr3(.{0.0, 1.0, 0.0});
const MOVEMENT_SPEED: f32 = 2.5;
const MOUSE_SENSITIVITY: f32 = 0.1;

// Camera attributes
position: zm.F32x4 = zm.loadArr3(.{0.0, 0.0, 0.0}),
front: zm.F32x4 = zm.loadArr3(.{0.0, 0.0, -1.0}),
up: zm.F32x4 = undefined,
right: zm.F32x4 = undefined,

// euler Angles
yaw: f32 = -90,
pitch: f32 = 0.0,

// camera options
zoom: f32 = 45.0,
speed_modifier: f32 = 1.0,

/// Initialize the camera.
/// If null is passed initial position is .{0.0, 0.0, 0.0}
pub fn init(position: ?zm.F32x4) Camera {
    const front = zm.loadArr3(.{0.0, 0.0, -1.0});
    const world_up = zm.loadArr3(.{0.0, 1.0, 0.0});
    const right = zm.normalize3(zm.cross3(front, world_up));
    const up = zm.normalize3(zm.cross3(right, front));

    return .{
        .position = if (position) |val| val else zm.loadArr3(.{0.0, 0.0, 0.0}),
        .right = zm.normalize3(zm.cross3(front, world_up)),
        .up = up,
    };
}

/// returns the view matrix calculated using Euler Angles and the LookAt Matrix
pub fn getViewMatrix(self: *Camera) zm.Mat {
    return zm.lookAtRh(self.position, self.position + self.front, self.up);
}

/// TODO: Implement
pub fn getProjMatrix(self: *Camera) zm.Mat {
    _ = &self;
    return zm.identity(); 
}

/// TODO: Implement
pub fn getProjViewMatrix(self: *Camera) zm.Mat {
    _ = &self;
    return zm.identity(); 
}

/// returns the view position of camera as [3]f32
pub fn getViewPos(self: *Camera) [3]f32 {
    return zm.vecToArr3(self.position);
}

pub fn getFrontPos(self: *Camera) [3]f32 {
    return zm.vecToArr3(self.front);
}

/// processes input received from any keyboard-like input system. 
/// Accepts input parameter in the form of camera defined ENUM (to abstract it from windowing systems)
pub fn processKeyboard(self: *Camera, direction: Camera.CameraMovement, delta_time: f32) void {
    const velocity = zm.f32x4s(MOVEMENT_SPEED * delta_time);
    switch (direction) {   
        .FORWARD => self.position += self.front * velocity * @as(zm.F32x4, @splat(self.speed_modifier)),
        .BACKWARD => self.position -= self.front * velocity * @as(zm.F32x4, @splat(self.speed_modifier)),
        .LEFT => self.position -= self.right * velocity * @as(zm.F32x4, @splat(self.speed_modifier)),
        .RIGHT => self.position += self.right * velocity * @as(zm.F32x4, @splat(self.speed_modifier)),
    }
    // make sure the user stays at the ground level
    // self.position[1] = 0.0;
}

/// Processes input received from a mouse input system. 
/// Expects the offset value in both the x and y direction.
pub fn processMouseMovement(self: *Camera, xoffset: f64, yoffset: f64, constrain_pitch: bool) void {
    const _xoffset = @as(f32, @floatCast(xoffset)) * MOUSE_SENSITIVITY;
    const _yoffset = @as(f32, @floatCast(yoffset)) * MOUSE_SENSITIVITY;

    self.yaw += _xoffset;
    self.pitch += _yoffset;

    // make sure that when pitch is out of bounds, screen doesn't get flipped
    if (constrain_pitch) {
        if (self.pitch > 89.0)
            self.pitch = 89.0;
        if (self.pitch < -89.0)
            self.pitch = -89.0;
    }

    // update Front, Right and Up Vectors using the updated Euler angles
    self.updateCameraVectors();
}

/// Processes input received from a mouse scroll-wheel event. 
/// Only requires input on the vertical wheel-axis
pub fn processMouseScroll(self: *Camera, yoffset: f64) void {
    self.zoom -= @as(f32, @floatCast(yoffset));
    if (self.zoom < 1.0)
        self.zoom = 1.0;
    if (self.zoom > 45.0)
        self.zoom = 45.0;
}

/// Calculates the front vector from the Camera's (updated) Euler Angles
fn updateCameraVectors(self: *Camera) void {
    // calculate the new Front vector
    var front: zm.F32x4 = undefined;
    front[0] = @cos(math.degreesToRadians(self.yaw)) * @cos(math.degreesToRadians(self.pitch));
    front[1] = @sin(math.degreesToRadians(self.pitch));
    front[2] = @sin(math.degreesToRadians(self.yaw)) * @cos(math.degreesToRadians(self.pitch));
    self.front = front;
    // also re-calculate the Right and Up vector
    self.right = zm.normalize3(zm.cross3(self.front, WORLD_UP));  // normalize the vectors, because their length gets closer to 0 the more you look up or down which results in slower movement.
    self.up    = zm.normalize3(zm.cross3(self.right, self.front));
}