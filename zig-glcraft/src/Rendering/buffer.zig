const std = @import("std");
const gl = @import("gl");
const Allocator = std.mem.Allocator;

pub const Buffer = struct {
    const Self = @This();

    size: i32 = 0,
    id: u32 = 0,
    type_of: u32,

    pub fn init(typeOf: u32) !Self {
        var self: Buffer = undefined;
        self.size = 0;
        self.id = 0;
        self.type_of = typeOf;
        gl.genBuffers(1, &self.id);
    }

    pub fn deinit(self: *Self) void {
        if (self.isValid())
        {
            gl.deleteBuffers(1, &self.id);
        }
    }

    fn isValid(self: *Self) bool {
        return self.id != 0;
    }
};

pub const VertexBuffer = struct {
    usingnamespace Buffer;
};