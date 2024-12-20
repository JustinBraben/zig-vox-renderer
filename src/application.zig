const std = @import("std");
const math = std.math;
const zgui = @import("zgui");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const zstbi = @import("zstbi");
const zm = @import("zmath");
const gl = zopengl.bindings;
const znoise = @import("znoise");
const Camera = @import("camera.zig");
const Shader = @import("shader.zig");
const Utils = @import("utils.zig");
const VAO = @import("vao.zig");
const VBO = @import("vbo.zig");
const CubeMesh = @import("Models/cube_mesh.zig");
const SkyboxMesh = @import("Models/skybox_mesh.zig");

pub const ConfigOptions = struct {
    width: i32 = 1280,
    height: i32 = 720,
    gl_major: i32 = 4,
    gl_minor: i32 = 1,
};

// Camera
const camera_pos = zm.loadArr3(.{ 0.0, 0.0, 5.0 });
var lastX: f64 = 0.0;
var lastY: f64 = 0.0;
var first_mouse = true;
var camera = Camera.init(camera_pos);

// Timing
var delta_time: f32 = 0.0;
var last_frame: f32 = 0.0;

const Application = @This();

window: *glfw.Window,
config: ConfigOptions,

pub fn init(config: ConfigOptions) !Application {
    try glfw.init();
    glfw.windowHintTyped(.context_version_major, config.gl_major);
    glfw.windowHintTyped(.context_version_minor, config.gl_minor);
    glfw.windowHintTyped(.opengl_profile, .opengl_core_profile);
    glfw.windowHintTyped(.opengl_forward_compat, true);
    glfw.windowHintTyped(.client_api, .opengl_api);
    glfw.windowHintTyped(.doublebuffer, true);
    return .{
        .window = try glfw.Window.create(config.width, config.height, "Voxel Renderer", null),
        .config = config,
    };
}

pub fn deinit(self: *Application) void {
    self.window.destroy();
    glfw.terminate();
}

