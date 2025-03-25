const std = @import("std");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;

const Window = @This();

pub const ConfigOptions = struct {
    width: i32 = 1280,
    height: i32 = 720,
    gl_major: i32 = 4,
    gl_minor: i32 = 1,
};

window: *glfw.Window,
config: ConfigOptions,

pub fn init(config: ConfigOptions) !Window {
    try glfw.init();
    glfw.windowHint(.context_version_major, config.gl_major);
    glfw.windowHint(.context_version_minor, config.gl_minor);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    glfw.windowHint(.opengl_forward_compat, true);
    glfw.windowHint(.client_api, .opengl_api);
    glfw.windowHint(.doublebuffer, true);

    const window = try glfw.Window.create(config.width, config.height, "Voxel Renderer", null);
    glfw.makeContextCurrent(window);

    return .{
        .window = window,
        .config = config,
    };
}

pub fn deinit(self: *Window) void {
    self.window.destroy();
    glfw.terminate();
}

pub fn shouldClose(self: *Window) bool {
    return self.window.shouldClose();
}

pub fn swapBuffers(self: *Window) void {
    self.window.swapBuffers();
}