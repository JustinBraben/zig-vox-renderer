const std = @import("std");
const Allocator = std.mem.Allocator;
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const Shader = @import("../shader.zig");
const VAO = @import("../vao.zig");
const VBO = @import("../vbo.zig");

const SkyboxMesh = @This();

shader: Shader,
vao: VAO,
buffers: std.ArrayList(VBO),
vertex_positions: []const gl.Float = &[_]gl.Float{
    // back face (CCW winding)
    1.0, -1.0, -1.0,    // bottom-left
    -1.0, -1.0, -1.0,   // bottom-right
    -1.0,  1.0, -1.0,   // top-right
    -1.0,  1.0, -1.0,   // top-right
    1.0,  1.0, -1.0,    // top-left
    1.0, -1.0, -1.0,    // bottom-left
    // front face (CCW winding)
    -1.0, -1.0,  1.0,   // bottom-left
    1.0, -1.0,  1.0,    // bottom-right
    1.0,  1.0,  1.0,    // top-right
    1.0,  1.0,  1.0,    // top-right
    -1.0,  1.0,  1.0,   // top-left
    -1.0, -1.0,  1.0,   // bottom-left
    // left face (CCW)
    -1.0, -1.0, -1.0,   // bottom-left
    -1.0, -1.0,  1.0,   // bottom-right
    -1.0,  1.0,  1.0,   // top-right
    -1.0,  1.0,  1.0,   // top-right
    -1.0,  1.0, -1.0,   // top-left
    -1.0, -1.0, -1.0,   // bottom-left
    // right face (CCW)
    1.0, -1.0,  1.0,   // bottom-left
    1.0, -1.0, -1.0,   // bottom-right
    1.0,  1.0, -1.0,   // top-right
    1.0,  1.0, -1.0,   // top-right
    1.0,  1.0,  1.0,   // top-left
    1.0, -1.0,  1.0,   // bottom-left
    // bottom face (CCW)      
    -1.0, -1.0, -1.0,   // bottom-left
    1.0, -1.0, -1.0,    // bottom-right
    1.0, -1.0,  1.0,    // top-right
    1.0, -1.0,  1.0,    // top-right
    -1.0, -1.0,  1.0,   // top-left
    -1.0, -1.0, -1.0,   // bottom-left
    // top face (CCW)
    -1.0,  1.0,  1.0,   // bottom-left
    1.0,  1.0,  1.0,    // bottom-right
    1.0,  1.0, -1.0,    // top-right
    1.0,  1.0, -1.0,    // top-right
    -1.0,  1.0, -1.0,   // top-left
    -1.0,  1.0,  1.0,   // bottom-left
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
pub fn init(gpa: Allocator, vs_path: []const u8, fs_path: []const u8) SkyboxMesh {
    return .{
        .shader = Shader.create(gpa, vs_path, fs_path),
        .vao = VAO.init(),
        .buffers = std.ArrayList(VBO).init(gpa),
    };
}

pub fn deinit(self: *SkyboxMesh) void {
    for (self.buffers.items) |*vbo| {
        vbo.deinit();
    }
    self.buffers.deinit();
    self.vao.deinit();
}

pub fn bindVAO(self: *SkyboxMesh) void {
    self.vao.bind();
}

pub fn unbindVAO(self: *SkyboxMesh) void {
    self.vao.unbind();
}

pub fn addVBO(self: *SkyboxMesh, size: gl.Int, data: []const gl.Float) !void {
    var vbo = VBO.init();
    vbo.bind(gl.ARRAY_BUFFER);
    vbo.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
    self.vao.enableVertexAttribArray(@intCast(self.buffers.items.len));
    self.vao.setVertexAttributePointer(@intCast(self.buffers.items.len), size, gl.FLOAT, gl.FALSE, size * @sizeOf(gl.Float), null);
    try self.buffers.append(vbo);
}

// skyboxVBO.bind(gl.ARRAY_BUFFER);
// skyboxVBO.bufferData(gl.ARRAY_BUFFER, skybox_mesh.vertex_positions, gl.STATIC_DRAW);
// skyboxVAO.enableVertexAttribArray(0);
// skyboxVAO.setVertexAttributePointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(gl.Float), null);