pub fn runLoop(self: *Application) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var arena_allocator_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator_state.deinit();
    const arena = arena_allocator_state.allocator();

    glfw.makeContextCurrent(self.window);
    _ = self.window.setCursorPosCallback(mouse_callback);
    try zopengl.loadCoreProfile(glfw.getProcAddress, @intCast(self.config.gl_major), @intCast(self.config.gl_minor));
    glfw.swapInterval(1);
    self.turnOffMouse();

    zgui.init(allocator);
    defer zgui.deinit();

    // configure global opengl state
    // -----------------------------
    gl.enable(gl.DEPTH_TEST);

    // create shader program
    var shader: Shader = Shader.create(arena, "assets/shaders/voxel_instance_vert.glsl", "assets/shaders/voxel_instance_frag.glsl");
    var skybox_shader: Shader = Shader.create(arena, "assets/shaders/skybox_vert.glsl", "assets/shaders/skybox_frag.glsl");

    var model_matrices = std.ArrayList([16]f32).init(allocator);
    defer model_matrices.deinit();

    var rng = std.Random.Xoshiro256.init(@intCast(std.time.timestamp()));
    const seed = rng.random().int(i32);
    const gen = znoise.FnlGenerator{
        .seed = @intCast(seed)
    };
    const height_range = 10.0;
    for (0..1000) |x_pos| {
        for (0..1000) |z_pos| {
            const x = @mod(@as(f32, @floatFromInt(x_pos)), 1000.0);
            const z = @mod(@as(f32, @floatFromInt(z_pos)), 1000.0);

            const y = @floor(gen.noise2(x, z) * height_range);

            const position = zm.translation(x, y, z);
            try model_matrices.append(zm.matToArr(position));
        }
    }

    // // set up vertex data (and buffer(s)) and configure vertex attributes
    // // ------------------------------------------------------------------
    const cube_mesh: CubeMesh = .{};
    const skybox_mesh: SkyboxMesh = .{};

    // cube VAO
    var cubeVAO = try VAO.init();
    defer cubeVAO.deinit();

    // Create two separate VBOs - one for positions, one for texture coordinates
    var positionVBO = try VBO.init();
    defer positionVBO.deinit();
    var texCoordVBO = try VBO.init();
    defer texCoordVBO.deinit();

    // Bind VAO
    cubeVAO.bind();
    positionVBO.bind(gl.ARRAY_BUFFER);
    positionVBO.bufferData(gl.ARRAY_BUFFER, cube_mesh.vertex_positions, gl.STATIC_DRAW);
    cubeVAO.enableVertexAttribArray(0);
    cubeVAO.setVertexAttributePointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(gl.Float), null);

    // Buffer texture coordinate data
    texCoordVBO.bind(gl.ARRAY_BUFFER);
    texCoordVBO.bufferData(gl.ARRAY_BUFFER, cube_mesh.texture_coords, gl.STATIC_DRAW);
    cubeVAO.enableVertexAttribArray(1);
    cubeVAO.setVertexAttributePointer(1, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(gl.Float), null);
    cubeVAO.unbind();

    // Add this after your cube VAO/VBO setup code:
    var instanceVBO = try VBO.init();
    defer instanceVBO.deinit();

    // Then in your main function, after creating model_matrices:
    const flattened_matrices = try Utils.flattenMatrices(model_matrices.items, allocator);
    defer allocator.free(flattened_matrices);

    // Bind VAO and set up instance data
    cubeVAO.bind();
    instanceVBO.bind(gl.ARRAY_BUFFER);
    instanceVBO.bufferData(gl.ARRAY_BUFFER, flattened_matrices, gl.STATIC_DRAW);

    // Set up instance matrix attribute pointers (location 2-5 for mat4)
    const vec4Size = 4 * @sizeOf(gl.Float);
    const mat4Size = 4 * vec4Size;

    cubeVAO.enableVertexAttribArray(2);
    gl.vertexAttribPointer(2, 4, gl.FLOAT, gl.FALSE, mat4Size, null);
    cubeVAO.enableVertexAttribArray(3);
    gl.vertexAttribPointer(3, 4, gl.FLOAT, gl.FALSE, mat4Size, @ptrFromInt(vec4Size));
    cubeVAO.enableVertexAttribArray(4);
    gl.vertexAttribPointer(4, 4, gl.FLOAT, gl.FALSE, mat4Size, @ptrFromInt(2 * vec4Size));
    cubeVAO.enableVertexAttribArray(5);
    gl.vertexAttribPointer(5, 4, gl.FLOAT, gl.FALSE, mat4Size, @ptrFromInt(3 * vec4Size));

    gl.vertexAttribDivisor(2, 1);
    gl.vertexAttribDivisor(3, 1);
    gl.vertexAttribDivisor(4, 1);
    gl.vertexAttribDivisor(5, 1);

    cubeVAO.unbind();

    // skybox VAO
    var skyboxVAO = try VAO.init();
    defer skyboxVAO.deinit();
    var skyboxVBO = try VBO.init();
    defer skyboxVBO.deinit();

    skyboxVAO.bind();
    skyboxVBO.bind(gl.ARRAY_BUFFER);
    skyboxVBO.bufferData(gl.ARRAY_BUFFER, skybox_mesh.vertex_positions, gl.STATIC_DRAW);
    skyboxVAO.enableVertexAttribArray(0);
    skyboxVAO.setVertexAttributePointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(gl.Float), null);
    skyboxVAO.unbind();

    // zstbi: loading an image.
    zstbi.init(allocator);
    defer zstbi.deinit();

    const dirt = &.{
        "assets/textures/dirt/right.jpg",
        "assets/textures/dirt/left.jpg",
        "assets/textures/dirt/top.jpg",
        "assets/textures/dirt/bottom.jpg",
        "assets/textures/dirt/front.jpg",
        "assets/textures/dirt/back.jpg",
    };
    const skybox = &.{
        "assets/textures/skybox/right.jpg",
        "assets/textures/skybox/left.jpg",
        "assets/textures/skybox/top.jpg",
        "assets/textures/skybox/bottom.jpg",
        "assets/textures/skybox/front.jpg",
        "assets/textures/skybox/back.jpg",
    };

    const dirt_cube_map_texture = try Utils.loadCubemap(dirt);
    const skybox_cube_map_texture = try Utils.loadCubemap(skybox);

    // shader configuration
    // --------------------
    shader.use();
    shader.setInt("texture_diffuse1", 0);

    skybox_shader.use();
    skybox_shader.setInt("skybox", 0);

    // Buffer to store Model matrix
    var model: [16]f32 = undefined;

    // View matrix
    var view: [16]f32 = undefined;

    // Buffer to store Ortho-projection matrix (in render loop)
    var projection: [16]f32 = undefined;

    var wireframe: bool = false;

    zgui.backend.init(self.window);
    defer zgui.backend.deinit();

    while (!self.window.shouldClose()) {
        // per-frame time logic
        // --------------------
        const current_frame: f32 = @floatCast(glfw.getTime());
        delta_time = current_frame - last_frame;
        last_frame = current_frame;

        self.handleEvents(delta_time);

        // render
        // ------
        gl.clearColor(0.1, 0.1, 0.1, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        // draw scene as normal
        shader.use();

        zm.storeMat(&model, zm.identity());

        var viewM = camera.getViewMatrix();
        zm.storeMat(&view, viewM);
        shader.setMat4f("view", view);

        // view/projection transformations
        const window_size = self.window.getSize();
        const aspect_ratio: f32 = @as(f32, @floatFromInt(window_size[0])) / @as(f32, @floatFromInt(window_size[1]));
        const projectionM = zm.perspectiveFovRhGl(Utils.radians(camera.zoom), aspect_ratio, 0.1, 100.0);
        zm.storeMat(&projection, projectionM);
        shader.setMat4f("projection",  projection);

        if (wireframe) {
            gl.polygonMode(gl.FRONT_AND_BACK, gl.LINE);
        } else {
            gl.polygonMode(gl.FRONT_AND_BACK, gl.FILL);
        }

        // cubes
        cubeVAO.bind();
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_CUBE_MAP, dirt_cube_map_texture);
        gl.drawArraysInstanced(gl.TRIANGLES, 0, 36, @intCast(model_matrices.items.len));
        cubeVAO.unbind();

        // draw skybox as last
        gl.depthFunc(gl.LEQUAL);  // change depth function so depth test passes when values are equal to depth buffer's content
        skybox_shader.use();
        viewM = zm.loadMat34(&view);
        zm.storeMat(&view, viewM);
        skybox_shader.setMat4f("view", view);
        skybox_shader.setMat4f("projection", projection);

        // skybox cube
        skyboxVAO.bind();
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_CUBE_MAP, skybox_cube_map_texture);
        gl.drawArrays(gl.TRIANGLES, 0, 36);
        skyboxVAO.unbind();
        gl.depthFunc(gl.LESS); // set depth function back to default

        const fb_size = self.window.getFramebufferSize();
        zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));
        zgui.setNextWindowPos(.{ .x = 0.0, .y = 0.0, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 0.0, .h = 0.0, .cond = .first_use_ever });
        if (zgui.begin("Debug Window", .{})) {
            _ = zgui.checkbox("wireframe", .{ .v = &wireframe });
        }
        zgui.end();
        zgui.backend.draw();

        self.window.swapBuffers();
        glfw.pollEvents();
    }
}

