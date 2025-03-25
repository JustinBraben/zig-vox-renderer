const std = @import("std");
const Allocator = std.mem.Allocator;
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const Window = @import("../engine/window.zig");
const Skybox = @import("skybox.zig");
const zstbi = @import("zstbi");

const Renderer = @This();

window: *glfw.Window,
skybox: Skybox,

pub fn init(allocator: Allocator, window: *Window) !Renderer {

    // configure global opengl flags
    // -----------------------------
    gl.enable(gl.DEPTH_TEST);
    gl.enable(gl.MULTISAMPLE);
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

pub fn beginFrame(self: *Renderer) void {
    _ = &self;
}

pub fn endFrame(self: *Renderer) void {
    _ = &self;
}