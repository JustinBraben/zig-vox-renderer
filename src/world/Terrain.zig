//! Deterministic heightmap terrain from seeded value-noise fBm, down to a bedrock
//! floor at `world_bottom`, with caves carved out of it: winding tunnels
//! (worms.zig) and caverns from 3D gradient noise.
//!
//! Every block is a pure function of (seed, world position), so chunks can be
//! generated in any order and their borders always line up.

const std = @import("std");
const builtin = @import("builtin");
const Chunk = @import("Chunk.zig");
const BlockId = @import("block.zig").BlockId;
const worms = @import("worms.zig");
const Sphere = worms.Sphere;

const Self = @This();

seed: u64,
/// shared cache of tunnel systems, or null to walk them every time
worm_cache: ?*worms.Cache = null,

pub const sea_level = 24;
pub const snow_line = 92;
/// y of the lowest block, always bedrock; nothing is below it.
pub const world_bottom = -64;
/// Bedrock fades out over this many blocks above `world_bottom`.
const bedrock_layers = 5;
/// Stone turns into deepstone below this, mixing over the blocks just under it.
const deepstone_line = 7;

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
    heights: [Chunk.size][Chunk.size]i32,
    min: i32,
    max: i32,
    /// every tree with a block in the column, including ones rooted in a neighbor
    trees: [max_column_trees]Tree,
    tree_count: usize,
    /// y of the highest block in the column, trees included
    top: i32,
    /// highest y caves may carve in each column (`ceilingOf`)
    ceilings: [Chunk.size][Chunk.size]i32,
    ceiling_max: i32,
    /// tunnel spheres overlapping the column
    spheres: [max_spheres]Sphere,
    sphere_count: usize,

    /// The tunnel spheres collected for the column.
    pub fn tunnels(self: *const Heightmap) []const Sphere {
        return self.spheres[0..@min(self.sphere_count, max_spheres)];
    }
};

/// Tunnels are collected this far around a column, so the trees rooted near it can
/// check whether their ground is carved.
const sphere_pad = tree_reach + tree_cell;
const max_spheres = 3072;
const max_padded_spheres = 6144;

pub fn heightmap(self: Self, column_x: i32, column_z: i32, map: *Heightmap) void {
    map.x = column_x * Chunk.size;
    map.z = column_z * Chunk.size;
    map.min = std.math.maxInt(i32);
    map.max = std.math.minInt(i32);
    map.ceiling_max = std.math.minInt(i32);
    // with a one-block border for the neighbors of the edge columns
    var padded: [Chunk.size + 2][Chunk.size + 2]i32 = undefined;
    for (&padded, 0..) |*row, pz| {
        for (row, 0..) |*h, px| h.* = self.height(map.x + @as(i32, @intCast(px)) - 1, map.z + @as(i32, @intCast(pz)) - 1);
    }
    for (0..Chunk.size) |z| {
        for (0..Chunk.size) |x| {
            const h = padded[z + 1][x + 1];
            map.heights[z][x] = h;
            map.min = @min(map.min, h);
            map.max = @max(map.max, h);
            const c = ceilingOf(h, .{ padded[z + 1][x], padded[z + 1][x + 2], padded[z][x + 1], padded[z + 2][x + 1] }, self.entrance(map.x + @as(i32, @intCast(x)), map.z + @as(i32, @intCast(z))));
            map.ceilings[z][x] = c;
            map.ceiling_max = @max(map.ceiling_max, c);
        }
    }
    var padded_spheres: [max_padded_spheres]Sphere = undefined;
    const count = worms.collect(self, map.x - sphere_pad, map.z - sphere_pad, map.x + Chunk.size - 1 + sphere_pad, map.z + Chunk.size - 1 + sphere_pad, &padded_spheres);
    if (builtin.is_test) std.debug.assert(count <= max_padded_spheres);
    const near = padded_spheres[0..@min(count, max_padded_spheres)];
    map.tree_count = self.treesNear(map.x, map.z, map.x + Chunk.size - 1, map.z + Chunk.size - 1, near, &map.trees);
    // only the ones overlapping the column are kept
    const lo = [3]i32{ map.x, std.math.minInt(i32) / 2, map.z };
    const hi = [3]i32{ map.x + Chunk.size - 1, std.math.maxInt(i32) / 2, map.z + Chunk.size - 1 };
    map.sphere_count = 0;
    for (near) |s| {
        if (!s.overlaps(lo, hi)) continue;
        if (map.sphere_count < max_spheres) map.spheres[map.sphere_count] = s;
        map.sphere_count += 1;
    }
    if (builtin.is_test) std.debug.assert(map.sphere_count <= max_spheres);
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
    const y0 = chunk_y * Chunk.size;
    const y1 = y0 + Chunk.size - 1;
    caves.any = false;
    caves.tunnels = false;
    if (y0 > @max(map.top, sea_level)) return .{ .uniform = .air };
    if (y1 < world_bottom) return .{ .uniform = .bedrock };
    if (y1 >= cave_floor and y0 <= map.ceiling_max) {
        self.sampleCaves(map, y0, caves);
        caves.tunnels = tunnelsCross(map, y0);
    }
    // blocks at least `stone_depth` below the surface are stone (deepstone further
    // down), unless a cave or an ore vein runs through
    if (y1 <= map.min - stone_depth and !caves.any and !caves.tunnels) {
        var veins_buffer: [max_veins]Vein = undefined;
        const has_ore = self.veins(@divExact(map.x, Chunk.size), chunk_y, @divExact(map.z, Chunk.size), &veins_buffer) > 0;
        if (!has_ore and y0 >= deepstone_line) return .{ .uniform = .stone };
        if (!has_ore and y1 < 0 and y0 >= world_bottom + bedrock_layers) return .{ .uniform = .deepstone };
    }
    return .mixed;
}

