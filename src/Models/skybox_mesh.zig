const std = @import("std");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;

const SkyboxMesh = @This();

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
}