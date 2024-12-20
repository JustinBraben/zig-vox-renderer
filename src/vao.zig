const std = @import("std");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;

const VAO = @This();

id: gl.Uint,

pub fn init() !VAO {
    var vao: gl.Uint = undefined;
    gl.genVertexArrays(1, &vao);
    return .{ .id = vao };
}

pub fn deinit(self: *VAO) void {
    gl.deleteVertexArrays(1, &self.id);
}

pub fn bind(self: *VAO) void {
    gl.bindVertexArray(self.id);
}

pub fn unbind(self: *VAO) void {
    _ = &self;
    gl.bindVertexArray(0);
}

pub fn setVertexAttributePointer(
    self: *VAO,
    index: gl.Uint,
    size: gl.Int,
    type_: gl.Enum,
    normalized: gl.Boolean,
    stride: gl.Sizei,
    offset: ?*const anyopaque
) void {
    _ = &self; // self is not used directly in the OpenGL call
    gl.vertexAttribPointer(
        index, 
        size, 
        type_, 
        normalized, 
        stride, 
        offset
    );
}

pub fn enableVertexAttribArray(self: *VAO, index: gl.Uint) void {
    _ = self; // self is not used directly in the OpenGL call
    gl.enableVertexAttribArray(index);
}