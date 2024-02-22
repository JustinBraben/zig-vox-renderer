const std = @import("std");
const gl = @import("gl");
const Allocator = std.mem.Allocator;

pub const Shader = struct {
    const Self = @This();

    id: u32,

    pub fn init(source: [:0]const u8, typeOf: u32) !Self {
        var self: Self = undefined;
        self.id = gl.createShader(typeOf);

        // TODO: get shader source and compiler shader
        gl.shaderSource(self.id, 1, source, null);
        gl.compileShader(self.id);

        var success: i32 = undefined;
        gl.getShaderiv(self.id, gl.COMPILE_STATUS, &success);

        if (success != 0) {
            // TODO: Get gl shader error log
            return error.ShaderCompilationFailed;
        }

        return self;
    }
};