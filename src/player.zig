//! The player: an axis-aligned box with gravity, jumping, swimming and block collision,
//! or a collision-free flying camera. Stepped at a fixed rate; `eye` interpolates
//! between the last two steps for rendering.

const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Pos = @Vector(3, f64);

const Self = @This();

pub const half_width = 0.3;
pub const height = 1.8;
pub const eye_height = 1.62;

/// blocks per second (squared)
const walk_speed = 4.3;
const sprint_speed = 5.6;
const gravity = 28.0;
const jump_speed = 8.5;
const terminal_speed = 60.0;
/// how quickly horizontal velocity reaches the target (1/s)
const ground_accel = 20.0;
const air_accel = 4.0;
const water_accel = 8.0;
/// in water: horizontal speed factor, gravity, and sinking / swimming up speeds
const swim_factor = 0.55;
const water_gravity = 6.0;
const sink_speed = 3.0;
const swim_up_speed = 4.0;
const swim_up_accel = 30.0;

/// Movement intent for one step; axes are -1..1.
pub const Input = struct {
    forward: f32 = 0,
    right: f32 = 0,
    /// fly up / down
    up: f32 = 0,
    /// jump, or swim up in water
    jump: bool = false,
    sprint: bool = false,
    /// flying speed in blocks per second
    fly_speed: f32 = 24,
};

/// feet: center of the bottom of the box
position: Pos,
prev_position: Pos,
velocity: Pos = .{ 0, 0, 0 },
on_ground: bool = false,
/// some of the body is in water (as of the last step)
in_water: bool = false,
flying: bool = false,

pub fn init(position: Pos) Self {
    return .{ .position = position, .prev_position = position };
}

/// Advances one fixed step. `world.isSolid(x, y, z) bool` decides what blocks movement,
/// `world.isWater(x, y, z) bool` where the player swims.
pub fn step(self: *Self, world: anytype, input: Input, yaw: f32, pitch: f32, dt: f64) void {
    self.prev_position = self.position;
    if (self.flying) return self.fly(input, yaw, pitch, dt);
    self.in_water = touchesWater(world, self.position);

    // horizontal movement only follows the yaw, so looking down doesn't slow you down
    const forward = math.fromDirection(yaw, 0);
    const right = math.normalize(math.cross(forward, .{ 0, 1, 0 }));
    var wish = math.scale(forward, input.forward) + math.scale(right, input.right);
    if (math.length(wish) > 0) wish = math.normalize(wish);
    var speed: f64 = if (input.sprint) sprint_speed else walk_speed;
    if (self.in_water) speed *= swim_factor;
    const accel: f64 = if (self.in_water) water_accel else if (self.on_ground) ground_accel else air_accel;
    const blend = 1 - @exp(-accel * dt);
    inline for (.{ 0, 2 }) |axis| {
        const target = @as(f64, wish[axis]) * speed;
        self.velocity[axis] += (target - self.velocity[axis]) * blend;
    }

    if (self.in_water) {
        // sink slowly; holding jump swims up
        self.velocity[1] = @max(self.velocity[1] - water_gravity * dt, -sink_speed);
        if (input.jump) self.velocity[1] = @min(self.velocity[1] + swim_up_accel * dt, swim_up_speed);
    } else {
        if (input.jump and self.on_ground) self.velocity[1] = jump_speed;
        self.velocity[1] = @max(self.velocity[1] - gravity * dt, -terminal_speed);
    }

    // one axis at a time, so blocked movement slides along walls
    self.on_ground = false;
    inline for (.{ 1, 0, 2 }) |axis| self.moveAxis(world, axis, self.velocity[axis] * dt);
}

/// Camera position, interpolated `alpha` (0..1) of the way from the previous step.
pub fn eye(self: *const Self, alpha: f64) Pos {
    const p = self.prev_position + (self.position - self.prev_position) * @as(Pos, @splat(alpha));
    return p + Pos{ 0, eye_height, 0 };
}

