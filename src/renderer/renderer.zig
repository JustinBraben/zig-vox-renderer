const std = @import("std");
const Allocator = std.mem.Allocator;
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const zm = @import("zmath");
const zstbi = @import("zstbi");
const Window = @import("../engine/window.zig");
const Skybox = @import("skybox.zig");
const Player = @import("../game/player.zig");

const Renderer = @This();

window: *glfw.Window,
skybox: Skybox,

pub fn init(allocator: Allocator, window: *Window) !Renderer {
    try zopengl.loadCoreProfile(glfw.getProcAddress, @intCast(window.config.gl_major), @intCast(window.config.gl_minor));
    glfw.swapInterval(1);

    // configure global opengl flags
    // -----------------------------
    gl.enable(gl.DEPTH_TEST);
    gl.enable(gl.CULL_FACE);
	gl.enable(gl.TEXTURE_CUBE_MAP_SEAMLESS);
    gl.cullFace(gl.BACK);
	gl.frontFace(gl.CCW);

    zstbi.init(allocator);

    return .{
        .window = window.window,
        .skybox = try Skybox.init(allocator),
    };
}

pub fn deinit(self: *Renderer) void {
    self.skybox.deinit();
    zstbi.deinit();
}

pub fn beginFrame(_: *Renderer) void {
    gl.clearColor(0.1, 0.1, 0.1, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
}

pub fn endFrame(self: *Renderer) void {
    _ = &self;
}

pub fn renderSkybox(self: *Renderer, player: *Player) void {
    // TODO: self.skybox.draw(camera)
    self.skybox.shader.use();
    gl.depthFunc(gl.LEQUAL);
    gl.cullFace(gl.FRONT);

    // View matrix
    var view: [16]f32 = undefined;
    // Buffer to store Ortho-projection matrix (in render loop)
    var projection: [16]f32 = undefined;

    var viewM = player.camera.getViewMatrix();
    zm.storeMat(&view, viewM);
    viewM = zm.loadMat34(&view);
    zm.storeMat(&view, viewM);

    const window_size = self.window.getSize();
    const aspect_ratio: f32 = @as(f32, @floatFromInt(window_size[0])) / @as(f32, @floatFromInt(window_size[1]));
    const projectionM = zm.perspectiveFovRhGl(std.math.degreesToRadians(player.camera.zoom), aspect_ratio, 0.1, 100.0);
    zm.storeMat(&projection, projectionM);
    
    self.skybox.shader.setMat4f("view", view);
    self.skybox.shader.setMat4f("projection", projection);
    
    self.skybox.vao.bind();
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_CUBE_MAP, self.skybox.texture.id);
    gl.drawArrays(gl.TRIANGLES, 0, 36);
    self.skybox.vao.unbind();
    
    gl.depthFunc(gl.LESS);
    gl.cullFace(gl.BACK);
}