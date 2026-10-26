//! Voxel ray traversal (Amanatides & Woo): walks every block a ray passes through,
//! in order, and reports the first targetable one (see `BlockId.isTargetable`).

const std = @import("std");
const BlockId = @import("block.zig").BlockId;
const math = @import("../math.zig");

pub const Hit = struct {
    block: [3]i32,
    /// outward normal of the face the ray entered through; zero when the ray starts inside the block
    normal: [3]i32,
    id: BlockId,
    distance: f32,

    /// The block on the hit face's side, where a placed block goes.
    pub fn adjacent(self: Hit) [3]i32 {
        return .{ self.block[0] + self.normal[0], self.block[1] + self.normal[1], self.block[2] + self.normal[2] };
    }
};

/// First targetable block along `dir` (normalized) within `max_dist` of `origin`.
/// `world.getBlock(x, y, z) ?BlockId` returning null (not loaded) ends the ray.
pub fn cast(world: anytype, origin: @Vector(3, f64), dir: math.Vec3, max_dist: f32) ?Hit {
    var cell: [3]i32 = undefined;
    var step: [3]i32 = undefined;
    var t_max: [3]f32 = undefined;
    var t_delta: [3]f32 = undefined;
    inline for (0..3) |i| {
        const base = @floor(origin[i]);
        cell[i] = @intFromFloat(base);
        // offset inside the starting block, small enough for f32
        const frac: f32 = @floatCast(origin[i] - base);
        if (dir[i] > 0) {
            step[i] = 1;
            t_delta[i] = 1 / dir[i];
            t_max[i] = (1 - frac) * t_delta[i];
        } else if (dir[i] < 0) {
            step[i] = -1;
            t_delta[i] = -1 / dir[i];
            t_max[i] = frac * t_delta[i];
        } else {
            step[i] = 0;
            t_delta[i] = std.math.inf(f32);
            t_max[i] = std.math.inf(f32);
        }
    }

    var normal: [3]i32 = .{ 0, 0, 0 };
    var distance: f32 = 0;
    while (true) {
        const id = world.getBlock(cell[0], cell[1], cell[2]) orelse return null;
        if (id.isTargetable()) return .{ .block = cell, .normal = normal, .id = id, .distance = distance };

        // advance across the nearest block boundary
        const axis: usize = if (t_max[0] < t_max[1])
            (if (t_max[0] < t_max[2]) 0 else 2)
        else
            (if (t_max[1] < t_max[2]) 1 else 2);
        distance = t_max[axis];
        if (distance > max_dist) return null;
        cell[axis] += step[axis];
        t_max[axis] += t_delta[axis];
        normal = .{ 0, 0, 0 };
        normal[axis] = -step[axis];
    }
}

/// Sparse test world: listed blocks are stone, everything else is air, and
/// blocks with |coordinate| > `loaded` are not loaded.
const TestWorld = struct {
    solid: []const [3]i32,
    loaded: i32 = 100,

    pub fn getBlock(self: TestWorld, x: i32, y: i32, z: i32) ?BlockId {
        if (@max(@abs(x), @abs(y), @abs(z)) > self.loaded) return null;
        for (self.solid) |p| {
            if (p[0] == x and p[1] == y and p[2] == z) return .stone;
        }
        return .air;
    }
};

test "hits the block in front and reports the entry face" {
    const world: TestWorld = .{ .solid = &.{.{ 0, 0, -3 }} };
    const hit = cast(world, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, -1 }, 5).?;
    try std.testing.expectEqual([3]i32{ 0, 0, -3 }, hit.block);
    try std.testing.expectEqual([3]i32{ 0, 0, 1 }, hit.normal);
    try std.testing.expectEqual([3]i32{ 0, 0, -2 }, hit.adjacent());
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), hit.distance, 1e-5);
}

test "crosses chunk borders and negative coordinates" {
    const world: TestWorld = .{ .solid = &.{.{ -33, 4, 0 }} };
    const hit = cast(world, .{ 1.5, 4.5, 0.5 }, .{ -1, 0, 0 }, 40).?;
    try std.testing.expectEqual([3]i32{ -33, 4, 0 }, hit.block);
    try std.testing.expectEqual([3]i32{ 1, 0, 0 }, hit.normal);
}

test "diagonal ray enters through the correct face" {
    // looking down at 45 degrees onto a floor block: enters through its top
    const world: TestWorld = .{ .solid = &.{.{ 2, -1, 0 }} };
    const d = math.normalize(.{ 1, -1, 0 });
    const hit = cast(world, .{ 1.1, 1.5, 0.5 }, d, 10).?;
    try std.testing.expectEqual([3]i32{ 2, -1, 0 }, hit.block);
    try std.testing.expectEqual([3]i32{ 0, 1, 0 }, hit.normal);
}

test "misses beyond the reach and stops at unloaded blocks" {
    const world: TestWorld = .{ .solid = &.{.{ 0, 0, 8 }} };
    try std.testing.expect(cast(world, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, 1 }, 5) == null);
    const unloaded: TestWorld = .{ .solid = &.{.{ 0, 0, 8 }}, .loaded = 4 };
    try std.testing.expect(cast(unloaded, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, 1 }, 20) == null);
}

test "starting inside a block hits it immediately" {
    const world: TestWorld = .{ .solid = &.{.{ 0, 0, 0 }} };
    const hit = cast(world, .{ 0.5, 0.5, 0.5 }, .{ 1, 0, 0 }, 5).?;
    try std.testing.expectEqual([3]i32{ 0, 0, 0 }, hit.block);
    try std.testing.expectEqual([3]i32{ 0, 0, 0 }, hit.normal);
    try std.testing.expectEqual(@as(f32, 0), hit.distance);
}
