const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Framebuffer = @import("frame_buffer.zig").Framebuffer;
const Texture = @import("texture.zig").Texture;

pub const FramebufferStack = struct {
    const Self = @This();

    allocator: Allocator,
    stack: std.ArrayList(Framebuffer),
    intermediate_textures: std.ArrayList(Texture),
};