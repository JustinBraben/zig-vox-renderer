//! Dropped items: small spinning blocks that fall, slide to a stop and are picked up
//! when the player walks over them. Stepped at the physics rate; not saved.

const std = @import("std");
const Allocator = std.mem.Allocator;
const block = @import("../world/block.zig");
const Stack = block.Stack;
const sprites = @import("../gfx/sprites.zig");
const Player = @import("../player.zig");
const Inventory = @import("inventory.zig");

const Pos = @Vector(3, f64);

const Self = @This();

/// half the size of the cube drawn
pub const half = 0.125;
const gravity = 20.0;
const terminal_speed = 40.0;
const water_gravity = 4.0;
const water_sink_speed = 1.5;
/// how quickly horizontal sliding stops (1/s) on the ground, in water and in the air
const ground_drag = 8.0;
const water_drag = 3.0;
const air_drag = 0.5;
/// seconds until an item disappears
pub const lifetime = 300;
/// how much farther than the player's box items are picked up from, sideways and vertically
const reach_side = 1.0;
const reach_vertical = 1.0;

pub const Item = struct {
    stack: Stack,
    /// bottom center
    position: Pos,
    prev_position: Pos,
    velocity: Pos,
    /// seconds since it was dropped
    age: f32 = 0,
    /// seconds after dropping before it can be picked up
    pickup_delay: f32,
};

items: std.ArrayList(Item) = .empty,

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.items.deinit(allocator);
}

pub fn spawn(self: *Self, allocator: Allocator, stack: Stack, position: Pos, velocity: Pos, pickup_delay: f32) !void {
    try self.items.append(allocator, .{
        .stack = stack,
        .position = position,
        .prev_position = position,
        .velocity = velocity,
        .pickup_delay = pickup_delay,
    });
}

/// Advances every item one fixed step. `world.isSolid(x, y, z) bool` and
/// `world.isWater(x, y, z) bool` as for the player.
pub fn step(self: *Self, world: anytype, dt: f64) void {
    var i: usize = 0;
    while (i < self.items.items.len) {
        const item = &self.items.items[i];
        item.age += @floatCast(dt);
        if (item.age > lifetime) {
            _ = self.items.swapRemove(i);
            continue;
        }
        move(item, world, dt);
        i += 1;
    }
}

fn move(item: *Item, world: anytype, dt: f64) void {
    item.prev_position = item.position;
    const p = &item.position;
    const v = &item.velocity;
    const cell = floor3(p.* + Pos{ 0, half, 0 });
    // a block placed on top of it pushes it up out of the way
    if (world.isSolid(cell[0], cell[1], cell[2])) {
        p[1] = @as(f64, @floatFromInt(cell[1])) + 1;
        v[1] = 0;
        return;
    }

    const in_water = world.isWater(cell[0], cell[1], cell[2]);
    if (in_water) {
        v[1] = @max(v[1] - water_gravity * dt, -water_sink_speed);
    } else {
        v[1] = @max(v[1] - gravity * dt, -terminal_speed);
    }

    // vertical first, so sideways movement knows whether it is on the ground
    var on_ground = false;
    const new_y = p[1] + v[1] * dt;
    const x = cell[0];
    const z = cell[2];
    if (v[1] < 0 and world.isSolid(x, floorInt(new_y), z)) {
        p[1] = @floor(new_y) + 1;
        v[1] = 0;
        on_ground = true;
    } else if (v[1] > 0 and world.isSolid(x, floorInt(new_y + 2 * half), z)) {
        p[1] = @floor(new_y + 2 * half) - 2 * half;
        v[1] = 0;
    } else {
        p[1] = new_y;
        on_ground = v[1] == 0 and world.isSolid(x, floorInt(p[1] - 0.01), z);
    }

    const drag: f64 = if (on_ground) ground_drag else if (in_water) water_drag else air_drag;
    const keep = @exp(-drag * dt);
    const y = floorInt(p[1] + 0.01);
    inline for (.{ 0, 2 }) |axis| {
        v[axis] *= keep;
        const next = p[axis] + v[axis] * dt;
        const edge = next + std.math.sign(v[axis]) * @as(f64, half);
        var probe = cell;
        probe[axis] = floorInt(edge);
        probe[1] = y;
        if (world.isSolid(probe[0], probe[1], probe[2])) {
            v[axis] = 0;
        } else {
            p[axis] = next;
        }
    }
}

/// Moves the items within reach of `player` into `inventory`, as many as fit; returns
/// how many blocks were picked up.
pub fn collect(self: *Self, player: *const Player, inventory: *Inventory) u32 {
    var picked: u32 = 0;
    var i: usize = 0;
    while (i < self.items.items.len) {
        const item = &self.items.items[i];
        if (item.age < item.pickup_delay or !inReach(player, item.position)) {
            i += 1;
            continue;
        }
        const left = inventory.add(item.stack.block, item.stack.count);
        picked += item.stack.count - left;
        if (left == 0) {
            _ = self.items.swapRemove(i);
            continue;
        }
        item.stack.count = left;
        i += 1;
    }
    return picked;
}

fn inReach(player: *const Player, p: Pos) bool {
    const d = p - player.position;
    const side = Player.half_width + reach_side;
    return @abs(d[0]) <= side and @abs(d[2]) <= side and
        d[1] >= -reach_vertical and d[1] <= Player.height + reach_vertical;
}

