const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const zm = @import("zmath");

const YAW: f32         =  0.0;
const PITCH: f32       =  0.0;
const SENSITIVITY: f32 =  0.075;
const FOV: f32         =  80.0;

const Camera = @This();

position: zm.F32x4 = undefined,
front: zm.F32x4 = zm.loadArr3(.{0.0, 0.0, -1.0}),
up: zm.F32x4 = zm.loadArr3(.{0.0, 1.0, 0.0}),
right: zm.F32x4 = undefined,
world_up: zm.F32x4 = zm.loadArr3(.{0.0, 1.0, 0.0}),
projection: zm.Mat = undefined,
yaw: f32 = YAW,
pitch: f32 = PITCH,
mouse_sensitivity: f32 = SENSITIVITY,
fov: f32 = FOV,
near_d: f32 = 1.0,
far_d: f32 = 10000.0,
ratio: f32 = undefined,

pub fn init(position: ?zm.F32x4, width: i32, height: i32) Camera {
    const front = zm.loadArr3(.{0.0, 0.0, -1.0});
    const world_up = zm.loadArr3(.{0.0, 1.0, 0.0});
    const right = zm.normalize3(zm.cross3(front, world_up));
    const up = zm.normalize3(zm.cross3(right, front));

    const ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    const projection = zm.perspectiveFovRhGl(math.degreesToRadians(FOV), ratio, 1.0, 10000);

    return .{
        .position = if (position) |val| val else zm.loadArr3(.{0.0, 0.0, 0.0}),
        .right = zm.normalize3(zm.cross3(front, world_up)),
        .up = up,
        .ratio = ratio,
        .projection = projection,
    };
}

pub fn handleResolution(self: *Camera, width: i32, height: i32) void {
    self.ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));

    self.projection = zm.perspectiveFovRhGl(math.degreesToRadians(self.fov), self.ratio, self.near_d, self.far_d);
}

pub fn updatePosition(self: *Camera, pos: zm.F32x4) void {
    self.position = pos;
}

pub fn getViewMatrix(self: *Camera) zm.Mat {
    const intra_voxel_pos = self.position - zm.floor(self.position);
    return zm.lookAtRh(intra_voxel_pos, intra_voxel_pos + self.front, self.up);
}

pub fn processMouseMovement(self: *Camera, xoffset: f64, yoffset: f64) void {
    const _xoffset = @as(f32, @floatCast(xoffset)) * self.mouse_sensitivity;
    const _yoffset = @as(f32, @floatCast(yoffset)) * self.mouse_sensitivity;

    self.yaw += _xoffset;
    self.pitch += _yoffset;

    self.pitch = math.clamp(self.pitch, -89.9, 89.9);

    self.updateVectors();
}

fn updateVectors(self: *Camera) void {
    var f: zm.F32x4 = undefined;
    f[0] = @cos(math.degreesToRadians(self.yaw)) * @cos(math.degreesToRadians(self.pitch));
    f[1] = @sin(math.degreesToRadians(self.pitch));
    f[2] = @sin(math.degreesToRadians(self.yaw)) * @cos(math.degreesToRadians(self.pitch));
    self.front = zm.normalize3(f);
    self.right = zm.normalize3(zm.cross3(self.front, self.world_up));
    self.up = zm.normalize3(zm.cross3(self.right, self.front));
}