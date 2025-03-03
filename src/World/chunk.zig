const std = @import("std");
const Allocator = std.mem.Allocator;
const zmath = @import("zmath");
const Mesh = @import("../Models/mesh.zig");
const Vertex = Mesh.Vertex;

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
        .allocator = allocator,
    };

    // Initialize blocks with air (id 0)
    for (&chunk.blocks) |*x_slice| {
        for (x_slice) |*y_slice| {
            for (y_slice) |*block| {
                block.* = Block{ .id = 0 };
            }
        }
    }

    return chunk;
}

// pub fn init(allocator: Allocator, pos: ChunkPos) !Chunk {
//     var chunk: Chunk = undefined;

//     chunk = .{
//         .pos = pos,
//         .blocks = undefined,
//         .mesh = null,
//         .is_dirty = true,
//         .is_empty = false,
//         .allocator = allocator,
//     };

//     // Initialize blocks with air (id 0)
//     for (&chunk.blocks) |*x_slice| {
//         for (x_slice) |*y_slice| {
//             for (y_slice) |*block| {
//                 block.* = Block{ .id = 0 };
//             }
//         }
//     }

//     return chunk;
// }

pub fn deinit(self: *Chunk) void {
    if (self.mesh) |*mesh| {
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

pub fn generateMesh(self: *Chunk) !void {
    // Skip if the chunk is not dirty
    if (!self.is_dirty) return;

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
                if (block.id == 0) continue;

                has_visible_blocks = true;

                // World position of this block
                const world_x: i32 = @as(i32, @intCast(x)) + self.pos.x * CHUNK_SIZE;
                const world_y: i32 = @as(i32, @intCast(y));
                const world_z: i32 = @as(i32, @intCast(z)) + self.pos.z * CHUNK_SIZE;
                // _ = world_x;
                // _ = world_y;
                // _ = world_z;

                // Local position for vertex offset within the chunk
                const local_x: f32 = @floatFromInt(x);
                const local_y: f32 = @floatFromInt(y);
                const local_z: f32 = @floatFromInt(z);

                for (directions, 0..) |dir, dir_idx| {
                    // Position of the adjacent block in world coordinates
                    const adj_x = world_x + dir[0];
                    const adj_y = world_y + dir[1];
                    const adj_z = world_z + dir[2];

                    // Check if the adjacent block is empty (air) or outside the chunk
                    var is_transparent = true;

                    // Convert world coordinates to chunk + local coordinates
                    const adj_chunk_x = @divFloor(adj_x, @as(i32, CHUNK_SIZE));
                    const adj_chunk_z = @divFloor(adj_z, @as(i32, CHUNK_SIZE));
                    const adj_local_x = @mod(adj_x, @as(i32, CHUNK_SIZE));
                    const adj_local_y = adj_y; // Y doesn't change with chunks
                    const adj_local_z = @mod(adj_z, @as(i32, CHUNK_SIZE));

                    // Check if adjacent position is in this chunk
                    if (adj_chunk_x == self.pos.x and adj_chunk_z == self.pos.z) {
                        // Make sure we're in bounds
                        if (adj_local_x >= 0 and adj_local_x < CHUNK_SIZE and
                            adj_local_y >= 0 and adj_local_y < CHUNK_SIZE and 
                            adj_local_z >= 0 and adj_local_z < CHUNK_SIZE) {
                            // Get the block from this chunk
                            const adj_block = self.blocks[@intCast(adj_local_x)][@intCast(adj_local_y)][@intCast(adj_local_z)];
                            is_transparent = adj_block.id == 0;
                        }
                    }
                    // For blocks at chunk boundaries, we'll always render the face for now
                    // In a complete implementation, you would check neighboring chunks

                    if (is_transparent) {
                        // Add face vertices to the mesh
                        // Select the appropriate face based on direction
                        switch (dir_idx) {
                            0 => try addFaceVertices(&vertices, local_x, local_y, local_z, .back),
                            1 => try addFaceVertices(&vertices, local_x, local_y, local_z, .front),
                            2 => try addFaceVertices(&vertices, local_x, local_y, local_z, .left),
                            3 => try addFaceVertices(&vertices, local_x, local_y, local_z, .right),
                            4 => try addFaceVertices(&vertices, local_x, local_y, local_z, .bottom),
                            5 => try addFaceVertices(&vertices, local_x, local_y, local_z, .top),
                            else => unreachable,
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

// Face type enum for readability
const FaceType = enum {
    front,
    back,
    left,
    right,
    top,
    bottom,
};

// Helper function to add vertices for a specific face of a block
fn addFaceVertices(vertices: *std.ArrayList(Vertex), x: f32, y: f32, z: f32, face_type: FaceType) !void {
    // Select the appropriate face vertices based on face type
    var face_vertices: [6]Vertex = undefined;
    
    // Copy the basic vertices from the template and offset them
    switch (face_type) {
        .back => {
            // Copy the back face vertices (vertices 0-5)
            face_vertices = basicFaceVertices(.back);
        },
        .front => {
            // Copy the front face vertices (vertices 6-11)
            face_vertices = basicFaceVertices(.front);
        },
        .left => {
            // Copy the left face vertices (vertices 12-17)
            face_vertices = basicFaceVertices(.left);
        },
        .right => {
            // Copy the right face vertices (vertices 18-23)
            face_vertices = basicFaceVertices(.right);
        },
        .bottom => {
            // Copy the bottom face vertices (vertices 24-29)
            face_vertices = basicFaceVertices(.bottom);
        },
        .top => {
            // Copy the top face vertices (vertices 30-35)
            face_vertices = basicFaceVertices(.top);
        },
    }
    
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
fn basicFaceVertices(face_type: FaceType) [6]Vertex {
    const start_idx: usize = switch (face_type) {
        .back => 0,
        .front => 6,
        .left => 12,
        .right => 18,
        .bottom => 24,
        .top => 30,
    };
    
    var result: [6]Vertex = undefined;
    for (0..6) |i| {
        result[i] = Mesh.basic_voxel_vertices[start_idx + i];
    }
    
    return result;
}