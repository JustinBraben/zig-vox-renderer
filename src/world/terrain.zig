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
    /// world x, z of the column's minimum corner
    x: i32,
    z: i32,
    heights: [chunk.size][chunk.size]i32,
    min: i32,
    max: i32,
    /// every tree with a block in the column, including ones rooted in a neighbor
    trees: [max_column_trees]Tree,
    tree_count: usize,
    /// y of the highest block in the column, trees included
    top: i32,
};

pub fn heightmap(self: Self, column_x: i32, column_z: i32, map: *Heightmap) void {
    map.x = column_x * chunk.size;
    map.z = column_z * chunk.size;
    map.min = std.math.maxInt(i32);
    map.max = std.math.minInt(i32);
    for (0..chunk.size) |z| {
        for (0..chunk.size) |x| {
            const h = self.height(map.x + @as(i32, @intCast(x)), map.z + @as(i32, @intCast(z)));
            map.heights[z][x] = h;
            map.min = @min(map.min, h);
            map.max = @max(map.max, h);
        }
    }
    map.tree_count = self.treesNear(map.x, map.z, map.x + chunk.size - 1, map.z + chunk.size - 1, &map.trees);
    map.top = map.max;
    for (map.trees[0..map.tree_count]) |t| map.top = @max(map.top, t.top());
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
    if (y0 > map.top) return .{ .uniform = .air };
    // blocks at least `stone_depth` below the surface are always stone
    if (y0 + chunk.size - 1 <= map.min - stone_depth) return .{ .uniform = .stone };
    return .mixed;
}

/// Fills `blocks` for the chunk at height `chunk_y` of `map`'s column.
pub fn fill(self: Self, chunk_y: i32, map: *const Heightmap, blocks: *chunk.Blocks) void {
    const y0 = chunk_y * chunk.size;
    for (0..chunk.size) |y| {
        const wy = y0 + @as(i32, @intCast(y));
        for (0..chunk.size) |z| {
            for (0..chunk.size) |x| {
                blocks[chunk.index(x, y, z)] = blockAt(wy, map.heights[z][x]);
            }
        }
    }

    // trees only grow into air, so a canopy never cuts into a neighboring hillside
    const lo: @Vector(3, i32) = .{ map.x, y0, map.z };
    const hi = lo + @as(@Vector(3, i32), @splat(chunk.size - 1));
    for (map.trees[0..map.tree_count]) |t| {
        const t_lo = @max(lo, @Vector(3, i32){ t.x - tree_reach, t.base, t.z - tree_reach });
        const t_hi = @min(hi, @Vector(3, i32){ t.x + tree_reach, t.top(), t.z + tree_reach });
        var wy = t_lo[1];
        while (wy <= t_hi[1]) : (wy += 1) {
            var wz = t_lo[2];
            while (wz <= t_hi[2]) : (wz += 1) {
                var wx = t_lo[0];
                while (wx <= t_hi[0]) : (wx += 1) {
                    const b = self.treeBlock(t, wx, wy, wz) orelse continue;
                    const i = chunk.index(@intCast(wx - lo[0]), @intCast(wy - lo[1]), @intCast(wz - lo[2]));
                    if (blocks[i] == .air) blocks[i] = b;
                }
            }
        }
    }
}

pub fn block(self: Self, x: i32, y: i32, z: i32) BlockId {
    const ground = blockAt(y, self.height(x, z));
    if (ground != .air) return ground;
    // the first tree wins, as in `fill`
    var trees: [4]Tree = undefined;
    const count = self.treesNear(x, z, x, z, &trees);
    for (trees[0..count]) |t| {
        if (self.treeBlock(t, x, y, z)) |b| return b;
    }
    return .air;
}

/// The top block of a column whose surface height is `surface`.
pub fn surfaceBlock(surface: i32) BlockId {
    return blockAt(surface, surface);
}

const stone_depth = 10;

fn blockAt(y: i32, surface: i32) BlockId {
    if (y > surface) return .air;
    const beach = surface <= sea_level + 1;
    if (y == surface) {
        if (beach) return .sand;
        if (surface >= snow_line) return .snow;
        if (surface >= snow_line - stone_depth) return .stone;
        return .grass;
    }
    if (y > surface - 4) return if (beach) .sand else .dirt;
    if (y > surface - stone_depth and beach) return .gravel;
    return .stone;
}

pub const Tree = struct {
    /// trunk column
    x: i32,
    z: i32,
    /// y of the lowest trunk block (one above the surface)
    base: i32,
    /// trunk length; the canopy tops out one block above it
    height: i32,
    kind: Kind,

    pub const Kind = enum { oak, spruce };

    /// y of the highest block
    pub fn top(self: Tree) i32 {
        return self.base + self.height;
    }
};

/// Trees sit on a jittered grid with at most one per `tree_cell`² cell.
const tree_cell = 6;
/// Largest horizontal canopy radius.
const tree_reach = 3;
/// Grass above this tends to grow spruces instead of oaks.
const spruce_line = 54;
/// Upper bound of trees overlapping one column: cells spanned by the column plus reach.
const max_column_trees = blk: {
    const span = (chunk.size + 2 * tree_reach + tree_cell - 2) / tree_cell + 1;
    break :blk span * span;
};

/// Chance in [0, 1) that a tree cell around (x, z) holds a tree: dense forests
/// where the low-frequency forest noise is high, a scattering of trees elsewhere.
pub fn forestCover(self: Self, x: i32, z: i32) f32 {
    const n = self.fbm(@as(f32, @floatFromInt(x)) / 180, @as(f32, @floatFromInt(z)) / 180, 2, 2);
    const t = std.math.clamp((n - 0.45) / 0.2, 0, 1);
    return @max(smooth(t) * 0.8, 0.04);
}

