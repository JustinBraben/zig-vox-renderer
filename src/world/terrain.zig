//! Deterministic heightmap terrain from seeded value-noise fBm.
//!
//! Every block is a pure function of (seed, world position), so chunks can be
//! generated in any order and their borders always line up.

const std = @import("std");
const chunk = @import("chunk.zig");
const BlockId = @import("block.zig").BlockId;

const Self = @This();

seed: u64,

pub const sea_level = 24;
pub const snow_line = 92;

/// Surface height (y of the top solid block) of the column at (x, z).
pub fn height(self: Self, x: i32, z: i32) i32 {
    const fx: f32 = @floatFromInt(x);
    const fz: f32 = @floatFromInt(z);
    // low-frequency "continent" shape decides where the mountains are
    const continent = self.fbm(fx / 420, fz / 420, 3, 0);
    const detail = self.fbm(fx / 64, fz / 64, 4, 1);
    const mountains = continent * continent * 96;
    return @intFromFloat(@floor(8 + mountains + detail * 24));
}

/// Surface heights of one chunk column; shared by every chunk stacked in it.
pub const Heightmap = struct {
    heights: [chunk.size][chunk.size]i32,
    min: i32,
    max: i32,
};

pub fn heightmap(self: Self, column_x: i32, column_z: i32, map: *Heightmap) void {
    map.min = std.math.maxInt(i32);
    map.max = std.math.minInt(i32);
    for (0..chunk.size) |z| {
        for (0..chunk.size) |x| {
            const h = self.height(column_x * chunk.size + @as(i32, @intCast(x)), column_z * chunk.size + @as(i32, @intCast(z)));
            map.heights[z][x] = h;
            map.min = @min(map.min, h);
            map.max = @max(map.max, h);
        }
    }
}

pub const Content = union(enum) {
    /// every block is this one
    uniform: BlockId,
    /// needs `fill`
    mixed,
};

/// What the chunk at height `chunk_y` of `map`'s column contains, without generating it.
pub fn classify(chunk_y: i32, map: *const Heightmap) Content {
    const y0 = chunk_y * chunk.size;
    if (y0 > map.max) return .{ .uniform = .air };
    // blocks at least `stone_depth` below the surface are always stone
    if (y0 + chunk.size - 1 <= map.min - stone_depth) return .{ .uniform = .stone };
    return .mixed;
}

/// Fills `blocks` for the chunk at height `chunk_y` of `map`'s column.
pub fn fill(chunk_y: i32, map: *const Heightmap, blocks: *chunk.Blocks) void {
    const y0 = chunk_y * chunk.size;
    for (0..chunk.size) |y| {
        const wy = y0 + @as(i32, @intCast(y));
        for (0..chunk.size) |z| {
            for (0..chunk.size) |x| {
                blocks[chunk.index(x, y, z)] = blockAt(wy, map.heights[z][x]);
            }
        }
    }
}

pub fn block(self: Self, x: i32, y: i32, z: i32) BlockId {
    return blockAt(y, self.height(x, z));
}

const stone_depth = 6;

fn blockAt(y: i32, surface: i32) BlockId {
    if (y > surface) return .air;
    const beach = surface <= sea_level + 1;
    if (y == surface) {
        if (beach) return .sand;
        if (surface >= snow_line) return .snow;
        if (surface >= snow_line - 6) return .stone;
        return .grass;
    }
    if (y > surface - 4) return if (beach) .sand else .dirt;
    if (y > surface - stone_depth and beach) return .gravel;
    return .stone;
}

/// Fractal Brownian motion over value noise, normalized to [0, 1).
fn fbm(self: Self, x: f32, z: f32, octaves: u32, salt: u64) f32 {
    var sum: f32 = 0;
    var amplitude: f32 = 1;
    var total: f32 = 0;
    var frequency: f32 = 1;
    for (0..octaves) |octave| {
        sum += amplitude * self.valueNoise(x * frequency, z * frequency, salt *% 31 +% octave);
        total += amplitude;
        amplitude *= 0.5;
        frequency *= 2;
    }
    return sum / total;
}

