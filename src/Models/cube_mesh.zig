const std = @import("std");
const Allocator = std.mem.Allocator;
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const Shader = @import("../shader.zig");
const VAO = @import("../vao.zig");
const VBO = @import("../vbo.zig");

const CubeMesh = @This();

shader: Shader,
vao: VAO,
/// position_vbo is first
/// normal_vbo is second
/// texCoord_vbo is third
/// instance_vbo is fourth
buffers: std.ArrayList(VBO),
vertex_positions: []const gl.Float = &[_]gl.Float{
    // back face (CCW winding)
    0.5, -0.5, -0.5,    // bottom-left
    -0.5, -0.5, -0.5,   // bottom-right
    -0.5,  0.5, -0.5,   // top-right
    -0.5,  0.5, -0.5,   // top-right
    0.5,  0.5, -0.5,    // top-left
    0.5, -0.5, -0.5,    // bottom-left
    // front face (CCW winding)
    -0.5, -0.5,  0.5,   // bottom-left
    0.5, -0.5,  0.5,    // bottom-right
    0.5,  0.5,  0.5,    // top-right
    0.5,  0.5,  0.5,    // top-right
    -0.5,  0.5,  0.5,   // top-left
    -0.5, -0.5,  0.5,   // bottom-left
    // left face (CCW)
    -0.5, -0.5, -0.5,   // bottom-left
    -0.5, -0.5,  0.5,   // bottom-right
    -0.5,  0.5,  0.5,   // top-right
    -0.5,  0.5,  0.5,   // top-right
    -0.5,  0.5, -0.5,   // top-left
    -0.5, -0.5, -0.5,   // bottom-left
    // right face (CCW)
    0.5, -0.5,  0.5,   // bottom-left
    0.5, -0.5, -0.5,   // bottom-right
    0.5,  0.5, -0.5,   // top-right
    0.5,  0.5, -0.5,   // top-right
    0.5,  0.5,  0.5,   // top-left
    0.5, -0.5,  0.5,   // bottom-left
    // bottom face (CCW)      
    -0.5, -0.5, -0.5,   // bottom-left
    0.5, -0.5, -0.5,    // bottom-right
    0.5, -0.5,  0.5,    // top-right
    0.5, -0.5,  0.5,    // top-right
    -0.5, -0.5,  0.5,   // top-left
    -0.5, -0.5, -0.5,   // bottom-left
    // top face (CCW)
    -0.5,  0.5,  0.5,   // bottom-left
    0.5,  0.5,  0.5,    // bottom-right
    0.5,  0.5, -0.5,    // top-right
    0.5,  0.5, -0.5,    // top-right
    -0.5,  0.5, -0.5,   // top-left
    -0.5,  0.5,  0.5,   // bottom-left
},
normal_positions: []const gl.Float = &[_]gl.Float{
    // back face (CCW winding)
    0.0, 0.0, -1.0,   // bottom-left
    0.0, 0.0, -1.0,   // bottom-right
    0.0, 0.0, -1.0,   // top-right
    0.0, 0.0, -1.0,   // top-right
    0.0, 0.0, -1.0,   // top-left
    0.0, 0.0, -1.0,   // bottom-left
    // front face (CCW winding)
    0.0, 0.0, 1.0,   // bottom-left
    0.0, 0.0, 1.0,   // bottom-right
    0.0, 0.0, 1.0,   // top-right
    0.0, 0.0, 1.0,   // top-right
    0.0, 0.0, 1.0,   // top-left
    0.0, 0.0, 1.0,   // bottom-left
    // left face (CCW)
    -1.0, 0.0, 0.0,   // bottom-left
    -1.0, 0.0, 0.0,   // bottom-right
    -1.0, 0.0, 0.0,   // top-right
    -1.0, 0.0, 0.0,   // top-right
    -1.0, 0.0, 0.0,   // top-left
    -1.0, 0.0, 0.0,   // bottom-left
    // right face (CCW)
    1.0, 0.0, 0.0,   // bottom-left
    1.0, 0.0, 0.0,   // bottom-right
    1.0, 0.0, 0.0,   // top-right
    1.0, 0.0, 0.0,   // top-right
    1.0, 0.0, 0.0,   // top-left
    1.0, 0.0, 0.0,   // bottom-left
    // bottom face (CCW)      
    0.0, -1.0, 0.0,   // bottom-left
    0.0, -1.0, 0.0,   // bottom-right
    0.0, -1.0, 0.0,   // top-right
    0.0, -1.0, 0.0,   // top-right
    0.0, -1.0, 0.0,   // top-left
    0.0, -1.0, 0.0,   // bottom-left
    // top face (CCW)
    0.0, 1.0, 0.0,   // bottom-left
    0.0, 1.0, 0.0,   // bottom-right
    0.0, 1.0, 0.0,   // top-right
    0.0, 1.0, 0.0,   // top-right
    0.0, 1.0, 0.0,   // top-left
    0.0, 1.0, 0.0,   // bottom-left
},
texture_coords: []const gl.Float = &[_]gl.Float{
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    1.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,

    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    1.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,

    1.0, 0.0,
    1.0, 1.0,
    0.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,
    1.0, 0.0,

    1.0, 0.0,
    1.0, 1.0,
    0.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,
    1.0, 0.0,

    0.0, 1.0,
    1.0, 1.0,
    1.0, 0.0,
    1.0, 0.0,
    0.0, 0.0,
    0.0, 1.0,

    0.0, 1.0,
    1.0, 1.0,
    1.0, 0.0,
    1.0, 0.0,
    0.0, 0.0,
    0.0, 1.0
},
pub fn init(gpa: Allocator, vs_path: []const u8, fs_path: []const u8) CubeMesh {
    return .{
        .shader = Shader.create(gpa, vs_path, fs_path),
        .vao = VAO.init(),
        .buffers = std.ArrayList(VBO).init(gpa),
    };
}

