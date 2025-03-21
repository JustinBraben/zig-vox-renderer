//! Chunk Manager
//! owns texture_atlas
//! manages chunk creation
const std = @import("std");
const Allocator = std.mem.Allocator;
const Atlas = @import("../gfx/atlas.zig");
const Chunk = @import("../world/chunk.zig");

const ChunkManager = @This();

allocator: Allocator,
texture_atlas: Atlas,

pub fn init(allocator: Allocator, atlas_path: [:0]const u8) !ChunkManager {
    return .{
        .allocator = allocator,
        .texture_atlas = try Atlas.initFromPath(atlas_path, 16, 16),
    };
}

pub fn deinit(self: *ChunkManager) void {
    self.texture_atlas.deinit();
}

pub fn generateChunkTerrain(_: *ChunkManager, chunk: *Chunk) !void {
    // Your terrain generation logic
    // Example: Simple flat terrain with some blocks
    const height = 5; // Flat terrain height
    
    var x: u32 = 0;
    while (x < Chunk.SIZE) : (x += 1) {
        var z: u32 = 0;
        while (z < Chunk.SIZE) : (z += 1) {
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                // Bedrock at bottom layer
                if (y == 0) {
                    chunk.setBlock(x, y, z, .{ .id = 7 });
                } 
                // Dirt for most layers
                else if (y < height - 1) {
                    chunk.setBlock(x, y, z, .{ .id = 3 });
                } 
                // Grass on top
                else {
                    chunk.setBlock(x, y, z, .{ .id = 2 });
                }
            }
        }
    }
}

pub fn generateChunkMesh(self: *ChunkManager, chunk: *Chunk) !void {
    try chunk.generateMesh(&self.texture_atlas);
}