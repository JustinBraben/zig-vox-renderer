const std = @import("std");
const Allocator = std.mem.Allocator;
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const zm = @import("zmath");
const zstbi = @import("zstbi");
const Input = @import("../engine/input.zig");
const Camera = @import("../renderer/camera.zig");

const Player = @This();

const MOVEMENT_SPEED: f32 = 2.5;

camera: Camera,

pub fn init() !Player {
    return .{
        .camera = Camera.init(null),
    };
}

pub fn deinit(self: *Player) void {
    _ = &self;
}

pub fn update(self: *Player, delta_time: f32, input: *Input) !void {
    // Movement
    if (input.isActionHeld(.move_forward)) {
        self.moveForward(delta_time);
    }

    // Camera rotation
    const cursor_delta = input.getCursorDelta();
    self.rotateCamera(cursor_delta);
}

pub fn moveForward(self: *Player, delta_time: f32) void {
    self.camera.processKeyboard(.FORWARD, delta_time);
    // self.camera.position = zm.loadArr3(.{self.camera.position[0], self.camera.position[1], self.camera.position[2] - (delta_time * MOVEMENT_SPEED)});
}

pub fn rotateCamera(self: *Player, cursor_delta: Input.Pos) void {
    self.camera.processMouseMovement(cursor_delta.x, cursor_delta.y, false);
}