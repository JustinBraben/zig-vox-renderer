const std = @import("std");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;

const VAO = @This();

id: gl.Uint,

pub fn init() VAO {
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

pub fn unbind(_: *VAO) void {
    gl.bindVertexArray(0);
}

// self is not used directly in the OpenGL call
pub fn setVertexAttributePointer(
    _: *VAO,
    index: gl.Uint,
    size: gl.Int,
    type_: gl.Enum,
    normalized: gl.Boolean,
    stride: gl.Sizei,
    offset: ?*const anyopaque
) void {
    gl.vertexAttribPointer(
        index,
        size,
        type_,
        normalized,
        stride,
        offset
    );
}

// self is not used directly in the OpenGL call
pub fn enableVertexAttribArray(_: *VAO, index: gl.Uint) void {
    gl.enableVertexAttribArray(index);
}

pub fn linkAttrib(
    _: *VAO,
    index: gl.Uint,
    size: gl.Int,
    type_: gl.Enum,
    normalized: gl.Boolean,
    stride: gl.Sizei,
    offset: ?*const anyopaque
) void {
    gl.vertexAttribPointer(
        index, 
        size, 
        type_, 
        normalized, 
        stride, 
        offset
    );
    gl.enableVertexAttribArray(index);
}