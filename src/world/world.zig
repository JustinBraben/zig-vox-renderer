//! The set of loaded chunks around the camera: generates, meshes and unloads
//! them with a per-frame budget, and draws the visible ones.

const std = @import("std");
const Allocator = std.mem.Allocator;

const chunk = @import("chunk.zig");
const Chunk = chunk.Chunk;
const ChunkPos = chunk.ChunkPos;
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
};

allocator: Allocator,
terrain: Terrain,
chunks: std.AutoHashMapUnmanaged(ChunkPos, *Chunk) = .empty,
/// column offsets within `offsets_radius + 2`, nearest first
offsets: std.ArrayList([2]i32) = .empty,
offsets_radius: i32 = -1,
padded: *mesher.Padded,
vertices: std.ArrayList(mesher.Vertex) = .empty,
scratch_keys: std.ArrayList(ChunkPos) = .empty,
stats: Stats = .{},

pub fn init(allocator: Allocator, seed: u64) !Self {
    return .{
        .allocator = allocator,
        .terrain = .{ .seed = seed },
        .padded = try allocator.create(mesher.Padded),
    };
}

pub fn deinit(self: *Self) void {
    var it = self.chunks.valueIterator();
    while (it.next()) |c| self.destroyChunk(c.*);
    self.chunks.deinit(self.allocator);
    self.offsets.deinit(self.allocator);
    self.vertices.deinit(self.allocator);
    self.scratch_keys.deinit(self.allocator);
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
    self.terrain = .{ .seed = seed };
    self.stats.arena_full = false;
}

pub fn update(self: *Self, arena: *MeshArena, camera_pos: @Vector(3, f64), config: Config, frame: u64) !void {
    const center = ChunkPos.fromWorld(camera_pos);
    const r = @max(config.render_distance, 0);
    if (r != self.offsets_radius) try self.buildOffsets(r);

    try self.unloadFar(arena, center, r, config, frame);

    // generate one ring beyond the view distance so edge chunks have neighbors to mesh against
    var generated: u32 = 0;
    gen: for (self.offsets.items) |off| {
        if (@max(@abs(off[0]), @abs(off[1])) > r + 1) continue;
        var y = config.min_y - 1;
        while (y <= config.max_y + 1) : (y += 1) {
            const pos: ChunkPos = .{ .x = center.x + off[0], .y = y, .z = center.z + off[1] };
            if (self.chunks.contains(pos)) continue;
            if (generated >= config.gen_budget) break :gen;
            try self.generateChunk(pos);
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
            try self.meshChunk(arena, c, frame);
            meshed += 1;
        }
    }

    self.stats.loaded = self.chunks.count();
    self.stats.generated_this_frame = generated;
    self.stats.meshed_this_frame = meshed;
    self.stats.pending = pending;
}

/// Records draws for every meshed chunk in view. Expects `pipeline.bind` to have been called.
pub fn draw(self: *Self, cmd: vk.CommandBuffer, pipeline: *const VoxelPipeline, camera_pos: @Vector(3, f64), frustum: ?math.Frustum, config: Config) void {
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

        const origin: math.Vec3 = @floatCast(c.pos.origin() - camera_pos);
        if (frustum) |f| {
            if (!f.intersectsAabb(origin, origin + @as(math.Vec3, @splat(chunk.size)))) continue;
        }
        pipeline.drawChunk(cmd, origin, range);
        drawn += 1;
        vertices += range.count;
    }

    self.stats.meshed = meshed;
    self.stats.drawn = drawn;
    self.stats.drawn_vertices = vertices;
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
        const c = self.chunks.fetchRemove(pos).?.value;
        if (c.mesh) |range| try arena.free(range, frame);
        self.destroyChunk(c);
    }
}

fn generateChunk(self: *Self, pos: ChunkPos) !void {
    const c = try self.allocator.create(Chunk);
    errdefer self.allocator.destroy(c);
    c.* = .{ .pos = pos };

    const blocks = try self.allocator.create(chunk.Blocks);
    if (self.terrain.generate(pos, blocks)) {
        c.blocks = blocks;
    } else {
        self.allocator.destroy(blocks);
        // nothing to mesh in an all-air chunk
        c.state = .meshed;
    }
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

fn meshChunk(self: *Self, arena: *MeshArena, c: *Chunk, frame: u64) !void {
    self.fillPadded(c.pos);
    self.vertices.clearRetainingCapacity();
    try mesher.meshChunk(self.allocator, self.padded, &self.vertices);

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
    var neighbors: [3][3][3]?*const chunk.Blocks = undefined;
    for (0..3) |y| {
        for (0..3) |z| {
            for (0..3) |x| {
                const n = self.chunks.get(pos.offset(@as(i32, @intCast(x)) - 1, @as(i32, @intCast(y)) - 1, @as(i32, @intCast(z)) - 1));
                neighbors[y][z][x] = if (n) |c| c.blocks else null;
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
                const blocks = neighbors[ay.n][az.n][ax.n];
                self.padded[mesher.paddedIndex(px, py, pz)] = if (blocks) |b| b[chunk.index(ax.local, ay.local, az.local)] else .air;
            }
        }
    }
}
