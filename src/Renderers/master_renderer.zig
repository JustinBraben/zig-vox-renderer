const std = @import("std");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const Camera = @import("../camera.zig");
const SkyboxRenderer = @import("skybox_renderer.zig");
const MasterRenderer = @This();

skybox_renderer: SkyboxRenderer,

pub fn finishRender(self: *MasterRenderer, window: *glfw.Window, camera: *Camera) void {
    gl.clearColor(0.1, 0.1, 0.1, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    gl.enable(gl.DEPTH_TEST);
    gl.enable(gl.CULL_FACE);
    
    // TODO: Render terrain/chunks based on camera

    // TODO: Render skybox based on camera

    window.swapBuffers();
}