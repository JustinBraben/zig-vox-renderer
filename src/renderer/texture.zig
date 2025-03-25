const std = @import("std");
const zopengl = @import("zopengl");
const zstbi = @import("zstbi");
const gl = zopengl.bindings;

const Texture = @This();

width: u32,
height: u32,
id: gl.Uint = 0, // OpenGL texture ID

pub fn initFromPixels(pixels: []u8, width: u32, height: u32, internalFormat: gl.Enum) Texture {
    var textureID: gl.Uint  = undefined;
    gl.genTextures(1, &textureID);
    gl.bindTexture(gl.TEXTURE_2D, textureID);

    // No interpolation
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);

    // Generate the textureID
    gl.texImage2D(
        gl.TEXTURE_2D, 
        0, 
        internalFormat, 
        @as(c_int, @intCast(width)), 
        @as(c_int, @intCast(height)), 
        0, 
        internalFormat, 
        gl.UNSIGNED_BYTE, 
        @ptrCast(pixels));

    return .{
        .width = width,
        .height = height,
        .id = textureID,
    };
}

pub fn initFromPath(path: [:0]const u8) !Texture {
    var texture_image = try zstbi.Image.loadFromFile(path, 0);
    defer texture_image.deinit();

    const format: gl.Enum = switch (texture_image.num_components) {
        1 => gl.RED,
        3 => gl.RGB,
        4 => gl.RGBA,
        else => unreachable,
    };
    
    return initFromPixels(texture_image.data, texture_image.width, texture_image.height, format);
}

/// loads a cubemap texture from 6 individual texture faces
/// order:
/// +X (right)
/// -X (left)
/// +Y (top)
/// -Y (bottom)
/// +Z (front) 
/// -Z (back)
pub fn initCubeMap(faces: []const [:0]const u8) !Texture {
    var textureID: gl.Uint = undefined;
    gl.genTextures(1, &textureID);
    gl.bindTexture(gl.TEXTURE_CUBE_MAP, textureID);

    var width: u32 = 0;
    var height: u32 = 0;

    for (faces, 0..) |face, i| {
        var texture_image = try zstbi.Image.loadFromFile(face, 0);
        defer texture_image.deinit();

        const format: gl.Enum = switch (texture_image.num_components) {
            1 => gl.RED,
            3 => gl.RGB,
            4 => gl.RGBA,
            else => unreachable,
        };

        // Generate the textureID
        gl.texImage2D(
            gl.TEXTURE_CUBE_MAP_POSITIVE_X + @as(c_uint, @intCast(i)), 
            0, 
            format, 
            @as(c_int, @intCast(texture_image.width)), 
            @as(c_int, @intCast(texture_image.height)), 
            0, 
            format, 
            gl.UNSIGNED_BYTE, 
            @ptrCast(texture_image.data));
        gl.generateMipmap(gl.TEXTURE_2D);

        if (width == 0) width = texture_image.width;
        if (height == 0) height = texture_image.height;
    }

    gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE);

    return .{
        .width = width,
        .height = height,
        .id = textureID,
    };
}

pub fn deinit(self: *Texture) void {
    gl.deleteTextures(1, &self.id);
}

pub fn bind(self: *Texture) void {
    gl.bindTexture(gl.TEXTURE_2D, self.id);
}