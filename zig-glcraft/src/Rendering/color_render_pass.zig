const std = @import("std");
const gl = @import("gl");
const ShaderProgram = @import("shader_program.zig").ShaderProgram;
const Texture = @import("texture.zig").Texture;

pub const ColorRenderPass = struct {
    shader: *ShaderProgram,

    pub fn init(shader: *ShaderProgram) !ColorRenderPass {
        return .{
            .shader = shader,
        };
    }

    pub fn setTexture(self: *ColorRenderPass, attachmentName: [:0]const u8, texture: *Texture, slot: i32) void {
        self.shader.setTexture(attachmentName, texture, slot);
    }

    pub fn render(self: *ColorRenderPass) void {
        self.shader.bind();
        gl.disable(gl.DEPTH_TEST);
        // TODO: With fullscreen quad, get vertex array and render indexed
        // FullscreenQuad.getVertexArray().renderIndexed();
        gl.enable(gl.DEPTH_TEST);
    }

    pub fn renderTextureWithEffect(texture: *Texture, effect: *ShaderProgram) void {
        const render_pass = try ColorRenderPass.init(effect);
        render_pass.setTexture("color_Texture", texture, 0);

        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT);
        render_pass.render();
    }

    pub fn renderTexture(texture: *Texture) void {
        // TODO: use AssetManager to get the color identity shader
        const colorIdentity: *ShaderProgram = undefined;
        renderTextureWithEffect(texture, colorIdentity);
    }
};