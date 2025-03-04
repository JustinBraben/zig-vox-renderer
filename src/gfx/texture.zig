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

pub fn deinit(self: *Texture) void {
    gl.deleteTextures(1, &self.id);
}

pub fn bind(self: *Texture) void {
    gl.bindTexture(gl.TEXTURE_2D, self.id);
}