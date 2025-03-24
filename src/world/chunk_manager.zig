//! Chunk Manager
//! Manages chunk lifecycle, loading, unloading, and caching
const std = @import("std");
const Allocator = std.mem.Allocator;
const znoise = @import("znoise");
const Atlas = @import("../gfx/atlas.zig");
const Chunk = @import("../world/chunk.zig");
const ChunkPos = Chunk.ChunkPos;

const ChunkManager = @This();

const ChunkCache = struct {
    last_accessed: i64,
    chunk: *Chunk,
};

allocator: Allocator,
texture_atlas: Atlas,
chunks: std.AutoHashMap(ChunkPos, ChunkCache),
/// Maximum number of chunks to keep in memory at once
max_chunks: usize = 256,

pub fn init(allocator: Allocator, atlas_path: [:0]const u8) !ChunkManager {
    return .{
        .allocator = allocator,
        .texture_atlas = try Atlas.initFromPath(atlas_path, 16, 16),
        .chunks = std.AutoHashMap(ChunkPos, ChunkCache).init(allocator),
    };
}

pub fn deinit(self: *ChunkManager) void {
    var it = self.chunks.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.chunk.deinit();
        self.allocator.destroy(entry.value_ptr.chunk);
    }
    self.chunks.deinit();
    self.texture_atlas.deinit();
}

/// Get a chunk at the specified position. Creates it if it doesn't exist.
pub fn getChunk(self: *ChunkManager, pos: ChunkPos) !*Chunk {
    const current_time = std.time.timestamp();
    
    // Check if the chunk is already loaded
    if (self.chunks.getPtr(pos)) |cache_entry| {
        // Update last accessed time
        cache_entry.last_accessed = current_time;
        return cache_entry.chunk;
    }
    
    // // Check if we need to evict chunks to stay within memory limits
    // if (self.chunks.count() >= self.max_chunks) {
    //     try self.evictLeastRecentlyUsedChunks(1);
    // }
    
    // Create a new chunk
    var chunk: *Chunk = undefined;
    chunk = try self.allocator.create(Chunk);
    chunk.* = Chunk.init(self.allocator, pos);
    
    // Store in the cache
    try self.chunks.put(pos, .{
        .last_accessed = current_time,
        .chunk = chunk,
    });
    
    return chunk;
}

/// Release a chunk from memory
pub fn releaseChunk(self: *ChunkManager, pos: ChunkPos) !void {
    // Get the chunk if it exists
    const entry = self.chunks.get(pos) orelse return;
    
    // Deinit and free the chunk
    entry.chunk.deinit();
    self.allocator.destroy(entry.chunk);
    
    // Remove from the hashmap
    _ = self.chunks.remove(pos);
}

/// Updates chunks around the player position, loading and unloading as needed
pub fn updateChunksAroundPlayer(self: *ChunkManager, player_pos: [3]f32, render_distance: i32) !void {
    // Calculate player's chunk position
    const player_chunk = ChunkPos.fromWorldPos(player_pos[0], player_pos[2]);
    
    // Track chunks to keep
    var chunks_to_keep = std.AutoHashMap(ChunkPos, void).init(self.allocator);
    defer chunks_to_keep.deinit();
    
    // Determine which chunks should be loaded
    var chunk_x = player_chunk.x - render_distance;
    while (chunk_x <= player_chunk.x + render_distance) : (chunk_x += 1) {
        var chunk_z = player_chunk.z - render_distance;
        while (chunk_z <= player_chunk.z + render_distance) : (chunk_z += 1) {
            const pos = ChunkPos{ .x = chunk_x, .z = chunk_z };
            
            // Calculate distance from player chunk
            const dx = chunk_x - player_chunk.x;
            const dz = chunk_z - player_chunk.z;
            const distance_squared = dx * dx + dz * dz;
            
            // Skip if outside circular render distance
            if (distance_squared > render_distance * render_distance) {
                continue;
            }
            
            // Mark this chunk to keep
            try chunks_to_keep.put(pos, {});
            
            // Ensure the chunk is loaded
            _ = try self.getChunk(pos);
        }
    }
    
    // Collect chunks to unload
    var chunks_to_unload = std.ArrayList(ChunkPos).init(self.allocator);
    defer chunks_to_unload.deinit();
    
    var it = self.chunks.iterator();
    while (it.next()) |entry| {
        if (!chunks_to_keep.contains(entry.key_ptr.*)) {
            try chunks_to_unload.append(entry.key_ptr.*);
        }
    }
    
    // Unload chunks outside render distance
    for (chunks_to_unload.items) |pos| {
        try self.releaseChunk(pos);
    }
}

