const std = @import("std");
const math = std.math;
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const zstbi = @import("zstbi");
const zm = @import("zmath");
const gl = zopengl.bindings;
const Camera = @import("camera.zig");
const Shader = @import("shader.zig");
const Utils = @import("utils.zig");
const VAO = @import("vao.zig");
const VBO = @import("vbo.zig");

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

    // configure global opengl state
    // -----------------------------
    gl.enable(gl.DEPTH_TEST);

    // create shader program
    var shader: Shader = Shader.create(arena, "Shaders/cubemap_vert.glsl", "Shaders/cubemap_frag.glsl");
    var skybox_shader: Shader = Shader.create(arena, "Shaders/skybox_vert.glsl", "Shaders/skybox_frag.glsl");

    // const cubeVertices = [_]gl.Float{
    //     // positions       // texture Coords
    //     -0.5, -0.5, -0.5,  0.0, 0.0,
    //      0.5, -0.5, -0.5,  1.0, 0.0,
    //      0.5,  0.5, -0.5,  1.0, 1.0,
    //      0.5,  0.5, -0.5,  1.0, 1.0,
    //     -0.5,  0.5, -0.5,  0.0, 1.0,
    //     -0.5, -0.5, -0.5,  0.0, 0.0,

    //     -0.5, -0.5,  0.5,  0.0, 0.0,
    //      0.5, -0.5,  0.5,  1.0, 0.0,
    //      0.5,  0.5,  0.5,  1.0, 1.0,
    //      0.5,  0.5,  0.5,  1.0, 1.0,
    //     -0.5,  0.5,  0.5,  0.0, 1.0,
    //     -0.5, -0.5,  0.5,  0.0, 0.0,

    //     -0.5,  0.5,  0.5,  1.0, 0.0,
    //     -0.5,  0.5, -0.5,  1.0, 1.0,
    //     -0.5, -0.5, -0.5,  0.0, 1.0,
    //     -0.5, -0.5, -0.5,  0.0, 1.0,
    //     -0.5, -0.5,  0.5,  0.0, 0.0,
    //     -0.5,  0.5,  0.5,  1.0, 0.0,

    //      0.5,  0.5,  0.5,  1.0, 0.0,
    //      0.5,  0.5, -0.5,  1.0, 1.0,
    //      0.5, -0.5, -0.5,  0.0, 1.0,
    //      0.5, -0.5, -0.5,  0.0, 1.0,
    //      0.5, -0.5,  0.5,  0.0, 0.0,
    //      0.5,  0.5,  0.5,  1.0, 0.0,

    //     -0.5, -0.5, -0.5,  0.0, 1.0,
    //      0.5, -0.5, -0.5,  1.0, 1.0,
    //      0.5, -0.5,  0.5,  1.0, 0.0,
    //      0.5, -0.5,  0.5,  1.0, 0.0,
    //     -0.5, -0.5,  0.5,  0.0, 0.0,
    //     -0.5, -0.5, -0.5,  0.0, 1.0,

    //     -0.5,  0.5, -0.5,  0.0, 1.0,
    //      0.5,  0.5, -0.5,  1.0, 1.0,
    //      0.5,  0.5,  0.5,  1.0, 0.0,
    //      0.5,  0.5,  0.5,  1.0, 0.0,
    //     -0.5,  0.5,  0.5,  0.0, 0.0,
    //     -0.5,  0.5, -0.5,  0.0, 1.0
    // };

    const cubePositions = [_]gl.Float{
        // positions       // texture Coords
        -0.5, -0.5, -0.5,
         0.5, -0.5, -0.5,
         0.5,  0.5, -0.5,
         0.5,  0.5, -0.5,
        -0.5,  0.5, -0.5,
        -0.5, -0.5, -0.5,

        -0.5, -0.5,  0.5,
         0.5, -0.5,  0.5,
         0.5,  0.5,  0.5,
         0.5,  0.5,  0.5,
        -0.5,  0.5,  0.5,
        -0.5, -0.5,  0.5,

        -0.5,  0.5,  0.5,
        -0.5,  0.5, -0.5,
        -0.5, -0.5, -0.5,
        -0.5, -0.5, -0.5,
        -0.5, -0.5,  0.5,
        -0.5,  0.5,  0.5,

         0.5,  0.5,  0.5,
         0.5,  0.5, -0.5,
         0.5, -0.5, -0.5,
         0.5, -0.5, -0.5,
         0.5, -0.5,  0.5,
         0.5,  0.5,  0.5,

        -0.5, -0.5, -0.5,
         0.5, -0.5, -0.5,
         0.5, -0.5,  0.5,
         0.5, -0.5,  0.5,
        -0.5, -0.5,  0.5,
        -0.5, -0.5, -0.5,

        -0.5,  0.5, -0.5,
         0.5,  0.5, -0.5,
         0.5,  0.5,  0.5,
         0.5,  0.5,  0.5,
        -0.5,  0.5,  0.5,
        -0.5,  0.5, -0.5,
    };

    const cubeTextureCoords = [_]gl.Float{
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

    const skyboxVertices = [_]gl.Float{
        // positions          
        -1.0,  1.0, -1.0,
        -1.0, -1.0, -1.0,
         1.0, -1.0, -1.0,
         1.0, -1.0, -1.0,
         1.0,  1.0, -1.0,
        -1.0,  1.0, -1.0,

        -1.0, -1.0,  1.0,
        -1.0, -1.0, -1.0,
        -1.0,  1.0, -1.0,
        -1.0,  1.0, -1.0,
        -1.0,  1.0,  1.0,
        -1.0, -1.0,  1.0,

         1.0, -1.0, -1.0,
         1.0, -1.0,  1.0,
         1.0,  1.0,  1.0,
         1.0,  1.0,  1.0,
         1.0,  1.0, -1.0,
         1.0, -1.0, -1.0,

        -1.0, -1.0,  1.0,
        -1.0,  1.0,  1.0,
         1.0,  1.0,  1.0,
         1.0,  1.0,  1.0,
         1.0, -1.0,  1.0,
        -1.0, -1.0,  1.0,

        -1.0,  1.0, -1.0,
         1.0,  1.0, -1.0,
         1.0,  1.0,  1.0,
         1.0,  1.0,  1.0,
        -1.0,  1.0,  1.0,
        -1.0,  1.0, -1.0,

        -1.0, -1.0, -1.0,
        -1.0, -1.0,  1.0,
         1.0, -1.0, -1.0,
         1.0, -1.0, -1.0,
        -1.0, -1.0,  1.0,
         1.0, -1.0,  1.0
    };

    // cube VAO
    var cubeVAO = try VAO.init();
    defer cubeVAO.deinit();

    // Create two separate VBOs - one for positions, one for texture coordinates
    var positionVBO = try VBO.init();
    var texCoordVBO = try VBO.init();

    // Bind VAO
    cubeVAO.bind();
    positionVBO.bind(gl.ARRAY_BUFFER);
    positionVBO.bufferData(gl.ARRAY_BUFFER, &cubePositions, gl.STATIC_DRAW);
    cubeVAO.enableVertexAttribArray(0);
    cubeVAO.setVertexAttributePointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(gl.Float), null);

    // Buffer texture coordinate data
    texCoordVBO.bind(gl.ARRAY_BUFFER);
    texCoordVBO.bufferData(gl.ARRAY_BUFFER, &cubeTextureCoords, gl.STATIC_DRAW);
    cubeVAO.enableVertexAttribArray(1);
    cubeVAO.setVertexAttributePointer(1, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(gl.Float), null);
    cubeVAO.unbind();

    // skybox VAO
    var skyboxVAO = try VAO.init();
    defer skyboxVAO.deinit();
    var skyboxVBO = try VBO.init();
    defer skyboxVBO.deinit();

    skyboxVAO.bind();
    skyboxVBO.bind(gl.ARRAY_BUFFER);
    skyboxVBO.bufferData(gl.ARRAY_BUFFER, &skyboxVertices, gl.STATIC_DRAW);
    skyboxVAO.enableVertexAttribArray(0);
    skyboxVAO.setVertexAttributePointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(gl.Float), null);
    skyboxVAO.unbind();

    // zstbi: loading an image.
    zstbi.init(allocator);
    defer zstbi.deinit();

    // load textures (we now use a utility function to keep the code more organized)
    // -----------------------------------------------------------------------------
    const container_path = "Resources/Textures/container.jpg";
    const faces = &.{
        "Resources/Textures/Skybox/right.jpg",
        "Resources/Textures/Skybox/left.jpg",
        "Resources/Textures/Skybox/top.jpg",
        "Resources/Textures/Skybox/bottom.jpg",
        "Resources/Textures/Skybox/front.jpg",
        "Resources/Textures/Skybox/back.jpg",
    };
    var cube_texture: gl.Uint = undefined;
    var cube_map_texture: gl.Uint = undefined;
    try loadTexture(container_path, &cube_texture);
    try loadCubemap(faces, &cube_map_texture);

    // shader configuration
    // --------------------
    shader.use();
    shader.setInt("texture1", 0);

    skybox_shader.use();
    skybox_shader.setInt("skybox", 0);

    // Buffer to store Model matrix
    var model: [16]f32 = undefined;

    // View matrix
    var view: [16]f32 = undefined;

    // Buffer to store Ortho-projection matrix (in render loop)
    var projection: [16]f32 = undefined;

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
        shader.setMat4f("model", model);

        var viewM = camera.getViewMatrix();
        zm.storeMat(&view, viewM);
        shader.setMat4f("view", view);

        // view/projection transformations
        const window_size = self.window.getSize();
        const aspect_ratio: f32 = @as(f32, @floatFromInt(window_size[0])) / @as(f32, @floatFromInt(window_size[1]));
        const projectionM = zm.perspectiveFovRhGl(Utils.radians(camera.zoom), aspect_ratio, 0.1, 100.0);
        zm.storeMat(&projection, projectionM);
        shader.setMat4f("projection",  projection);

        // cubes
        cubeVAO.bind();
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, cube_texture);
        gl.drawArrays(gl.TRIANGLES, 0, 36);
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
        gl.bindTexture(gl.TEXTURE_CUBE_MAP, cube_map_texture);
        gl.drawArrays(gl.TRIANGLES, 0, 36);
        skyboxVAO.unbind();
        gl.depthFunc(gl.LESS); // set depth function back to default


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