/// The tree of grid cell (cx, cz), if it has one.
fn treeInCell(self: Self, cx: i32, cz: i32) ?Tree {
    const h = self.hash(cx, cz, 3);
    const x = cx * tree_cell + @as(i32, @intCast(h % tree_cell));
    const z = cz * tree_cell + @as(i32, @intCast((h >> 8) % tree_cell));
    const roll = @as(f32, @floatFromInt((h >> 16) & 0xffff)) / (1 << 16);
    if (roll >= self.forestCover(x, z)) return null;
    const surface = self.height(x, z);
    if (surfaceBlock(surface) != .grass) return null;
    // a ragged band where the two kinds mix
    const spruce = surface + @as(i32, @intCast((h >> 32) % 12)) > spruce_line;
    const extra: i32 = @intCast((h >> 40) % 4);
    return .{
        .x = x,
        .z = z,
        .base = surface + 1,
        .height = if (spruce) 6 + extra else 4 + @min(extra, 2),
        .kind = if (spruce) .spruce else .oak,
    };
}

/// Collects every tree that may have a block in the rect [x0, x1] × [z0, z1],
/// in a fixed order (cells by z, then x). Returns the count.
fn treesNear(self: Self, x0: i32, z0: i32, x1: i32, z1: i32, out: []Tree) usize {
    var count: usize = 0;
    var cz = @divFloor(z0 - tree_reach, tree_cell);
    while (cz <= @divFloor(z1 + tree_reach, tree_cell)) : (cz += 1) {
        var cx = @divFloor(x0 - tree_reach, tree_cell);
        while (cx <= @divFloor(x1 + tree_reach, tree_cell)) : (cx += 1) {
            const t = self.treeInCell(cx, cz) orelse continue;
            if (t.x + tree_reach < x0 or t.x - tree_reach > x1 or t.z + tree_reach < z0 or t.z - tree_reach > z1) continue;
            out[count] = t;
            count += 1;
        }
    }
    return count;
}

/// The block tree `t` puts at (x, y, z), if any.
fn treeBlock(self: Self, t: Tree, x: i32, y: i32, z: i32) ?BlockId {
    const dx = x - t.x;
    const dz = z - t.z;
    if (dx == 0 and dz == 0 and y >= t.base and y < t.top()) return .log;
    // layers below the top of the canopy
    const d = t.top() - y;
    if (d < 0) return null;
    switch (t.kind) {
        .oak => {
            if (d > 3) return null;
            const r: i32 = if (d >= 2) 2 else 1;
            if (@abs(dx) > r or @abs(dz) > r) return null;
            // a plus on top, and a rounded blob below with some corners missing
            if (d == 0 and dx != 0 and dz != 0) return null;
            if (r == 2 and @abs(dx) == 2 and @abs(dz) == 2) {
                if (self.hash(x, z, 4 +% @as(u64, @bitCast(@as(i64, y)))) & 1 == 0) return null;
            }
            return .leaves;
        },
        .spruce => {
            if (y < t.base + 2) return null;
            // rings widening downward, every other one pulled in: 0, 1, 1, 2, 1, 3, 2, 3, 2, ...
            const r: i32 = @min(3, @divFloor(d + 1, 2)) - @intFromBool(d >= 4 and @mod(d, 2) == 0);
            if (dx * dx + dz * dz > @max(r * r + r - 1, 0)) return null;
            return .leaves;
        },
    }
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
    return @as(f32, @floatFromInt(self.hash(x, z, salt) >> 40)) / @as(f32, 1 << 24);
}

fn hash(self: Self, x: i64, z: i64, salt: u64) u64 {
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
    return h;
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
    terrain.fill(pos.y, &map, blocks);
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
            terrain.fill(cy, &map, blocks);
            for (blocks) |b| try std.testing.expectEqual(content.uniform, b);
        }
    }
    try std.testing.expect(found_stone);
}

test "trees grow on grass and match the per-block function" {
    const terrain: Self = .{ .seed = 7 };
    const blocks = try std.testing.allocator.create(chunk.Blocks);
    defer std.testing.allocator.destroy(blocks);

    var logs: usize = 0;
    var leaves: usize = 0;
    var cx: i32 = -4;
    while (cx <= 4) : (cx += 1) {
        var map: Heightmap = undefined;
        terrain.heightmap(cx, 3 - cx, &map);
        for (map.trees[0..map.tree_count]) |t| {
            try std.testing.expectEqual(BlockId.grass, terrain.block(t.x, t.base - 1, t.z));
            try std.testing.expect(t.top() <= map.top);
        }
        var cy: i32 = 0;
        while (cy <= 4) : (cy += 1) {
            if (classify(cy, &map) != .mixed) continue;
            terrain.fill(cy, &map, blocks);
            // every block, so canopies crossing the chunk's borders are covered too
            for (0..chunk.size) |y| {
                for (0..chunk.size) |z| {
                    for (0..chunk.size) |x| {
                        const b = blocks[chunk.index(x, y, z)];
                        const wx = map.x + @as(i32, @intCast(x));
                        const wy = cy * chunk.size + @as(i32, @intCast(y));
                        const wz = map.z + @as(i32, @intCast(z));
                        try std.testing.expectEqual(terrain.block(wx, wy, wz), b);
                        if (b == .log) logs += 1;
                        if (b == .leaves) leaves += 1;
                    }
                }
            }
        }
    }
    try std.testing.expect(logs > 0);
    try std.testing.expect(leaves > logs);
}
