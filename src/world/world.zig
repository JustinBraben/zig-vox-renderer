//! The set of loaded chunks around the camera: generates, meshes and unloads
//! them with a per-frame budget, and draws the visible ones.

const std = @import("std");
const Allocator = std.mem.Allocator;

const chunk = @import("chunk.zig");
const Chunk = chunk.Chunk;
const ChunkPos = chunk.ChunkPos;
const BlockId = @import("block.zig").BlockId;
const mesher = @import("mesher.zig");
const Terrain = @import("terrain.zig");
const math = @import("../math.zig");
const MeshArena = @import("../gfx/mesh_arena.zig");
const VoxelPipeline = @import("../gfx/voxel_pipeline.zig");
const vk = @import("../gfx/vulkan_context.zig").vk;

const log = std.log.scoped(.world);

const Self = @This();

pub const Config = struct {
    /// horizontal radius in chunks (square)
    render_distance: i32,
    /// vertical chunk range that is meshed and drawn
    min_y: i32,
    max_y: i32,
    gen_budget: u32,
    mesh_budget: u32,
};

/// A set of chunk columns (x, z).
pub const ColumnSet = std.AutoHashMapUnmanaged([2]i32, void);

pub const Stats = struct {
    loaded: u32 = 0,
    /// chunks with a non-empty mesh
    meshed: u32 = 0,
    drawn: u32 = 0,
    drawn_vertices: u64 = 0,
    /// chunks within view distance that are still waiting for a mesh
    pending: u32 = 0,
    generated_this_frame: u32 = 0,
    meshed_this_frame: u32 = 0,
    arena_full: bool = false,

    // CPU time spent this frame
    update_ms: f32 = 0,
    gen_ms: f32 = 0,
    mesh_ms: f32 = 0,
    draw_ms: f32 = 0,
    // totals since the last regenerate, for per-chunk averages
    gen_total: u64 = 0,
    gen_total_ns: u64 = 0,
    mesh_total: u64 = 0,
    mesh_total_ns: u64 = 0,
    /// mesh passes skipped because the chunk was buried
    mesh_skipped: u64 = 0,
};

allocator: Allocator,
io: std.Io,
terrain: Terrain,
chunks: std.AutoHashMapUnmanaged(ChunkPos, *Chunk) = .empty,
/// heightmaps of loaded chunk columns, keyed by column (x, z)
heightmaps: std.AutoHashMapUnmanaged([2]i32, *Terrain.Heightmap) = .empty,
/// column offsets within `offsets_radius + 2`, nearest first
offsets: std.ArrayList([2]i32) = .empty,
offsets_radius: i32 = -1,
padded: *mesher.Padded,
vertices: std.ArrayList(mesher.Vertex) = .empty,
scratch_keys: std.ArrayList(ChunkPos) = .empty,
scratch_columns: std.ArrayList([2]i32) = .empty,
/// chunks whose blocks were edited (or that border an edit) and need a new mesh;
/// meshed at the start of the next update regardless of the mesh budget
dirty: std.ArrayList(ChunkPos) = .empty,
/// center and config of the previous update; unloading only runs when they change
last_center: ?ChunkPos = null,
last_config: ?Config = null,
/// every chunk in range is generated and meshed, so updates can be skipped
settled: bool = false,
stats: Stats = .{},

pub fn init(allocator: Allocator, io: std.Io, seed: u64) !Self {
    return .{
        .allocator = allocator,
        .io = io,
        .terrain = .{ .seed = seed },
        .padded = try allocator.create(mesher.Padded),
    };
}

pub fn deinit(self: *Self) void {
    var it = self.chunks.valueIterator();
    while (it.next()) |c| self.destroyChunk(c.*);
    self.chunks.deinit(self.allocator);
    self.clearHeightmaps();
    self.heightmaps.deinit(self.allocator);
    self.scratch_columns.deinit(self.allocator);
    self.offsets.deinit(self.allocator);
    self.vertices.deinit(self.allocator);
    self.scratch_keys.deinit(self.allocator);
    self.dirty.deinit(self.allocator);
    self.allocator.destroy(self.padded);
}

