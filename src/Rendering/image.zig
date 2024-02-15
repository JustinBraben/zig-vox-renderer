const std = @import("std");
const Allocator = std.mem.Allocator;
const glm = @import("ziglm");

const Vec2u = glm.Vec2(u32);

pub const Image = struct {
    const Self = @This();

    allocator: Allocator,
    width: u32,
    height: u32,
    data: std.ArrayList(u8),
    
    pub fn init(allocator: Allocator, width: u32, height: u32) !Self {
        var image: Self = undefined;
        image = Self{ 
            .allocator = allocator, 
            .width = width, 
            .height = height, 
            .data = std.ArrayList(u8).init(allocator) 
        };
        return image;
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit();
    }

    pub fn subImage(self: *Self) !Self {
        var new_image: Self = undefined;
        new_image = self.*;
        new_image.height = 1;
        return new_image;
    }
};