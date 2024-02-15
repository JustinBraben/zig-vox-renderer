const std = @import("std");
const gl = @import("gl");
const Image = @import("image.zig").Image;
const Allocator = std.mem.Allocator;

pub const Texture = struct {
    const Self = @This();

    allocator: Allocator = undefined,
    id: u32 = 0,
    type_of: u32 = undefined,
    generate_mip_map: bool = undefined,

    pub fn init(allocator: Allocator, typeOf: u32, generateMipMap: bool, maxLod: i32) !Self {
        // TODO: assert type is texture 2d, or texture 2d array, or cube map
        var texture: Self = Self{ .allocator = allocator, .type_of = typeOf, .generate_mip_map = generateMipMap };
        gl.genTextures(1, &texture.id);
        texture.bind();

        gl.texParameteri(texture.type_of, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_BORDER);
        gl.texParameteri(texture.type_of, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_BORDER);
        if (texture.type_of == gl.TEXTURE_CUBE_MAP) {
            gl.texParameteri(texture.type_of, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_BORDER);
        }

        gl.texParameteri(texture.type_of, gl.TEXTURE_MIN_FILTER, if (generateMipMap) gl.NEAREST_MIPMAP_NEAREST else gl.NEAREST);
        gl.texParameteri(texture.type_of, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        if (generateMipMap) {
            gl.texParameteri(texture.type_of, gl.TEXTURE_MAX_LOD, maxLod);
        }

        texture.unbind();
        return texture;
    }

    pub fn deinit(self: *Self) void {
        if (self.isValid()) {
            gl.deleteTextures(1, &self.id);
        }
    }

    pub fn isValid(self: *Self) bool {
        return self.id != 0;
    }

    pub fn bind(self: *Self) void {
        gl.bindTexture(self.type_of, self.id);
    }

    pub fn bindToSlot(self: *Self, slot: u32) void {
        gl.activeTexture(gl.TEXTURE0 + slot);
        self.bind();
    }

    pub fn unbind(self: *Self) void {
        gl.bindTexture(self.type_of, 0);
    }
};