pub fn deinit(self: *CubeMesh) void {
    for (self.buffers.items) |*vbo| {
        vbo.deinit();
    }
    self.buffers.deinit();
    self.vao.deinit();
}

pub fn bindVAO(self: *CubeMesh) void {
    self.vao.bind();
}

pub fn unbindVAO(self: *CubeMesh) void {
    self.vao.unbind();
}

pub fn addVBO(self: *CubeMesh, size: gl.Int, data: []const gl.Float) !void {
    var vbo = VBO.init();
    vbo.bind(gl.ARRAY_BUFFER);
    vbo.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
    self.vao.enableVertexAttribArray(@intCast(self.buffers.items.len));
    self.vao.setVertexAttributePointer(@intCast(self.buffers.items.len), size, gl.FLOAT, gl.FALSE, size * @sizeOf(gl.Float), null);
    try self.buffers.append(vbo);
}

pub fn addInstanceVBO(self: *CubeMesh, size: usize, data: []const gl.Float) !void {
    const vec4Size = size * @sizeOf(gl.Float);
    const mat4Size = size * vec4Size;
    var vbo = VBO.init();
    vbo.bind(gl.ARRAY_BUFFER);
    vbo.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
    self.vao.enableVertexAttribArray(3);
    gl.vertexAttribPointer(3, @intCast(size), gl.FLOAT, gl.FALSE, @intCast(mat4Size), null);
    self.vao.enableVertexAttribArray(4);
    gl.vertexAttribPointer(4, @intCast(size), gl.FLOAT, gl.FALSE, @intCast(mat4Size), @ptrFromInt(vec4Size));
    self.vao.enableVertexAttribArray(5);
    gl.vertexAttribPointer(5, @intCast(size), gl.FLOAT, gl.FALSE, @intCast(mat4Size), @ptrFromInt(2 * vec4Size));
    self.vao.enableVertexAttribArray(6);
    gl.vertexAttribPointer(6, @intCast(size), gl.FLOAT, gl.FALSE, @intCast(mat4Size), @ptrFromInt(3 * vec4Size));
    gl.vertexAttribDivisor(3, 1);
    gl.vertexAttribDivisor(4, 1);
    gl.vertexAttribDivisor(5, 1);
    gl.vertexAttribDivisor(6, 1);
    try self.buffers.append(vbo);
}