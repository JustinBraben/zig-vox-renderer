const std = @import("std");
const Allocator = std.mem.Allocator;
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const Shader = @import("../gfx/shader.zig");
const VAO = @import("../gfx/vao.zig");
const VBO = @import("../gfx/vbo.zig");
const TextureAtlas = @import("../gfx/atlas.zig");

const Mesh = @This();

// Vertex data for a single block face
pub const Vertex = struct {
    position: [3]gl.Float,
    normal: [3]gl.Float,
    uv: [2]gl.Float,
    // You might want to add more attributes later
};

vao: VAO,
vbo: VBO,
vertex_count: usize = 0,

pub fn init() Mesh {
    var vao: VAO = undefined;
    var vbo: VBO = undefined;

    vao = VAO.init();
    vbo = VBO.init();

    vao.bind();
    vbo.bind(gl.ARRAY_BUFFER);

    // Define vertex attributes
    // Position
    vao.enableVertexAttribArray(0);
    vao.setVertexAttributePointer(0, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), null);
    
    // Normal
    vao.enableVertexAttribArray(1);
    const normal_offset: [*c]c_uint = (3 * @sizeOf(gl.Float));
    vao.setVertexAttributePointer(1, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), normal_offset);
    
    // UV
    vao.enableVertexAttribArray(2);
    const uv_offset: [*c]c_uint = (6 * @sizeOf(gl.Float));
    vao.setVertexAttributePointer(2, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), uv_offset);
    
    vao.unbind();

    return .{
        .vao = vao,
        .vbo = vbo,
    };
}

pub fn deinit(self: *Mesh) void {
    self.vbo.deinit();
    self.vao.deinit();
}

pub fn uploadData(self: *Mesh, vertices: []const Vertex) void {
    self.vao.bind();
    defer self.vao.unbind();

    self.vbo.bind(gl.ARRAY_BUFFER);
    gl.bufferData(gl.ARRAY_BUFFER, @intCast(vertices.len * @sizeOf(Vertex)), vertices.ptr, gl.STATIC_DRAW);
    self.vertex_count = vertices.len;
}

pub fn draw(self: *Mesh) void {
    if (self.vertex_count == 0) return;

    self.vao.bind();
    defer self.vao.unbind();
    gl.drawArrays(gl.TRIANGLES, 0, @intCast(self.vertex_count));
}

pub fn setBasicVoxel(self: *Mesh, atlas: *const TextureAtlas) void {
    // const vertices = basic_voxel_vertices;

    // self.uploadData(&vertices);

    var vertices: [36]Vertex = undefined;
    
    // Copy the basic vertices positions and normals
    for (0..36) |i| {
        vertices[i].position = .{
            basic_voxel_vertices[i].position[0],
            basic_voxel_vertices[i].position[1],
            basic_voxel_vertices[i].position[2],
        };
        vertices[i].normal = .{
            basic_voxel_vertices[i].normal[0],
            basic_voxel_vertices[i].normal[1],
            basic_voxel_vertices[i].normal[2],
        };
    }
    
    // Update UVs for each face based on texture atlas
    updateFaceUVs(&vertices, 0, atlas, .DIRT_SIDE);   // Back face
    updateFaceUVs(&vertices, 6, atlas, .DIRT_SIDE);  // Front face
    updateFaceUVs(&vertices, 12, atlas, .DIRT_SIDE);  // Left face
    updateFaceUVs(&vertices, 18, atlas, .DIRT_SIDE); // Right face
    updateFaceUVs(&vertices, 24, atlas, .DIRT_BOTTOM); // Bottom face
    updateFaceUVs(&vertices, 30, atlas, .DIRT_TOP);   // Top face
    
    self.uploadData(&vertices);
}

// Update UVs for a specific face with texture atlas coordinates
pub fn updateFaceUVs(vertices: []Vertex, start_idx: usize, atlas: *const TextureAtlas, texture_id: TextureAtlas.BlockTexture) void {
    // Make sure there are enough vertices
    if (start_idx + 6 > vertices.len) return;
    
    const uvs = atlas.getFaceCoords(texture_id);
    
    // Triangle 1
    vertices[start_idx + 0].uv = .{ uvs[0][0], uvs[0][1] }; // bottom-left
    vertices[start_idx + 1].uv = .{ uvs[1][0], uvs[1][1] }; // bottom-right
    vertices[start_idx + 2].uv = .{ uvs[2][0], uvs[2][1] }; // top-right

    // Triangle 2
    vertices[start_idx + 3].uv = .{ uvs[4][0], uvs[4][1] }; // bottom-left
    vertices[start_idx + 4].uv = .{ uvs[5][0], uvs[5][1] }; // top-right
    vertices[start_idx + 5].uv = .{ uvs[3][0], uvs[3][1] }; // top-left
}

