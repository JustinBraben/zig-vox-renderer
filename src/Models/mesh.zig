const std = @import("std");
const Allocator = std.mem.Allocator;
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const Shader = @import("../shader.zig");
const VAO = @import("../vao.zig");
const VBO = @import("../vbo.zig");

const Mesh = @This();

// Vertex data for a single block face
pub const Vertex = struct {
    position: [3]gl.Float,
    normal: [3]gl.Float,
    uv: [2]gl.Float,
    // You might want to add more attributes later
};

vao: VAO,
vbo: VBO,
vertex_count: usize = 0,

pub fn init() Mesh {
    var vao: VAO = undefined;
    var vbo: VBO = undefined;

    vao = VAO.init();
    vbo = VBO.init();

    vao.bind();
    vbo.bind(gl.ARRAY_BUFFER);

    // Define vertex attributes
    // Position
    vao.enableVertexAttribArray(0);
    vao.setVertexAttributePointer(0, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), null);
    
    // Normal
    vao.enableVertexAttribArray(1);
    const normal_offset: [*c]c_uint = (3 * @sizeOf(gl.Float));
    vao.setVertexAttributePointer(1, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), normal_offset);
    
    // UV
    vao.enableVertexAttribArray(2);
    const uv_offset: [*c]c_uint = (6 * @sizeOf(gl.Float));
    vao.setVertexAttributePointer(2, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), uv_offset);
    
    vao.unbind();

    return .{
        .vao = vao,
        .vbo = vbo,
    };
}

pub fn deinit(self: *Mesh) void {
    self.vbo.deinit();
    self.vao.deinit();
}

pub fn uploadData(self: *Mesh, vertices: []const Vertex) void {
    self.vao.bind();
    defer self.vao.unbind();

    self.vbo.bind(gl.ARRAY_BUFFER);
    gl.bufferData(gl.ARRAY_BUFFER, @intCast(vertices.len * @sizeOf(Vertex)), vertices.ptr, gl.STATIC_DRAW);
    self.vertex_count = vertices.len;
}

pub fn draw(self: *Mesh) void {
    if (self.vertex_count == 0) return;

    self.vao.bind();
    defer self.vao.unbind();
    gl.drawArrays(gl.TRIANGLES, 0, @intCast(self.vertex_count));
}

pub fn setBasicVoxel(self: *Mesh) void {
    const vertices = basic_voxel_vertices;

    self.uploadData(&vertices);
}

