const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const zm = @import("zmath");
const Shader = @import("shader.zig");
const SkyboxMesh = @import("../models/skybox_mesh.zig");
const Utils = @import("../utils.zig");
const Camera = @import("../camera.zig");
const World = @import("../world/world.zig");
const ChunkManager = @import("../world/chunk_manager.zig");

const Renderer = @This();

allocator: Allocator,
basic_voxel_mesh_shader: Shader,
skybox_shader: Shader,
skybox_texture: u32,
skybox_mesh: SkyboxMesh,

pub fn init(allocator: Allocator) !Renderer {
    var skybox_mesh = SkyboxMesh.init(allocator, "assets/shaders/skybox_vert.glsl", "assets/shaders/skybox_frag.glsl");
    skybox_mesh.bindVAO();
    try skybox_mesh.addVBO(3, skybox_mesh.vertex_positions);
    skybox_mesh.unbindVAO();
    
    const skybox = &.{
        "assets/textures/skybox/right.jpg",
        "assets/textures/skybox/left.jpg",
        "assets/textures/skybox/top.jpg",
        "assets/textures/skybox/bottom.jpg",
        "assets/textures/skybox/front.jpg",
        "assets/textures/skybox/back.jpg",
    };
    const skybox_texture = try Utils.loadCubemap(skybox);
    
    return .{
        .allocator = allocator,
        .basic_voxel_mesh_shader = Shader.create(allocator, "assets/shaders/basic_voxel_mesh_vert.glsl", "assets/shaders/basic_voxel_mesh_frag.glsl"),
        .skybox_shader = skybox_mesh.shader,
        .skybox_texture = skybox_texture,
        .skybox_mesh = skybox_mesh,
    };
}

pub fn deinit(self: *Renderer) void {
    self.skybox_mesh.deinit();
}

pub fn setWireframe(_: *Renderer, wireframe_on: bool) void {
    if (wireframe_on) {
        gl.polygonMode(gl.FRONT_AND_BACK, gl.LINE);
    } else {
        gl.polygonMode(gl.FRONT_AND_BACK, gl.FILL);
    }
}

pub fn renderWorld(self: *Renderer, world: *World, chunk_manager: *ChunkManager, window_size: [2]c_int, camera: *Camera) void {
    const aspect_ratio: f32 = @as(f32, @floatFromInt(window_size[0])) / @as(f32, @floatFromInt(window_size[1]));
    const projection_matrix = zm.perspectiveFovRhGl(math.degreesToRadians(camera.zoom), aspect_ratio, 0.1, 1000.0);
    var projection: [16]f32 = undefined;
    zm.storeMat(&projection, projection_matrix);
    
    var view: [16]f32 = undefined;
    zm.storeMat(&view, camera.getViewMatrix());
    
    // Render chunks
    self.basic_voxel_mesh_shader.use();
    self.basic_voxel_mesh_shader.setMat4f("u_view", view);
    self.basic_voxel_mesh_shader.setMat4f("u_projection", projection);
    self.basic_voxel_mesh_shader.setVec3f("u_viewPos", camera.getViewPos());
    self.basic_voxel_mesh_shader.setInt("u_texture", 0);
    
    gl.activeTexture(gl.TEXTURE0);
    chunk_manager.texture_atlas.texture.bind();

    var it = world.chunks.valueIterator();
    while (it.next()) |chunk| {
        if (chunk.*.*.mesh) |*mesh| {
            const chunk_offset = chunk.*.*.pos.worldOffset();
            const chunk_model = zm.translation(
                chunk_offset[0],
                0.0,
                chunk_offset[2]
            );
            
            self.basic_voxel_mesh_shader.setMat4f("u_model", zm.matToArr(chunk_model));
            mesh.draw();
        }
    }
    
    // Render skybox
    self.renderSkybox(view, projection);
}

fn renderSkybox(self: *Renderer, view: [16]f32, projection: [16]f32) void {
    self.skybox_shader.use();
    gl.depthFunc(gl.LEQUAL);
    gl.cullFace(gl.FRONT);
    
    self.skybox_shader.setMat4f("view", zm.matToArr(zm.loadMat34(&view)));
    self.skybox_shader.setMat4f("projection", projection);
    
    self.skybox_mesh.bindVAO();
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_CUBE_MAP, self.skybox_texture);
    gl.drawArrays(gl.TRIANGLES, 0, 36);
    self.skybox_mesh.unbindVAO();
    
    gl.depthFunc(gl.LESS);
    gl.cullFace(gl.BACK);
}