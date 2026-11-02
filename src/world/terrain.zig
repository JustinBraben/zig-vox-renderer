//! Deterministic heightmap terrain from seeded value-noise fBm, with caves carved
//! out of it by 3D gradient noise.
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

/// Surface height (y of the top solid block) of the column at (x, z). Columns below
/// `sea_level` are flooded up to it.
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
    /// highest y caves may carve in each column (`ceilingOf`)
    ceilings: [chunk.size][chunk.size]i32,
    ceiling_max: i32,
};

pub fn heightmap(self: Self, column_x: i32, column_z: i32, map: *Heightmap) void {
    map.x = column_x * chunk.size;
    map.z = column_z * chunk.size;
    map.min = std.math.maxInt(i32);
    map.max = std.math.minInt(i32);
    map.ceiling_max = std.math.minInt(i32);
    // with a one-block border for the neighbors of the edge columns
    var padded: [chunk.size + 2][chunk.size + 2]i32 = undefined;
    for (&padded, 0..) |*row, pz| {
        for (row, 0..) |*h, px| h.* = self.height(map.x + @as(i32, @intCast(px)) - 1, map.z + @as(i32, @intCast(pz)) - 1);
    }
    for (0..chunk.size) |z| {
        for (0..chunk.size) |x| {
            const h = padded[z + 1][x + 1];
            map.heights[z][x] = h;
            map.min = @min(map.min, h);
            map.max = @max(map.max, h);
            const c = ceilingOf(h, .{ padded[z + 1][x], padded[z + 1][x + 2], padded[z][x + 1], padded[z + 2][x + 1] }, self.entrance(map.x + @as(i32, @intCast(x)), map.z + @as(i32, @intCast(z))));
            map.ceilings[z][x] = c;
            map.ceiling_max = @max(map.ceiling_max, c);
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

/// What the chunk at height `chunk_y` of `map`'s column contains, without generating
/// it. Samples the chunk's cave lattice into `caves` for `fill`.
pub fn classify(self: Self, chunk_y: i32, map: *const Heightmap, caves: *Caves) Content {
    const y0 = chunk_y * chunk.size;
    caves.any = false;
    if (y0 > @max(map.top, sea_level)) return .{ .uniform = .air };
    if (y0 + chunk.size > cave_floor and y0 <= map.ceiling_max) self.sampleCaves(map, y0, caves);
    // blocks at least `stone_depth` below the surface are stone, unless a cave runs through
    if (y0 + chunk.size - 1 <= map.min - stone_depth and !caves.any) return .{ .uniform = .stone };
    return .mixed;
}

/// Fills `blocks` for the chunk at height `chunk_y` of `map`'s column, whose caves
/// `classify` sampled.
pub fn fill(self: Self, chunk_y: i32, map: *const Heightmap, caves: *const Caves, blocks: *chunk.Blocks) void {
    const y0 = chunk_y * chunk.size;
    for (0..chunk.size) |y| {
        const wy = y0 + @as(i32, @intCast(y));
        for (0..chunk.size) |z| {
            for (0..chunk.size) |x| {
                blocks[chunk.index(x, y, z)] = blockAt(wy, map.heights[z][x]);
            }
        }
    }
    if (caves.any) carve(y0, map, caves, blocks);

    // trees only grow into air, so a canopy never cuts into a neighboring hillside (or the sea)
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
    if (ground == .water) return ground;
    if (ground != .air and !self.carved(x, y, z)) return ground;
    // the first tree wins, as in `fill`
    var trees: [4]Tree = undefined;
    const count = self.treesNear(x, z, x, z, &trees);
    for (trees[0..count]) |t| {
        if (self.treeBlock(t, x, y, z)) |b| return b;
    }
    return .air;
}

/// A column near (x, z), stepping along +x, whose surface block isn't carved out by a
/// cave: its x, surface height and z.
pub fn spawnColumn(self: Self, x: i32, z: i32) [3]i32 {
    var sx = x;
    while (self.carved(sx, self.height(sx, z), z)) sx += 1;
    return .{ sx, self.height(sx, z), z };
}

/// The top block of a column whose surface height is `surface`.
pub fn surfaceBlock(surface: i32) BlockId {
    return blockAt(surface, surface);
}

const stone_depth = 10;

fn blockAt(y: i32, surface: i32) BlockId {
    if (y > surface) return if (y <= sea_level) .water else .air;
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
    // not over a cave entrance
    if (self.carved(x, surface, z)) return null;
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

/// Caves are carved from `cave_floor` up to a column's ceiling.
pub const cave_floor = 4;
/// Solid ground left above caves under beaches and the sea.
const cave_roof = 4;
/// Solid ground left above caves on dry land away from entrances.
const land_roof = 3;
/// Caves break through the surface where the entrance noise is above this.
const entrance_threshold = 0.62;
/// Spacing of the lattice where the cave density is sampled: `cell` across, `cell_y`
/// up. A chunk has `cells` × `cells_y` × `cells` cells.
const cell = 4;
const cell_y = 8;
const cells = chunk.size / cell;
const cells_y = chunk.size / cell_y;

/// The highest y caves may carve in a column with surface height `surface`, next to
/// columns with surface heights `neighbors`. On dry land caves break through the
/// surface where `open`, and keep a thin roof elsewhere; beaches and the sea floor
/// keep a thicker one, and caves next to the sea stay below the sea floor, so no cave
/// ever opens into water.
fn ceilingOf(surface: i32, neighbors: [4]i32, open: bool) i32 {
    var c = if (surface <= sea_level + 1)
        surface - cave_roof
    else if (open) surface else surface - land_roof;
    for (neighbors) |n| {
        if (n < sea_level) c = @min(c, n);
    }
    return c;
}

/// Whether caves may break through the surface at (x, z): in scattered patches.
fn entrance(self: Self, x: i32, z: i32) bool {
    return self.fbm(@as(f32, @floatFromInt(x)) / 96, @as(f32, @floatFromInt(z)) / 96, 1, 14) > entrance_threshold;
}

/// The highest y caves may carve in the column at (x, z), as in `Heightmap.ceilings`.
fn ceiling(self: Self, x: i32, z: i32) i32 {
    return ceilingOf(self.height(x, z), .{ self.height(x - 1, z), self.height(x + 1, z), self.height(x, z - 1), self.height(x, z + 1) }, self.entrance(x, z));
}

/// Cave density at the lattice points of a chunk, [y][z][x]. Blocks are carved where
/// the density interpolated between the corners of their cell is below 0.
pub const Caves = struct {
    density: [cells_y + 1][cells + 1][cells + 1]f32,
    /// whether any lattice point that can carve is below 0; if not, nothing is carved
    any: bool,
};

/// Samples the cave lattice of the chunk at height `y0` in `map`'s column. Points no
/// carvable block interpolates from are left solid (1) without sampling.
fn sampleCaves(self: Self, map: *const Heightmap, y0: i32, caves: *Caves) void {
    caves.any = false;
    for (0..cells + 1) |lz| {
        for (0..cells + 1) |lx| {
            // the highest ceiling of the columns in the cells around this point
            var reach: i32 = std.math.minInt(i32);
            for (lz * cell -| cell..@min(lz * cell + cell, chunk.size)) |z| {
                for (lx * cell -| cell..@min(lx * cell + cell, chunk.size)) |x| reach = @max(reach, map.ceilings[z][x]);
            }
            const x = map.x + @as(i32, @intCast(lx * cell));
            const z = map.z + @as(i32, @intCast(lz * cell));
            const width = self.tunnelWidth(x, z);
            for (0..cells_y + 1) |ly| {
                const y = y0 + @as(i32, @intCast(ly * cell_y));
                const d = &caves.density[ly][lz][lx];
                // only cells with blocks from the floor up to the ceiling need it
                if (y + cell_y <= cave_floor or y > reach + cell_y) {
                    d.* = 1;
                    continue;
                }
                d.* = self.densityWith(x, y, z, width);
                if (d.* < 0) caves.any = true;
            }
        }
    }
}

/// Carves the caves out of the blocks of the chunk at height `y0` in `map`'s column.
fn carve(y0: i32, map: *const Heightmap, caves: *const Caves, blocks: *chunk.Blocks) void {
    for (0..cells_y) |cy| {
        for (0..cells) |cz| {
            for (0..cells) |cx| {
                var corners: [8]f32 = undefined;
                for (&corners, 0..) |*c, k| c.* = caves.density[cy + (k >> 2)][cz + ((k >> 1) & 1)][cx + (k & 1)];
                // interpolation stays between the corners
                if (std.mem.min(f32, &corners) >= 0) continue;
                for (0..cell_y) |dy| {
                    const y = cy * cell_y + dy;
                    const wy = y0 + @as(i32, @intCast(y));
                    if (wy < cave_floor) continue;
                    for (0..cell) |dz| {
                        const z = cz * cell + dz;
                        for (0..cell) |dx| {
                            const x = cx * cell + dx;
                            // the ceiling is never above the surface, so this is solid ground
                            if (wy > map.ceilings[z][x]) continue;
                            if (interpolate(corners, dx, dy, dz) < 0) blocks[chunk.index(x, y, z)] = .air;
                        }
                    }
                }
            }
        }
    }
}

/// Whether a cave carves out the block at (x, y, z), as `carve` does.
fn carved(self: Self, x: i32, y: i32, z: i32) bool {
    if (y < cave_floor or y > self.ceiling(x, z)) return false;
    const ox = @divFloor(x, cell) * cell;
    const oy = @divFloor(y, cell_y) * cell_y;
    const oz = @divFloor(z, cell) * cell;
    var corners: [8]f32 = undefined;
    for (&corners, 0..) |*c, k| {
        c.* = self.caveDensity(ox + cell * @as(i32, @intCast(k & 1)), oy + cell_y * @as(i32, @intCast(k >> 2)), oz + cell * @as(i32, @intCast((k >> 1) & 1)));
    }
    if (std.mem.min(f32, &corners) >= 0) return false;
    return interpolate(corners, @intCast(x - ox), @intCast(y - oy), @intCast(z - oz)) < 0;
}

/// Trilinear interpolation inside a cell between its `corners` (index x + 2z + 4y), at
/// block offset (dx, dy, dz).
fn interpolate(corners: [8]f32, dx: usize, dy: usize, dz: usize) f32 {
    const tx = @as(f32, @floatFromInt(dx)) / cell;
    const ty = @as(f32, @floatFromInt(dy)) / cell_y;
    const tz = @as(f32, @floatFromInt(dz)) / cell;
    const bottom = std.math.lerp(std.math.lerp(corners[0], corners[1], tx), std.math.lerp(corners[2], corners[3], tx), tz);
    const top = std.math.lerp(std.math.lerp(corners[4], corners[5], tx), std.math.lerp(corners[6], corners[7], tx), tz);
    return std.math.lerp(bottom, top, ty);
}

/// Cave density at a lattice point: winding tunnels where two noise fields are both
/// near zero, and caverns where a third is high, more often deeper down.
fn caveDensity(self: Self, x: i32, y: i32, z: i32) f32 {
    return self.densityWith(x, y, z, self.tunnelWidth(x, z));
}

/// How far from zero the tunnel fields may be, varying slowly across the map.
fn tunnelWidth(self: Self, x: i32, z: i32) f32 {
    return tunnel_width * (0.6 + 0.8 * self.fbm(@as(f32, @floatFromInt(x)) / 160, @as(f32, @floatFromInt(z)) / 160, 1, 13));
}

/// `caveDensity` with the column's `tunnelWidth`.
fn densityWith(self: Self, x: i32, y: i32, z: i32, width: f32) f32 {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const fz: f32 = @floatFromInt(z);
    // squashed vertically, so tunnels mostly run sideways
    const a = self.fbm3(fx / tunnel_scale, fy / (tunnel_scale * 0.6), fz / tunnel_scale, 2, 10);
    const b = self.fbm3(fx / tunnel_scale, fy / (tunnel_scale * 0.6), fz / tunnel_scale, 2, 11);
    const tunnel = @max(@abs(a), @abs(b)) - width;
    const c = self.fbm3(fx / cavern_scale, fy / (cavern_scale * 0.6), fz / cavern_scale, 2, 12);
    const depth = std.math.clamp((cavern_depth - fy) / cavern_depth, 0, 1);
    const cavern = cavern_threshold - cavern_deep_bonus * depth - c;
    return @min(tunnel, cavern);
}

const tunnel_scale = 56;
const tunnel_width = 0.05;
const cavern_scale = 80;
const cavern_threshold = 0.42;
const cavern_deep_bonus = 0.12;
/// caverns are most common from here down
const cavern_depth = 48;

/// Fractal Brownian motion over 3D gradient noise, in about [-1, 1].
fn fbm3(self: Self, x: f32, y: f32, z: f32, octaves: u32, salt: u64) f32 {
    var sum: f32 = 0;
    var amplitude: f32 = 1;
    var total: f32 = 0;
    var frequency: f32 = 1;
    for (0..octaves) |octave| {
        sum += amplitude * self.gradientNoise(x * frequency, y * frequency, z * frequency, salt *% 31 +% octave);
        total += amplitude;
        amplitude *= 0.5;
        frequency *= 2;
    }
    return sum / total;
}

/// Perlin-style gradient noise with the 12 cube edge gradients, in about [-1, 1].
fn gradientNoise(self: Self, x: f32, y: f32, z: f32, salt: u64) f32 {
    const x0 = @floor(x);
    const y0 = @floor(y);
    const z0 = @floor(z);
    const ix: i64 = @intFromFloat(x0);
    const iy: i64 = @intFromFloat(y0);
    const iz: i64 = @intFromFloat(z0);
    const fx = x - x0;
    const fy = y - y0;
    const fz = z - z0;
    var dots: [8]f32 = undefined;
    for (&dots, 0..) |*d, k| {
        const cx: i64 = @intCast(k & 1);
        const cz: i64 = @intCast((k >> 1) & 1);
        const cy: i64 = @intCast(k >> 2);
        const h = self.hash3(ix + cx, iy + cy, iz + cz, salt);
        d.* = gradientDot(h, fx - @as(f32, @floatFromInt(cx)), fy - @as(f32, @floatFromInt(cy)), fz - @as(f32, @floatFromInt(cz)));
    }
    const tx = fade(fx);
    const ty = fade(fy);
    const tz = fade(fz);
    const bottom = std.math.lerp(std.math.lerp(dots[0], dots[1], tx), std.math.lerp(dots[2], dots[3], tx), tz);
    const top = std.math.lerp(std.math.lerp(dots[4], dots[5], tx), std.math.lerp(dots[6], dots[7], tx), tz);
    return std.math.lerp(bottom, top, ty);
}

fn gradientDot(h: u64, x: f32, y: f32, z: f32) f32 {
    return switch (h % 12) {
        0 => x + y,
        1 => -x + y,
        2 => x - y,
        3 => -x - y,
        4 => x + z,
        5 => -x + z,
        6 => x - z,
        7 => -x - z,
        8 => y + z,
        9 => -y + z,
        10 => y - z,
        else => -y - z,
    };
}

/// Quintic fade, smooth in its first and second derivatives.
fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6 - 15) + 10);
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

/// A cheaper hash than `hash` for the many lattice points of 3D noise: one mixing round.
fn hash3(self: Self, x: i64, y: i64, z: i64, salt: u64) u64 {
    var h: u64 = self.seed ^ (salt *% 0x9e3779b97f4a7c15);
    h ^= @as(u64, @bitCast(x)) *% 0xbf58476d1ce4e5b9;
    h ^= @as(u64, @bitCast(y)) *% 0xd6e8feb86659fd93;
    h ^= @as(u64, @bitCast(z)) *% 0x94d049bb133111eb;
    h ^= h >> 32;
    h *%= 0xd6e8feb86659fd93;
    h ^= h >> 32;
    return h;
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
    var caves: Caves = undefined;
    try std.testing.expectEqual(Content.mixed, terrain.classify(pos.y, &map, &caves));
    terrain.fill(pos.y, &map, &caves, blocks);
    for ([_]usize{ 0, 31 }) |x| {
        for (0..chunk.size) |y| {
            for ([_]usize{ 0, 31 }) |z| {
                const expected = terrain.block(pos.x * 32 + @as(i32, @intCast(x)), @intCast(y), pos.z * 32 + @as(i32, @intCast(z)));
                try std.testing.expectEqual(expected, blocks[chunk.index(x, y, z)]);
            }
        }
    }

    // far above the terrain is empty
    try std.testing.expectEqual(Content{ .uniform = .air }, terrain.classify(10, &map, &caves));
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
            var caves: Caves = undefined;
            const content = terrain.classify(cy, &map, &caves);
            if (content != .uniform) continue;
            if (content.uniform == .stone) found_stone = true;
            terrain.fill(cy, &map, &caves, blocks);
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
            var caves: Caves = undefined;
            if (terrain.classify(cy, &map, &caves) != .mixed) continue;
            terrain.fill(cy, &map, &caves, blocks);
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

test "low ground is flooded up to sea level" {
    const terrain: Self = .{ .seed = 7 };
    // find a column under the sea
    var x: i32 = 0;
    while (terrain.height(x, 0) >= sea_level) : (x += 1) {
        if (x > 100_000) return error.SkipZigTest;
    }
    const h = terrain.height(x, 0);
    try std.testing.expectEqual(BlockId.sand, terrain.block(x, h, 0));
    try std.testing.expectEqual(BlockId.water, terrain.block(x, h + 1, 0));
    try std.testing.expectEqual(BlockId.water, terrain.block(x, sea_level, 0));
    try std.testing.expectEqual(BlockId.air, terrain.block(x, sea_level + 1, 0));
}

test "caves run underground, open to the surface in places and never into water" {
    const terrain: Self = .{ .seed = 1337 };
    const blocks = try std.testing.allocator.create(chunk.Blocks);
    defer std.testing.allocator.destroy(blocks);
    var underground: usize = 0;
    var hollow: usize = 0;
    var entrances: usize = 0;
    var cx: i32 = -4;
    while (cx < 4) : (cx += 1) {
        var cz: i32 = -4;
        while (cz < 4) : (cz += 1) {
            var map: Heightmap = undefined;
            terrain.heightmap(cx, cz, &map);
            var cy: i32 = 0;
            while (cy <= 3) : (cy += 1) {
                var caves: Caves = undefined;
                if (terrain.classify(cy, &map, &caves) != .mixed) continue;
                terrain.fill(cy, &map, &caves, blocks);
                for (0..chunk.size) |y| {
                    const wy = cy * chunk.size + @as(i32, @intCast(y));
                    for (0..chunk.size) |z| {
                        for (0..chunk.size) |x| {
                            const b = blocks[chunk.index(x, y, z)];
                            const surface = map.heights[z][x];
                            if (wy <= surface) {
                                underground += 1;
                                if (b == .air) hollow += 1;
                                if (b == .air and wy == surface) entrances += 1;
                            }
                            if (b != .air) continue;
                            // no air next to water inside the chunk
                            if (x > 0) try std.testing.expect(blocks[chunk.index(x - 1, y, z)] != .water);
                            if (x < chunk.size - 1) try std.testing.expect(blocks[chunk.index(x + 1, y, z)] != .water);
                            if (z > 0) try std.testing.expect(blocks[chunk.index(x, y, z - 1)] != .water);
                            if (z < chunk.size - 1) try std.testing.expect(blocks[chunk.index(x, y, z + 1)] != .water);
                            if (y < chunk.size - 1) try std.testing.expect(blocks[chunk.index(x, y + 1, z)] != .water);
                        }
                    }
                }
            }
        }
    }
    // a few percent of the ground is hollow
    try std.testing.expect(hollow * 100 > underground and hollow * 100 < underground * 10);
    try std.testing.expect(entrances > 0);
}

test "carved chunks match the per-block function" {
    const terrain: Self = .{ .seed = 1337 };
    const blocks = try std.testing.allocator.create(chunk.Blocks);
    defer std.testing.allocator.destroy(blocks);
    // the first chunk along +x of the lowest layer that a cave runs through
    var cx: i32 = 0;
    var map: Heightmap = undefined;
    var caves: Caves = undefined;
    while (true) : (cx += 1) {
        terrain.heightmap(cx, 0, &map);
        if (terrain.classify(0, &map, &caves) == .mixed and caves.any) break;
    }
    terrain.fill(0, &map, &caves, blocks);
    var hollow: usize = 0;
    // every other layer and row, to keep the test quick
    var y: usize = 0;
    while (y < chunk.size) : (y += 2) {
        var z: usize = 0;
        while (z < chunk.size) : (z += 2) {
            for (0..chunk.size) |x| {
                const b = blocks[chunk.index(x, y, z)];
                try std.testing.expectEqual(terrain.block(map.x + @as(i32, @intCast(x)), @intCast(y), map.z + @as(i32, @intCast(z))), b);
                if (b == .air and @as(i32, @intCast(y)) < map.heights[z][x]) hollow += 1;
            }
        }
    }
    try std.testing.expect(hollow > 0);
}

test "chunks below the caves stay uniform stone" {
    const terrain: Self = .{ .seed = 1337 };
    var map: Heightmap = undefined;
    terrain.heightmap(0, 0, &map);
    var caves: Caves = undefined;
    try std.testing.expectEqual(Content{ .uniform = .stone }, terrain.classify(-1, &map, &caves));
}

test "spawn is on solid ground" {
    const terrain: Self = .{ .seed = 1337 };
    const x, const h, const z = terrain.spawnColumn(0, 0);
    try std.testing.expect(terrain.block(x, h, z) != .air);
    try std.testing.expectEqual(BlockId.air, terrain.block(x, h + 1, z));
}