/// Whether the block at (x, y, z) overlaps the player's box.
pub fn intersectsBlock(self: *const Self, x: i32, y: i32, z: i32) bool {
    const b = bounds(self.position);
    const cell = [3]f64{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
    inline for (0..3) |i| {
        if (b.max[i] <= cell[i] or b.min[i] >= cell[i] + 1) return false;
    }
    return true;
}

pub fn setFlying(self: *Self, flying: bool) void {
    self.flying = flying;
    self.on_ground = false;
}

fn fly(self: *Self, input: Input, yaw: f32, pitch: f32, dt: f64) void {
    const forward = math.fromDirection(yaw, pitch);
    const right = math.normalize(math.cross(forward, .{ 0, 1, 0 }));
    const dir = math.scale(forward, input.forward) + math.scale(right, input.right) + Vec3{ 0, input.up, 0 };
    if (math.length(dir) == 0) {
        self.velocity = .{ 0, 0, 0 };
        return;
    }
    const speed = input.fly_speed * @as(f32, if (input.sprint) 4 else 1);
    self.velocity = @floatCast(math.scale(math.normalize(dir), speed));
    self.position += self.velocity * @as(Pos, @splat(dt));
}

/// Whether the water reaches the feet or the middle of the body at `p`.
fn touchesWater(world: anytype, p: Pos) bool {
    const x: i32 = @intFromFloat(@floor(p[0]));
    const z: i32 = @intFromFloat(@floor(p[2]));
    inline for (.{ 0.1, height / 2.0 }) |dy| {
        if (world.isWater(x, @intFromFloat(@floor(p[1] + dy)), z)) return true;
    }
    return false;
}

const Box = struct { min: Pos, max: Pos };

fn bounds(p: Pos) Box {
    return .{
        .min = .{ p[0] - half_width, p[1], p[2] - half_width },
        .max = .{ p[0] + half_width, p[1] + height, p[2] + half_width },
    };
}

/// Moves along one axis and pushes back out of any solid block. Steps are short
/// (at most 1 block at terminal speed and 60 Hz), so nothing is skipped over.
fn moveAxis(self: *Self, world: anytype, comptime axis: usize, delta: f64) void {
    if (delta == 0) return;
    self.position[axis] += delta;
    const b = bounds(self.position);

    // blocks overlapping the box; the epsilon keeps flush contact from counting as overlap
    const eps = 1e-6;
    var lo: [3]i32 = undefined;
    var hi: [3]i32 = undefined;
    inline for (0..3) |i| {
        lo[i] = @intFromFloat(@floor(b.min[i] + eps));
        hi[i] = @intFromFloat(@floor(b.max[i] - eps));
    }

    // the blocking cell nearest to where the box came from
    var blocked: ?i32 = null;
    var y = lo[1];
    while (y <= hi[1]) : (y += 1) {
        var z = lo[2];
        while (z <= hi[2]) : (z += 1) {
            var x = lo[0];
            while (x <= hi[0]) : (x += 1) {
                if (!world.isSolid(x, y, z)) continue;
                const c = switch (axis) {
                    0 => x,
                    1 => y,
                    else => z,
                };
                blocked = if (blocked) |prev| (if (delta > 0) @min(prev, c) else @max(prev, c)) else c;
            }
        }
    }

    const cell: f64 = @floatFromInt(blocked orelse return);
    const extent: [2]f64 = if (axis == 1) .{ 0, height } else .{ half_width, half_width };
    if (delta > 0) {
        self.position[axis] = cell - extent[1];
    } else {
        self.position[axis] = cell + 1 + extent[0];
        if (axis == 1) self.on_ground = true;
    }
    self.velocity[axis] = 0;
}

/// Solid below y = 0, a wall at x >= 3 and a ceiling at y >= 4 for z >= 5.
const TestWorld = struct {
    pub fn isSolid(_: TestWorld, x: i32, y: i32, z: i32) bool {
        return y < 0 or x >= 3 or (z >= 5 and y >= 4);
    }

    pub fn isWater(_: TestWorld, _: i32, _: i32, _: i32) bool {
        return false;
    }
};

/// Solid below y = 0, water from y = 0 up to y = 9.
const PoolWorld = struct {
    pub fn isSolid(_: PoolWorld, _: i32, y: i32, _: i32) bool {
        return y < 0;
    }

    pub fn isWater(_: PoolWorld, _: i32, y: i32, _: i32) bool {
        return y >= 0 and y < 10;
    }
};

fn simulate(p: *Self, input: Input, seconds: f64) void {
    const dt = 1.0 / 60.0;
    var t: f64 = 0;
    while (t < seconds) : (t += dt) p.step(TestWorld{}, input, 0, 0, dt);
}

test "falls and lands on the floor" {
    var p = Self.init(.{ 0.5, 10, 0.5 });
    simulate(&p, .{}, 2);
    try std.testing.expectEqual(@as(f64, 0), p.position[1]);
    try std.testing.expect(p.on_ground);
    try std.testing.expectEqual(@as(f64, 0), p.velocity[1]);
}

test "a wall stops walking" {
    var p = Self.init(.{ 0.5, 0, 0.5 });
    // yaw 90 faces +X
    const dt = 1.0 / 60.0;
    for (0..180) |_| p.step(TestWorld{}, .{ .forward = 1 }, 90, 0, dt);
    try std.testing.expectApproxEqAbs(@as(f64, 3 - half_width), p.position[0], 1e-9);
    try std.testing.expect(p.on_ground);
}

test "jumps only from the ground, about 1.25 blocks high" {
    var p = Self.init(.{ 0.5, 0, 0.5 });
    simulate(&p, .{}, 0.1);
    try std.testing.expect(p.on_ground);

    const dt = 1.0 / 60.0;
    var peak: f64 = 0;
    p.step(TestWorld{}, .{ .jump = true }, 0, 0, dt);
    for (0..60) |_| {
        // holding jump in the air does nothing
        p.step(TestWorld{}, .{ .jump = true }, 0, 0, dt);
        peak = @max(peak, p.position[1]);
        if (p.on_ground) break;
    }
    try std.testing.expect(peak > 1.1 and peak < 1.4);
}

test "bumps its head on a ceiling" {
    // ceiling bottom at y = 4; standing on a pillar top at y = 1.5 leaves 0.7 blocks of headroom
    var p = Self.init(.{ 0.5, 2, 5.5 });
    p.on_ground = true;
    p.step(TestWorld{}, .{ .jump = true }, 0, 0, 1.0 / 60.0);
    simulate(&p, .{}, 0.3);
    try std.testing.expect(p.position[1] + height <= 4);
}

test "block intersection" {
    const p = Self.init(.{ 0.5, 0, 0.5 });
    try std.testing.expect(p.intersectsBlock(0, 0, 0));
    try std.testing.expect(p.intersectsBlock(0, 1, 0));
    try std.testing.expect(!p.intersectsBlock(0, 2, 0));
    try std.testing.expect(!p.intersectsBlock(1, 0, 0));
    try std.testing.expect(!p.intersectsBlock(0, -1, 0));
}

test "sinks slowly in water and swims up while jump is held" {
    const dt = 1.0 / 60.0;
    var p = Self.init(.{ 0.5, 6, 0.5 });
    for (0..30) |_| {
        p.step(PoolWorld{}, .{}, 0, 0, dt);
        try std.testing.expect(p.velocity[1] >= -sink_speed);
    }
    try std.testing.expect(p.in_water);
    const sunk = p.position[1];
    try std.testing.expect(sunk < 6 and sunk > 6 - sink_speed * 0.5);

    for (0..60) |_| p.step(PoolWorld{}, .{ .jump = true }, 0, 0, dt);
    try std.testing.expect(p.position[1] > sunk + 1);
}
