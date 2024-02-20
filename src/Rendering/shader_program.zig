const std = @import("std");
const gl = @import("gl");
const glm = @import("ziglm");
const Allocator = std.mem.Allocator;
const Texture = @import("texture.zig").Texture;
const Shader = @import("shader.zig").Shader;

const Mat4x4 = glm.Mat4x4;

pub const ShaderProgram = struct {
    const Self = @This();

    shader_program: u32,

    pub fn init(vertexShader: *Shader, fragmentShader: *Shader) !Self {
        var self: Self = undefined;
        self.shader_program = gl.createProgram();

        gl.attachShader(self, fragmentShader.id);
        gl.attachShader(self, vertexShader.id);

        gl.linkProgram(self);

        var success: i32 = undefined;
        gl.getProgramiv(self, gl.LINK_STATUS, &success);

        if (success < 1) {
            return error.ShaderProgramCompilationFailed;
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        gl.deleteProgram(self.shader_program);
    }

    pub fn getUniformLocation(self: *Self, location: [:0] const u8) i32 {
        return gl.getUniformLocation(self.shader_program, location);
    }

    pub fn bind(self: *Self) void {
        gl.useProgram(self.shader_program);
    }

    pub fn setMat4(self: *Self, location: [:0] const u8, value: *Mat4x4(f32)) void {
        gl.useProgram(self.shader_program);
        gl.uniformMatrix4fv(self.shader_program, self.getUniformLocation(location), 1, gl.FALSE, value.cols);
    }

    pub fn setTexture(self: *Self, location: [:0] const u8, texture: *Texture, slot: i32) void {
        texture.bindToSlot(slot);
        gl.programUniform1i(self.shader_program, self.getUniformLocation(location), slot);
    }
};