const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Framebuffer = struct {
    const Self = @This();

    allocator: Allocator,
    id: u32 = 0,

    attachment_names: std.ArrayList(u32),

    width: u32,
    height: u32,

    pub fn init(allocator: Allocator, width: u32, height: u32, createDepthAttachment: bool, colorAttachmentCount: u32) !Self {
        var framebuffer = Self{
            .allocator = allocator,
            .id = 0,
            .attachment_names = std.ArrayList(u32).init(allocator),
            .width = width,
            .height = height,
        };

        framebuffer.bind(false);

        if (createDepthAttachment) {
            // TODO: create depth attachment
        }

        var i: u32 = 0;
        while(i < colorAttachmentCount) : (i += 1) {
            // TODO: Texture attachment
            // allocate texture

            // TODO: Create an id for attachmentName
            const attachment_name: u32 = i;
            
            framebuffer.attachment_names.append(attachment_name) orelse {
                return error.FailedtoAppendAttachmentName;
            };
        }

        framebuffer.unbind();

        return framebuffer;
    }

    pub fn deinit(self: *Self) void {
        if (self.id != 0) {
            // TODO: delete framebuffers
        }
    }

    pub fn bind(self: *Framebuffer, forDrawing: bool) void {
        _ = self;
        // TODO: bind framebuffer
        if (forDrawing) {
            // TODO: draw buffers
        }
    }

    pub fn unbind(self: *Framebuffer) void {
        // TODO: unbind framebuffer
        _ = self;
    }
};