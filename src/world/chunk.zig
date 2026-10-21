//! A cubic 32³ chunk of blocks.

const std = @import("std");
const BlockId = @import("block.zig").BlockId;

pub const size = 32;
pub const volume = size * size * size;

pub const Blocks = [volume]BlockId;

/// Chunk coordinates; the chunk covers world blocks [pos * size, pos * size + size).
pub const ChunkPos = struct {
    x: i32,
    y: i32,
    z: i32,

    pub fn fromBlock(bx: i32, by: i32, bz: i32) ChunkPos {
        return .{ .x = @divFloor(bx, size), .y = @divFloor(by, size), .z = @divFloor(bz, size) };
    }

    pub fn fromWorld(p: @Vector(3, f64)) ChunkPos {
        return fromBlock(@intFromFloat(@floor(p[0])), @intFromFloat(@floor(p[1])), @intFromFloat(@floor(p[2])));
    }

    pub fn offset(self: ChunkPos, dx: i32, dy: i32, dz: i32) ChunkPos {
        return .{ .x = self.x + dx, .y = self.y + dy, .z = self.z + dz };
    }

    /// World position of the chunk's minimum corner.
    pub fn origin(self: ChunkPos) @Vector(3, f64) {
        return .{
            @floatFromInt(@as(i64, self.x) * size),
            @floatFromInt(@as(i64, self.y) * size),
            @floatFromInt(@as(i64, self.z) * size),
        };
    }
};

pub fn index(x: usize, y: usize, z: usize) usize {
    return x + z * size + y * size * size;
}

pub const State = enum {
    /// block data exists, no mesh yet (or it needs rebuilding)
    generated,
    /// mesh is up to date (possibly empty)
    meshed,
};

pub const Chunk = struct {
    pos: ChunkPos,
    /// null when every block is `uniform`
    blocks: ?*Blocks = null,
    uniform: BlockId = .air,
    state: State = .generated,
    /// vertex range in the mesh arena, null when there is nothing to draw
    mesh: ?MeshRange = null,
    /// bit per side (+X, -X, +Y, -Y, +Z, -Z, as in the mesher), set when that
    /// whole boundary layer is opaque; see `updateSolidSides`
    solid_sides: u6 = 0,

    pub fn get(self: *const Chunk, x: usize, y: usize, z: usize) BlockId {
        const blocks = self.blocks orelse return self.uniform;
        return blocks[index(x, y, z)];
    }

    pub fn isSolid(self: *const Chunk) bool {
        return self.blocks == null and self.uniform.isOpaque();
    }

    /// Recomputes `solid_sides` from the block data.
    pub fn updateSolidSides(self: *Chunk) void {
        const blocks = self.blocks orelse {
            self.solid_sides = if (self.uniform.isOpaque()) 0b111111 else 0;
            return;
        };
        self.solid_sides = 0;
        for (0..6) |side| {
            const layer: usize = if (side % 2 == 0) size - 1 else 0;
            if (layerSolid(blocks, side / 2, layer)) self.solid_sides |= @as(u6, 1) << @intCast(side);
        }
    }
};

/// True when every block with coordinate `layer` on `axis` (0 = x, 1 = y, 2 = z) is opaque.
fn layerSolid(blocks: *const Blocks, axis: usize, layer: usize) bool {
    for (0..size) |a| {
        for (0..size) |b| {
            var p: [3]usize = undefined;
            p[axis] = layer;
            p[(axis + 1) % 3] = a;
            p[(axis + 2) % 3] = b;
            if (!blocks[index(p[0], p[1], p[2])].isOpaque()) return false;
        }
    }
    return true;
}

pub const MeshRange = struct {
    first: u32,
    count: u32,
};

test "solid sides of a half-filled chunk" {
    const blocks = try std.testing.allocator.create(Blocks);
    defer std.testing.allocator.destroy(blocks);
    // bottom half stone, top half air
    for (0..size) |y| {
        for (0..size * size) |i| blocks[y * size * size + i] = if (y < size / 2) .stone else .air;
    }
    var c: Chunk = .{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .blocks = blocks };
    c.updateSolidSides();
    // only -Y (bit 3) is fully solid
    try std.testing.expectEqual(@as(u6, 0b001000), c.solid_sides);

    c.blocks = null;
    c.uniform = .stone;
    c.updateSolidSides();
    try std.testing.expectEqual(@as(u6, 0b111111), c.solid_sides);
}

test "chunk pos from negative blocks" {
    try std.testing.expectEqual(ChunkPos{ .x = -1, .y = 0, .z = 0 }, ChunkPos.fromBlock(-1, 0, 31));
    try std.testing.expectEqual(ChunkPos{ .x = -1, .y = -2, .z = 1 }, ChunkPos.fromBlock(-32, -33, 32));
    try std.testing.expectEqual(ChunkPos{ .x = -1, .y = 0, .z = 0 }, ChunkPos.fromWorld(.{ -0.5, 0.5, 31.9 }));
}
