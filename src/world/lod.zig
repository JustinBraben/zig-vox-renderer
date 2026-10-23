//! Distant terrain: a quadtree of coarse heightmap tiles around the camera.
//!
//! A level-k tile covers 2^k × 2^k chunk columns as a 32×32 grid of cells, each
//! cell 2^k blocks wide, meshed straight from `Terrain.height` (no block data).
//! Level 0 is the voxel chunks of `World`. A tile splits into its four children
//! when it is close enough and every child can be drawn, so leaves never overlap
//! and coarse terrain shows until the detail is ready.

const std = @import("std");
const Allocator = std.mem.Allocator;

const chunk = @import("chunk.zig");
const BlockId = @import("block.zig").BlockId;
const mesher = @import("mesher.zig");
const Terrain = @import("terrain.zig");
const World = @import("world.zig");
const math = @import("../math.zig");
const MeshArena = @import("../gfx/mesh_arena.zig");
const VoxelPipeline = @import("../gfx/voxel_pipeline.zig");
const vk = @import("../gfx/vulkan_context.zig").vk;

const Self = @This();

pub const Config = struct {
    /// level of the root tiles, the coarsest one
    max_level: u5,
    /// root tiles in each direction around the camera's
    root_radius: i32,
    /// a tile above level 1 splits when it is closer than this many of its own widths
    split_dist: i32,
    build_budget: u32,
};

pub const Stats = struct {
    tiles: u32 = 0,
    leaves: u32 = 0,
    drawn: u32 = 0,
    drawn_vertices: u64 = 0,
    /// tiles the selection wants that aren't built yet
    pending: u32 = 0,
    built_this_frame: u32 = 0,
    arena_full: bool = false,
    update_ms: f32 = 0,
    draw_ms: f32 = 0,
};

/// Tile `(x, z)` of `level` covers chunk columns [x * 2^level, (x + 1) * 2^level).
pub const Key = struct {
    level: u5,
    x: i32,
    z: i32,
};

const Tile = struct {
    /// null when the arena was full
    mesh: ?MeshArena.Range,
    extent: Extent,
    /// selection pass that last reached the tile; unreached tiles are freed
    used: u64,
};

allocator: Allocator,
io: std.Io,
tiles: std.AutoHashMapUnmanaged(Key, Tile) = .empty,
leaves: std.ArrayList(Key) = .empty,
/// chunk columns drawn as voxels; everything else is covered by a leaf
columns: World.ColumnSet = .empty,
/// tiles to build, filled by the selection
queue: std.ArrayList(Key) = .empty,
scratch_keys: std.ArrayList(Key) = .empty,
vertices: std.ArrayList(mesher.Vertex) = .empty,
pass: u64 = 0,
stats: Stats = .{},

pub fn init(allocator: Allocator, io: std.Io) Self {
    return .{ .allocator = allocator, .io = io };
}

pub fn deinit(self: *Self) void {
    self.tiles.deinit(self.allocator);
    self.leaves.deinit(self.allocator);
    self.columns.deinit(self.allocator);
    self.queue.deinit(self.allocator);
    self.scratch_keys.deinit(self.allocator);
    self.vertices.deinit(self.allocator);
}

/// Drops every tile; their mesh ranges are freed as of `frame`.
pub fn clear(self: *Self, arena: *MeshArena, frame: u64) !void {
    var it = self.tiles.valueIterator();
    while (it.next()) |tile| if (tile.mesh) |range| try arena.free(range, frame);
    self.tiles.clearRetainingCapacity();
    self.leaves.clearRetainingCapacity();
    self.columns.clearRetainingCapacity();
    self.stats = .{};
}

const Selection = struct {
    world: *const World,
    world_config: World.Config,
    config: Config,
    /// camera chunk column
    cx: i32,
    cz: i32,

    /// Chebyshev distance in chunk columns from the camera's column to the tile (0 inside it).
    fn distance(s: *const Selection, key: Key) i32 {
        const n = width(key);
        const dx = @max(key.x * n - s.cx, s.cx - (key.x * n + n - 1), 0);
        const dz = @max(key.z * n - s.cz, s.cz - (key.z * n + n - 1), 0);
        return @max(dx, dz);
    }

    fn wantsSplit(s: *const Selection, key: Key) bool {
        const n = width(key);
        const r = @max(s.world_config.render_distance, 0);
        // only into chunks that `World` meshes
        if (key.level == 1) {
            const x0 = key.x * n;
            const z0 = key.z * n;
            return x0 >= s.cx - r and x0 + n - 1 <= s.cx + r and z0 >= s.cz - r and z0 + n - 1 <= s.cz + r;
        }
        const d = s.distance(key);
        return d < s.config.split_dist * n or d <= r;
    }

    /// Coarse tiles first, so there are no holes; then nearest first.
    fn buildsBefore(s: *const Selection, a: Key, b: Key) bool {
        if (a.level != b.level) return a.level > b.level;
        return s.distance(a) < s.distance(b);
    }
};

