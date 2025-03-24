//! World
//! Generation, persistance, save management
const std = @import("std");
const Allocator = std.mem.Allocator;
const zm = @import("zmath");
const znoise = @import("znoise");
const Atlas = @import("../gfx/atlas.zig");
const Chunk = @import("chunk.zig");
const ChunkPos = Chunk.ChunkPos;
const ChunkManager = @import("chunk_manager.zig");

const World = @This();

/// Different biome types for terrain generation
pub const BiomeType = enum {
    plains,
    desert,
    mountains,
    forest,
};

allocator: Allocator,
chunk_manager: *ChunkManager,
rng: std.Random.DefaultPrng,
seed: i32,
terrain_gen: znoise.FnlGenerator,
/// Current game time (day/night cycle)
game_time: f32 = 0.0,
/// Weather state
is_raining: bool = false,
/// World generation configuration
generation_config: struct {
    /// Maximum terrain height
    max_height: i32 = 64,
    /// Biome noise scale
    biome_scale: f32 = 0.01,
    /// Terrain noise scale
    terrain_scale: f32 = 0.05,
    /// Sea level
    sea_level: i32 = 32,
},

pub fn init(allocator: Allocator, chunk_manager: *ChunkManager, seed: ?i32) !World {
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const world_seed = seed orelse rng.random().int(i32);
    const gen = znoise.FnlGenerator{
        .seed = @intCast(world_seed)
    };
    
    return .{
        .allocator = allocator,
        .chunk_manager = chunk_manager,
        .rng = rng,
        .seed = world_seed,
        .terrain_gen = gen,
        .generation_config = .{},
    };
}

// pub fn generate(self: *World, atlas: *const Atlas) !void {
//     try self.chunks.append(Chunk.init(self.allocator, .{ .x = 0, .z = -1 }));
//     var basic_chunk = self.chunks.getLast();
//     basic_chunk.setBlock(1, 1, 1, .{ .id = 1 });
//     basic_chunk.setBlock(5, 5, 5, .{ .id = 1 });
//     basic_chunk.setBlock(6, 6, 6, .{ .id = 1 });
//     basic_chunk.setBlock(8, 10, 10, .{ .id = 1 });
//     basic_chunk.setBlock(10, 10, 10, .{ .id = 1 });
//     try basic_chunk.generateMesh(atlas);
// }

// pub fn generate(self: *World) !void {
//     // for (0..1000) |x_pos| {
//     //     for (0..1000) |z_pos| {
//     //         const x = @mod(@as(f32, @floatFromInt(x_pos)), 1000.0);
//     //         const z = @mod(@as(f32, @floatFromInt(z_pos)), 1000.0);

//     //         const y = @floor(self.gen.noise2(x, z) * self.height_range);

//     //         // const position = zm.translation(x, y, z);
//     //         try self.model_matrices.append(zm.matToArr(zm.translation(x, y, z)));
//     //     }
//     // }

//     // TODO: Fix chunk generation
//     // for (0..10) |x_pos| {
//     //     for (0..10) |y_pos| {
//     //         for (0..10) |z_pos| {
//     //             const x = @as(f32, @floatFromInt(x_pos));
//     //             const y = @as(f32, @floatFromInt(y_pos));
//     //             const z = @as(f32, @floatFromInt(z_pos));

//     //             self.chunk.setBlock(.Cube, @intFromFloat(x), @intFromFloat(y), @intFromFloat(z));
//     //             try self.model_matrices.append(zm.matToArr(zm.translation(x, y, z)));
//     //         }
//     //     }
//     // }

//     for (0..200) |x_pos| {
//         for (0..100) |y_pos| {
//             for (0..100) |z_pos| {
//                 const x = @mod(@as(f32, @floatFromInt(x_pos)), 1000.0);
//                 const y = @mod(@as(f32, @floatFromInt(y_pos)), 1000.0);
//                 const z = @mod(@as(f32, @floatFromInt(z_pos)), 1000.0);
                
