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

pub var lastX: f64 = 0.0;
pub var lastY: f64 = 0.0;

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

    // Set callbacks
    _ = window.setCursorPosCallback(mouse_callback);
    try zopengl.loadCoreProfile(glfw.getProcAddress, @intCast(config.gl_major), @intCast(config.gl_minor));
    glfw.swapInterval(1);

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

fn mouse_callback(_: *glfw.Window, xposIn: f64, yposIn: f64) callconv(.C) void {
    // No camera movement
    // if (toggle_cursor) return;

    const xpos: f32 = @floatCast(@trunc(xposIn));
    const ypos: f32 = @floatCast(@trunc(yposIn));

    // if (first_mouse)
    // {
    //     lastX = xpos;
    //     lastY = ypos;
    //     first_mouse = false;
    // }

    const xoffset = xpos - lastX;
    const yoffset = lastY - ypos; // reversed since y-coordinates go from bottom to top
    lastX = xpos;
    lastY = ypos;

    // TODO: Should set a bool that camera should processMouseMovement
    _ = xoffset;
    _ = yoffset;
    // camera.processMouseMovement(xoffset, yoffset, true);
}