// Create a mesh with multiple different blocks from the texture atlas
pub fn createVoxelMesh(self: *Mesh, allocator: Allocator, blocks: []const struct {
    position: [3]f32,
    type: u32,
}, atlas: *const TextureAtlas) !void {
    // Each block has 6 faces * 6 vertices per face = 36 vertices
    var vertices = try std.ArrayList(Vertex).initCapacity(allocator, blocks.len * 36);
    defer vertices.deinit();

    // For each block
    for (blocks) |block| {
        // Add vertices for each face, with proper position offset and texture coordinates
        try addBlockFaces(&vertices, block.position, block.type, atlas);
    }

    self.uploadData(vertices.items);
}

// Add all faces for a block at the given position
fn addBlockFaces(vertices: *std.ArrayList(Vertex), position: [3]f32, block_type: u32, atlas: *const TextureAtlas) !void {
    // Get texture IDs for each face based on block type
    const face_ids = [_]u32{
        atlas.getBlockTexture(block_type, .Side),   // Back
        atlas.getBlockTexture(block_type, .Side),   // Front
        atlas.getBlockTexture(block_type, .Side),   // Left
        atlas.getBlockTexture(block_type, .Side),   // Right
        atlas.getBlockTexture(block_type, .Bottom), // Bottom
        atlas.getBlockTexture(block_type, .Top),    // Top
    };

    // Add each face with corresponding texture coordinates
    try addFace(vertices, position, 0, face_ids[0], atlas);  // Back
    try addFace(vertices, position, 6, face_ids[1], atlas);  // Front
    try addFace(vertices, position, 12, face_ids[2], atlas); // Left
    try addFace(vertices, position, 18, face_ids[3], atlas); // Right
    try addFace(vertices, position, 24, face_ids[4], atlas); // Bottom
    try addFace(vertices, position, 30, face_ids[5], atlas); // Top
}

// Add a specific face for a block
fn addFace(vertices: *std.ArrayList(Vertex), position: [3]f32, face_start: usize, texture_id: u32, atlas: *const TextureAtlas) !void {
    // Get texture coordinates for this face from the atlas
    const uvs = atlas.getFaceCoords(texture_id);
    
    // Add 6 vertices for the face (2 triangles)
    for (0..6) |i| {
        const base_index = face_start + i;
        
        // Create a new vertex with:
        // 1. Position from basic_voxel_vertices offset by block position
        // 2. Normal unchanged from basic_voxel_vertices
        // 3. UVs from texture atlas
        try vertices.append(.{
            .position = .{
                basic_voxel_vertices[base_index].position[0] + position[0],
                basic_voxel_vertices[base_index].position[1] + position[1],
                basic_voxel_vertices[base_index].position[2] + position[2],
            },
            .normal = basic_voxel_vertices[base_index].normal,
            .uv = .{ uvs[i % 6][0], uvs[i % 6][1] },
        });
    }
}