//                 const noise = self.gen.noise3(x, y, z);
//                 if (noise > 0) {
//                     try self.model_matrices.append(zm.matToArr(zm.translation(x, y, z)));
//                 }
//             }
//         }
//     }

//     self.flattened_matrices = try Utils.flattenMatrices(self.model_matrices.items, self.allocator);
// }

pub fn deinit(self: *World) void {
    // var it = self.chunks.iterator();
    // while (it.next()) |entry| {
    //     entry.value_ptr.*.deinit();
    //     self.allocator.destroy(entry.value_ptr.*);
    // }
    // self.chunks.deinit();
    _ = &self;
}

/// Updates the world state - time, weather, etc.
pub fn update(self: *World, delta_time: f32) void {
    // Update game time (day/night cycle)
    self.game_time += delta_time * 0.1; // Adjust speed as needed
    if (self.game_time >= 24.0) {
        self.game_time -= 24.0;
    }
    
    // Random weather changes
    if (self.rng.random().float(f32) < 0.001) { // 0.1% chance per update
        self.is_raining = !self.is_raining;
    }
}

/// Generate terrain for a chunk at the given position
pub fn generateTerrain(self: *World, chunk: *Chunk) !void {
    // Constants for terrain generation
    const HEIGHT_SCALE = @as(f32, @floatFromInt(self.generation_config.max_height));
    const TERRAIN_SCALE = self.generation_config.terrain_scale;
    const BIOME_SCALE = self.generation_config.biome_scale;
    const SEA_LEVEL = self.generation_config.sea_level;
    
    // Iterate through all positions in the chunk
    var x: u32 = 0;
    while (x < Chunk.CHUNK_SIZE) : (x += 1) {
        var z: u32 = 0;
        while (z < Chunk.CHUNK_SIZE) : (z += 1) {
            // Calculate world coordinates for seamless generation
            const world_x = @as(f32, @floatFromInt(chunk.pos.x * Chunk.CHUNK_SIZE + @as(i32, @intCast(x))));
            const world_z = @as(f32, @floatFromInt(chunk.pos.z * Chunk.CHUNK_SIZE + @as(i32, @intCast(z))));
            
            // Determine biome type using a separate noise layer
            const biome_noise = self.terrain_gen.noise2(world_x * BIOME_SCALE, world_z * BIOME_SCALE);
            const biome = self.getBiomeFromNoise(biome_noise);
            
            // Generate height using noise
            const height_noise = self.terrain_gen.noise2(world_x * TERRAIN_SCALE, world_z * TERRAIN_SCALE);
            const height_adjusted = self.adjustHeightForBiome(height_noise, biome);
            
            // Calculate terrain height
            const terrain_height = @as(i32, @intFromFloat(@floor(height_adjusted * HEIGHT_SCALE)));
            
            // Fill blocks in the chunk
            var y: u32 = 0;
            while (y < Chunk.CHUNK_SIZE) : (y += 1) {
                const world_y = @as(i32, @intCast(y));
                if (world_y < terrain_height) {
                    // Underground blocks
                    if (world_y < terrain_height - 4) {
                        chunk.setBlock(x, y, z, .{ .id = .GRASS }); // Stone
                    } else {
                        chunk.setBlock(x, y, z, .{ .id = .GRASS }); // Dirt
                    }
                } else if (world_y == terrain_height) {
                    // Surface block based on biome
                    const surface_block = self.getSurfaceBlockForBiome(biome);
                    chunk.setBlock(x, y, z, .{ .id = @enumFromInt(surface_block) });
                } else if (world_y <= SEA_LEVEL and world_y > terrain_height) {
                    // Water if below sea level
                    chunk.setBlock(x, y, z, .{ .id = .GRASS }); // Water
                } else {
                    // Air above surface
                    chunk.setBlock(x, y, z, .{ .id = .GRASS }); // Air
                }
            }
        }
    }
}