/// Whether a tunnel sphere of `map` may carve a block of the chunk at height `y0`.
fn tunnelsCross(map: *const Heightmap, y0: i32) bool {
    const lo = [3]i32{ map.x, @max(y0, cave_floor), map.z };
    const hi = [3]i32{ map.x + Chunk.size - 1, @min(y0 + Chunk.size - 1, map.ceiling_max), map.z + Chunk.size - 1 };
    if (lo[1] > hi[1]) return false;
    for (map.tunnels()) |s| {
        if (s.overlaps(lo, hi)) return true;
    }
    return false;
}

/// Fills `blocks` for the chunk at height `chunk_y` of `map`'s column, whose caves
/// `classify` sampled.
pub fn fill(self: Self, chunk_y: i32, map: *const Heightmap, caves: *const Caves, blocks: *Chunk.Blocks) void {
    const y0 = chunk_y * Chunk.size;
    for (0..Chunk.size) |y| {
        const wy = y0 + @as(i32, @intCast(y));
        for (0..Chunk.size) |z| {
            for (0..Chunk.size) |x| {
                blocks[Chunk.index(x, y, z)] = self.ground(map.x + @as(i32, @intCast(x)), wy, map.z + @as(i32, @intCast(z)), map.heights[z][x]);
            }
        }
    }
    // before the caves, so they cut through the veins and show them on their walls
    self.placeOres(chunk_y, map, blocks);
    if (caves.any) carve(y0, map, caves, blocks);
    if (caves.tunnels) carveTunnels(y0, map, blocks);

    // trees only grow into air, so a canopy never cuts into a neighboring hillside (or the sea)
    const lo: @Vector(3, i32) = .{ map.x, y0, map.z };
    const hi = lo + @as(@Vector(3, i32), @splat(Chunk.size - 1));
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
                    const i = Chunk.index(@intCast(wx - lo[0]), @intCast(wy - lo[1]), @intCast(wz - lo[2]));
                    if (blocks[i] == .air) blocks[i] = b;
                }
            }
        }
    }
}

/// The generated block at (x, y, z), as `fill` makes it. Slow where caves may be: for
/// physics at the edge of the loaded world, and tests.
pub fn block(self: Self, x: i32, y: i32, z: i32) BlockId {
    return self.blockWith(x, y, z, null);
}

/// `block`, with the tunnel spheres within `sphere_pad` of (x, z) (sideways) if the
/// caller has them, or null to collect them when needed.
fn blockWith(self: Self, x: i32, y: i32, z: i32, spheres: ?[]const Sphere) BlockId {
    var ground_block = self.ground(x, y, z, self.height(x, z));
    if (ground_block == .stone or ground_block == .deepstone) ground_block = self.oreAt(x, y, z) orelse ground_block;
    if (ground_block == .water) return ground_block;
    if (ground_block != .air and !self.carved(x, y, z, spheres)) return ground_block;
    // the first tree wins, as in `fill`
    var trees: [4]Tree = undefined;
    const count = self.treesNear(x, z, x, z, spheres, &trees);
    for (trees[0..count]) |t| {
        if (self.treeBlock(t, x, y, z)) |b| return b;
    }
    return .air;
}

/// A column near (x, z), stepping along +x, whose surface block isn't carved out by a
/// cave: its x, surface height and z.
pub fn spawnColumn(self: Self, x: i32, z: i32) [3]i32 {
    var sx = x;
    while (self.carved(sx, self.height(sx, z), z, null)) sx += 1;
    return .{ sx, self.height(sx, z), z };
}

/// The top block of a column whose surface height is `surface`.
pub fn surfaceBlock(surface: i32) BlockId {
    return blockAt(surface, surface);
}

const stone_depth = 10;

