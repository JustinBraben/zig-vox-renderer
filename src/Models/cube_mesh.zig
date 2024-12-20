const std = @import("std");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;

const CubeMesh = @This();

vertex_positions: []const gl.Float = &[_]gl.Float{
    // back face (CCW winding)
    0.5, -0.5, -0.5,   // bottom-left
    -0.5, -0.5, -0.5,   // bottom-right
    -0.5,  0.5, -0.5,   // top-right
    -0.5,  0.5, -0.5,   // top-right
    0.5,  0.5, -0.5,   // top-left
    0.5, -0.5, -0.5,   // bottom-left
    // front face (CCW winding)
    -0.5, -0.5,  0.5,   // bottom-left
    0.5, -0.5,  0.5,   // bottom-right
    0.5,  0.5,  0.5,   // top-right
    0.5,  0.5,  0.5,   // top-right
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
    -0.5, -0.5, -0.5,  // bottom-left
    0.5, -0.5, -0.5,  // bottom-right
    0.5, -0.5,  0.5,  // top-right
    0.5, -0.5,  0.5,  // top-right
    -0.5, -0.5,  0.5,  // top-left
    -0.5, -0.5, -0.5,  // bottom-left
    // top face (CCW)
    -0.5,  0.5,  0.5,  // bottom-left
    0.5,  0.5,  0.5,  // bottom-right
    0.5,  0.5, -0.5,  // top-right
    0.5,  0.5, -0.5,  // top-right
    -0.5,  0.5, -0.5,  // top-left
    -0.5,  0.5,  0.5,  // bottom-left
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
}