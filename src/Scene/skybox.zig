const std = @import("std");
const Allocator = std.mem.Allocator;
const glm = @import("ziglm");

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

    pub fn update(self: *Self, deltaTime: f32) void {
        self.rotation += self.rotation_speed * deltaTime;
        self.transform = Mat4x4(f32).rotate_y(self.rotation);
    }
};