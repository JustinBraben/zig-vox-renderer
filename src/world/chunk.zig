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
    /// null when the chunk is entirely air
    blocks: ?*Blocks = null,
    state: State = .generated,
    /// vertex range in the mesh arena, null when there is nothing to draw
    mesh: ?MeshRange = null,

    pub fn get(self: *const Chunk, x: usize, y: usize, z: usize) BlockId {
        const blocks = self.blocks orelse return .air;
        return blocks[index(x, y, z)];
    }
};

pub const MeshRange = struct {
    first: u32,
    count: u32,
};

test "chunk pos from negative blocks" {
    try std.testing.expectEqual(ChunkPos{ .x = -1, .y = 0, .z = 0 }, ChunkPos.fromBlock(-1, 0, 31));
    try std.testing.expectEqual(ChunkPos{ .x = -1, .y = -2, .z = 1 }, ChunkPos.fromBlock(-32, -33, 32));
    try std.testing.expectEqual(ChunkPos{ .x = -1, .y = 0, .z = 0 }, ChunkPos.fromWorld(.{ -0.5, 0.5, 31.9 }));
}