pub const basic_voxel_vertices = [_]Vertex{
    // Back face (CCW winding)
    .{ .position = [_]f32{ 0.5, -0.5, -0.5}, .normal = [_]f32{0.0, 0.0, -1.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left
    .{ .position = [_]f32{-0.5, -0.5, -0.5}, .normal = [_]f32{0.0, 0.0, -1.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-right
    .{ .position = [_]f32{-0.5,  0.5, -0.5}, .normal = [_]f32{0.0, 0.0, -1.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{-0.5,  0.5, -0.5}, .normal = [_]f32{0.0, 0.0, -1.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{ 0.5,  0.5, -0.5}, .normal = [_]f32{0.0, 0.0, -1.0}, .uv = [_]f32{1.0, 0.0} }, // top-left
    .{ .position = [_]f32{ 0.5, -0.5, -0.5}, .normal = [_]f32{0.0, 0.0, -1.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left

    // Front face (CCW winding)
    .{ .position = [_]f32{-0.5, -0.5,  0.5}, .normal = [_]f32{0.0, 0.0, 1.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left
    .{ .position = [_]f32{ 0.5, -0.5,  0.5}, .normal = [_]f32{0.0, 0.0, 1.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-right
    .{ .position = [_]f32{ 0.5,  0.5,  0.5}, .normal = [_]f32{0.0, 0.0, 1.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{ 0.5,  0.5,  0.5}, .normal = [_]f32{0.0, 0.0, 1.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{-0.5,  0.5,  0.5}, .normal = [_]f32{0.0, 0.0, 1.0}, .uv = [_]f32{1.0, 0.0} }, // top-left
    .{ .position = [_]f32{-0.5, -0.5,  0.5}, .normal = [_]f32{0.0, 0.0, 1.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left

    // Left face (CCW)
    .{ .position = [_]f32{-0.5, -0.5, -0.5}, .normal = [_]f32{-1.0, 0.0, 0.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left
    .{ .position = [_]f32{-0.5, -0.5,  0.5}, .normal = [_]f32{-1.0, 0.0, 0.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-right
    .{ .position = [_]f32{-0.5,  0.5,  0.5}, .normal = [_]f32{-1.0, 0.0, 0.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{-0.5,  0.5,  0.5}, .normal = [_]f32{-1.0, 0.0, 0.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{-0.5,  0.5, -0.5}, .normal = [_]f32{-1.0, 0.0, 0.0}, .uv = [_]f32{1.0, 0.0} }, // top-left
    .{ .position = [_]f32{-0.5, -0.5, -0.5}, .normal = [_]f32{-1.0, 0.0, 0.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left

    // Right face (CCW)
    .{ .position = [_]f32{ 0.5, -0.5,  0.5}, .normal = [_]f32{1.0, 0.0, 0.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left
    .{ .position = [_]f32{ 0.5, -0.5, -0.5}, .normal = [_]f32{1.0, 0.0, 0.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-right
    .{ .position = [_]f32{ 0.5,  0.5, -0.5}, .normal = [_]f32{1.0, 0.0, 0.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{ 0.5,  0.5, -0.5}, .normal = [_]f32{1.0, 0.0, 0.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{ 0.5,  0.5,  0.5}, .normal = [_]f32{1.0, 0.0, 0.0}, .uv = [_]f32{1.0, 0.0} }, // top-left
    .{ .position = [_]f32{ 0.5, -0.5,  0.5}, .normal = [_]f32{1.0, 0.0, 0.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left

    // Bottom face (CCW)      
    .{ .position = [_]f32{-0.5, -0.5, -0.5}, .normal = [_]f32{0.0, -1.0, 0.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-left
    .{ .position = [_]f32{ 0.5, -0.5, -0.5}, .normal = [_]f32{0.0, -1.0, 0.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-right
    .{ .position = [_]f32{ 0.5, -0.5,  0.5}, .normal = [_]f32{0.0, -1.0, 0.0}, .uv = [_]f32{1.0, 0.0} }, // top-right
    .{ .position = [_]f32{ 0.5, -0.5,  0.5}, .normal = [_]f32{0.0, -1.0, 0.0}, .uv = [_]f32{1.0, 0.0} }, // top-right
    .{ .position = [_]f32{-0.5, -0.5,  0.5}, .normal = [_]f32{0.0, -1.0, 0.0}, .uv = [_]f32{0.0, 0.0} }, // top-left
    .{ .position = [_]f32{-0.5, -0.5, -0.5}, .normal = [_]f32{0.0, -1.0, 0.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-left

    // Top face (CCW)
    .{ .position = [_]f32{-0.5,  0.5,  0.5}, .normal = [_]f32{0.0, 1.0, 0.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-left
    .{ .position = [_]f32{ 0.5,  0.5,  0.5}, .normal = [_]f32{0.0, 1.0, 0.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-right
    .{ .position = [_]f32{ 0.5,  0.5, -0.5}, .normal = [_]f32{0.0, 1.0, 0.0}, .uv = [_]f32{1.0, 0.0} }, // top-right
    .{ .position = [_]f32{ 0.5,  0.5, -0.5}, .normal = [_]f32{0.0, 1.0, 0.0}, .uv = [_]f32{1.0, 0.0} }, // top-right
    .{ .position = [_]f32{-0.5,  0.5, -0.5}, .normal = [_]f32{0.0, 1.0, 0.0}, .uv = [_]f32{0.0, 0.0} }, // top-left
    .{ .position = [_]f32{-0.5,  0.5,  0.5}, .normal = [_]f32{0.0, 1.0, 0.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-left
};

pub const vertex_positions = &[_]gl.Float{
    // back face (CCW winding)
    0.5, -0.5, -0.5,    // bottom-left
    -0.5, -0.5, -0.5,   // bottom-right
    -0.5,  0.5, -0.5,   // top-right
    -0.5,  0.5, -0.5,   // top-right
    0.5,  0.5, -0.5,    // top-left
    0.5, -0.5, -0.5,    // bottom-left
    // front face (CCW winding)
    -0.5, -0.5,  0.5,   // bottom-left
    0.5, -0.5,  0.5,    // bottom-right
    0.5,  0.5,  0.5,    // top-right
    0.5,  0.5,  0.5,    // top-right
    -0.5,  0.5,  0.5,   // top-left
    -0.5, -0.5,  0.5,   // bottom-left
    // left face (CCW)
    -0.5, -0.5, -0.5,   // bottom-left
    -0.5, -0.5,  0.5,   // bottom-right
    -0.5,  0.5,  0.5,   // top-right
    -0.5,  0.5,  0.5,   // top-right
    -0.5,  0.5, -0.5,   // top-left
    -0.5, -0.5, -0.5,   // bottom-left
    // right face (CCW)
    0.5, -0.5,  0.5,   // bottom-left
    0.5, -0.5, -0.5,   // bottom-right
    0.5,  0.5, -0.5,   // top-right
    0.5,  0.5, -0.5,   // top-right
    0.5,  0.5,  0.5,   // top-left
    0.5, -0.5,  0.5,   // bottom-left
    // bottom face (CCW)      
    -0.5, -0.5, -0.5,   // bottom-left
    0.5, -0.5, -0.5,    // bottom-right
    0.5, -0.5,  0.5,    // top-right
    0.5, -0.5,  0.5,    // top-right
    -0.5, -0.5,  0.5,   // top-left
    -0.5, -0.5, -0.5,   // bottom-left
    // top face (CCW)
    -0.5,  0.5,  0.5,   // bottom-left
    0.5,  0.5,  0.5,    // bottom-right
    0.5,  0.5, -0.5,    // top-right
    0.5,  0.5, -0.5,    // top-right
    -0.5,  0.5, -0.5,   // top-left
    -0.5,  0.5,  0.5,   // bottom-left
};

pub const normal_positions = &[_]gl.Float{
    // back face (CCW winding)
    0.0, 0.0, -1.0,   // bottom-left
    0.0, 0.0, -1.0,   // bottom-right
    0.0, 0.0, -1.0,   // top-right
    0.0, 0.0, -1.0,   // top-right
    0.0, 0.0, -1.0,   // top-left
    0.0, 0.0, -1.0,   // bottom-left
    // front face (CCW winding)
    0.0, 0.0, 1.0,   // bottom-left
    0.0, 0.0, 1.0,   // bottom-right
    0.0, 0.0, 1.0,   // top-right
    0.0, 0.0, 1.0,   // top-right
    0.0, 0.0, 1.0,   // top-left
    0.0, 0.0, 1.0,   // bottom-left
    // left face (CCW)
    -1.0, 0.0, 0.0,   // bottom-left
    -1.0, 0.0, 0.0,   // bottom-right
    -1.0, 0.0, 0.0,   // top-right
    -1.0, 0.0, 0.0,   // top-right
    -1.0, 0.0, 0.0,   // top-left
    -1.0, 0.0, 0.0,   // bottom-left
    // right face (CCW)
    1.0, 0.0, 0.0,   // bottom-left
    1.0, 0.0, 0.0,   // bottom-right
    1.0, 0.0, 0.0,   // top-right
    1.0, 0.0, 0.0,   // top-right
    1.0, 0.0, 0.0,   // top-left
    1.0, 0.0, 0.0,   // bottom-left
    // bottom face (CCW)      
    0.0, -1.0, 0.0,   // bottom-left
    0.0, -1.0, 0.0,   // bottom-right
    0.0, -1.0, 0.0,   // top-right
    0.0, -1.0, 0.0,   // top-right
    0.0, -1.0, 0.0,   // top-left
    0.0, -1.0, 0.0,   // bottom-left
    // top face (CCW)
    0.0, 1.0, 0.0,   // bottom-left
    0.0, 1.0, 0.0,   // bottom-right
    0.0, 1.0, 0.0,   // top-right
    0.0, 1.0, 0.0,   // top-right
    0.0, 1.0, 0.0,   // top-left
    0.0, 1.0, 0.0,   // bottom-left
};

pub const texture_coords = &[_]gl.Float{
    // back face (CCW winding)
    1.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    // front face (CCW winding)
    1.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    // left face (CCW)
    1.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    // right face (CCW)
    1.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    // bottom face (CCW)
    1.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    // top face (CCW)
    1.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
};