/// The block at (x, y, z) of a column with surface height `surface`, before caves
/// and trees: `blockAt`, with deepstone and bedrock deep down.
fn ground(self: Self, x: i32, y: i32, z: i32, surface: i32) BlockId {
    const b = blockAt(y, surface);
    if (b != .stone or y >= deepstone_line) return b;
    if (y < world_bottom + bedrock_layers) {
        // always at the bottom, thinning out above it
        const above: u64 = @intCast(@max(y - world_bottom, 0));
        if (self.hash3(x, y, z, 20) % bedrock_layers < bedrock_layers - above) return .bedrock;
    }
    if (y < 0) return .deepstone;
    // mixed in with stone, more of it lower down
    const below: u64 = @intCast(deepstone_line - y);
    return if (self.hash3(x, y, z, 21) % (deepstone_line + 1) < below) .deepstone else .stone;
}

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
    const span = (Chunk.size + 2 * tree_reach + tree_cell - 2) / tree_cell + 1;
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
fn treeInCell(self: Self, cx: i32, cz: i32, spheres: ?[]const Sphere) ?Tree {
    const h = self.hash(cx, cz, 3);
    const x = cx * tree_cell + @as(i32, @intCast(h % tree_cell));
    const z = cz * tree_cell + @as(i32, @intCast((h >> 8) % tree_cell));
    const roll = @as(f32, @floatFromInt((h >> 16) & 0xffff)) / (1 << 16);
    if (roll >= self.forestCover(x, z)) return null;
    const surface = self.height(x, z);
    if (surfaceBlock(surface) != .grass) return null;
    // not over a cave entrance
    if (self.carved(x, surface, z, spheres)) return null;
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
/// in a fixed order (cells by z, then x). Returns the count. `spheres`, if given, holds the
/// tunnels within `sphere_pad` of the rect.
fn treesNear(self: Self, x0: i32, z0: i32, x1: i32, z1: i32, spheres: ?[]const Sphere, out: []Tree) usize {
    var count: usize = 0;
    var cz = @divFloor(z0 - tree_reach, tree_cell);
    while (cz <= @divFloor(z1 + tree_reach, tree_cell)) : (cz += 1) {
        var cx = @divFloor(x0 - tree_reach, tree_cell);
        while (cx <= @divFloor(x1 + tree_reach, tree_cell)) : (cx += 1) {
            const t = self.treeInCell(cx, cz, spheres) orelse continue;
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

/// Ore that veins of `block` are made of, in the y range `lo`..`hi` (inclusive). Each
/// chunk-sized cell makes `tries` attempts at a vein, each kept with probability
/// `chance`/256, and veins have radii between `r_min` and `r_max` per axis.
const OreKind = struct {
    block: BlockId,
    lo: i32,
    hi: i32,
    tries: u32,
    chance: u32,
    r_min: f32,
    r_max: f32,
};

const ore_kinds = [_]OreKind{
    .{ .block = .coal_ore, .lo = -10, .hi = 160, .tries = 6, .chance = 128, .r_min = 1.5, .r_max = 2.8 },
    .{ .block = .iron_ore, .lo = -50, .hi = 40, .tries = 4, .chance = 110, .r_min = 1.2, .r_max = 2.2 },
    .{ .block = .gold_ore, .lo = world_bottom, .hi = -10, .tries = 2, .chance = 100, .r_min = 1.0, .r_max = 1.8 },
    .{ .block = .crystal_ore, .lo = world_bottom, .hi = -41, .tries = 1, .chance = 80, .r_min = 0.8, .r_max = 1.4 },
};

pub const max_veins = blk: {
    var n = 0;
    for (ore_kinds) |k| n += k.tries;
    break :blk n;
};

/// Vein centers stay this far from the edges of their cell, more than any radius, so a
/// vein never leaves the chunk it belongs to.
const vein_margin = 3;

/// An ellipsoid of ore, only in stone and deepstone; a quarter of its blocks, picked
/// by hash, are left as they were so it looks rough.
pub const Vein = struct {
    center: [3]f32,
    radius: [3]f32,
    lo: i32,
    hi: i32,
    block: BlockId,

    fn contains(self: Vein, terrain: Self, x: i32, y: i32, z: i32) bool {
        if (y < self.lo or y > self.hi) return false;
        var d: f32 = 0;
        for ([3]i32{ x, y, z }, self.center, self.radius) |p, c, r| {
            const t = (@as(f32, @floatFromInt(p)) - c) / r;
            d += t * t;
        }
        return d <= 1 and terrain.hash3(x, y, z, 31) & 3 != 0;
    }

    /// Block bounds (inclusive) of the ellipsoid.
    fn bounds(self: Vein) [2][3]i32 {
        var lo: [3]i32 = undefined;
        var hi: [3]i32 = undefined;
        for (self.center, self.radius, &lo, &hi) |c, r, *l, *h| {
            l.* = @intFromFloat(@ceil(c - r));
            h.* = @intFromFloat(@floor(c + r));
        }
        return .{ lo, hi };
    }
};

/// The ore veins of the chunk-sized cell (cx, cy, cz), into `out`; returns how many.
/// The first vein listed wins where veins overlap.
pub fn veins(self: Self, cx: i32, cy: i32, cz: i32, out: *[max_veins]Vein) usize {
    var n: usize = 0;
    var salt: u64 = 0;
    for (ore_kinds) |kind| {
        for (0..kind.tries) |_| {
            salt += 1;
            const h = self.hash3(cx, cy, cz, 40 + salt);
            if (h & 0xff >= kind.chance) continue;
            const span = Chunk.size - 1 - 2 * vein_margin;
            var center: [3]f32 = undefined;
            for (&center, [3]i32{ cx, cy, cz }, 0..) |*c, cell_pos, axis| {
                const offset: i32 = @intCast((h >> @intCast(8 + 8 * axis)) % (span + 1));
                c.* = @floatFromInt(cell_pos * Chunk.size + vein_margin + offset);
            }
            const y: i32 = @intFromFloat(center[1]);
            if (y < kind.lo or y > kind.hi) continue;
            var radius: [3]f32 = undefined;
            for (&radius, 0..) |*r, axis| {
                const t = @as(f32, @floatFromInt((h >> @intCast(32 + 8 * axis)) & 0xff)) / 255;
                r.* = std.math.lerp(kind.r_min, kind.r_max, t);
            }
            out[n] = .{ .center = center, .radius = radius, .lo = kind.lo, .hi = kind.hi, .block = kind.block };
            n += 1;
        }
    }
    return n;
}

/// The ore at (x, y, z) if that block is stone or deepstone, as `placeOres` puts it.
fn oreAt(self: Self, x: i32, y: i32, z: i32) ?BlockId {
    var buffer: [max_veins]Vein = undefined;
    const n = self.veins(@divFloor(x, Chunk.size), @divFloor(y, Chunk.size), @divFloor(z, Chunk.size), &buffer);
    for (buffer[0..n]) |v| {
        if (v.contains(self, x, y, z)) return v.block;
    }
    return null;
}

/// Turns the stone and deepstone inside the veins of the chunk at height `chunk_y` of
/// `map`'s column into ore.
fn placeOres(self: Self, chunk_y: i32, map: *const Heightmap, blocks: *Chunk.Blocks) void {
    var buffer: [max_veins]Vein = undefined;
    const n = self.veins(@divExact(map.x, Chunk.size), chunk_y, @divExact(map.z, Chunk.size), &buffer);
    const origin = [3]i32{ map.x, chunk_y * Chunk.size, map.z };
    for (buffer[0..n]) |v| {
        const lo, const hi = v.bounds();
        var y = lo[1];
        while (y <= hi[1]) : (y += 1) {
            var z = lo[2];
            while (z <= hi[2]) : (z += 1) {
                var x = lo[0];
                while (x <= hi[0]) : (x += 1) {
                    const i = Chunk.index(@intCast(x - origin[0]), @intCast(y - origin[1]), @intCast(z - origin[2]));
                    if (blocks[i] != .stone and blocks[i] != .deepstone) continue;
                    if (v.contains(self, x, y, z)) blocks[i] = v.block;
                }
            }
        }
    }
}

/// Caves are carved from `cave_floor` (just above the bedrock) up to a column's ceiling.
pub const cave_floor = world_bottom + bedrock_layers;
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
const cells = Chunk.size / cell;
const cells_y = Chunk.size / cell_y;

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

/// The surface height at (x, z) if a tunnel may break through the surface there.
pub fn entranceHeight(self: Self, x: i32, z: i32) ?i32 {
    if (!self.entrance(x, z)) return null;
    const h = self.height(x, z);
    return if (h > sea_level + 1) h else null;
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
    /// whether a tunnel of the heightmap may carve the chunk
    tunnels: bool,
};

/// Samples the cave lattice of the chunk at height `y0` in `map`'s column. Points no
/// carvable block interpolates from are left solid (1) without sampling.
fn sampleCaves(self: Self, map: *const Heightmap, y0: i32, caves: *Caves) void {
    caves.any = false;
    for (0..cells + 1) |lz| {
        for (0..cells + 1) |lx| {
            // the highest ceiling of the columns in the cells around this point
            var reach: i32 = std.math.minInt(i32);
            for (lz * cell -| cell..@min(lz * cell + cell, Chunk.size)) |z| {
                for (lx * cell -| cell..@min(lx * cell + cell, Chunk.size)) |x| reach = @max(reach, map.ceilings[z][x]);
            }
            const x = map.x + @as(i32, @intCast(lx * cell));
            const z = map.z + @as(i32, @intCast(lz * cell));
            for (0..cells_y + 1) |ly| {
                const y = y0 + @as(i32, @intCast(ly * cell_y));
                const d = &caves.density[ly][lz][lx];
                // only cells with blocks from the floor up to the ceiling need it
                if (y + cell_y <= cave_floor or y > reach + cell_y) {
                    d.* = 1;
                    continue;
                }
                d.* = self.caveDensity(x, y, z);
                if (d.* < 0) caves.any = true;
            }
        }
    }
}

/// Carves the caves out of the blocks of the chunk at height `y0` in `map`'s column.
fn carve(y0: i32, map: *const Heightmap, caves: *const Caves, blocks: *Chunk.Blocks) void {
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
                            if (interpolate(corners, dx, dy, dz) < 0) blocks[Chunk.index(x, y, z)] = .air;
                        }
                    }
                }
            }
        }
    }
}