/// Generate a simple flat world for testing
pub fn generateFlatWorld(_: *World, chunk: *Chunk) !void {
    const FLAT_HEIGHT = 4; // Height of the terrain
    
    var x: u32 = 0;
    while (x < Chunk.CHUNK_SIZE) : (x += 1) {
        var z: u32 = 0;
        while (z < Chunk.CHUNK_SIZE) : (z += 1) {
            var y: u32 = 0;
            while (y < Chunk.CHUNK_SIZE) : (y += 1) {
                if (y < FLAT_HEIGHT - 1) {
                    chunk.setBlock(x, y, z, .{ .id = .STONE }); // Stone
                } else if (y == FLAT_HEIGHT - 1) {
                    chunk.setBlock(x, y, z, .{ .id = .DIRT }); // Dirt
                } else if (y == FLAT_HEIGHT) {
                    chunk.setBlock(x, y, z, .{ .id = .GRASS }); // Grass
                } else {
                    chunk.setBlock(x, y, z, .{ .id = .AIR }); // Air
                }
            }
        }
    }
}

/// Update chunks around the player
pub fn updateChunksAroundPlayer(self: *World, player_pos: [3]f32) !void {
    try self.chunk_manager.updateChunksAroundPlayer(player_pos, Chunk.RENDER_DISTANCE);
    
    // Process newly loaded chunks that need terrain generation
    var it = self.chunk_manager.chunks.iterator();
    while (it.next()) |entry| {
        const chunk = entry.value_ptr.chunk;
        // Only generate terrain if this is a new chunk
        if (chunk.is_dirty) {
            // Generate terrain
            try self.generateTerrain(chunk);
            // Mark for mesh generation
            try self.chunk_manager.updateChunkMesh(chunk);
        }
    }
}

// /// Save the current world state to disk
// pub fn saveWorld(self: *World, world_name: []const u8) !void {
//     // Create a directory for the world
//     try std.fs.cwd().makePath(world_name);
    
//     // Save world metadata
//     var meta_file = try std.fs.cwd().createFile(
//         try std.fmt.allocPrint(self.allocator, "{s}/world.meta", .{world_name}),
//         .{}
//     );
//     defer meta_file.close();
    
//     // Write metadata (seed, time, etc.)
//     try meta_file.writer().print(
//         "seed={d}\ntime={d}\nweather={d}\n",
//         .{ self.seed, self.game_time, @intFromBool(self.is_raining) }
//     );
    
//     // Save all currently loaded chunks
//     var it = self.chunk_manager.chunks.iterator();
//     while (it.next()) |entry| {
//         const chunk = entry.value_ptr.chunk;
//         const chunk_pos = chunk.pos;
        
//         // Create filename for this chunk
//         const chunk_filename = try std.fmt.allocPrint(
//             self.allocator,
//             "{s}/chunk_{d}_{d}.dat",
//             .{ world_name, chunk_pos.x, chunk_pos.z }
//         );
//         defer self.allocator.free(chunk_filename);
        
//         // Save chunk data
//         var chunk_file = try std.fs.cwd().createFile(chunk_filename, .{});
//         defer chunk_file.close();
        
//         // Serialize chunk data
//         // For simplicity, we'll just write the raw block data
//         // In a real implementation, you might want to compress this
//         for (chunk.blocks, 0..) |x_slice, x| {
//             for (x_slice, 0..) |y_slice, y| {
//                 for (y_slice, 0..) |block, z| {
//                     try chunk_file.writer().writeIntLittle(u16, block.id);
//                 }
//             }
//         }
//     }
// }

// /// Load a world from disk
// pub fn loadWorld(self: *World, world_name: []const u8) !void {
//     // Read world metadata
//     var meta_file = try std.fs.cwd().openFile(
//         try std.fmt.allocPrint(self.allocator, "{s}/world.meta", .{world_name}),
//         .{}
//     );
//     defer meta_file.close();
    
//     // Basic parsing of metadata file
//     var buf: [1024]u8 = undefined;
//     const meta_content = try meta_file.readToEndAlloc(self.allocator, buf.len);
//     defer self.allocator.free(meta_content);
    
