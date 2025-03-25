const std = @import("std");
const Allocator = std.mem.Allocator;
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const zm = @import("zmath");
const Window = @import("../engine/window.zig");
const Skybox = @import("skybox.zig");
const zstbi = @import("zstbi");

const Renderer = @This();

window: *glfw.Window,
skybox: Skybox,

pub fn init(allocator: Allocator, window: *Window) !Renderer {

    // configure global opengl flags
    // -----------------------------
    gl.enable(gl.DEPTH_TEST);
    gl.enable(gl.CULL_FACE);
	gl.enable(gl.TEXTURE_CUBE_MAP_SEAMLESS);
    gl.cullFace(gl.BACK);
	gl.frontFace(gl.CCW);

    zstbi.init(allocator);

    return .{
        .window = window.window,
        .skybox = try Skybox.init(allocator),
    };
}

pub fn deinit(self: *Renderer) void {
    self.skybox.deinit();
    zstbi.deinit();
}

pub fn beginFrame(_: *Renderer) void {
    gl.clearColor(0.1, 0.1, 0.1, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
}

pub fn endFrame(self: *Renderer) void {
    _ = &self;
}

pub fn renderSkybox(self: *Renderer) void {
    self.skybox.shader.use();
    gl.depthFunc(gl.LEQUAL);
    gl.cullFace(gl.FRONT);

    // Hard code position to start
    const position = zm.loadArr3(.{0.0, 0.0, 0.0});
    const front = zm.loadArr3(.{0.0, 0.0, -1.0});
    const world_up = zm.loadArr3(.{0.0, 1.0, 0.0});
    const right = zm.normalize3(zm.cross3(front, world_up));
    const up = zm.normalize3(zm.cross3(right, front));
    const view = zm.lookAtRh(position, position + front, up);

    const window_size = self.window.getSize();
    const aspect_ratio: f32 = @as(f32, @floatFromInt(window_size[0])) / @as(f32, @floatFromInt(window_size[1]));
    const projection = zm.perspectiveFovRhGl(std.math.degreesToRadians(45.0), aspect_ratio, 0.1, 100.0);
    
    self.skybox.shader.setMat4f("view", zm.matToArr(zm.loadMat34(&zm.matToArr(view))));
    self.skybox.shader.setMat4f("projection", zm.matToArr(projection));
    
    self.skybox.vao.bind();
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_CUBE_MAP, self.skybox.texture.id);
    gl.drawArrays(gl.TRIANGLES, 0, 36);
    self.skybox.vao.unbind();
    
    gl.depthFunc(gl.LESS);
    gl.cullFace(gl.BACK);
}