fn width(key: Key) i32 {
    return @as(i32, 1) << key.level;
}

fn children(key: Key) [4]Key {
    const level = key.level - 1;
    const x = key.x * 2;
    const z = key.z * 2;
    return .{
        .{ .level = level, .x = x, .z = z },
        .{ .level = level, .x = x + 1, .z = z },
        .{ .level = level, .x = x, .z = z + 1 },
        .{ .level = level, .x = x + 1, .z = z + 1 },
    };
}

pub fn update(self: *Self, arena: *MeshArena, world: *const World, camera_pos: @Vector(3, f64), world_config: World.Config, config: Config, frame: u64) !void {
    const start = self.now();
    defer self.stats.update_ms = toMs(self.since(start));
    std.debug.assert(config.max_level >= 1);

    const center = chunk.ChunkPos.fromWorld(camera_pos);
    const s: Selection = .{ .world = world, .world_config = world_config, .config = config, .cx = center.x, .cz = center.z };
    self.pass += 1;
    self.leaves.clearRetainingCapacity();
    self.columns.clearRetainingCapacity();
    self.queue.clearRetainingCapacity();

    const root_x = center.x >> config.max_level;
    const root_z = center.z >> config.max_level;
    var z = root_z - config.root_radius;
    while (z <= root_z + config.root_radius) : (z += 1) {
        var x = root_x - config.root_radius;
        while (x <= root_x + config.root_radius) : (x += 1) {
            try self.visit(&s, .{ .level = config.max_level, .x = x, .z = z });
        }
    }

    std.mem.sort(Key, self.queue.items, &s, Selection.buildsBefore);
    const built = @min(self.queue.items.len, config.build_budget);
    for (self.queue.items[0..built]) |key| try self.build(arena, &world.terrain, key);

    // free tiles the selection no longer reaches
    self.scratch_keys.clearRetainingCapacity();
    var it = self.tiles.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.used != self.pass) try self.scratch_keys.append(self.allocator, entry.key_ptr.*);
    }
    for (self.scratch_keys.items) |key| {
        const tile = self.tiles.fetchRemove(key).?.value;
        if (tile.mesh) |range| try arena.free(range, frame);
    }

    self.stats.tiles = self.tiles.count();
    self.stats.leaves = @intCast(self.leaves.items.len);
    self.stats.pending = @intCast(self.queue.items.len - built);
    self.stats.built_this_frame = @intCast(built);
}

/// Marks the tile as used and either splits it or records it as a leaf.
/// Tiles are only visited once built, except roots.
fn visit(self: *Self, s: *const Selection, key: Key) !void {
    const tile = self.tiles.getPtr(key);
    if (tile) |t| t.used = self.pass;
    if (s.wantsSplit(key) and try self.childrenReady(s, key)) {
        for (children(key)) |child| {
            if (key.level == 1) {
                try self.columns.put(self.allocator, .{ child.x, child.z }, {});
            } else {
                try self.visit(s, child);
            }
        }
        return;
    }
    if (tile != null) {
        try self.leaves.append(self.allocator, key);
    } else {
        try self.queue.append(self.allocator, key);
    }
}

/// Whether every child can be drawn; queues the children that aren't built.
fn childrenReady(self: *Self, s: *const Selection, key: Key) !bool {
    var ready = true;
    for (children(key)) |child| {
        if (key.level == 1) {
            if (!s.world.columnReady(child.x, child.z, s.world_config)) ready = false;
        } else if (self.tiles.getPtr(child)) |t| {
            t.used = self.pass;
        } else {
            ready = false;
            try self.queue.append(self.allocator, child);
        }
    }
    return ready;
}

fn build(self: *Self, arena: *MeshArena, terrain: *const Terrain, key: Key) !void {
    var cells: Grid = undefined;
    var blocks: Surface = undefined;
    sample(terrain, key, &cells, &blocks);
    self.vertices.clearRetainingCapacity();
    const extent = try meshTile(self.allocator, &cells, &blocks, width(key), &self.vertices);

    var tile: Tile = .{ .mesh = null, .extent = extent, .used = self.pass };
    if (self.vertices.items.len > 0) {
        tile.mesh = try arena.upload(self.vertices.items);
        if (tile.mesh == null) self.stats.arena_full = true;
    }
    try self.tiles.put(self.allocator, key, tile);
}