/// Find blocks that span across chunk boundaries
pub fn getBlockAtWorldCoords(self: *ChunkManager, world_x: i32, world_y: i32, world_z: i32) !?Chunk.Block {
    // Calculate chunk position
    const chunk_pos = ChunkPos{
        .x = @divFloor(world_x, Chunk.CHUNK_SIZE),
        .z = @divFloor(world_z, Chunk.CHUNK_SIZE),
    };
    
    // Calculate local coordinates within the chunk
    const local_x = @mod(world_x, Chunk.CHUNK_SIZE);
    const local_y = world_y; // Y doesn't change with chunks
    const local_z = @mod(world_z, Chunk.CHUNK_SIZE);
    
    // Handle negative coordinates (mod returns positive value, we want negative)
    const adjusted_local_x = if (local_x < 0) local_x + Chunk.CHUNK_SIZE else local_x;
    const adjusted_local_z = if (local_z < 0) local_z + Chunk.CHUNK_SIZE else local_z;
    
    // Make sure coordinates are valid for a chunk
    if (local_y < 0 or local_y >= Chunk.CHUNK_SIZE) {
        return null;
    }
    
    // Try to get the chunk
    const entry = self.chunks.get(chunk_pos) orelse return null;
    
    // Get the block from the chunk
    return entry.chunk.getBlock(
        @intCast(adjusted_local_x), 
        @intCast(local_y), 
        @intCast(adjusted_local_z)
    );
}

/// Evict least recently used chunks when cache is full
fn evictLeastRecentlyUsedChunks(self: *ChunkManager, count: usize) !void {
    var eviction_list = std.ArrayList(struct { pos: ChunkPos, timestamp: i64 }).init(self.allocator);
    defer eviction_list.deinit();
    
    // Collect all chunks and their timestamps
    var it = self.chunks.iterator();
    while (it.next()) |entry| {
        try eviction_list.append(.{
            .pos = entry.key_ptr.*,
            .timestamp = entry.value_ptr.last_accessed,
        });
    }
    
    // Sort by timestamp (oldest first)
    std.sort.sort(struct { pos: ChunkPos, timestamp: i64 }, eviction_list.items, {}, struct {
        fn lessThan(_: void, a: struct { pos: ChunkPos, timestamp: i64 }, b: struct { pos: ChunkPos, timestamp: i64 }) bool {
            return a.timestamp < b.timestamp;
        }
    }.lessThan);
    
    // Evict the oldest chunks
    const evict_count = @min(count, eviction_list.items.len);
    for (0..evict_count) |i| {
        try self.releaseChunk(eviction_list.items[i].pos);
    }
}

/// Check if a chunk needs mesh updating
pub fn updateChunkMesh(self: *ChunkManager, chunk: *Chunk) !void {
    if (chunk.is_dirty) {
        try chunk.generateMesh(&self.texture_atlas);
    }
}

/// Update meshes for all loaded chunks
pub fn updateAllMeshes(self: *ChunkManager) !void {
    var it = self.chunks.iterator();
    while (it.next()) |entry| {
        try self.updateChunkMesh(entry.value_ptr.chunk);
    }
}

test "chunk manager basics" {
    // Create a testing allocator
    const allocator = std.testing.allocator;

    const zstbi = @import("zstbi");
    zstbi.init(allocator);
    defer zstbi.deinit();
    
    // Create the chunk manager
    var chunk_manager = try ChunkManager.init(allocator, "assets/textures/blocks.png");
    defer chunk_manager.deinit();
    
    // Test getting a chunk
    const pos = ChunkPos{ .x = 0, .z = 0 };
    const chunk = try chunk_manager.getChunk(pos);

    try std.testing.expectEqual(ChunkPos{ .x = 0, .z = 0 }, chunk.pos);
    
    // Verify the chunk exists
    try std.testing.expect(chunk_manager.chunks.contains(pos));
    
    // Test releasing a chunk
    try chunk_manager.releaseChunk(pos);
    try std.testing.expect(!chunk_manager.chunks.contains(pos));
}