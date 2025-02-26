const std = @import("std");
const Allocator = std.mem.Allocator;
const zmath = @import("zmath");
const Mesh = @import("../Models/mesh.zig");

const Chunk = @This();

pub const CHUNK_SIZE = 16; // Dimensions of a chunk (16x16x16 blocks)
pub const RENDER_DISTANCE = 8; // Number of chunks to render in each direction

pub const ChunkPos = struct {
    x: i32,
    z: i32,
    
    pub fn fromWorldPos(world_x: f32, world_z: f32) ChunkPos {
        const chunk_size_f32: f32 = @floatFromInt(CHUNK_SIZE);
        return .{
            .x = @intFromFloat(@floor(world_x / chunk_size_f32)),
            .y = @intFromFloat(@floor(world_z / chunk_size_f32)),
        };
    }
    
    pub fn worldOffset(self: ChunkPos) zmath.Vec {
        return zmath.f32x4(
            @floatFromInt(self.x * CHUNK_SIZE),
            0,
            @floatFromInt(self.z * CHUNK_SIZE),
            0
        );
    }
    
    pub fn equals(self: ChunkPos, other: ChunkPos) bool {
        return self.x == other.x and self.z == other.z;
    }
    
    pub fn hash(self: ChunkPos) u64 {
        return @as(u64, @intCast(self.x)) << 32 | (@as(u64, @intCast(self.x)) & 0xFFFFFFFF);
    }
};

pub const Block = struct {
    // Block type, properties, etc.
    id: u16,
    // Maybe add more properties later
};


pos: ChunkPos,
blocks: [CHUNK_SIZE][CHUNK_SIZE][CHUNK_SIZE]Block,
mesh: ?Mesh = null,
/// Flag to indicate if the mesh needs rebuilding
is_dirty: bool,
/// Flag to indicate if the chunk has any visible blocks
is_empty: bool,
allocator: Allocator,

pub fn init(allocator: Allocator, pos: ChunkPos) !*Chunk {
    var chunk: *Chunk = undefined;
    chunk = try allocator.create(Chunk);

    chunk.* = .{
        .pos = pos,
        .blocks = undefined,
        .mesh = null,
        .is_dirty = true,
        .is_empty = false,
    };

    // Initialize blocks with air (id 0)
    for (chunk.blocks) |*x_slice| {
        for (x_slice) |*y_slice| {
            for (y_slice) |*block| {
                block.* = Block{ .id = 0 };
            }
        }
    }

    return chunk;
}

pub fn deinit(self: *Chunk) void {
    if (self.mesh) |mesh| {
        mesh.deinit();
    }
    self.allocator.destroy(self);
}

pub fn getBlock(self: *Chunk, x: usize, y: usize, z: usize) Block {
    return self.blocks[x][y][z];
}

pub fn setBlock(self: *Chunk, x: usize, y: usize, z: usize, block: Block) void {
    self.blocks[x][y][z] = block;
    self.is_dirty = true; // Mark chunk for mesh rebuild
}