/// Records draws for every leaf in view. Expects `pipeline.bind` to have been called.
pub fn draw(self: *Self, cmd: vk.CommandBuffer, pipeline: *const VoxelPipeline, camera_pos: @Vector(3, f64), frustum: ?math.Frustum) void {
    const start = self.now();
    var drawn: u32 = 0;
    var vertices: u64 = 0;
    for (self.leaves.items) |key| {
        const tile = self.tiles.get(key).?;
        const range = tile.mesh orelse continue;
        const scale = width(key);
        const blocks = chunk.size * scale;
        const corner: @Vector(3, f64) = .{
            @floatFromInt(@as(i64, key.x) * blocks),
            @floatFromInt(@as(i64, tile.extent.base) * scale),
            @floatFromInt(@as(i64, key.z) * blocks),
        };
        const origin: math.Vec3 = @floatCast(corner - camera_pos);
        if (frustum) |f| {
            const size: math.Vec3 = .{ @floatFromInt(blocks), @floatFromInt(tile.extent.height * scale), @floatFromInt(blocks) };
            if (!f.intersectsAabb(origin, origin + size)) continue;
        }
        pipeline.drawChunk(cmd, origin, range, @floatFromInt(scale));
        drawn += 1;
        vertices += range.count;
    }
    self.stats.drawn = drawn;
    self.stats.drawn_vertices = vertices;
    self.stats.draw_ms = toMs(self.since(start));
}

fn now(self: *const Self) std.Io.Timestamp {
    return .now(self.io, .awake);
}

fn since(self: *const Self, start: std.Io.Timestamp) u64 {
    return @intCast(@max(start.untilNow(self.io, .awake).nanoseconds, 0));
}

fn toMs(ns: u64) f32 {
    return @floatCast(@as(f64, @floatFromInt(ns)) / std.time.ns_per_ms);
}

// Tile meshing

pub const grid_size = chunk.size + 2;
/// Top of each cell of a tile plus a one-cell border, in cells, as [z][x].
pub const Grid = [grid_size][grid_size]i32;
/// Surface block of each cell of a tile, as [z][x].
pub const Surface = [chunk.size][chunk.size]BlockId;

/// How far border faces reach below the lower side, in cells, to hide cracks
/// against neighbors of another level.
const skirt = 2;
/// Steeper drops than this (in blocks) show stone instead of the surface block.
const cliff_blocks = 4;
/// Forest cover (see `Terrain.forestCover`) above which a cell shows tree canopy.
const forest_cover = 0.5;
/// How far the canopy sits above the ground, in blocks; within `cliff_blocks`
/// so forest edges show leaves rather than stone.
const canopy_blocks = 4;

/// Vertical span of a tile mesh, in cells: vertex y is relative to `base`.
pub const Extent = struct {
    base: i32,
    height: i32,
};

/// Samples the terrain at the center of each cell of the tile and its border.
pub fn sample(terrain: *const Terrain, key: Key, cells: *Grid, blocks: *Surface) void {
    const scale = width(key);
    const x0 = key.x * chunk.size * scale;
    const z0 = key.z * chunk.size * scale;
    for (cells, 0..) |*row, gz| {
        for (row, 0..) |*cell, gx| {
            const bx = x0 + (@as(i32, @intCast(gx)) - 1) * scale + @divFloor(scale, 2);
            const bz = z0 + (@as(i32, @intCast(gz)) - 1) * scale + @divFloor(scale, 2);
            var h = terrain.height(bx, bz);
            var surface = Terrain.surfaceBlock(h);
            // dense forest reads as a raised canopy instead of the grass under it
            if (surface == .grass and terrain.forestCover(bx, bz) > forest_cover) {
                h += canopy_blocks;
                surface = .leaves;
            }
            // top of the surface block, rounded to whole cells
            cell.* = @divFloor(h + 1 + @divFloor(scale, 2), scale);
            const interior = gx >= 1 and gx <= chunk.size and gz >= 1 and gz <= chunk.size;
            if (interior) blocks[gz - 1][gx - 1] = surface;
        }
    }
}