fn valueNoise(self: Self, x: f32, z: f32, salt: u64) f32 {
    const x0 = @floor(x);
    const z0 = @floor(z);
    const ix: i64 = @intFromFloat(x0);
    const iz: i64 = @intFromFloat(z0);
    const tx = smooth(x - x0);
    const tz = smooth(z - z0);
    const a = self.lattice(ix, iz, salt);
    const b = self.lattice(ix + 1, iz, salt);
    const c = self.lattice(ix, iz + 1, salt);
    const d = self.lattice(ix + 1, iz + 1, salt);
    return std.math.lerp(std.math.lerp(a, b, tx), std.math.lerp(c, d, tx), tz);
}

fn smooth(t: f32) f32 {
    return t * t * (3 - 2 * t);
}

/// Hash of a lattice point to [0, 1).
fn lattice(self: Self, x: i64, z: i64, salt: u64) f32 {
    var h: u64 = self.seed ^ (salt *% 0x9e3779b97f4a7c15);
    h ^= @as(u64, @bitCast(x)) *% 0xbf58476d1ce4e5b9;
    h = std.math.rotl(u64, h, 31);
    h ^= @as(u64, @bitCast(z)) *% 0x94d049bb133111eb;
    // splitmix64 finalizer
    h ^= h >> 30;
    h *%= 0xbf58476d1ce4e5b9;
    h ^= h >> 27;
    h *%= 0x94d049bb133111eb;
    h ^= h >> 31;
    return @as(f32, @floatFromInt(h >> 40)) / @as(f32, 1 << 24);
}

test "terrain is deterministic and in range" {
    const a: Self = .{ .seed = 1234 };
    const b: Self = .{ .seed = 1234 };
    const other: Self = .{ .seed = 99 };
    var differs = false;
    var x: i32 = -500;
    while (x < 500) : (x += 37) {
        const h = a.height(x, x * 3);
        try std.testing.expectEqual(h, b.height(x, x * 3));
        try std.testing.expect(h >= 0 and h < 140);
        if (h != other.height(x, x * 3)) differs = true;
    }
    try std.testing.expect(differs);
}

test "generated chunks match the per-block function across borders" {
    const terrain: Self = .{ .seed = 7 };
    const blocks = try std.testing.allocator.create(chunk.Blocks);
    defer std.testing.allocator.destroy(blocks);

    const pos: chunk.ChunkPos = .{ .x = -1, .y = 0, .z = 2 };
    var map: Heightmap = undefined;
    terrain.heightmap(pos.x, pos.z, &map);
    try std.testing.expectEqual(Content.mixed, classify(pos.y, &map));
    fill(pos.y, &map, blocks);
    for ([_]usize{ 0, 31 }) |x| {
        for (0..chunk.size) |y| {
            for ([_]usize{ 0, 31 }) |z| {
                const expected = terrain.block(pos.x * 32 + @as(i32, @intCast(x)), @intCast(y), pos.z * 32 + @as(i32, @intCast(z)));
                try std.testing.expectEqual(expected, blocks[chunk.index(x, y, z)]);
            }
        }
    }

    // far above the terrain is empty
    try std.testing.expectEqual(Content{ .uniform = .air }, classify(10, &map));
}

test "uniform chunks really are uniform" {
    const terrain: Self = .{ .seed = 7 };
    const blocks = try std.testing.allocator.create(chunk.Blocks);
    defer std.testing.allocator.destroy(blocks);

    var found_stone = false;
    var cx: i32 = -6;
    while (cx <= 6) : (cx += 1) {
        var map: Heightmap = undefined;
        terrain.heightmap(cx, cx * 2, &map);
        var cy: i32 = -2;
        while (cy <= 4) : (cy += 1) {
            const content = classify(cy, &map);
            if (content != .uniform) continue;
            if (content.uniform == .stone) found_stone = true;
            fill(cy, &map, blocks);
            for (blocks) |b| try std.testing.expectEqual(content.uniform, b);
        }
    }
    try std.testing.expect(found_stone);
}
