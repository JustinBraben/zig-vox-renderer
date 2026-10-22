//! Line overlays: the outline of the targeted block and the crosshair. Shares the
//! voxel pipeline's descriptor sets for the scene's view_proj.

const std = @import("std");

const VulkanContext = @import("vulkan_context.zig");
const vk = VulkanContext.vk;
const VoxelPipeline = @import("voxel_pipeline.zig");
const Pipeline = @import("pipeline.zig");
const Assets = @import("../assets.zig");

const Self = @This();

/// See outline.vert.
const PushConstants = extern struct {
    /// xyz: block minimum corner relative to the camera, w: 0 = block outline, 1 = crosshair
    origin: [4]f32,
    /// xy: crosshair half-size in NDC
    params: [4]f32,
};

/// crosshair arm length in pixels
const crosshair_px = 9;

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

    const pipeline = try Pipeline.create(device, assets, layout, color_format, depth_format, .{
        .vert = "outline.vert",
        .frag = "outline.frag",
        .topology = .line_list,
        // reverse-Z: hidden behind closer geometry
        .depth_compare = .greater_or_equal,
    });
    return .{ .device = device, .layout = layout, .pipeline = pipeline };
}

pub fn deinit(self: *Self) void {
    self.device.destroyPipeline(self.pipeline, null);
    self.device.destroyPipelineLayout(self.layout, null);
}

/// Binds the pipeline and the frame's scene uniforms; call before the draws below.
/// Viewport and scissor are expected to be set already (`VoxelPipeline.bind` does that).
pub fn bind(self: *const Self, cmd: vk.CommandBuffer, voxel: *const VoxelPipeline, frame: usize) void {
    self.device.cmdBindPipeline(cmd, .graphics, self.pipeline);
    self.device.cmdBindDescriptorSets(cmd, .graphics, self.layout, 0, &.{voxel.descriptor_sets[frame]}, &.{});
}

/// Outlines the block whose minimum corner is at `origin` (relative to the camera).
pub fn drawBlock(self: *const Self, cmd: vk.CommandBuffer, origin: [3]f32) void {
    self.push(cmd, .{ .origin = .{ origin[0], origin[1], origin[2], 0 }, .params = .{ 0, 0, 0, 0 } });
    self.device.cmdDraw(cmd, 24, 1, 0, 0);
}

pub fn drawCrosshair(self: *const Self, cmd: vk.CommandBuffer, extent: vk.Extent2D) void {
    const w: f32 = @floatFromInt(@max(extent.width, 1));
    const h: f32 = @floatFromInt(@max(extent.height, 1));
    self.push(cmd, .{ .origin = .{ 0, 0, 0, 1 }, .params = .{ 2 * crosshair_px / w, 2 * crosshair_px / h, 0, 0 } });
    self.device.cmdDraw(cmd, 4, 1, 0, 0);
}

fn push(self: *const Self, cmd: vk.CommandBuffer, constants: PushConstants) void {
    self.device.cmdPushConstants(cmd, self.layout, .{ .vertex_bit = true }, 0, @sizeOf(PushConstants), &constants);
}
