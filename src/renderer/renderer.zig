const std = @import("std");
const Allocator = std.mem.Allocator;
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const Window = @import("../engine/window.zig");
const Shader = @import("shader.zig");

const Renderer = @This();

window: *glfw.Window,
skybox_shader: Shader,

pub fn init(allocator: Allocator, window: *Window) !Renderer {

    // configure global opengl flags
    // -----------------------------
    gl.enable(gl.DEPTH_TEST);
    gl.enable(gl.MULTISAMPLE);
    gl.enable(gl.CULL_FACE);
    gl.cullFace(gl.BACK);
	gl.frontFace(gl.CCW);
	gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    return .{
        .window = window.window,
        .skybox_shader = try Shader.create(allocator, "assets/shaders/skybox_vert.glsl", "assets/shaders/skybox_frag.glsl"),
    };
}

pub fn deinit(self: *Renderer) void {
    _ = &self;
}

pub fn beginFrame(self: *Renderer) void {
    _ = &self;
}

pub fn endFrame(self: *Renderer) void {
    _ = &self;
}