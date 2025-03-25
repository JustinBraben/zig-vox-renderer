const std = @import("std");
const Allocator = std.mem.Allocator;
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const Window = @import("../engine/window.zig");
const Shader = @import("shader.zig");
const Texture = @import("texture.zig");
const VAO = @import("vao.zig");
const VBO = @import("vbo.zig");

const Skybox = @This();

vao: VAO,
buffers: std.ArrayList(VBO),
texture: Texture,
shader: Shader,

pub fn init(allocator: Allocator) !Skybox {
    const skybox_paths = &.{
        "assets/textures/skybox/right.jpg",
        "assets/textures/skybox/left.jpg",
        "assets/textures/skybox/top.jpg",
        "assets/textures/skybox/bottom.jpg",
        "assets/textures/skybox/front.jpg",
        "assets/textures/skybox/back.jpg",
    };

    var skybox = Skybox{
        .vao = VAO.init(),
        .buffers = std.ArrayList(VBO).init(allocator),
        .texture = try Texture.initCubeMap(skybox_paths),
        .shader = try Shader.create(allocator, "assets/shaders/skybox_vert.glsl", "assets/shaders/skybox_frag.glsl")
    };

    skybox.vao.bind();
    try skybox.addVBO(3, &vertex_positions);
    skybox.vao.unbind();

    // var vbo = VBO.init();
    // vbo.bind(gl.ARRAY_BUFFER);
    // vbo.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
    // self.vao.enableVertexAttribArray(@intCast(self.buffers.items.len));
    // self.vao.setVertexAttributePointer(@intCast(self.buffers.items.len), size, gl.FLOAT, gl.FALSE, size * @sizeOf(gl.Float), null);
    // try self.buffers.append(vbo);

    // skybox_mesh.bindVAO();
    // try skybox_mesh.addVBO(3, skybox_mesh.vertex_positions);
    // skybox_mesh.unbindVAO();
    return skybox;
}

pub fn deinit(self: *Skybox) void {
    for (self.buffers.items) |*vbo| {
        vbo.deinit();
    }
    self.buffers.deinit();
    self.vao.deinit();
    self.texture.deinit();
}

pub fn addVBO(self: *Skybox, size: gl.Int, data: []const gl.Float) !void {
    var vbo = VBO.init();
    vbo.bind(gl.ARRAY_BUFFER);
    vbo.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
    self.vao.enableVertexAttribArray(@intCast(self.buffers.items.len));
    self.vao.setVertexAttributePointer(@intCast(self.buffers.items.len), size, gl.FLOAT, gl.FALSE, size * @sizeOf(gl.Float), null);
    try self.buffers.append(vbo);
}

pub fn reloadTexture(self: *Skybox) void {
    _ = &self;
}

pub fn draw(self: *Skybox) void {
    _ = &self;
}

const vertex_positions = [_]gl.Float{
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
};

const texture_coords = [_]gl.Float{
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
};