//     // Parse metadata (very basic implementation)
//     var lines = std.mem.split(u8, meta_content, "\n");
//     while (lines.next()) |line| {
//         if (std.mem.startsWith(u8, line, "seed=")) {
//             self.seed = try std.fmt.parseInt(i32, line[5..], 10);
//             // Reinitialize the terrain generator with the loaded seed
//             self.terrain_gen = znoise.FnlGenerator{
//                 .seed = @intCast(self.seed)
//             };
//         } else if (std.mem.startsWith(u8, line, "time=")) {
//             self.game_time = try std.fmt.parseFloat(f32, line[5..]);
//         } else if (std.mem.startsWith(u8, line, "weather=")) {
//             const weather_int = try std.fmt.parseInt(u8, line[8..], 10);
//             self.is_raining = weather_int == 1;
//         }
//     }
    
//     // Note: We don't load any chunks here - they'll be loaded
//     // when the player moves near them through the standard mechanism
// }

/// Get block type at a specific world position
pub fn getBlockAtWorldPos(self: *World, world_x: f32, world_y: f32, world_z: f32) !?Chunk.Block {
    const x = @as(i32, @intFromFloat(@floor(world_x)));
    const y = @as(i32, @intFromFloat(@floor(world_y)));
    const z = @as(i32, @intFromFloat(@floor(world_z)));
    
    return try self.chunk_manager.getBlockAtWorldCoords(x, y, z);
}

/// Get the biome type from noise value
fn getBiomeFromNoise(self: *World, noise: f32) BiomeType {
    _ = self; // Unused for now
    
    // Simple biome mapping based on noise value
    if (noise < -0.5) {
        return .desert;
    } else if (noise < 0.0) {
        return .plains;
    } else if (noise < 0.5) {
        return .forest;
    } else {
        return .mountains;
    }
}

/// Adjust height noise based on biome
fn adjustHeightForBiome(self: *World, height: f32, biome: BiomeType) f32 {
    _ = self; // Unused for now
    
    return switch (biome) {
        .plains => height * 0.5 + 0.4, // Flatter, higher base
        .desert => height * 0.3 + 0.3, // Very flat
        .forest => height * 0.7 + 0.4, // Somewhat hilly
        .mountains => height * 1.2 + 0.5, // Very mountainous
    };
}

/// Get the appropriate surface block for a biome
fn getSurfaceBlockForBiome(self: *World, biome: BiomeType) u16 {
    return switch (biome) {
        .plains => 1, // Grass
        .desert => 4, // Sand
        .forest => 1, // Grass
        .mountains => biome_block: {
            // Random stone outcroppings
            const random_val = self.rng.random().float(f32);
            break :biome_block if (random_val < 0.7) 1 else 3; // 70% grass, 30% stone
        },
    };
}

test "world generation basics" {
    // Create a testing allocator
    const allocator = std.testing.allocator;

    const zstbi = @import("zstbi");
    zstbi.init(allocator);
    defer zstbi.deinit();
    
    // Create chunk manager
    var chunk_manager = try ChunkManager.init(allocator, "assets/textures/blocks.png");
    defer chunk_manager.deinit();
    
    // Create world with a fixed seed for deterministic testing
    var world = try World.init(allocator, &chunk_manager, 12345);
    defer world.deinit();
    
    // Test that the world initialized correctly
    try std.testing.expectEqual(@as(i32, 12345), world.seed);
    
    // Get a test chunk
    const chunk_pos = ChunkPos{ .x = 0, .z = 0 };
    const chunk = try chunk_manager.getChunk(chunk_pos);
    
    // Generate terrain and verify it's not empty
    try world.generateFlatWorld(chunk);
    
    // Check that we have some non-air blocks
    var has_terrain = false;
    for (chunk.blocks) |x_slice| {
        for (x_slice) |y_slice| {
            for (y_slice) |block| {
                if (block.id != .AIR) {
                    has_terrain = true;
                    break;

                }
            }
        }
    }
    
    try std.testing.expect(has_terrain);
}