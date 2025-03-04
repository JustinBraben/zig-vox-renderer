const std = @import("std");
const Utils = @import("../utils.zig");

const TextureAtlas = @This();

// Atlas size in tiles (e.g., 16x16 for 256 different textures)
width: u32,
height: u32,
texture_id: u32, // OpenGL texture ID

pub const BlockTexture = enum(u32) {
    DIRT_TOP = 0,
    DIRT_SIDE = 1,
    DIRT_BOTTOM = 2,
};

// Texture IDs for specific blocks
pub const TextureIDs = struct {
    // Example block IDs - you would define more as needed
    dirt_top: u32 = 0,
    dirt_side: u32 = 1,
    dirt_bottom: u32 = 2,
    // Add more block texture IDs as needed
};

pub fn init(atlas_width: u32, atlas_height: u32) TextureAtlas {
    return .{
        .width = atlas_width,
        .height = atlas_height,
        .texture_id = 0,
    };
}

// Load the atlas texture
pub fn load(self: *TextureAtlas, file_path: [:0]const u8) !void {
    self.texture_id = try Utils.loadTexture(file_path);
}

// Calculate texture coordinates for a specific tile in the atlas
pub fn getTextureCoords(self: TextureAtlas, texture_id: BlockTexture) [4][2]f32 {
    const tile_width = 1.0 / @as(f32, @floatFromInt(self.width));
    const tile_height = 1.0 / @as(f32, @floatFromInt(self.height));
    
    // Calculate the position of this tile in the atlas grid
    const tile_x = @intFromEnum(texture_id) % self.width;
    const tile_y = @intFromEnum(texture_id) / self.width;
    
    // Calculate normalized texture coordinates (0.0 to 1.0)
    const x1: f32 = @as(f32, @floatFromInt(tile_x)) * tile_width;
    const y1: f32 = @as(f32, @floatFromInt(tile_y)) * tile_height;
    const x2: f32 = x1 + tile_width;
    const y2: f32 = y1 + tile_height;
    
    // Return texture coordinates for the four corners
    // Format: [bottom-left, bottom-right, top-right, top-left]
    return .{
        .{ x1, y2 }, // bottom-left
        .{ x2, y2 }, // bottom-right
        .{ x2, y1 }, // top-right
        .{ x1, y1 }, // top-left
    };
}

// Get texture coordinates for a face, ready to be used in triangles
pub fn getFaceCoords(self: TextureAtlas, texture_id: BlockTexture) [6][2]f32 {
    const coords = self.getTextureCoords(texture_id);
    
    // Convert the four corner coordinates to six vertices (two triangles)
    return .{
        coords[0], // bottom-left
        coords[1], // bottom-right
        coords[2], // top-right
        coords[0], // bottom-left
        coords[2], // top-right
        coords[3], // top-left
    };
}


// // Example of how to create and use a basic voxel mesh with texture atlas
// pub fn createBasicVoxelMesh(atlas: *TextureAtlas) Mesh {
//     var mesh = Mesh.init();
    
//     // Define vertex positions (unchanged from your current code)
//     const positions = [_]f32{
//         // Same cube vertices as before
//         // ...
//     };
    
//     // Define texture coordinates using the atlas
//     var tex_coords = [_]f32{};
//     const texture_ids = [_]u32{
//         // Back face
//         TextureAtlas.TextureIDs.dirt_side,
//         // Front face
//         TextureAtlas.TextureIDs.dirt_side,
//         // Left face
//         TextureAtlas.TextureIDs.dirt_side,
//         // Right face
//         TextureAtlas.TextureIDs.dirt_side,
//         // Bottom face
//         TextureAtlas.TextureIDs.dirt_bottom,
//         // Top face
//         TextureAtlas.TextureIDs.dirt_top,
//     };
    
//     // Generate texture coordinates for all faces
//     for (texture_ids, 0..) |id, i| {
//         const face_coords = atlas.getFaceCoords(id);
//         // Flatten the coordinates and add them to the tex_coords array
//         // This depends on how you organize your vertex data
//     }
    
//     // Set up the mesh with these coordinates
//     mesh.setPositions(positions);
//     mesh.setTextureCoords(tex_coords);
    
//     return mesh;
// }