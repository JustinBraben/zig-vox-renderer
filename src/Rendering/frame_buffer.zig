const std = @import("std");
const Allocator = std.mem.Allocator;
const Renderbuffer = @import("render_buffer.zig").RenderBuffer;
const Texture = @import("texture.zig").Texture;

pub const Framebuffer = struct {
    const Self = @This();

    allocator: Allocator,

    id: u32 = 0,

    attachments: std.ArrayList(Texture),
    attachment_names: std.ArrayList(u32),
    depth_attachment: *Renderbuffer,

    width: i32 = 0,
    height: i32 = 0,
};