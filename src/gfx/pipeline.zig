//! Overlay graphics pipelines into the main color + depth target: by default without
//! vertex buffers (geometry from gl_VertexIndex), depth tested, not depth written and
//! not blended.

const std = @import("std");

const VulkanContext = @import("vulkan_context.zig");
const vk = VulkanContext.vk;
const VoxelPipeline = @import("voxel_pipeline.zig");
const Assets = @import("../assets.zig");

pub const Options = struct {
    /// shader names in assets/shaders, without `.spv`
    vert: []const u8,
    frag: []const u8,
    topology: vk.PrimitiveTopology,
    depth_compare: vk.CompareOp,
    depth_test: bool = true,
    depth_write: bool = false,
    /// alpha blending
    blend: bool = false,
    vertex_input: *const vk.PipelineVertexInputStateCreateInfo = &.{},
};

pub fn create(device: vk.DeviceProxy, assets: *const Assets, layout: vk.PipelineLayout, color_format: vk.Format, depth_format: vk.Format, options: Options) !vk.Pipeline {
    const vertex_module = try VoxelPipeline.loadShaderModule(device, assets, options.vert);
    defer device.destroyShaderModule(vertex_module, null);
    const fragment_module = try VoxelPipeline.loadShaderModule(device, assets, options.frag);
    defer device.destroyShaderModule(fragment_module, null);

    const rendering_info = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = &.{color_format},
        .depth_attachment_format = depth_format,
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
        .p_vertex_input_state = options.vertex_input,
        .p_input_assembly_state = &.{
            .topology = options.topology,
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
            .front_face = .counter_clockwise,
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
        .p_depth_stencil_state = &.{
            .depth_test_enable = if (options.depth_test) .true else .false,
            .depth_write_enable = if (options.depth_write) .true else .false,
            .depth_compare_op = options.depth_compare,
            .depth_bounds_test_enable = .false,
            .stencil_test_enable = .false,
            .front = std.mem.zeroes(vk.StencilOpState),
            .back = std.mem.zeroes(vk.StencilOpState),
            .min_depth_bounds = 0,
            .max_depth_bounds = 1,
        },
        .p_color_blend_state = &.{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = &.{.{
                .blend_enable = if (options.blend) .true else .false,
                .src_color_blend_factor = .src_alpha,
                .dst_color_blend_factor = .one_minus_src_alpha,
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
    return pipeline;
}
