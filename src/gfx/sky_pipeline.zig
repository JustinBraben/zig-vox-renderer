//! Skybox: a full-screen triangle at the far plane sampling the sky cubemap.
//! Shares the voxel pipeline's descriptor sets (binding 1 is the cubemap) and is
//! drawn after the terrain so only uncovered pixels are shaded.

const std = @import("std");

const VulkanContext = @import("vulkan_context.zig");
const vk = VulkanContext.vk;
const VoxelPipeline = @import("voxel_pipeline.zig");
const Camera = @import("../camera.zig");
const math = @import("../math.zig");
const Assets = @import("../assets.zig");

const Self = @This();

/// Camera basis scaled for reconstructing view rays; see sky.vert.
pub const PushConstants = extern struct {
    right: [4]f32,
    up: [4]f32,
    forward: [4]f32,
};

device: vk.DeviceProxy,
layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

pub fn init(device: vk.DeviceProxy, assets: *const Assets, voxel: *const VoxelPipeline, color_format: vk.Format, depth_format: vk.Format) !Self {
    const layout = try device.createPipelineLayout(&.{
        .set_layout_count = 1,
        .p_set_layouts = &.{voxel.set_layout},
        .push_constant_range_count = 1,
        .p_push_constant_ranges = &.{.{
            .stage_flags = .{ .vertex_bit = true },
            .offset = 0,
            .size = @sizeOf(PushConstants),
        }},
    }, null);
    errdefer device.destroyPipelineLayout(layout, null);

    const pipeline = try createPipeline(device, assets, layout, color_format, depth_format);
    return .{ .device = device, .layout = layout, .pipeline = pipeline };
}

pub fn deinit(self: *Self) void {
    self.device.destroyPipeline(self.pipeline, null);
    self.device.destroyPipelineLayout(self.layout, null);
}

/// Draws the sky behind everything already rendered. Viewport and scissor are
/// expected to be set already (`VoxelPipeline.bind` does that).
pub fn draw(self: *const Self, cmd: vk.CommandBuffer, voxel: *const VoxelPipeline, frame: usize, camera: *const Camera, fov_deg: f32, aspect: f32) void {
    const forward = camera.forward();
    const right = camera.right();
    const up = math.cross(right, forward);
    const tan_half = @tan(std.math.degreesToRadians(fov_deg) / 2);
    const push: PushConstants = .{
        .right = .{ right[0], right[1], right[2], tan_half * aspect },
        .up = .{ up[0], up[1], up[2], tan_half },
        .forward = .{ forward[0], forward[1], forward[2], 0 },
    };

    const device = self.device;
    device.cmdBindPipeline(cmd, .graphics, self.pipeline);
    device.cmdBindDescriptorSets(cmd, .graphics, self.layout, 0, &.{voxel.descriptor_sets[frame]}, &.{});
    device.cmdPushConstants(cmd, self.layout, .{ .vertex_bit = true }, 0, @sizeOf(PushConstants), &push);
    device.cmdDraw(cmd, 3, 1, 0, 0);
}

fn createPipeline(device: vk.DeviceProxy, assets: *const Assets, layout: vk.PipelineLayout, color_format: vk.Format, depth_format: vk.Format) !vk.Pipeline {
    const vertex_module = try VoxelPipeline.loadShaderModule(device, assets, "sky.vert");
    defer device.destroyShaderModule(vertex_module, null);
    const fragment_module = try VoxelPipeline.loadShaderModule(device, assets, "sky.frag");
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
        // the triangle comes from gl_VertexIndex
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
            .depth_test_enable = .true,
            .depth_write_enable = .false,
            // reverse-Z: only passes where the depth is still at the cleared 0
            .depth_compare_op = .greater_or_equal,
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
    return pipeline;
}