/// Carves the tunnels of `map` out of the blocks of the chunk at height `y0` in its column.
fn carveTunnels(y0: i32, map: *const Heightmap, blocks: *Chunk.Blocks) void {
    const lo = [3]i32{ map.x, @max(y0, cave_floor), map.z };
    const hi = [3]i32{ map.x + Chunk.size - 1, @min(y0 + Chunk.size - 1, map.ceiling_max), map.z + Chunk.size - 1 };
    for (map.tunnels()) |s| {
        if (!s.overlaps(lo, hi)) continue;
        const s_lo = @max(@as(@Vector(3, i32), lo), @Vector(3, i32){ floorInt(s.x - s.r), floorInt(s.y - s.ry), floorInt(s.z - s.r) });
        const s_hi = @min(@as(@Vector(3, i32), hi), @Vector(3, i32){ floorInt(s.x + s.r), floorInt(s.y + s.ry), floorInt(s.z + s.r) });
        var wy = s_lo[1];
        while (wy <= s_hi[1]) : (wy += 1) {
            var wz = s_lo[2];
            while (wz <= s_hi[2]) : (wz += 1) {
                var wx = s_lo[0];
                while (wx <= s_hi[0]) : (wx += 1) {
                    const x: usize = @intCast(wx - map.x);
                    const z: usize = @intCast(wz - map.z);
                    if (wy > map.ceilings[z][x] or !s.contains(wx, wy, wz)) continue;
                    blocks[Chunk.index(x, @intCast(wy - y0), z)] = .air;
                }
            }
        }
    }
}

