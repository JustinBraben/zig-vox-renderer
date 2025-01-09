const std = @import("std");
const Allocator = std.mem.Allocator;
const BlockType = @import("block.zig").BlockType;

// Constants for chunk dimensions
pub const chunk_size = 16;
pub const chunk_height = chunk_size * chunk_size;
pub const chunk_volume = chunk_size * chunk_size * chunk_size;

const Chunk = @This();

/// World position x of chunk
world_x: i32 = 0,
/// World position z of chunk
world_z: i32 = 0,
/// Palette-based block storage
blocks: [chunk_size][chunk_size][chunk_size]BlockType = std.mem.zeroes([chunk_size][chunk_size][chunk_size]BlockType),
/// Bit indicating if chunk contains only-air blocks
is_empty: bool = true,

pub fn setBlock(self: *Chunk, block_type: BlockType, x: u4, y: u4, z: u4) void {
    self.blocks[y][z][x] = block_type;
}

pub fn getBlock(self: *Chunk, x: u4, y: u4, z: u4) BlockType {
    return self.blocks[y][z][x];
}