/// Drops every chunk; their mesh ranges are freed as of `frame`.
pub fn regenerate(self: *Self, arena: *MeshArena, seed: u64, frame: u64) !void {
    var it = self.chunks.valueIterator();
    while (it.next()) |c| {
        if (c.*.mesh) |range| try arena.free(range, frame);
        self.destroyChunk(c.*);
    }
    self.chunks.clearRetainingCapacity();
    self.dirty.clearRetainingCapacity();
    self.clearHeightmaps();
    self.terrain = .{ .seed = seed };
    self.stats = .{};
    self.settled = false;
}

/// The block at world position (x, y, z), or null when its chunk isn't loaded.
pub fn getBlock(self: *const Self, x: i32, y: i32, z: i32) ?BlockId {
    const c = self.chunks.get(ChunkPos.fromBlock(x, y, z)) orelse return null;
    const l = local(x, y, z);
    return c.get(l[0], l[1], l[2]);
}

/// Whether the block blocks movement. Falls back to the generated terrain where no
/// chunk is loaded, so the edge of the loaded area is neither a wall nor a pit.
pub fn isSolid(self: *const Self, x: i32, y: i32, z: i32) bool {
    const block = self.getBlock(x, y, z) orelse self.terrain.block(x, y, z);
    return block.isOpaque();
}

/// Changes one block and queues remeshing of its chunk and of every neighbor whose
/// one-block border (faces + AO) contains it. Does nothing if the chunk isn't loaded.
pub fn setBlock(self: *Self, x: i32, y: i32, z: i32, block: BlockId) !void {
    const pos = ChunkPos.fromBlock(x, y, z);
    const c = self.chunks.get(pos) orelse return;
    const l = local(x, y, z);
    if (c.get(l[0], l[1], l[2]) == block) return;
    try c.set(self.allocator, l[0], l[1], l[2], block);
    c.modified = true;

    // per axis: this chunk, plus the neighbor on the side the block touches
    var ranges: [3][2]i32 = undefined;
    for (l, &ranges) |v, *range| {
        range.* = .{ if (v == 0) -1 else 0, if (v == chunk.size - 1) 1 else 0 };
    }
    var dy = ranges[1][0];
    while (dy <= ranges[1][1]) : (dy += 1) {
        var dz = ranges[2][0];
        while (dz <= ranges[2][1]) : (dz += 1) {
            var dx = ranges[0][0];
            while (dx <= ranges[0][1]) : (dx += 1) {
                const n_pos = pos.offset(dx, dy, dz);
                const n = self.chunks.get(n_pos) orelse continue;
                n.state = .generated;
                try self.dirty.append(self.allocator, n_pos);
            }
        }
    }
    self.settled = false;
}

/// Chunk-local coordinates of a world block.
fn local(x: i32, y: i32, z: i32) [3]usize {
    return .{ @intCast(@mod(x, chunk.size)), @intCast(@mod(y, chunk.size)), @intCast(@mod(z, chunk.size)) };
}