fn floorInt(v: f32) i32 {
    return @intFromFloat(@floor(v));
}

/// Whether a cave carves out the block at (x, y, z), as `carve` and `carveTunnels` do.
/// `spheres` holds the tunnels near (x, z), or null to collect them.
fn carved(self: Self, x: i32, y: i32, z: i32, spheres: ?[]const Sphere) bool {
    if (y < cave_floor or y > self.ceiling(x, z)) return false;
    const ox = @divFloor(x, cell) * cell;
    const oy = @divFloor(y, cell_y) * cell_y;
    const oz = @divFloor(z, cell) * cell;
    var corners: [8]f32 = undefined;
    for (&corners, 0..) |*c, k| {
        c.* = self.caveDensity(ox + cell * @as(i32, @intCast(k & 1)), oy + cell_y * @as(i32, @intCast(k >> 2)), oz + cell * @as(i32, @intCast((k >> 1) & 1)));
    }
    if (std.mem.min(f32, &corners) < 0 and interpolate(corners, @intCast(x - ox), @intCast(y - oy), @intCast(z - oz)) < 0) return true;
    var buffer: [1024]Sphere = undefined;
    const near = spheres orelse buffer[0..@min(worms.collect(self, x, z, x, z, &buffer), buffer.len)];
    for (near) |s| {
        if (s.contains(x, y, z)) return true;
    }
    return false;
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

/// Cave density at a lattice point: below 0 in caverns, where a noise field is high
/// enough; deep down it needs to be less high.
fn caveDensity(self: Self, x: i32, y: i32, z: i32) f32 {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const fz: f32 = @floatFromInt(z);
    // squashed vertically, so caverns are wider than they are tall
    const c = self.fbm3(fx / cavern_scale, fy / (cavern_scale * 0.5), fz / cavern_scale, 2, 12);
    const depth = std.math.clamp((cavern_top - fy) / (cavern_top - cavern_deep), 0, 1);
    return std.math.lerp(cavern_threshold_top, cavern_threshold_deep, depth) - c;
}

const cavern_scale = 96;
/// Caverns get more common from `cavern_top` down to `cavern_deep`.
const cavern_top = sea_level;
const cavern_deep = -16;
const cavern_threshold_top = 0.5;
const cavern_threshold_deep = 0.33;

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

/// Tunnel spheres around `map`'s column, collected separately from the heightmap's
/// (over a wider rect), for checking blocks against `blockWith` quickly.
const TestSpheres = struct {
    buffer: []Sphere,
    count: usize,

    fn init(terrain: Self, map: *const Heightmap) !TestSpheres {
        const buffer = try std.testing.allocator.alloc(Sphere, 16384);
        const pad = sphere_pad + 5;
        const count = worms.collect(terrain, map.x - pad, map.z - pad, map.x + Chunk.size - 1 + pad, map.z + Chunk.size - 1 + pad, buffer);
        try std.testing.expect(count <= buffer.len);
        return .{ .buffer = buffer, .count = count };
    }

    fn deinit(self: TestSpheres) void {
        std.testing.allocator.free(self.buffer);
    }

    fn slice(self: TestSpheres) []const Sphere {
        return self.buffer[0..self.count];
    }
};

test "generated chunks match the per-block function across borders" {
    const terrain: Self = .{ .seed = 7 };
    const blocks = try std.testing.allocator.create(Chunk.Blocks);
    defer std.testing.allocator.destroy(blocks);

    var map: Heightmap = undefined;
    terrain.heightmap(-1, 2, &map);
    try std.testing.expect(map.sphere_count <= max_spheres);
    for ([_]i32{ -2, 0 }) |cy| {
        var caves: Caves = undefined;
        try std.testing.expectEqual(Content.mixed, terrain.classify(cy, &map, &caves));
        terrain.fill(cy, &map, &caves, blocks);
        for ([_]usize{ 0, 31 }) |x| {
            for (0..Chunk.size) |y| {
                for ([_]usize{ 0, 31 }) |z| {
                    const expected = terrain.block(map.x + @as(i32, @intCast(x)), cy * Chunk.size + @as(i32, @intCast(y)), map.z + @as(i32, @intCast(z)));
                    try std.testing.expectEqual(expected, blocks[Chunk.index(x, y, z)]);
                }
            }
        }
    }

    // far above the terrain is empty
    var caves: Caves = undefined;
    try std.testing.expectEqual(Content{ .uniform = .air }, terrain.classify(10, &map, &caves));
}

test "uniform chunks really are uniform" {
    const terrain: Self = .{ .seed = 7 };
    const blocks = try std.testing.allocator.create(Chunk.Blocks);
    defer std.testing.allocator.destroy(blocks);

    var found: std.EnumSet(BlockId) = .initEmpty();
    var cx: i32 = -6;
    while (cx <= 6) : (cx += 1) {
        var map: Heightmap = undefined;
        terrain.heightmap(cx, cx * 2, &map);
        var cy: i32 = -3;
        while (cy <= 4) : (cy += 1) {
            var caves: Caves = undefined;
            const content = terrain.classify(cy, &map, &caves);
            if (content != .uniform) continue;
            found.insert(content.uniform);
            terrain.fill(cy, &map, &caves, blocks);
            for (blocks) |b| try std.testing.expectEqual(content.uniform, b);
        }
    }
    try std.testing.expect(found.contains(.air));
    try std.testing.expect(found.contains(.bedrock));
}

test "trees grow on grass and match the per-block function" {
    const terrain: Self = .{ .seed = 7 };
    const blocks = try std.testing.allocator.create(Chunk.Blocks);
    defer std.testing.allocator.destroy(blocks);

    var logs: usize = 0;
    var leaves: usize = 0;
    var cx: i32 = -4;
    while (cx <= 4) : (cx += 1) {
        var map: Heightmap = undefined;
        terrain.heightmap(cx, 3 - cx, &map);
        const spheres = try TestSpheres.init(terrain, &map);
        defer spheres.deinit();
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
            for (0..Chunk.size) |y| {
                for (0..Chunk.size) |z| {
                    for (0..Chunk.size) |x| {
                        const b = blocks[Chunk.index(x, y, z)];
                        const wx = map.x + @as(i32, @intCast(x));
                        const wy = cy * Chunk.size + @as(i32, @intCast(y));
                        const wz = map.z + @as(i32, @intCast(z));
                        try std.testing.expectEqual(terrain.blockWith(wx, wy, wz, spheres.slice()), b);
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

/// The blocks of a box of `columns`² chunk columns, chunk layers `cy0`..`cy1`, with the
/// surface heights; [y][z][x] from the box's minimum corner.
const TestRegion = struct {
    columns: usize,
    cy0: i32,
    layers: usize,
    blocks: []BlockId,
    surface: []i32,

    fn init(terrain: Self, columns: usize, cy0: i32, cy1: i32) !TestRegion {
        const layers: usize = @intCast(cy1 - cy0 + 1);
        const side = columns * Chunk.size;
        const self: TestRegion = .{
            .columns = columns,
            .cy0 = cy0,
            .layers = layers,
            .blocks = try std.testing.allocator.alloc(BlockId, side * side * layers * Chunk.size),
            .surface = try std.testing.allocator.alloc(i32, side * side),
        };
        const blocks = try std.testing.allocator.create(Chunk.Blocks);
        defer std.testing.allocator.destroy(blocks);
        const map = try std.testing.allocator.create(Heightmap);
        defer std.testing.allocator.destroy(map);
        for (0..columns) |cz| {
            for (0..columns) |cx| {
                terrain.heightmap(@intCast(cx), @intCast(cz), map);
                for (0..Chunk.size) |z| {
                    for (0..Chunk.size) |x| self.surface[(cz * Chunk.size + z) * side + cx * Chunk.size + x] = map.heights[z][x];
                }
                for (0..layers) |l| {
                    var caves: Caves = undefined;
                    const cy = cy0 + @as(i32, @intCast(l));
                    switch (terrain.classify(cy, map, &caves)) {
                        .uniform => |b| @memset(blocks, b),
                        .mixed => terrain.fill(cy, map, &caves, blocks),
                    }
                    for (0..Chunk.size) |y| {
                        for (0..Chunk.size) |z| {
                            for (0..Chunk.size) |x| self.blocks[self.index(cx * Chunk.size + x, l * Chunk.size + y, cz * Chunk.size + z)] = blocks[Chunk.index(x, y, z)];
                        }
                    }
                }
            }
        }
        return self;
    }

    fn deinit(self: TestRegion) void {
        std.testing.allocator.free(self.blocks);
        std.testing.allocator.free(self.surface);
    }

    fn width(self: TestRegion) usize {
        return self.columns * Chunk.size;
    }

    fn tall(self: TestRegion) usize {
        return self.layers * Chunk.size;
    }

    fn index(self: TestRegion, x: usize, y: usize, z: usize) usize {
        return (y * self.width() + z) * self.width() + x;
    }

    fn worldY(self: TestRegion, y: usize) i32 {
        return self.cy0 * Chunk.size + @as(i32, @intCast(y));
    }

    /// Whether the block is a carved out underground one.
    fn hollow(self: TestRegion, x: usize, y: usize, z: usize) bool {
        return self.blocks[self.index(x, y, z)] == .air and self.worldY(y) <= self.surface[z * self.width() + x];
    }
};

test "caves run deep, open to the surface in places and never into water" {
    const terrain: Self = .{ .seed = 1337 };
    const region = try TestRegion.init(terrain, 6, -3, 3);
    defer region.deinit();
    var underground: usize = 0;
    var hollow: usize = 0;
    var deep: usize = 0;
    var entrances: usize = 0;
    const side = region.width();
    for (0..region.tall()) |y| {
        const wy = region.worldY(y);
        for (0..side) |z| {
            for (0..side) |x| {
                const b = region.blocks[region.index(x, y, z)];
                if (wy <= world_bottom) try std.testing.expectEqual(BlockId.bedrock, b);
                if (wy < 0) try std.testing.expect(b != .stone);
                if (wy >= deepstone_line) try std.testing.expect(b != .deepstone);
                const surface = region.surface[z * side + x];
                if (wy >= world_bottom and wy <= surface) underground += 1;
                if (!region.hollow(x, y, z)) continue;
                try std.testing.expect(wy >= cave_floor);
                hollow += 1;
                if (wy < -32) deep += 1;
                if (wy == surface) entrances += 1;
                // no air next to water
                if (x > 0) try std.testing.expect(region.blocks[region.index(x - 1, y, z)] != .water);
                if (x < side - 1) try std.testing.expect(region.blocks[region.index(x + 1, y, z)] != .water);
                if (z > 0) try std.testing.expect(region.blocks[region.index(x, y, z - 1)] != .water);
                if (z < side - 1) try std.testing.expect(region.blocks[region.index(x, y, z + 1)] != .water);
                if (y + 1 < region.tall()) try std.testing.expect(region.blocks[region.index(x, y + 1, z)] != .water);
            }
        }
    }
    // a few percent of the ground is hollow
    try std.testing.expect(hollow * 100 > underground * 2 and hollow * 100 < underground * 12);
    try std.testing.expect(deep * 10 > hollow);
    try std.testing.expect(entrances > 0);
}

test "caves join up into networks" {
    const terrain: Self = .{ .seed = 1337 };
    const region = try TestRegion.init(terrain, 6, -2, 3);
    defer region.deinit();
    const side = region.width();
    const total = side * side * region.tall();
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(std.testing.allocator, total);
    defer seen.deinit(std.testing.allocator);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(std.testing.allocator);

    var hollow: usize = 0;
    var largest: usize = 0;
    var largest_span: i32 = 0;
    for (0..total) |start| {
        const x0 = start % side;
        const z0 = start / side % side;
        const y0 = start / (side * side);
        if (seen.isSet(start) or !region.hollow(x0, y0, z0)) continue;
        var size: usize = 0;
        var lo: usize = y0;
        var hi: usize = y0;
        seen.set(start);
        try stack.append(std.testing.allocator, @intCast(start));
        while (stack.pop()) |i| {
            size += 1;
            const x = i % side;
            const z = i / side % side;
            const y = i / (side * side);
            lo = @min(lo, y);
            hi = @max(hi, y);
            const neighbors = [6][3]isize{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 } };
            for (neighbors) |d| {
                const nx = @as(isize, @intCast(x)) + d[0];
                const ny = @as(isize, @intCast(y)) + d[1];
                const nz = @as(isize, @intCast(z)) + d[2];
                if (nx < 0 or nz < 0 or ny < 0 or nx >= side or nz >= side or ny >= region.tall()) continue;
                const n = region.index(@intCast(nx), @intCast(ny), @intCast(nz));
                if (seen.isSet(n) or !region.hollow(@intCast(nx), @intCast(ny), @intCast(nz))) continue;
                seen.set(n);
                try stack.append(std.testing.allocator, @intCast(n));
            }
        }
        hollow += size;
        if (size > largest) {
            largest = size;
            largest_span = @intCast(hi - lo + 1);
        }
    }
    try std.testing.expect(largest * 2 >= hollow);
    try std.testing.expect(largest_span >= 40);
}

test "carved chunks match the per-block function" {
    const terrain: Self = .{ .seed = 1337 };
    const blocks = try std.testing.allocator.create(Chunk.Blocks);
    defer std.testing.allocator.destroy(blocks);
    // the first deep chunk along +x that both kinds of cave run through
    var cx: i32 = 0;
    var map: Heightmap = undefined;
    var caves: Caves = undefined;
    while (true) : (cx += 1) {
        try std.testing.expect(cx < 64);
        terrain.heightmap(cx, 0, &map);
        if (terrain.classify(-1, &map, &caves) == .mixed and caves.any and caves.tunnels) break;
    }
    terrain.fill(-1, &map, &caves, blocks);
    const spheres = try TestSpheres.init(terrain, &map);
    defer spheres.deinit();
    var hollow: usize = 0;
    // every other layer and row, to keep the test quick
    var y: usize = 0;
    while (y < Chunk.size) : (y += 2) {
        var z: usize = 0;
        while (z < Chunk.size) : (z += 2) {
            for (0..Chunk.size) |x| {
                const b = blocks[Chunk.index(x, y, z)];
                const wx = map.x + @as(i32, @intCast(x));
                const wy = @as(i32, @intCast(y)) - Chunk.size;
                const wz = map.z + @as(i32, @intCast(z));
                try std.testing.expectEqual(terrain.blockWith(wx, wy, wz, spheres.slice()), b);
                // and a few with the tunnels collected for the block alone
                if (x % 8 == 0 and y % 8 == 0) try std.testing.expectEqual(terrain.block(wx, wy, wz), b);
                if (b == .air) hollow += 1;
            }
        }
    }
    try std.testing.expect(hollow > 0);
}

test "the bottom of the world is bedrock" {
    const terrain: Self = .{ .seed = 1337 };
    var map: Heightmap = undefined;
    terrain.heightmap(0, 0, &map);
    var caves: Caves = undefined;
    try std.testing.expectEqual(Content{ .uniform = .bedrock }, terrain.classify(-3, &map, &caves));
    var x: i32 = -20;
    while (x < 20) : (x += 1) try std.testing.expectEqual(BlockId.bedrock, terrain.block(x, world_bottom, 3 * x));
}

test "spawn is on solid ground" {
    const terrain: Self = .{ .seed = 1337 };
    const x, const h, const z = terrain.spawnColumn(0, 0);
    try std.testing.expect(terrain.block(x, h, z) != .air);
    try std.testing.expectEqual(BlockId.air, terrain.block(x, h + 1, z));
}

test "ore veins stay inside their cell and their depth band" {
    const terrain: Self = .{ .seed = 1337 };
    var found: std.EnumSet(BlockId) = .initEmpty();
    var buffer: [max_veins]Vein = undefined;
    var cx: i32 = -4;
    while (cx <= 4) : (cx += 1) {
        var cy: i32 = -2;
        while (cy <= 3) : (cy += 1) {
            var cz: i32 = -4;
            while (cz <= 4) : (cz += 1) {
                const n = terrain.veins(cx, cy, cz, &buffer);
                for (buffer[0..n]) |v| {
                    found.insert(v.block);
                    const lo, const hi = v.bounds();
                    for (lo, hi, [3]i32{ cx, cy, cz }) |l, h, c| {
                        try std.testing.expect(l >= c * Chunk.size);
                        try std.testing.expect(h < (c + 1) * Chunk.size);
                    }
                    const y: i32 = @intFromFloat(v.center[1]);
                    try std.testing.expect(y >= v.lo and y <= v.hi);
                    if (v.block == .crystal_ore) try std.testing.expect(y <= -41);
                }
            }
        }
    }
    for ([_]BlockId{ .coal_ore, .iron_ore, .gold_ore, .crystal_ore }) |ore| try std.testing.expect(found.contains(ore));
}

test "buried chunks with ore are generated in full and match the per-block function" {
    const terrain: Self = .{ .seed = 1337 };
    const blocks = try std.testing.allocator.create(Chunk.Blocks);
    defer std.testing.allocator.destroy(blocks);
    var ores: usize = 0;
    var cx: i32 = 0;
    while (cx < 8) : (cx += 1) {
        var map: Heightmap = undefined;
        terrain.heightmap(cx, -cx, &map);
        var cy: i32 = -2;
        while (cy <= 1) : (cy += 1) {
            var caves: Caves = undefined;
            const content = terrain.classify(cy, &map, &caves);
            terrain.fill(cy, &map, &caves, blocks);
            if (content == .uniform) {
                for (blocks) |b| try std.testing.expectEqual(content.uniform, b);
                continue;
            }
            for (0..Chunk.size) |y| {
                const wy = cy * Chunk.size + @as(i32, @intCast(y));
                for (0..Chunk.size) |z| {
                    for (0..Chunk.size) |x| {
                        const b = blocks[Chunk.index(x, y, z)];
                        switch (b) {
                            .coal_ore => try std.testing.expect(wy >= -10),
                            .iron_ore => try std.testing.expect(wy >= -50 and wy <= 40),
                            .gold_ore => try std.testing.expect(wy <= -10),
                            .crystal_ore => try std.testing.expect(wy <= -41),
                            else => continue,
                        }
                        ores += 1;
                        // spot checks, the per-block function is slow
                        if (ores % 16 == 0) {
                            try std.testing.expectEqual(b, terrain.block(map.x + @as(i32, @intCast(x)), wy, map.z + @as(i32, @intCast(z))));
                        }
                    }
                }
            }
        }
    }
    try std.testing.expect(ores > 0);
}
