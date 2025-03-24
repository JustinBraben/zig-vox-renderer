const std = @import("std");
const Allocator = std.mem.Allocator;
const zm = @import("zmath");
const znoise = @import("znoise");
const Chunk = @import("chunk.zig");
const ChunkPos = Chunk.ChunkPos;
const ChunkManager = @import("chunk_manager.zig");
const Atlas = @import("../gfx/atlas.zig");
const Utils = @import("../utils.zig");

const World = @This();

allocator: Allocator,
rng: std.Random.DefaultPrng,
seed: i32,
gen: znoise.FnlGenerator,
chunks: std.AutoHashMap(ChunkPos, *Chunk),
render_distance: i32 = 4,

pub fn init(gpa: Allocator) !World {
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const seed = rng.random().int(i32);
    const gen = znoise.FnlGenerator{
        .seed = @intCast(seed)
    };
    return .{
        .allocator = gpa,
        .rng = rng,
        .seed = seed,
        .gen = gen,
        .chunks = std.AutoHashMap(ChunkPos, *Chunk).init(gpa),
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
    var it = self.chunks.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.deinit();
        self.allocator.destroy(entry.value_ptr.*);
    }
    self.chunks.deinit();
}

pub fn updateChunksAroundPlayer(self: *World, player_pos: [3]f32, chunk_manager: *ChunkManager) !void {
    // Calculate which chunk the player is in
    const player_chunk_x: i32 = @intFromFloat(@floor(player_pos[0] / Chunk.CHUNK_SIZE));
    const player_chunk_z: i32 = @intFromFloat(@floor(player_pos[2] / Chunk.CHUNK_SIZE));
    
    // Track chunks to unload
    var chunks_to_keep = std.AutoHashMap(ChunkPos, void).init(self.allocator);
    defer chunks_to_keep.deinit();

    // Determine which chunks should be loaded
    var chunk_x = player_chunk_x - self.render_distance;
    while (chunk_x <= player_chunk_x + self.render_distance) : (chunk_x += 1) {
        var chunk_z = player_chunk_z - self.render_distance;
        while (chunk_z <= player_chunk_z + self.render_distance) : (chunk_z += 1) {
            const pos = ChunkPos{ .x = chunk_x, .z = chunk_z };
            
            // Calculate distance from player chunk
            const dx = chunk_x - player_chunk_x;
            const dz = chunk_z - player_chunk_z;
            const distance_squared = dx * dx + dz * dz;
            
            // Skip if outside circular render distance
            if (distance_squared > self.render_distance * self.render_distance) {
                continue;
            }
            
            // Mark this chunk to keep
            try chunks_to_keep.put(pos, {});
            
            // Load chunk if not already loaded
            if (!self.chunks.contains(pos)) {
                try self.loadChunk(pos, chunk_manager);
            }
        }
    }
    
    // Unload chunks outside render distance
    var it = self.chunks.iterator();
    var chunks_to_unload = std.ArrayList(ChunkPos).init(self.allocator);
    defer chunks_to_unload.deinit();
    
    while (it.next()) |entry| {
        if (!chunks_to_keep.contains(entry.key_ptr.*)) {
            try chunks_to_unload.append(entry.key_ptr.*);
        }
    }
    
    for (chunks_to_unload.items) |pos| {
        try self.unloadChunk(pos);
    }
}

fn loadChunk(self: *World, pos: ChunkPos, chunk_manager: *ChunkManager) !void {
    var chunk: *Chunk = undefined;
    chunk = try self.allocator.create(Chunk);
    chunk.* = Chunk.init(self.allocator, .{ .x = pos.x, .z = pos.z });
    // var chunk: Chunk = undefined;
    // const chunk = Chunk.init(self.allocator, .{ .x = pos.x, .z = pos.z });
    
    // Generate terrain
    try chunk_manager.generateChunkTerrain(chunk);
    
    // Generate mesh
    try chunk_manager.generateChunkMesh(chunk);
    
    // Store in world
    try self.chunks.put(pos, chunk);
}

fn unloadChunk(self: *World, pos: ChunkPos) !void {
    const chunk = self.chunks.get(pos) orelse return;
    chunk.deinit();
    self.allocator.destroy(chunk);
    _ = self.chunks.remove(pos);
}

pub fn draw(self: *World) void {
    for (self.chunks.items) |chunk| {
        if (chunk.mesh) |*mesh| {
            _ = mesh;
            // const chunk_offset = chunk.pos.worldOffset();

            // const chunk_model = zm.translation(
            //     chunk_offset[0],
            //     0.0,
            //     chunk_offset[2]
            // );
            
            // // Set the model matrix for the chunk
            // basic_voxel_mesh_shader.setMat4f("u_model", zm.matToArr(chunk_model));

            // gl.activeTexture(gl.TEXTURE0);
            // texture_atlas.texture.bind();
            // mesh.draw();
        }
    }
}