pub fn update(self: *Self, arena: *MeshArena, camera_pos: @Vector(3, f64), config: Config, frame: u64) !void {
    const start = self.now();
    var gen_ns: u64 = 0;
    var mesh_ns: u64 = 0;
    defer {
        self.stats.gen_ms = toMs(gen_ns);
        self.stats.mesh_ms = toMs(mesh_ns);
        self.stats.update_ms = toMs(self.since(start));
    }

    const center = ChunkPos.fromWorld(camera_pos);
    const r = @max(config.render_distance, 0);
    if (!std.meta.eql(self.last_center, center) or !std.meta.eql(self.last_config, config)) {
        if (r != self.offsets_radius) try self.buildOffsets(r);
        try self.unloadFar(arena, center, r, config, frame);
        self.last_center = center;
        self.last_config = config;
        self.settled = false;
    }
    self.stats.loaded = self.chunks.count();
    self.stats.generated_this_frame = 0;
    self.stats.meshed_this_frame = 0;

    // edits first and unbudgeted, so they show up this frame
    if (self.dirty.items.len > 0) {
        const t = self.now();
        var i: usize = 0;
        while (i < self.dirty.items.len) {
            const pos = self.dirty.items[i];
            const in_range = @abs(pos.x - center.x) <= r and @abs(pos.z - center.z) <= r and
                pos.y >= config.min_y and pos.y <= config.max_y;
            // out of range: streaming meshes it when it comes back into view
            const c = (if (in_range) self.chunks.get(pos) else null) orelse {
                _ = self.dirty.swapRemove(i);
                continue;
            };
            if (!self.neighborsLoaded(pos)) {
                i += 1;
                continue;
            }
            if (c.state != .meshed) try self.meshChunk(arena, c, frame);
            _ = self.dirty.swapRemove(i);
        }
        mesh_ns += self.since(t);
    }

    if (self.settled) return;

    // generate one ring beyond the view distance so edge chunks have neighbors to mesh against
    var generated: u32 = 0;
    gen: for (self.offsets.items) |off| {
        if (@max(@abs(off[0]), @abs(off[1])) > r + 1) continue;
        var y = config.min_y - 1;
        while (y <= config.max_y + 1) : (y += 1) {
            const pos: ChunkPos = .{ .x = center.x + off[0], .y = y, .z = center.z + off[1] };
            if (self.chunks.contains(pos)) continue;
            if (generated >= config.gen_budget) break :gen;
            const t = self.now();
            try self.generateChunk(pos);
            gen_ns += self.since(t);
            generated += 1;
        }
    }

    var meshed: u32 = 0;
    var pending: u32 = 0;
    for (self.offsets.items) |off| {
        if (@max(@abs(off[0]), @abs(off[1])) > r) continue;
        var y = config.min_y;
        while (y <= config.max_y) : (y += 1) {
            const pos: ChunkPos = .{ .x = center.x + off[0], .y = y, .z = center.z + off[1] };
            const c = self.chunks.get(pos) orelse {
                pending += 1;
                continue;
            };
            if (c.state == .meshed) continue;
            if (meshed >= config.mesh_budget or !self.neighborsLoaded(pos)) {
                pending += 1;
                continue;
            }
            const t = self.now();
            try self.meshChunk(arena, c, frame);
            mesh_ns += self.since(t);
            meshed += 1;
        }
    }

    self.settled = generated == 0 and pending == 0;
    self.stats.loaded = self.chunks.count();
    self.stats.generated_this_frame = generated;
    self.stats.meshed_this_frame = meshed;
    self.stats.pending = pending;
    self.stats.gen_total += generated;
    self.stats.gen_total_ns += gen_ns;
    self.stats.mesh_total += meshed;
    self.stats.mesh_total_ns += mesh_ns;
}

/// Whether every chunk of column (x, z) in the configured y range has a mesh
/// (possibly empty, possibly being rebuilt), so the column can be drawn without holes.
pub fn columnReady(self: *const Self, x: i32, z: i32, config: Config) bool {
    var y = config.min_y;
    while (y <= config.max_y) : (y += 1) {
        const c = self.chunks.get(.{ .x = x, .y = y, .z = z }) orelse return false;
        if (c.state != .meshed and c.mesh == null) return false;
    }
    return true;
}

