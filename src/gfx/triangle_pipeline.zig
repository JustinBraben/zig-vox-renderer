//! Hardcoded-vertex triangle pipeline (dynamic rendering, no vertex buffers).

const std = @import("std");

const VulkanContext = @import("vulkan_context.zig");
const vk = VulkanContext.vk;

const Self = @This();

const vert_spv align(@alignOf(u32)) = @embedFile("triangle_vert").*;
const frag_spv align(@alignOf(u32)) = @embedFile("triangle_frag").*;

pub const PushConstants = extern struct {
    tint: [4]f32,
};

device: vk.DeviceProxy,
layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

pub fn init(device: vk.DeviceProxy, color_format: vk.Format) !Self {
    const vertex_module = try createShaderModule(device, &vert_spv);
    defer device.destroyShaderModule(vertex_module, null);
    const fragment_module = try createShaderModule(device, &frag_spv);
    defer device.destroyShaderModule(fragment_module, null);

    const layout = try device.createPipelineLayout(&.{
        .push_constant_range_count = 1,
        .p_push_constant_ranges = &.{.{
            .stage_flags = .{ .vertex_bit = true },
            .offset = 0,
            .size = @sizeOf(PushConstants),
        }},
    }, null);
    errdefer device.destroyPipelineLayout(layout, null);

    const rendering_info = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = &.{color_format},
        .depth_attachment_format = .undefined,
        .stencil_attachment_format = .undefined,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try device.createGraphicsPipelines(.null_handle, &.{.{
        .p_next = &rendering_info,
        .stage_count = 2,
        .p_stages = &.{
            .{ .stage = .{ .vertex_bit = true }, .module = vertex_module, .p_name = "main" },
            .{ .stage = .{ .fragment_bit = true }, .module = fragment_module, .p_name = "main" },
        },
        .p_vertex_input_state = &.{},
        .p_input_assembly_state = &.{
            .topology = .triangle_list,
            .primitive_restart_enable = .false,
        },
        .p_viewport_state = &.{
            .viewport_count = 1,
            .scissor_count = 1,
        },
        .p_rasterization_state = &.{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = .{},
            .front_face = .clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        },
        .p_multisample_state = &.{
            .sample_shading_enable = .false,
            .rasterization_samples = .{ .@"1_bit" = true },
            .min_sample_shading = 1,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        },
        .p_color_blend_state = &.{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = &.{.{
                .blend_enable = .false,
                .src_color_blend_factor = .one,
                .dst_color_blend_factor = .zero,
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .zero,
                .alpha_blend_op = .add,
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            }},
            .blend_constants = .{ 0, 0, 0, 0 },
        },
        .p_dynamic_state = &.{
            .dynamic_state_count = 2,
            .p_dynamic_states = &.{ .viewport, .scissor },
        },
        .layout = layout,
        .render_pass = .null_handle,
        .subpass = 0,
        .base_pipeline_index = -1,
    }}, null, @ptrCast(&pipeline));

    return .{ .device = device, .layout = layout, .pipeline = pipeline };
}

pub fn deinit(self: *Self) void {
    self.device.destroyPipeline(self.pipeline, null);
    self.device.destroyPipelineLayout(self.layout, null);
}

/// Records the triangle draw. Expects to be inside a rendering scope.
pub fn draw(self: *const Self, cmd: vk.CommandBuffer, extent: vk.Extent2D, push: PushConstants) void {
    const device = self.device;
    device.cmdBindPipeline(cmd, .graphics, self.pipeline);
    device.cmdSetViewport(cmd, 0, &.{.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0,
        .max_depth = 1,
    }});
    device.cmdSetScissor(cmd, 0, &.{.{ .offset = .{ .x = 0, .y = 0 }, .extent = extent }});
    device.cmdPushConstants(cmd, self.layout, .{ .vertex_bit = true }, 0, @sizeOf(PushConstants), &push);
    device.cmdDraw(cmd, 3, 1, 0, 0);
}

fn createShaderModule(device: vk.DeviceProxy, spv: []align(@alignOf(u32)) const u8) !vk.ShaderModule {
    return device.createShaderModule(&.{
        .code_size = spv.len,
        .p_code = @ptrCast(spv.ptr),
    }, null);
}
