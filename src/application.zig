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
const Shader = @import("shader.zig");
const Utils = @import("utils.zig");
const VAO = @import("vao.zig");
const VBO = @import("vbo.zig");
const CubeMesh = @import("Models/cube_mesh.zig");
const SkyboxMesh = @import("Models/skybox_mesh.zig");
const Mesh = @import("Models/mesh.zig");
const World = @import("World/world.zig");
const Chunk = @import("World/chunk.zig");

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
    glfw.windowHintTyped(.context_version_major, config.gl_major);
    glfw.windowHintTyped(.context_version_minor, config.gl_minor);
    glfw.windowHintTyped(.opengl_profile, .opengl_core_profile);
    glfw.windowHintTyped(.opengl_forward_compat, true);
    glfw.windowHintTyped(.client_api, .opengl_api);
    glfw.windowHintTyped(.doublebuffer, true);

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
    self.turnOffMouse();

    // const height_range = 10.0;
    // var world = try World.init(self.allocator, height_range);
    // try world.generate();
    // defer world.deinit();

    // set up vertex data (and buffer(s)) and configure vertex attributes
    // ------------------------------------------------------------------
    // Pass it the vertex shader and fragment shader
    // var cube_mesh = CubeMesh.init(self.allocator, "assets/shaders/voxel_instance_vert.glsl", "assets/shaders/voxel_instance_frag.glsl");
    // defer cube_mesh.deinit();

    // cube_mesh.bindVAO();
    // try cube_mesh.addVBO(3, cube_mesh.vertex_positions);
    // try cube_mesh.addVBO(3, cube_mesh.normal_positions);
    // try cube_mesh.addVBO(2, cube_mesh.texture_coords);
    // try cube_mesh.addInstanceVBO(4, world.flattened_matrices);
    // cube_mesh.unbindVAO();

    var basic_chunk = try Chunk.init(self.allocator, .{ .x = 0, .z = -1 });
    defer basic_chunk.deinit();
    basic_chunk.setBlock(1, 1, 1, .{ .id = 1 });
    basic_chunk.setBlock(5, 5, 5, .{ .id = 1 });
    basic_chunk.setBlock(6, 6, 6, .{ .id = 1 });
    try basic_chunk.generateMesh();

    var basic_voxel_mesh = Mesh.init();
    defer basic_voxel_mesh.deinit();
    basic_voxel_mesh.setBasicVoxel();
    var basic_voxel_mesh_shader = Shader.create(self.allocator, "assets/shaders/basic_voxel_mesh_vert.glsl", "assets/shaders/basic_voxel_mesh_frag.glsl");


    var skybox_mesh = SkyboxMesh.init(self.allocator, "assets/shaders/skybox_vert.glsl", "assets/shaders/skybox_frag.glsl");
    defer skybox_mesh.deinit();
    skybox_mesh.bindVAO();
    try skybox_mesh.addVBO(3, skybox_mesh.vertex_positions);
    skybox_mesh.unbindVAO();

    // const dirt = &.{
    //     "assets/textures/dirt/right.jpg",
    //     "assets/textures/dirt/left.jpg",
    //     "assets/textures/dirt/top.jpg",
    //     "assets/textures/dirt/bottom.jpg",
    //     "assets/textures/dirt/front.jpg",
    //     "assets/textures/dirt/back.jpg",
    // };
    const skybox = &.{
        "assets/textures/skybox/right.jpg",
        "assets/textures/skybox/left.jpg",
        "assets/textures/skybox/top.jpg",
        "assets/textures/skybox/bottom.jpg",
        "assets/textures/skybox/front.jpg",
        "assets/textures/skybox/back.jpg",
    };

    // Load all textures for dirt blocks
    const dirt_texture: DirtTextures = try .{
        .right = try Utils.loadTexture("assets/textures/dirt/right.jpg"),
        .left = try Utils.loadTexture("assets/textures/dirt/left.jpg"),
        .top = try Utils.loadTexture("assets/textures/dirt/top.jpg"),
        .bottom = try Utils.loadTexture("assets/textures/dirt/bottom.jpg"),
        .front = try Utils.loadTexture("assets/textures/dirt/front.jpg"),
        .back = try Utils.loadTexture("assets/textures/dirt/back.jpg"),
    };

    const skybox_cube_map_texture = try Utils.loadCubemap(skybox);

    var wireframe: bool = false;
    var light_direction: [3]f32 = .{ 0.0, -1.0, -1.0 };
    var shininess: f32 = 32.0;

    // // shader configuration
    // // --------------------
    basic_voxel_mesh_shader.use();
    basic_voxel_mesh_shader.setInt("u_texture", 0);

    skybox_mesh.shader.use();
    skybox_mesh.shader.setInt("skybox", 0);

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

        const tz_handle_events = ztracy.ZoneN(@src(), "Application.handleEvents(delta_time)");
        self.handleEvents(delta_time);
        tz_handle_events.End();

        // render
        // ------
        gl.clearColor(0.1, 0.1, 0.1, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        // // draw scene as normal
        // cube_mesh.shader.use();
        // cube_mesh.shader.setVec3f("light.direction",  light_direction);
        // cube_mesh.shader.setFloat("material.shininess", shininess);
        // const tz_viewPos = ztracy.ZoneN(@src(), "cube_mesh.shader.setVec3f(\"viewPos\", camera.getViewPos())");
        // cube_mesh.shader.setVec3f("viewPos", camera.getViewPos());
        // tz_viewPos.End();
        basic_voxel_mesh_shader.use();
        basic_voxel_mesh_shader.setMat4f("u_model", zm.matToArr(zm.identity()));
        basic_voxel_mesh_shader.setVec3f("u_viewPos", camera.getViewPos());

        // TODO: Only change this when view changes 
        // which is whenever the camera moves
        var viewM = camera.getViewMatrix();
        zm.storeMat(&view, viewM);
        // cube_mesh.shader.setMat4f("view", view);
        basic_voxel_mesh_shader.setMat4f("u_view", view);

        // TODO: This projection could just be calculated up front 
        // and only recalculated when 
        // window size changes, camera zoom changes, near/far changes etc
        const window_size = self.window.getSize();
        const aspect_ratio: f32 = @as(f32, @floatFromInt(window_size[0])) / @as(f32, @floatFromInt(window_size[1]));
        const projectionM = zm.perspectiveFovRhGl(Utils.radians(camera.zoom), aspect_ratio, 0.1, 1000.0);
        zm.storeMat(&projection, projectionM);
        // cube_mesh.shader.setMat4f("projection",  projection);
        basic_voxel_mesh_shader.setMat4f("u_projection", projection);

        if (wireframe) {
            gl.polygonMode(gl.FRONT_AND_BACK, gl.LINE);
        } else {
            gl.polygonMode(gl.FRONT_AND_BACK, gl.FILL);
        }

        // // cubes
        // cube_mesh.bindVAO();
        // gl.activeTexture(gl.TEXTURE0);
        // gl.bindTexture(gl.TEXTURE_CUBE_MAP, dirt_cube_map_texture);
        // gl.drawArraysInstanced(gl.TRIANGLES, 0, 36, @intCast(world.model_matrices.items.len));
        // cube_mesh.unbindVAO();
        basic_voxel_mesh.vao.bind();
        gl.activeTexture(gl.TEXTURE0);
        // Back face (vertices 0-5)
        gl.bindTexture(gl.TEXTURE_2D, dirt_texture.back);
        gl.drawArrays(gl.TRIANGLES, 0, 6);

        // Front face (vertices 6-11)
        gl.bindTexture(gl.TEXTURE_2D, dirt_texture.front);
        gl.drawArrays(gl.TRIANGLES, 6, 6);

        // Left face (vertices 12-17)
        gl.bindTexture(gl.TEXTURE_2D, dirt_texture.left);
        gl.drawArrays(gl.TRIANGLES, 12, 6);

        // Right face (vertices 18-23)
        gl.bindTexture(gl.TEXTURE_2D, dirt_texture.right);
        gl.drawArrays(gl.TRIANGLES, 18, 6);

        // Bottom face (vertices 24-29)
        gl.bindTexture(gl.TEXTURE_2D, dirt_texture.bottom);
        gl.drawArrays(gl.TRIANGLES, 24, 6);

        // Top face (vertices 30-35)
        gl.bindTexture(gl.TEXTURE_2D, dirt_texture.top);
        gl.drawArrays(gl.TRIANGLES, 30, 6);
        // basic_voxel_mesh.draw();
        basic_voxel_mesh.vao.unbind();

        // Render one chunk
        if (basic_chunk.mesh) |*mesh| {
            // Calculate the chunk's world position model matrix
            const chunk_offset = basic_chunk.pos.worldOffset();
            // const chunk_model = zm.mul(
            //     zm.scaling(16, 1.0, 16), 
            //     zm.translation(
            //         chunk_offset[0],
            //         0.0,
            //         chunk_offset[2])
            // );

            const chunk_model = zm.translation(
                chunk_offset[0],
                0.0,
                chunk_offset[2]
            );
            
            // Set the model matrix for the chunk
            basic_voxel_mesh_shader.setMat4f("u_model", zm.matToArr(chunk_model));

            mesh.vao.bind();
            gl.activeTexture(gl.TEXTURE0);
            
            // Back face (vertices 0-5)
            gl.bindTexture(gl.TEXTURE_2D, dirt_texture.back);
            gl.drawArrays(gl.TRIANGLES, 0, 6);

            // Front face (vertices 6-11)
            gl.bindTexture(gl.TEXTURE_2D, dirt_texture.front);
            gl.drawArrays(gl.TRIANGLES, 6, 6);

            // Left face (vertices 12-17)
            gl.bindTexture(gl.TEXTURE_2D, dirt_texture.left);
            gl.drawArrays(gl.TRIANGLES, 12, 6);

            // Right face (vertices 18-23)
            gl.bindTexture(gl.TEXTURE_2D, dirt_texture.right);
            gl.drawArrays(gl.TRIANGLES, 18, 6);

            // Bottom face (vertices 24-29)
            gl.bindTexture(gl.TEXTURE_2D, dirt_texture.bottom);
            gl.drawArrays(gl.TRIANGLES, 24, 6);

            // Top face (vertices 30-35)
            gl.bindTexture(gl.TEXTURE_2D, dirt_texture.top);
            gl.drawArrays(gl.TRIANGLES, 30, 6);

            // Back face (vertices 0-5)
            gl.bindTexture(gl.TEXTURE_2D, dirt_texture.back);
            gl.drawArrays(gl.TRIANGLES, 36, 6);

            // Front face (vertices 6-11)
            gl.bindTexture(gl.TEXTURE_2D, dirt_texture.front);
            gl.drawArrays(gl.TRIANGLES, 42, 6);

            // Left face (vertices 12-17)
            gl.bindTexture(gl.TEXTURE_2D, dirt_texture.left);
            gl.drawArrays(gl.TRIANGLES, 48, 6);

            // Right face (vertices 18-23)
            gl.bindTexture(gl.TEXTURE_2D, dirt_texture.right);
            gl.drawArrays(gl.TRIANGLES, 54, 6);

            // Bottom face (vertices 24-29)
            gl.bindTexture(gl.TEXTURE_2D, dirt_texture.bottom);
            gl.drawArrays(gl.TRIANGLES, 60, 6);

            // Top face (vertices 30-35)
            gl.bindTexture(gl.TEXTURE_2D, dirt_texture.top);
            gl.drawArrays(gl.TRIANGLES, 66, 6);

            // mesh.draw();
            mesh.vao.unbind();
        }

        // draw skybox as last
        skybox_mesh.shader.use();
        gl.depthFunc(gl.LEQUAL);  // change depth function so depth test passes when values are equal to depth buffer's content
        gl.cullFace(gl.FRONT);
        viewM = zm.loadMat34(&view);
        zm.storeMat(&view, viewM);
        skybox_mesh.shader.setMat4f("view", view);
        skybox_mesh.shader.setMat4f("projection", projection);

        // skybox cube
        skybox_mesh.bindVAO();
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_CUBE_MAP, skybox_cube_map_texture);
        gl.drawArrays(gl.TRIANGLES, 0, 36);
        skybox_mesh.unbindVAO();
        gl.depthFunc(gl.LESS); // set depth function back to default
        gl.cullFace(gl.BACK);  // set cull function back to default

        const fb_size = self.window.getFramebufferSize();
        zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));
        zgui.setNextWindowPos(.{ .x = 0.0, .y = 0.0, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 0.0, .h = 0.0, .cond = .first_use_ever });
        if (zgui.begin("Debug Window", .{})) {
            _ = zgui.checkbox("wireframe", .{ .v = &wireframe });
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

fn handleEvents(self: *Application, deltaTime: f32) void {
    if (self.window.getKey(.escape) == .press) {
        self.window.setShouldClose(true);
    }

    if (self.window.getKey(.c) == .press) {
        toggle_cursor = !toggle_cursor;
        if (toggle_cursor) {
            self.window.setInputMode(.cursor, glfw.Cursor.Mode.normal);
            return;
        } else {
            self.window.setInputMode(.cursor, glfw.Cursor.Mode.disabled);
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

fn turnOffMouse(self: *Application) void {
    self.window.setInputMode(.cursor, glfw.Cursor.Mode.disabled);
}

fn turnOnMouse(self: *Application) void {
    self.window.setInputMode(.cursor, glfw.Cursor.Mode.normal);
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