/// Records draws for every meshed chunk in view, limited to `columns` when given
/// (the rest is covered by distant terrain). Expects `pipeline.bind` to have been called.
pub fn draw(self: *Self, cmd: vk.CommandBuffer, pipeline: *const VoxelPipeline, camera_pos: @Vector(3, f64), frustum: ?math.Frustum, config: Config, columns: ?*const ColumnSet) void {
    const start = self.now();
    const center = ChunkPos.fromWorld(camera_pos);
    const r = @max(config.render_distance, 0);
    var drawn: u32 = 0;
    var meshed: u32 = 0;
    var vertices: u64 = 0;

    var it = self.chunks.valueIterator();
    while (it.next()) |entry| {
        const c = entry.*;
        const range = c.mesh orelse continue;
        meshed += 1;
        if (@abs(c.pos.x - center.x) > r or @abs(c.pos.z - center.z) > r) continue;
        if (c.pos.y < config.min_y or c.pos.y > config.max_y) continue;
        if (columns) |set| if (!set.contains(.{ c.pos.x, c.pos.z })) continue;

        const origin: math.Vec3 = @floatCast(c.pos.origin() - camera_pos);
        if (frustum) |f| {
            if (!f.intersectsAabb(origin, origin + @as(math.Vec3, @splat(chunk.size)))) continue;
        }
        pipeline.drawChunk(cmd, origin, range, 1);
        drawn += 1;
        vertices += range.count;
    }

    self.stats.meshed = meshed;
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

fn buildOffsets(self: *Self, r: i32) !void {
    self.offsets.clearRetainingCapacity();
    const extent = r + 2;
    var z = -extent;
    while (z <= extent) : (z += 1) {
        var x = -extent;
        while (x <= extent) : (x += 1) try self.offsets.append(self.allocator, .{ x, z });
    }
    std.mem.sort([2]i32, self.offsets.items, {}, struct {
        fn lessThan(_: void, a: [2]i32, b: [2]i32) bool {
            return a[0] * a[0] + a[1] * a[1] < b[0] * b[0] + b[1] * b[1];
        }
    }.lessThan);
    self.offsets_radius = r;
}

fn unloadFar(self: *Self, arena: *MeshArena, center: ChunkPos, r: i32, config: Config, frame: u64) !void {
    self.scratch_keys.clearRetainingCapacity();
    var it = self.chunks.iterator();
    while (it.next()) |entry| {
        const pos = entry.key_ptr.*;
        const far = @abs(pos.x - center.x) > r + 2 or @abs(pos.z - center.z) > r + 2;
        const out_of_range = pos.y < config.min_y - 1 or pos.y > config.max_y + 1;
        if (far or out_of_range) try self.scratch_keys.append(self.allocator, pos);
    }
    for (self.scratch_keys.items) |pos| {
        const c = self.chunks.get(pos).?;
        if (c.mesh) |range| try arena.free(range, frame);
        c.mesh = null;
        if (c.modified) {
            // keep the edited blocks (they can't be regenerated); remesh when back in range
            c.state = .generated;
            continue;
        }
        _ = self.chunks.remove(pos);
        self.destroyChunk(c);
    }

    self.scratch_columns.clearRetainingCapacity();
    var columns = self.heightmaps.keyIterator();
    while (columns.next()) |column| {
        if (@abs(column[0] - center.x) > r + 2 or @abs(column[1] - center.z) > r + 2) {
            try self.scratch_columns.append(self.allocator, column.*);
        }
    }
    for (self.scratch_columns.items) |column| {
        self.allocator.destroy(self.heightmaps.fetchRemove(column).?.value);
    }
}

fn clearHeightmaps(self: *Self) void {
    var it = self.heightmaps.valueIterator();
    while (it.next()) |map| self.allocator.destroy(map.*);
    self.heightmaps.clearRetainingCapacity();
}

/// The column's heightmap, computed on first use.
fn heightmap(self: *Self, x: i32, z: i32) !*const Terrain.Heightmap {
    if (self.heightmaps.get(.{ x, z })) |map| return map;
    const map = try self.allocator.create(Terrain.Heightmap);
    errdefer self.allocator.destroy(map);
    self.terrain.heightmap(x, z, map);
    try self.heightmaps.put(self.allocator, .{ x, z }, map);
    return map;
}

fn generateChunk(self: *Self, pos: ChunkPos) !void {
    const map = try self.heightmap(pos.x, pos.z);
    const c = try self.allocator.create(Chunk);
    c.* = .{ .pos = pos };
    errdefer self.destroyChunk(c);

    switch (Terrain.classify(pos.y, map)) {
        .uniform => |block| {
            c.uniform = block;
            // nothing to mesh in an all-air chunk
            if (!block.isOpaque()) c.state = .meshed;
        },
        .mixed => {
            const blocks = try self.allocator.create(chunk.Blocks);
            Terrain.fill(pos.y, map, blocks);
            c.blocks = blocks;
        },
    }
    c.updateSolidSides();
    try self.chunks.put(self.allocator, pos, c);
}

fn destroyChunk(self: *Self, c: *Chunk) void {
    if (c.blocks) |blocks| self.allocator.destroy(blocks);
    self.allocator.destroy(c);
}

fn neighborsLoaded(self: *const Self, pos: ChunkPos) bool {
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (!self.chunks.contains(pos.offset(dx, dy, dz))) return false;
            }
        }
    }
    return true;
}

