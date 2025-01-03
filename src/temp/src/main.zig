const std = @import("std");
const Allocator = std.mem.Allocator;
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const zm = @import("zmath");
const Camera = @import("misc/camera.zig");
const Shader = @import("misc/shader.zig");
const ChunkRenderer = @import("rendering/chunk_renderer.zig");

pub const ConfigOptions = struct {
    width: i32 = 1920,
    height: i32 = 1080,
    fullscreen: bool = false,
    gl_major: i32 = 4,
    gl_minor: i32 = 4,
};


pub const MESH_TYPE = enum(i32) {
    SPHERE = 0,
    TERRAIN = 1,
    RANDOM = 2,
    CHECKERBOARD = 3,
    EMPTY = 4,
    Count = 5,
};

var mesh_type = @intFromEnum(MESH_TYPE.SPHERE);

const ChunkRenderRata = struct {
    chunk_pos: zm.Vec = .{0, 0, 0, 0},
    face_draw_commands: std.BoundedArray(ChunkRenderer.DrawElementsIndirectCommand, 6) = std.BoundedArray(ChunkRenderer.DrawElementsIndirectCommand, 6).init(6),
};

var chunk_renderer: ChunkRenderer = undefined;

var camera: Camera = undefined;
var last_x: f64 = 0.0;
var last_y: f64 = 0.0;

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const config: ConfigOptions = .{};

    _ = glfw.setErrorCallback(glfw_error_callback);

    try glfw.init();
    defer glfw.terminate();

    const window = try init_window(config);
    defer window.destroy();
    window.setInputMode(.cursor, glfw.Cursor.Mode.disabled);
    glfw.makeContextCurrent(window);

    _ = window.setCursorPosCallback(mouse_callback);
    _ = window.setKeyCallback(key_callback);
    window.setPos(0, 31);
    try zopengl.loadCoreProfile(glfw.getProcAddress, @intCast(config.gl_major), @intCast(config.gl_minor));
    glfw.swapInterval(1);

    init_opengl();

    chunk_renderer = try ChunkRenderer.init(gpa);
    defer chunk_renderer.deinit();

    const shader = Shader.create(gpa, "src/shaders/main_vert.glsl", "src/shaders/main_frag.glsl");
    _ = shader;
    camera = Camera.init(null, config.width, config.height);

    var forward_move: f32 = 0.0;
    var right_move: f32 = 0.0;
    const noclip_speed: f32 = 250.0;

    var delta_time: f32 = 0.0;
    var last_frame: f32 = @floatCast(glfw.getTime());

    while (!window.shouldClose()) {
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        const current_frame: f32 = @floatCast(glfw.getTime());
        delta_time = current_frame - last_frame;
        last_frame = current_frame;

        if (window.getKey(.w) == .press) { 
            forward_move = 1.0;
        } else if (window.getKey(.s) == .press) {
            forward_move = -1.0;
        } else {
            forward_move = 0.0;
        }

        if (window.getKey(.d) == .press) { 
            right_move = 1.0;
        } else if (window.getKey(.a) == .press) {
            right_move = -1.0;
        } else {
            right_move = 0.0;
        }

        const wish_dir = (camera.front * @as(zm.F32x4, @splat(forward_move))) + (camera.right * @as(zm.F32x4, @splat(right_move)));
        camera.position += @as(zm.F32x4, @splat(noclip_speed)) * wish_dir * @as(zm.F32x4, @splat(delta_time));

        window.swapBuffers();
        glfw.pollEvents();
    }
}

fn mouse_callback(_: *glfw.Window, xpos: f64, ypos: f64) callconv(.C) void {
    camera.processMouseMovement(xpos - last_x, last_y - ypos);
    last_x = xpos;
    last_y = ypos;
    // std.debug.print("Camera moved! X: {d}, Y: {d}\n", .{last_x, last_y});
}

fn key_callback(
    window: *glfw.Window,
    _: glfw.Key,
    _: i32,
    _: glfw.Action,
    _: glfw.Mods,
) callconv(.C) void {
    if (window.getKey(.escape) == .press) {
        window.setShouldClose(true);
    }
    
    if (window.getKey(.x) == .release) {
        var last_poly_mode: [2]gl.Int = undefined;
        gl.getIntegerv(gl.POLYGON_MODE, &last_poly_mode);

        if (last_poly_mode[0] == gl.FILL) {
            gl.polygonMode(gl.FRONT_AND_BACK, gl.LINE);
        } else {
            gl.polygonMode(gl.FRONT_AND_BACK, gl.FILL);
        }
    }

    if (window.getKey(.one) == .release) {
        std.debug.print("Forward: {d}, {d}, {d} \n", .{camera.front[0], camera.front[1], camera.front[2]});
    }

    if (window.getKey(.space) == .release) {
        // createTestChunk();
    }

    if (window.getKey(.tab) == .release) {
        mesh_type += 1;
        if (mesh_type >= @intFromEnum(MESH_TYPE.Count)) {
            mesh_type = 0;
        }
        // createTestChunk();
    }
}

fn createTestChunk() void {

}

fn init_window(config: ConfigOptions) !*glfw.Window {
    glfw.windowHintTyped(.context_version_major, config.gl_major);
    glfw.windowHintTyped(.context_version_minor, config.gl_minor);
    glfw.windowHintTyped(.opengl_profile, .opengl_core_profile);
    glfw.windowHintTyped(.samples, 2);

    const window = try glfw.Window.create(config.width, config.height, "Binary Greedy Meshing", null);

    return window;
}

fn init_opengl() void {
    gl.enable(gl.DEBUG_OUTPUT);
    gl.debugMessageControl(gl.DONT_CARE, gl.DONT_CARE, gl.DEBUG_SEVERITY_NOTIFICATION, 0, null, gl.FALSE);
    gl.debugMessageCallback(message_callback, null);

    gl.enable(gl.DEPTH_TEST);

    gl.frontFace(gl.CCW);
    gl.cullFace(gl.BACK);
    gl.enable(gl.CULL_FACE);

    gl.clearColor(0.529, 0.808, 0.922, 0.0);

    gl.enable(gl.MULTISAMPLE);
}

fn message_callback(
    source: gl.Enum,
    d_type: gl.Enum,
    id: gl.Uint,
    severity: gl.Enum,
    length: gl.Sizei,
    message: [*c]const gl.Char,
    userParam: *const anyopaque,
) callconv(.C) void {
    _ = source;
    _ = id;
    _ = length;
    _ = userParam;
    const SEVERITY = switch (severity) {
        gl.DEBUG_SEVERITY_LOW => "LOW",
        gl.DEBUG_SEVERITY_MEDIUM => "MEDIUM",
        gl.DEBUG_SEVERITY_HIGH => "HIGH",
        gl.DEBUG_SEVERITY_NOTIFICATION => "NOTIFICATION",
        else => unreachable,
    };

    const debug_type_error = if (d_type == gl.DEBUG_TYPE_ERROR) "** GL ERROR **" else "";

    std.debug.print("GL CALLBACK: {s} type, severity = {s}, message = {s}\n", 
    .{
        debug_type_error,
        SEVERITY, 
        message
    });
}

fn glfw_error_callback(
    error_code: i32,
    description: *?[:0]const u8,
) callconv(.C) void {
    std.debug.print("GLFW error {d}: {?s}\n", .{error_code, description});
}