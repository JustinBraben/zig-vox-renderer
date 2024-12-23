const std = @import("std");
const Allocator = std.mem.Allocator;
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const Shader = @import("../shader.zig");

const CubeMesh = @This();

shader: Shader,
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
    };
}