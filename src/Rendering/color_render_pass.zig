const std = @import("std");
const ShaderProgram = @import("shader_program.zig").ShaderProgram;
const Texture = @import("texture.zig").Texture;

pub const ColorRenderPass = struct {
    shader: *ShaderProgram,

    pub fn init(shader: *ShaderProgram) !ColorRenderPass {
        return .{
            .shader = shader,
        };
    }

    pub fn setTexture(self: *ColorRenderPass, attachmentName: [:0]const u8, texture: *Texture) void {
        
    }
};