fn handleEvents(self: *Application, deltaTime: f32) void {
    if (self.window.getKey(.escape) == .press) {
        self.window.setShouldClose(true);
    }

    camera.speed_modifier = if (self.window.getKey(.left_shift) == .press) 3.0 else 1.0;

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

fn turnOffMouse(self: *Application) void {
    self.window.setInputMode(.cursor, glfw.Cursor.Mode.disabled);
}

fn turnOnMouse(self: *Application) void {
    self.window.setInputMode(.cursor, glfw.Cursor.Mode.normal);
}

fn mouse_callback(window: *glfw.Window, xposIn: f64, yposIn: f64) callconv(.C) void {
    _ = &window;
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

fn loadTexture(path: [:0]const u8, textureID: *c_uint) !void {
    // var textureID: gl.Uint = undefined;
    gl.genTextures(1, textureID);

    var texture_image = try zstbi.Image.loadFromFile(path, 0);
    defer texture_image.deinit();

    const format: gl.Enum = switch (texture_image.num_components) {
        1 => gl.RED,
        3 => gl.RGB,
        4 => gl.RGBA,
        else => unreachable,
    };

    std.debug.print("{s} is {}\n", .{path, format});

    gl.bindTexture(gl.TEXTURE_2D, textureID.*);
    // Generate the textureID
    gl.texImage2D(
        gl.TEXTURE_2D, 
        0, 
        format, 
        @as(c_int, @intCast(texture_image.width)), 
        @as(c_int, @intCast(texture_image.height)), 
        0, 
        format, 
        gl.UNSIGNED_BYTE, 
        @ptrCast(texture_image.data));
    gl.generateMipmap(gl.TEXTURE_2D);

    // set the texture1 wrapping parameters
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT); // set texture wrapping to GL_REPEAT (default wrapping method)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
    // set textureID filtering parameters
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
}

/// loads a cubemap texture from 6 individual texture faces
/// order:
/// +X (right)
/// -X (left)
/// +Y (top)
/// -Y (bottom)
/// +Z (front) 
/// -Z (back)
fn loadCubemap(faces: []const [:0]const u8, textureID: *c_uint) !void {
    // var textureID: gl.Uint = undefined;
    gl.genTextures(1, textureID);
    gl.bindTexture(gl.TEXTURE_CUBE_MAP, textureID.*);

    for (faces, 0..) |face, i| {
        var texture_image = try zstbi.Image.loadFromFile(face, 0);
        defer texture_image.deinit();

        const format: gl.Enum = switch (texture_image.num_components) {
            1 => gl.RED,
            3 => gl.RGB,
            4 => gl.RGBA,
            else => unreachable,
        };

        // Generate the textureID
        gl.texImage2D(
            gl.TEXTURE_CUBE_MAP_POSITIVE_X + @as(c_uint, @intCast(i)), 
            0, 
            format, 
            @as(c_int, @intCast(texture_image.width)), 
            @as(c_int, @intCast(texture_image.height)), 
            0, 
            format, 
            gl.UNSIGNED_BYTE, 
            @ptrCast(texture_image.data));
        gl.generateMipmap(gl.TEXTURE_2D);

    }

    // std.debug.print("{s} is {}\n", .{path, format});

    // set the texture1 wrapping parameters

    gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE);
}