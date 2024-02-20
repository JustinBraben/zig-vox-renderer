const std = @import("std");
const gl = @import("gl");
const Allocator = std.mem.Allocator;
const Texture = @import("texture.zig").Texture;
const Shader = @import("shader.zig").Shader;

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

    pub fn setMat4(self: *Self, location: [:0] const u8, value: ) void {
        gl.useProgram(self.shader_program);
        gl.uniformMatrix4fv(self.shader_program, _location: GLint, 1, gl.FALSE, value);
    }

    pub fn setTexture(self: *Self, location: [:0] const u8, texture: *Texture, slot: i32) void {
        texture.bindToSlot(slot);
        gl.programUniform1i(self.shader_program, _location: GLint, slot);
    }
};