pub const basic_voxel_vertices = [_]Vertex{
    // Back face (CCW winding)
    .{ .position = [_]f32{ 0.5, -0.5, -0.5}, .normal = [_]f32{0.0, 0.0, -1.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left
    .{ .position = [_]f32{-0.5, -0.5, -0.5}, .normal = [_]f32{0.0, 0.0, -1.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-right
    .{ .position = [_]f32{-0.5,  0.5, -0.5}, .normal = [_]f32{0.0, 0.0, -1.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{-0.5,  0.5, -0.5}, .normal = [_]f32{0.0, 0.0, -1.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{ 0.5,  0.5, -0.5}, .normal = [_]f32{0.0, 0.0, -1.0}, .uv = [_]f32{1.0, 0.0} }, // top-left
    .{ .position = [_]f32{ 0.5, -0.5, -0.5}, .normal = [_]f32{0.0, 0.0, -1.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left

    // Front face (CCW winding)
    .{ .position = [_]f32{-0.5, -0.5,  0.5}, .normal = [_]f32{0.0, 0.0, 1.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left
    .{ .position = [_]f32{ 0.5, -0.5,  0.5}, .normal = [_]f32{0.0, 0.0, 1.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-right
    .{ .position = [_]f32{ 0.5,  0.5,  0.5}, .normal = [_]f32{0.0, 0.0, 1.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{ 0.5,  0.5,  0.5}, .normal = [_]f32{0.0, 0.0, 1.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{-0.5,  0.5,  0.5}, .normal = [_]f32{0.0, 0.0, 1.0}, .uv = [_]f32{1.0, 0.0} }, // top-left
    .{ .position = [_]f32{-0.5, -0.5,  0.5}, .normal = [_]f32{0.0, 0.0, 1.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left

    // Left face (CCW)
    .{ .position = [_]f32{-0.5, -0.5, -0.5}, .normal = [_]f32{-1.0, 0.0, 0.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left
    .{ .position = [_]f32{-0.5, -0.5,  0.5}, .normal = [_]f32{-1.0, 0.0, 0.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-right
    .{ .position = [_]f32{-0.5,  0.5,  0.5}, .normal = [_]f32{-1.0, 0.0, 0.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{-0.5,  0.5,  0.5}, .normal = [_]f32{-1.0, 0.0, 0.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{-0.5,  0.5, -0.5}, .normal = [_]f32{-1.0, 0.0, 0.0}, .uv = [_]f32{1.0, 0.0} }, // top-left
    .{ .position = [_]f32{-0.5, -0.5, -0.5}, .normal = [_]f32{-1.0, 0.0, 0.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left

    // Right face (CCW)
    .{ .position = [_]f32{ 0.5, -0.5,  0.5}, .normal = [_]f32{1.0, 0.0, 0.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left
    .{ .position = [_]f32{ 0.5, -0.5, -0.5}, .normal = [_]f32{1.0, 0.0, 0.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-right
    .{ .position = [_]f32{ 0.5,  0.5, -0.5}, .normal = [_]f32{1.0, 0.0, 0.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{ 0.5,  0.5, -0.5}, .normal = [_]f32{1.0, 0.0, 0.0}, .uv = [_]f32{0.0, 0.0} }, // top-right
    .{ .position = [_]f32{ 0.5,  0.5,  0.5}, .normal = [_]f32{1.0, 0.0, 0.0}, .uv = [_]f32{1.0, 0.0} }, // top-left
    .{ .position = [_]f32{ 0.5, -0.5,  0.5}, .normal = [_]f32{1.0, 0.0, 0.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-left

    // Bottom face (CCW)      
    .{ .position = [_]f32{-0.5, -0.5, -0.5}, .normal = [_]f32{0.0, -1.0, 0.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-left
    .{ .position = [_]f32{ 0.5, -0.5, -0.5}, .normal = [_]f32{0.0, -1.0, 0.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-right
    .{ .position = [_]f32{ 0.5, -0.5,  0.5}, .normal = [_]f32{0.0, -1.0, 0.0}, .uv = [_]f32{1.0, 0.0} }, // top-right
    .{ .position = [_]f32{ 0.5, -0.5,  0.5}, .normal = [_]f32{0.0, -1.0, 0.0}, .uv = [_]f32{1.0, 0.0} }, // top-right
    .{ .position = [_]f32{-0.5, -0.5,  0.5}, .normal = [_]f32{0.0, -1.0, 0.0}, .uv = [_]f32{0.0, 0.0} }, // top-left
    .{ .position = [_]f32{-0.5, -0.5, -0.5}, .normal = [_]f32{0.0, -1.0, 0.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-left

    // Top face (CCW)
    .{ .position = [_]f32{-0.5,  0.5,  0.5}, .normal = [_]f32{0.0, 1.0, 0.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-left
    .{ .position = [_]f32{ 0.5,  0.5,  0.5}, .normal = [_]f32{0.0, 1.0, 0.0}, .uv = [_]f32{1.0, 1.0} }, // bottom-right
    .{ .position = [_]f32{ 0.5,  0.5, -0.5}, .normal = [_]f32{0.0, 1.0, 0.0}, .uv = [_]f32{1.0, 0.0} }, // top-right
    .{ .position = [_]f32{ 0.5,  0.5, -0.5}, .normal = [_]f32{0.0, 1.0, 0.0}, .uv = [_]f32{1.0, 0.0} }, // top-right
    .{ .position = [_]f32{-0.5,  0.5, -0.5}, .normal = [_]f32{0.0, 1.0, 0.0}, .uv = [_]f32{0.0, 0.0} }, // top-left
    .{ .position = [_]f32{-0.5,  0.5,  0.5}, .normal = [_]f32{0.0, 1.0, 0.0}, .uv = [_]f32{0.0, 1.0} }, // bottom-left
};

pub const vertex_positions = &[_]gl.Float{
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
};

pub const normal_positions = &[_]gl.Float{
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
};

pub const texture_coords = &[_]gl.Float{
    // back face (CCW winding)
    1.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    // front face (CCW winding)
    1.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    // left face (CCW)
    1.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    // right face (CCW)
    1.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    // bottom face (CCW)
    1.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    // top face (CCW)
    1.0, 1.0,
    0.0, 1.0,
    0.0, 0.0,
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
};