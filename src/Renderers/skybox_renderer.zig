const std = @import("std");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const Shader = @import("../shader.zig");
const Utils = @import("../utils.zig");
const Camera = @import("../camera.zig");
const SkyboxMesh = @import("../Models/skybox_mesh.zig");
const SkyboxRenderer = @This();

skybox_cube: SkyboxMesh = .{},
shader: Shader = undefined,

pub fn render(self: *SkyboxRenderer, camera: *Camera) void {
    
}