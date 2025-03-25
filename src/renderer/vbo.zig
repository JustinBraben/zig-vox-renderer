const std = @import("std");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;

const VBO = @This();

id: gl.Uint,

pub fn init() VBO {
    var vbo: gl.Uint = undefined;
    gl.genBuffers(1, &vbo);
    return .{ .id = vbo };
}

pub fn initWithData(data: []const gl.Float) VBO {
    var vbo: gl.Uint = undefined;
    gl.genBuffers(1, &vbo);
    gl.bufferData(gl.ARRAY_BUFFER, vbo);
    gl.bufferData(gl.ARRAY_BUFFER, @intCast(data.len * @sizeOf(gl.Float)), data.ptr, gl.STATIC_DRAW);
}

pub fn deinit(self: *VBO) void {
    gl.deleteBuffers(1, &self.id);
}

pub fn bind(self: *VBO, target: gl.Enum) void {
    gl.bindBuffer(target, self.id);
}

pub fn unbind(_: *VBO, target: gl.Enum) void {
    gl.bindBuffer(target, 0);
}

pub fn bufferData(
    _: *VBO, 
    target: gl.Enum, 
    data: []const gl.Float, 
    usage: gl.Enum
) void {
    gl.bufferData(
        target, 
        @intCast(data.len * @sizeOf(gl.Float)), 
        data.ptr, 
        usage
    );
}