//! Chunk Manager
//! owns texture_atlas
//! manages chunk creation
const std = @import("std");
const Allocator = std.mem.Allocator;
const znoise = @import("znoise");
const Atlas = @import("../gfx/atlas.zig");
const Chunk = @import("../world/chunk.zig");

const ChunkManager = @This();

allocator: Allocator,
texture_atlas: Atlas,
rng: std.Random.DefaultPrng,
seed: i32,
gen: znoise.FnlGenerator,

pub fn init(allocator: Allocator, atlas_path: [:0]const u8) !ChunkManager {
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const seed = rng.random().int(i32);
    const gen = znoise.FnlGenerator{
        .seed = @intCast(seed)
    };
    return .{
        .allocator = allocator,
        .texture_atlas = try Atlas.initFromPath(atlas_path, 16, 16),
        .rng = rng,
        .seed = seed,
        .gen = gen,
    };
}

pub fn deinit(self: *ChunkManager) void {
    self.texture_atlas.deinit();
}

/// Simple flat terrain with some blocks
pub fn generateFlatChunkTerrain(_: *ChunkManager, chunk: *Chunk) !void {
    // Example: Simple flat terrain with some blocks
    const height = 8; // Flat terrain height

    var x: u32 = 0;
    while (x < Chunk.CHUNK_SIZE) : (x += 1) {
        var z: u32 = 0;
        while (z < Chunk.CHUNK_SIZE) : (z += 1) {
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                // Just dirt for now
                if (y == 0) {
                    chunk.setBlock(x, y, z, .{ .id = 1 });
                }
            }
        }
    }
}

pub fn generateChunkTerrain(self: *ChunkManager, chunk: *Chunk) !void {
    // Constants to tune the terrain generation
    // Test
    const NOISE_SCALE = 0.05;     // Controls detail level (smaller = more detailed)
    const NOISE_THRESHOLD = 0.0;  // Threshold for placing blocks (-1 to 1 range)

    var x: u32 = 0;
    while (x < Chunk.CHUNK_SIZE) : (x += 1) {
        var y: u32 = 0;
        while (y < Chunk.CHUNK_SIZE) : (y += 1) {
            var z: u32 = 0;
            while (z < Chunk.CHUNK_SIZE) : (z += 1) {
                // Calculate world coordinates for seamless chunks
                const worldX: f32 = @as(f32, @floatFromInt(chunk.pos.x * Chunk.CHUNK_SIZE + @as(i32, @intCast(x))));
                const worldY: f32 = @as(f32, @floatFromInt(y));
                const worldZ: f32 = @as(f32, @floatFromInt(chunk.pos.z * Chunk.CHUNK_SIZE + @as(i32, @intCast(z))));

                // Generate 3D noise
                const noiseValue = self.gen.noise3(
                    worldX * NOISE_SCALE, 
                    worldY * NOISE_SCALE, 
                    worldZ * NOISE_SCALE
                );

                // Place grass block if noise is above threshold
                if (noiseValue > NOISE_THRESHOLD) {
                    chunk.setBlock(x, y, z, .{ .id = 1 }); // Grass block
                }
                // Otherwise, leave it as air (don't set any block)
            }
        }
    }
}

pub fn generateChunkMesh(self: *ChunkManager, chunk: *Chunk) !void {
    try chunk.generateMesh(&self.texture_atlas);
}