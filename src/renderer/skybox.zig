const std = @import("std");
const Allocator = std.mem.Allocator;
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const zm = @import("zmath");
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
    self.shader.use();
    gl.depthFunc(gl.LEQUAL);
    gl.cullFace(gl.FRONT);

    // Hard code position to start
    const position = zm.loadArr3(.{0.0, 0.0, 0.0});
    const front = zm.loadArr3(.{0.0, 0.0, -1.0});
    const world_up = zm.loadArr3(.{0.0, 1.0, 0.0});
    const right = zm.normalize3(zm.cross3(front, world_up));
    const up = zm.normalize3(zm.cross3(right, front));
    const view = zm.lookAtRh(position, position + front, up);

    const window_size = self.window.getSize();
    const aspect_ratio: f32 = @as(f32, @floatFromInt(window_size[0])) / @as(f32, @floatFromInt(window_size[1]));
    const projection = zm.perspectiveFovRhGl(std.math.degreesToRadians(45.0), aspect_ratio, 0.1, 100.0);
    
    self.shader.setMat4f("view", zm.matToArr(zm.loadMat34(&zm.matToArr(view))));
    self.shader.setMat4f("projection", zm.matToArr(projection));
    
    self.vao.bind();
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_CUBE_MAP, self.texture.id);
    gl.drawArrays(gl.TRIANGLES, 0, 36);
    self.vao.unbind();
    
    gl.depthFunc(gl.LESS);
    gl.cullFace(gl.BACK);
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