/// True when no face of the chunk can be visible: it is solid and each face
/// neighbor's side touching it is solid too.
fn buried(self: *const Self, c: *const Chunk) bool {
    if (!c.isSolid()) return false;
    // same side order as `Chunk.solid_sides`; side ^ 1 is the opposite side
    const neighbors = [6][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
    for (neighbors, 0..) |d, side| {
        const n = self.chunks.get(c.pos.offset(d[0], d[1], d[2])) orelse return false;
        if (n.solid_sides & (@as(u6, 1) << @intCast(side ^ 1)) == 0) return false;
    }
    return true;
}

fn meshChunk(self: *Self, arena: *MeshArena, c: *Chunk, frame: u64) !void {
    self.vertices.clearRetainingCapacity();
    if (self.buried(c)) {
        self.stats.mesh_skipped += 1;
    } else {
        self.fillPadded(c.pos);
        try mesher.meshChunk(self.allocator, self.padded, &self.vertices);
    }

    if (c.mesh) |old| try arena.free(old, frame);
    c.mesh = null;
    c.state = .meshed;
    if (self.vertices.items.len == 0) return;

    c.mesh = try arena.upload(self.vertices.items);
    if (c.mesh == null and !self.stats.arena_full) {
        log.warn("mesh arena is full ({d} vertices); increase its capacity or lower the render distance", .{arena.capacity});
        self.stats.arena_full = true;
    }
}

/// Copies the chunk and a one-block border of its 26 neighbors into `self.padded`.
fn fillPadded(self: *Self, pos: ChunkPos) void {
    var neighbors: [3][3][3]?*const Chunk = undefined;
    for (0..3) |y| {
        for (0..3) |z| {
            for (0..3) |x| {
                neighbors[y][z][x] = self.chunks.get(pos.offset(@as(i32, @intCast(x)) - 1, @as(i32, @intCast(y)) - 1, @as(i32, @intCast(z)) - 1));
            }
        }
    }

    // per padded coordinate: which neighbor (0..2) and the local coordinate inside it
    const Axis = struct { n: usize, local: usize };
    var axis: [mesher.padded_size]Axis = undefined;
    for (&axis, 0..) |*a, p| {
        a.* = if (p == 0)
            .{ .n = 0, .local = chunk.size - 1 }
        else if (p == mesher.padded_size - 1)
            .{ .n = 2, .local = 0 }
        else
            .{ .n = 1, .local = p - 1 };
    }

    for (axis, 0..) |ay, py| {
        for (axis, 0..) |az, pz| {
            for (axis, 0..) |ax, px| {
                const n = neighbors[ay.n][az.n][ax.n];
                self.padded[mesher.paddedIndex(px, py, pz)] = if (n) |c| c.get(ax.local, ay.local, az.local) else .air;
            }
        }
    }
}
