const std = @import("std");
const gl = @import("gl");
const Allocator = std.mem.Allocator;
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
};