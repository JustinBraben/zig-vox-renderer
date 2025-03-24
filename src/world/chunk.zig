//! Chunk
//! fundamental data structure for a chunk
const std = @import("std");
const Allocator = std.mem.Allocator;
const zmath = @import("zmath");
const Mesh = @import("../models/mesh.zig");
const Vertex = Mesh.Vertex;
const Atlas = @import("../gfx/atlas.zig");
const Block = @import("block.zig");

const Chunk = @This();

pub const CHUNK_SIZE = 8; // Dimensions of a chunk (32x32x32 blocks)
pub const RENDER_DISTANCE = 8; // Number of chunks to render in each direction

pub const ChunkPos = struct {
    x: i32,
    z: i32,
    
    pub fn fromWorldPos(world_x: f32, world_z: f32) ChunkPos {
        const chunk_size_f32: f32 = @floatFromInt(CHUNK_SIZE);
        return .{
            .x = @intFromFloat(@floor(world_x / chunk_size_f32)),
            .z = @intFromFloat(@floor(world_z / chunk_size_f32)),
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

pos: ChunkPos,
blocks: [CHUNK_SIZE][CHUNK_SIZE][CHUNK_SIZE]Block,
mesh: ?Mesh = null,
/// Flag to indicate if the mesh needs rebuilding
is_dirty: bool,
/// Flag to indicate if the chunk has any visible blocks
is_empty: bool,
allocator: Allocator,
/// Neighbors for mesh generation (only assigned when needed)
neighbors: [6]?*Chunk = [_]?*Chunk{null} ** 6,

pub fn init(allocator: Allocator, pos: ChunkPos) Chunk {
    var chunk: Chunk = .{
        .pos = pos,
        .blocks = undefined,
        .mesh = null,
        .is_dirty = true,
        .is_empty = false,
        .allocator = allocator,
    };

    // Initialize blocks with air (id 0)
    for (&chunk.blocks) |*x_slice| {
        for (x_slice) |*y_slice| {
            for (y_slice) |*block| {
                block.* = Block{ .id = .AIR };
            }
        }
    }

    return chunk;
}

pub fn deinit(self: *Chunk) void {
    if (self.mesh) |*mesh| {
        mesh.deinit();
    }
}

pub fn getBlock(self: *Chunk, x: usize, y: usize, z: usize) Block {
    return self.blocks[x][y][z];
}

pub fn setBlock(self: *Chunk, x: usize, y: usize, z: usize, block: Block) void {
    self.blocks[x][y][z] = block;
    self.is_dirty = true; // Mark chunk for mesh rebuild
}

/// Check if coordinates are valid for this chunk
pub fn isValidCoord(x: usize, y: usize, z: usize) bool {
    return x < CHUNK_SIZE and y < CHUNK_SIZE and z < CHUNK_SIZE;
}

/// Set a neighbor chunk for accurate boundary mesh generation
pub fn setNeighbor(self: *Chunk, direction: Direction, chunk: ?*Chunk) void {
    self.neighbors[@intFromEnum(direction)] = chunk;
    // If we're setting a neighbor, we might need to update our mesh
    self.is_dirty = true;
}

pub const Direction = enum(u8) {
    north = 0, // +z
    south = 1, // -z
    west = 2,  // -x
    east = 3,  // +x
    down = 4,  // -y
    up = 5,    // +y
};

/// Get a block potentially from a neighboring chunk
pub fn getNeighboringBlock(self: *const Chunk, x: i32, y: i32, z: i32) ?Block {
    // Check if inside this chunk
    if (x >= 0 and x < CHUNK_SIZE and 
        y >= 0 and y < CHUNK_SIZE and 
        z >= 0 and z < CHUNK_SIZE) {
        return self.blocks[@intCast(x)][@intCast(y)][@intCast(z)];
    }
    
    // Determine which neighbor we need
    var direction: Direction = undefined;
    var nx: i32 = x;
    var ny: i32 = y;
    var nz: i32 = z;
    
    if (x < 0) {
        direction = .west;
        nx = CHUNK_SIZE - 1;
    } else if (x >= CHUNK_SIZE) {
        direction = .east;
        nx = 0;
    } else if (y < 0) {
        direction = .down;
        ny = CHUNK_SIZE - 1;
    } else if (y >= CHUNK_SIZE) {
        direction = .up;
        ny = 0;
    } else if (z < 0) {
        direction = .south;
        nz = CHUNK_SIZE - 1;
    } else if (z >= CHUNK_SIZE) {
        direction = .north;
        nz = 0;
    } else {
        unreachable; // Should have been caught in the first check
    }
    
    // Check if we have that neighbor
    const neighbor_chunk = self.neighbors[@intFromEnum(direction)];
    if (neighbor_chunk) |chunk| {
        return chunk.blocks[@intCast(nx)][@intCast(ny)][@intCast(nz)];
    }
    
    // No neighbor, assume air
    return .{ .id = .AIR };
}

pub fn generateMesh(self: *Chunk, atlas: *const Atlas) !void {
    // Skip if the chunk is not dirty or empty
    if (!self.is_dirty or self.is_empty) return;

    var vertices = std.ArrayList(Vertex).init(self.allocator);
    defer vertices.deinit();

    // Directions for checking adjacent blocks (x, y, z)
    const directions = [_][3]i32{
        [_]i32{ 0, 0, 1 },  // North
        [_]i32{ 0, 0, -1 }, // South
        [_]i32{ -1, 0, 0 }, // West
        [_]i32{ 1, 0, 0 },  // East
        [_]i32{ 0, -1, 0 }, // Down
        [_]i32{ 0, 1, 0 },  // Up
    };

    // Iterate through all blocks in the chunk
    var has_visible_blocks = false;

    for (self.blocks, 0..) |x_slice, x| {
        for (x_slice, 0..) |y_slice, y| {
            for (y_slice, 0..) |block, z| {
                // Skip air blocks (id 0)
                if (block.id == .AIR) continue;

                has_visible_blocks = true;

                // Local position for vertex offset within the chunk
                const local_x: f32 = @floatFromInt(x);
                const local_y: f32 = @floatFromInt(y);
                const local_z: f32 = @floatFromInt(z);

                for (directions, 0..) |dir, dir_idx| {
                    // Position of the adjacent block
                    const adj_x = @as(i32, @intCast(x)) + dir[0];
                    const adj_y = @as(i32, @intCast(y)) + dir[1];
                    const adj_z = @as(i32, @intCast(z)) + dir[2];

                    // Get the adjacent block, checking neighbors if needed
                    const adj_block_opt = self.getNeighboringBlock(adj_x, adj_y, adj_z);
                    const is_transparent = if (adj_block_opt) |adj_block| adj_block.isTransparent() else true;

                    if (is_transparent) {
                        // First, add face vertices to the mesh
                        const base_index = vertices.items.len;
                        try addFaceVertices(&vertices, local_x, local_y, local_z, @enumFromInt(dir_idx));

                        // Then update UVs for the newly added vertices
                        if (vertices.items.len >= base_index + 6) {
                            // Get slice of the 6 vertices we just added
                            const face_slice = vertices.items[base_index..base_index+6];
                            
                            // Get texture ID based on block type and face
                            const texture_id = getTextureForBlock(block, @enumFromInt(dir_idx));
                            
                            // Update UVs for this face
                            const uvs = atlas.getFaceCoords(texture_id);
                            
                            // Triangle 1
                            face_slice[0].uv = .{ uvs[0][0], uvs[0][1] }; // bottom-left
                            face_slice[1].uv = .{ uvs[1][0], uvs[1][1] }; // bottom-right
                            face_slice[2].uv = .{ uvs[2][0], uvs[2][1] }; // top-right

                            // Triangle 2
                            face_slice[3].uv = .{ uvs[4][0], uvs[4][1] }; // bottom-left
                            face_slice[4].uv = .{ uvs[5][0], uvs[5][1] }; // top-right
                            face_slice[5].uv = .{ uvs[3][0], uvs[3][1] }; // top-left
                        }
                    }
                }
            }
        }
    }

    // Create or update the mesh
    if (has_visible_blocks) {
        if (self.mesh == null) {
            self.mesh = Mesh.init();
        }
        self.mesh.?.uploadData(vertices.items);
    } else {
        if (self.mesh) |*mesh| {
            mesh.deinit();
            self.mesh = null;
        }
    }

    self.is_empty = !has_visible_blocks;
    self.is_dirty = false;
}

/// Select the appropriate texture for a block based on block type and face
fn getTextureForBlock(block: Block, face: Direction) Atlas.BlockTexture {
    return switch (@intFromEnum(block.id)) {
        // 0 => .AIR, // Should never happen
        1 => switch (face) { // Grass block
            .up => .DIRT_TOP,
            .down => .DIRT_BOTTOM,
            else => .DIRT_SIDE,
        },
        // 2 => .DIRT_SIDE, // Dirt
        // 3 => .STONE, // Stone
        // 4 => .SAND, // Sand
        // 5 => .WATER, // Water
        else => .DIRT_SIDE, // Default fallback
    };
}

// Helper function to add vertices for a specific face of a block
fn addFaceVertices(vertices: *std.ArrayList(Vertex), x: f32, y: f32, z: f32, face_type: Direction) !void {
    // Select the appropriate face vertices based on face type
    var face_vertices: [6]Vertex = undefined;

    face_vertices = basicFaceVertices(face_type);
    
    // Offset each vertex by the block position
    for (&face_vertices) |*vertex| {
        vertex.position[0] += x;
        vertex.position[1] += y;
        vertex.position[2] += z;
    }
    
    // Add vertices to the array
    for (face_vertices) |vertex| {
        try vertices.append(vertex);
    }
}

// Helper function to get the basic vertices for a face from our template
fn basicFaceVertices(face_type: Direction) [6]Vertex {
    const start_idx: usize = @intFromEnum(face_type) * 6;
    
    var result: [6]Vertex = undefined;
    for (0..6) |i| {
        result[i] = Mesh.basic_voxel_vertices[start_idx + i];
    }
    
    return result;
}

test "Chunk - initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create a test chunk
    const pos = ChunkPos{ .x = 0, .z = 0 };
    var chunk = Chunk.init(allocator, pos);
    defer chunk.deinit();
    
    // Verify the chunk is initialized with air blocks
    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                try std.testing.expectEqual(.AIR, chunk.getBlock(x, y, z).id);
            }
        }
    }
    
    // Test setting and getting blocks
    chunk.setBlock(1, 2, 3, .{ .id = .DIRT });
    try std.testing.expectEqual(.DIRT, chunk.getBlock(1, 2, 3).id);
    
    // Verify the chunk is marked dirty
    try std.testing.expect(chunk.is_dirty);
}

test "Chunk - hash function" {
    // Test that different positions create different hashes
    const pos1 = ChunkPos{ .x = 1, .z = 2 };
    const pos2 = ChunkPos{ .x = 2, .z = 1 };
    
    try std.testing.expect(pos1.hash() != pos2.hash());
    
    // Test that same positions create same hashes
    const pos3 = ChunkPos{ .x = 1, .z = 2 };
    try std.testing.expectEqual(pos1.hash(), pos3.hash());
}