/// Appends the mesh of one tile to `out`: cell tops (merged into runs along x),
/// cliff sides between cells, and skirts around the tile edge. Positions are in
/// cells; the shader scales them by `scale`.
pub fn meshTile(allocator: Allocator, cells: *const Grid, blocks: *const Surface, scale: i32, out: *std.ArrayList(mesher.Vertex)) !Extent {
    var lowest: i32 = std.math.maxInt(i32);
    var highest: i32 = std.math.minInt(i32);
    for (cells, 0..) |row, gz| {
        for (row, 0..) |t, gx| {
            lowest = @min(lowest, t);
            const interior = gx >= 1 and gx <= chunk.size and gz >= 1 and gz <= chunk.size;
            if (interior) highest = @max(highest, t);
        }
    }
    const base = lowest - skirt;

    for (0..chunk.size) |z| {
        var x: usize = 0;
        while (x < chunk.size) {
            const t = cells[z + 1][x + 1];
            const block = blocks[z][x];
            var end = x + 1;
            while (end < chunk.size and cells[z + 1][end + 1] == t and blocks[z][end] == block) end += 1;
            const y = t - base;
            try emitFace(allocator, out, 2, .{ @intCast(x), y, @intCast(z) }, .{ @intCast(end), y, @intCast(z + 1) }, block.color());
            x = end;
        }
    }

    // face index (as in the mesher) and neighbor direction
    const sides = [4]struct { face: u32, dx: i32, dz: i32 }{
        .{ .face = 0, .dx = 1, .dz = 0 },
        .{ .face = 1, .dx = -1, .dz = 0 },
        .{ .face = 4, .dx = 0, .dz = 1 },
        .{ .face = 5, .dx = 0, .dz = -1 },
    };
    for (0..chunk.size) |z| {
        for (0..chunk.size) |x| {
            const t = cells[z + 1][x + 1];
            const xi: i32 = @intCast(x);
            const zi: i32 = @intCast(z);
            for (sides) |side| {
                const nx = xi + side.dx;
                const nz = zi + side.dz;
                const nt = cells[@intCast(nz + 1)][@intCast(nx + 1)];
                const border = nx < 0 or nx >= chunk.size or nz < 0 or nz >= chunk.size;
                const bottom = if (border) @min(nt, t) - skirt else nt;
                if (bottom >= t) continue;
                const cliff = (t - nt) * scale > cliff_blocks;
                const color = if (cliff) BlockId.stone.color() else blocks[z][x].color();
                try emitFace(allocator, out, side.face, .{ xi, bottom - base, zi }, .{ xi + 1, t - base, zi + 1 }, color);
            }
        }
    }

    return .{ .base = base, .height = highest - base };
}

/// One face of the box [lo, hi] (in tile-local cells), as a quad in the mesher's corner order.
fn emitFace(allocator: Allocator, out: *std.ArrayList(mesher.Vertex), face_index: u32, lo: [3]i32, hi: [3]i32, color: u32) !void {
    const face = mesher.faces[face_index];
    const quad = try out.addManyAsArray(allocator, 4);
    for (quad, mesher.corner_uv) |*vertex, uv| {
        var p: [3]u32 = undefined;
        for (&p, 0..) |*c, a| {
            const high = if (face.normal[a] != 0) face.normal[a] > 0 else if (face.u[a] != 0) uv[0] == 1 else uv[1] == 1;
            // y can exceed the 6-bit vertex range on extreme tiles; flatten those
            c.* = @intCast(std.math.clamp(if (high) hi[a] else lo[a], 0, 63));
        }
        vertex.* = .init(p[0], p[1], p[2], face_index, 3, color);
    }
}

const testing = std.testing;

fn flatTile(cells: *Grid, blocks: *Surface, height: i32) void {
    for (cells) |*row| @memset(row, height);
    for (blocks) |*row| @memset(row, .grass);
}

test "flat tile is one top run per row plus skirts" {
    var cells: Grid = undefined;
    var blocks: Surface = undefined;
    flatTile(&cells, &blocks, 5);
    var out: std.ArrayList(mesher.Vertex) = .empty;
    defer out.deinit(testing.allocator);
    const extent = try meshTile(testing.allocator, &cells, &blocks, 2, &out);
    try testing.expectEqual(@as(usize, (32 + 32 * 4) * 4), out.items.len);
    try testing.expectEqual(Extent{ .base = 3, .height = 2 }, extent);
}

test "a raised cell splits its row and gets four sides" {
    var cells: Grid = undefined;
    var blocks: Surface = undefined;
    flatTile(&cells, &blocks, 5);
    cells[10][10] = 6;
    var out: std.ArrayList(mesher.Vertex) = .empty;
    defer out.deinit(testing.allocator);
    _ = try meshTile(testing.allocator, &cells, &blocks, 2, &out);
    try testing.expectEqual(@as(usize, (34 + 4 + 32 * 4) * 4), out.items.len);
}

test "tiles of real terrain fit the vertex format at every level" {
    const terrain: Terrain = .{ .seed = 1337 };
    var cells: Grid = undefined;
    var blocks: Surface = undefined;
    var out: std.ArrayList(mesher.Vertex) = .empty;
    defer out.deinit(testing.allocator);
    for (1..7) |level| {
        var i: i32 = -3;
        while (i <= 3) : (i += 1) {
            const key: Key = .{ .level = @intCast(level), .x = i * 5, .z = -i * 3 };
            sample(&terrain, key, &cells, &blocks);
            out.clearRetainingCapacity();
            const extent = try meshTile(testing.allocator, &cells, &blocks, width(key), &out);
            try testing.expect(extent.height <= 63);
            try testing.expect(out.items.len <= chunk.volume / 2 * 6 * 4);
        }
    }
}
