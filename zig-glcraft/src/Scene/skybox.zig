const std = @import("std");
const gl = @import("gl");
const glm = @import("ziglm");
const ShaderProgram = @import("../Rendering//shader_program.zig").ShaderProgram;
const VertexArray = @import("../Rendering/vertex_array.zig");
const Allocator = std.mem.Allocator;

const Mat4x4 = glm.Mat4x4;

pub const Skybox = struct {
    const Self = @This();

    allocator: Allocator,
    transform: Mat4x4(f32),
    // vertexArray: VertexArray,
    // cube_map: *Texture,
    // shader: *ShaderProgram,

    rotation: f32 = 0,
    rotation_speed: f32 = 0.01,

    pub fn init(allocator: Allocator) !Self {
        const transform = Mat4x4(f32).as(1);
        return Self{
            .allocator = allocator,
            .transform = transform,
        };
    }

    pub fn update(self: *Self, projection: Mat4x4(f32), cameraView: Mat4x4(f32),  deltaTime: f32) void {
        _ = projection;
        _ = cameraView;
        self.rotation += self.rotation_speed * deltaTime;
        // self.transform = projection * glm.Mat4(glm.Mat3(cameraView));
    }

    pub fn render(self: *Self) void {
        _ = self;

        gl.depthFunc(gl.LEQUAL);
        gl.disable(gl.CULL_FACE);

        // TODO: bind shader
        // set texture
        // set mat4 transform of shader
        // bind vertex array

        gl.depthFunc(gl.LESS);
        gl.enable(gl.CULL_FACE);
    }
};