/// Adds the items to `batch` as cubes relative to `camera`, `alpha` (0..1) of the way
/// from their previous step. `light(item_position) f32` gives each one's brightness.
pub fn draw(self: *const Self, batch: *sprites.Batch, camera: Pos, alpha: f64, light: anytype) void {
    for (self.items.items) |item| {
        const p = item.prev_position + (item.position - item.prev_position) * @as(Pos, @splat(alpha));
        const bob = 0.05 * (1 + @sin(item.age * 2.5));
        const rel: @Vector(3, f32) = @floatCast(p - camera);
        const faces = sprites.Faces.of(item.stack.block).shaded(sprites.face_shade, light.at(p));
        batch.cube(.{ rel[0], rel[1] + half + bob, rel[2] }, half, item.age * 1.2, faces.layers, faces.colors);
    }
}

fn floorInt(v: f64) i32 {
    return @intFromFloat(@floor(v));
}

fn floor3(p: Pos) [3]i32 {
    return .{ floorInt(p[0]), floorInt(p[1]), floorInt(p[2]) };
}

/// Solid below y = 0 and at x >= 2; water at y >= 5 for z >= 10.
const TestWorld = struct {
    pub fn isSolid(_: TestWorld, x: i32, y: i32, _: i32) bool {
        return y < 0 or x >= 2;
    }

    pub fn isWater(_: TestWorld, _: i32, y: i32, z: i32) bool {
        return z >= 10 and y >= 0 and y < 5;
    }
};

const testing = std.testing;

fn simulate(items: *Self, seconds: f64) void {
    const dt = 1.0 / 60.0;
    var t: f64 = 0;
    while (t < seconds) : (t += dt) items.step(TestWorld{}, dt);
}

test "falls, lands and slides to a stop" {
    var items: Self = .{};
    defer items.deinit(testing.allocator);
    try items.spawn(testing.allocator, .{ .block = .dirt, .count = 1 }, .{ 0.5, 3, 0.5 }, .{ 0, 2, -3 }, 0);
    simulate(&items, 3);
    const item = items.items.items[0];
    try testing.expectEqual(0, item.position[1]);
    try testing.expectApproxEqAbs(0, item.velocity[2], 1e-3);
    try testing.expect(item.position[2] < 0);
}

test "a wall stops it" {
    var items: Self = .{};
    defer items.deinit(testing.allocator);
    try items.spawn(testing.allocator, .{ .block = .dirt, .count = 1 }, .{ 0.5, 0, 0.5 }, .{ 10, 0, 0 }, 0);
    simulate(&items, 1);
    try testing.expect(items.items.items[0].position[0] <= 2 - half);
}

test "sinks slowly in water" {
    var items: Self = .{};
    defer items.deinit(testing.allocator);
    try items.spawn(testing.allocator, .{ .block = .dirt, .count = 1 }, .{ 0.5, 4.5, 10.5 }, .{ 0, 0, 0 }, 0);
    simulate(&items, 1);
    try testing.expect(items.items.items[0].position[1] > 4.5 - water_sink_speed - 0.01);
    try testing.expect(items.items.items[0].velocity[1] >= -water_sink_speed);
}

test "is pushed up out of a block placed on it" {
    const Walled = struct {
        pub fn isSolid(_: @This(), _: i32, y: i32, _: i32) bool {
            return y < 1;
        }
        pub fn isWater(_: @This(), _: i32, _: i32, _: i32) bool {
            return false;
        }
    };
    var items: Self = .{};
    defer items.deinit(testing.allocator);
    try items.spawn(testing.allocator, .{ .block = .dirt, .count = 1 }, .{ 0.5, 0, 0.5 }, .{ 0, 0, 0 }, 0);
    items.step(Walled{}, 1.0 / 60.0);
    try testing.expectEqual(1, items.items.items[0].position[1]);
}

test "picked up after the delay, partly when the inventory is nearly full" {
    var items: Self = .{};
    defer items.deinit(testing.allocator);
    var inv: Inventory = .{};
    for (0..Inventory.size - 1) |_| _ = inv.add(.stone, 64);
    _ = inv.add(.sand, 60);
    const player = Player.init(.{ 0.5, 0, 0.5 });
    try items.spawn(testing.allocator, .{ .block = .sand, .count = 10 }, .{ 1.2, 0, 0.5 }, .{ 0, 0, 0 }, 0.5);
    try items.spawn(testing.allocator, .{ .block = .dirt, .count = 1 }, .{ 5, 0, 0.5 }, .{ 0, 0, 0 }, 0);

    try testing.expectEqual(0, items.collect(&player, &inv));
    simulate(&items, 0.6);
    try testing.expectEqual(4, items.collect(&player, &inv));
    try testing.expectEqual(2, items.items.items.len);
    try testing.expectEqual(6, items.items.items[0].stack.count);
}

test "disappear after their lifetime" {
    var items: Self = .{};
    defer items.deinit(testing.allocator);
    try items.spawn(testing.allocator, .{ .block = .dirt, .count = 1 }, .{ 0.5, 0, 0.5 }, .{ 0, 0, 0 }, 0);
    items.items.items[0].age = lifetime - 0.001;
    items.step(TestWorld{}, 1.0 / 60.0);
    try testing.expectEqual(0, items.items.items.len);
}
