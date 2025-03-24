const std = @import("std");
const Allocator = std.mem.Allocator;
const ztracy = @import("ztracy");
const math = std.math;
const zgui = @import("zgui");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const zstbi = @import("zstbi");
const zm = @import("zmath");
const gl = zopengl.bindings;
const Camera = @import("camera.zig");
const Renderer = @import("gfx/renderer.zig");
const World = @import("world/world.zig");
const ChunkManager = @import("world/chunk_manager.zig");

pub const ConfigOptions = struct {
    width: i32 = 1280,
    height: i32 = 720,
    gl_major: i32 = 4,
    gl_minor: i32 = 1,
};

// Instead of loading a cubemap, load individual 2D textures
const DirtTextures = struct {
    right: u32,
    left: u32,
    top: u32,
    bottom: u32,
    front: u32,
    back: u32,
};

// Camera
const camera_pos = zm.loadArr3(.{ 0.0, 0.0, 5.0 });
var lastX: f64 = 0.0;
var lastY: f64 = 0.0;
var first_mouse = true;
var camera = Camera.init(camera_pos);
var toggle_cursor = false;

// Timing
var delta_time: f32 = 0.0;
var last_frame: f32 = 0.0;

const Application = @This();

allocator: Allocator,
window: *glfw.Window,
config: ConfigOptions,

pub fn init(gpa: Allocator, config: ConfigOptions) !Application {
    try glfw.init();
    glfw.windowHint(.context_version_major, config.gl_major);
    glfw.windowHint(.context_version_minor, config.gl_minor);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    glfw.windowHint(.opengl_forward_compat, true);
    glfw.windowHint(.client_api, .opengl_api);
    glfw.windowHint(.doublebuffer, true);

    const window = try glfw.Window.create(config.width, config.height, "Voxel Renderer", null);
    glfw.makeContextCurrent(window);

    _ = window.setCursorPosCallback(mouse_callback);
    try zopengl.loadCoreProfile(glfw.getProcAddress, @intCast(config.gl_major), @intCast(config.gl_minor));
    glfw.swapInterval(1);

    // configure global opengl state
    // -----------------------------
    gl.enable(gl.DEPTH_TEST);
    gl.enable(gl.CULL_FACE);
    gl.enable(gl.MULTISAMPLE);
    gl.enable(gl.TEXTURE_CUBE_MAP_SEAMLESS);

    zgui.init(gpa);
    zstbi.init(gpa);
    zgui.backend.init(window);

    return .{
        .allocator = gpa,
        .window = window,
        .config = config,
    };
}

pub fn deinit(self: *Application) void {
    zgui.backend.deinit();
    zstbi.deinit();
    zgui.deinit();
    self.window.destroy();
    glfw.terminate();
}

pub fn runLoop(self: *Application) !void {
    try self.turnOffMouse();

    // // const height_range = 10.0;
    // // var world = try World.init(self.allocator, height_range);
    // // try world.generate();
    // // defer world.deinit();
    // // var world = try World.init(self.allocator);
    // // defer world.deinit();

    var chunk_manager = try ChunkManager.init(self.allocator, "assets/textures/blocks.png");
    defer chunk_manager.deinit();

    var world = try World.init(self.allocator, &chunk_manager, null);
    defer world.deinit();
    
    var renderer = try Renderer.init(self.allocator, "assets/textures/blocks.png");
    defer renderer.deinit();

    var wireframe: bool = false;
    var light_direction: [3]f32 = .{ 0.0, -1.0, -1.0 };
    var shininess: f32 = 32.0;

    while (!self.window.shouldClose()) {
        // per-frame time logic
        // --------------------
        const current_frame: f32 = @floatCast(glfw.getTime());
        delta_time = current_frame - last_frame;
        last_frame = current_frame;

        try self.handleEvents(delta_time);

        // NEW Update chunks around player
        try world.updateChunksAroundPlayer(camera.getViewPos());

        // render
        // ------
        gl.clearColor(0.1, 0.1, 0.1, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        const window_size = self.window.getSize();
        renderer.renderWorld(&world, window_size, &camera);

        const fb_size = self.window.getFramebufferSize();
        zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));
        zgui.setNextWindowPos(.{ .x = 0.0, .y = 0.0, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 0.0, .h = 0.0, .cond = .first_use_ever });
        if (zgui.begin("Debug Window", .{})) {
            if (zgui.checkbox("wireframe", .{ .v = &wireframe })) {
                renderer.setWireframe(wireframe);
            }
            _ = zgui.text("Camera Pos x:{d} y:{d} z:{d}", .{camera.position[0], camera.position[1], camera.position[2]});
            _ = zgui.dragFloat("shininess", .{ .v = &shininess, .min = 16.0, .max = 128.0 });
            if (zgui.dragFloat3("light direction", .{ .v = &light_direction, .min = -1.0, .max = 1.0, })) {
                // cube_mesh.shader.setVec3f("light.direction",  light_direction);
            }
        }
        zgui.end();
        zgui.backend.draw();

        self.window.swapBuffers();
        glfw.pollEvents();
    }
}

fn handleEvents(self: *Application, deltaTime: f32) !void {
    if (self.window.getKey(.escape) == .press) {
        self.window.setShouldClose(true);
    }

    if (self.window.getKey(.c) == .press) {
        toggle_cursor = !toggle_cursor;
        if (toggle_cursor) {
            try self.window.setInputMode(.cursor, glfw.Cursor.Mode.normal);
            return;
        } else {
            try self.window.setInputMode(.cursor, glfw.Cursor.Mode.disabled);
        }
    }

    camera.speed_modifier = if (self.window.getKey(.left_shift) == .press) 50.0 else 25.0;

    if (self.window.getKey(.w) == .press) {
        camera.processKeyboard(.FORWARD, deltaTime);
    }
    if (self.window.getKey(.a) == .press) {
        camera.processKeyboard(.LEFT, deltaTime);
    }
    if (self.window.getKey(.s) == .press) {
        camera.processKeyboard(.BACKWARD, deltaTime);
    }
    if (self.window.getKey(.d) == .press) {
        camera.processKeyboard(.RIGHT, deltaTime);
    }
}

fn turnOffMouse(self: *Application) !void {
    try self.window.setInputMode(.cursor, glfw.Cursor.Mode.disabled);
}

fn turnOnMouse(self: *Application) !void {
    try self.window.setInputMode(.cursor, glfw.Cursor.Mode.normal);
}

fn mouse_callback(_: *glfw.Window, xposIn: f64, yposIn: f64) callconv(.C) void {
    // No camera movement
    if (toggle_cursor) return;

    const xpos: f32 = @floatCast(@trunc(xposIn));
    const ypos: f32 = @floatCast(@trunc(yposIn));

    if (first_mouse)
    {
        lastX = xpos;
        lastY = ypos;
        first_mouse = false;
    }

    const xoffset = xpos - lastX;
    const yoffset = lastY - ypos; // reversed since y-coordinates go from bottom to top
    lastX = xpos;
    lastY = ypos;

    camera.processMouseMovement(xoffset, yoffset, true);
}