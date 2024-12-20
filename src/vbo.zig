const std = @import("std");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;

const VBO = @This();

id: gl.Uint,

pub fn init() !VBO {
    var vbo: gl.Uint = undefined;
    gl.genBuffers(1, &vbo);
    return .{ .id = vbo };
}

pub fn deinit(self: *VBO) void {
    gl.deleteBuffers(1, &self.id);
}

pub fn bind(self: *VBO, target: gl.Enum) void {
    gl.bindBuffer(target, self.id);
}

pub fn unbind(self: *VBO, target: gl.Enum) void {
    _ = &self;
    gl.bindBuffer(target, 0);
}

pub fn bufferData(
    self: *VBO, 
    target: gl.Enum, 
    data: []const f32, 
    usage: gl.Enum
) void {
    _ = &self; // self is not used directly in the OpenGL call
    gl.bufferData(
        target, 
        @intCast(data.len * @sizeOf(gl.Float)), 
        data.ptr, 
        usage
    );
}