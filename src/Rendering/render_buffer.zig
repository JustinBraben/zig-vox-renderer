const std = @import("std");
const gl = @import("gl");

pub const RenderBuffer = struct {
    const Self = @This();

    id: u32 = 0,
    width: i32 = 0,
    height: i32 = 0,

    pub fn init(typeOf: u32, width: i32, height: i32) !Self {
        var self = Self{}; 
        gl.genRenderbuffers(1, &self.id);
        self.bind();

        gl.renderbufferStorage(gl.RENDERBUFFER, typeOf, width, height);

        self.unbind();
    }

    pub fn deinit(self: *Self) void {
        if (self.isValid()){
            gl.deleteRenderbuffers(1, &self.id);
        }
    }

    pub fn isValid(self: *Self) bool {
        return self.id != 0;
    }

    pub fn bind(self: *Self) void {
        gl.bindRenderbuffer(gl.RENDERBUFFER, self.id);
    }

    pub fn unbind(self: *Self) void {
        _ = self;
        gl.bindRenderbuffer(gl.RENDERBUFFER, 0);
    }
};