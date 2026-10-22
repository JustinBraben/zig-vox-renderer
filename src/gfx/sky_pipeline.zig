//! Skybox: a full-screen triangle at the far plane sampling the sky cubemap.
//! Shares the voxel pipeline's descriptor sets (binding 1 is the cubemap) and is
//! drawn after the terrain so only uncovered pixels are shaded.

const std = @import("std");

const VulkanContext = @import("vulkan_context.zig");
const vk = VulkanContext.vk;
const VoxelPipeline = @import("voxel_pipeline.zig");
const Pipeline = @import("pipeline.zig");
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

    const pipeline = try Pipeline.create(device, assets, layout, color_format, depth_format, .{
        .vert = "sky.vert",
        .frag = "sky.frag",
        .topology = .triangle_list,
        // reverse-Z: only passes where the depth is still at the cleared 0
        .depth_compare = .greater_or_equal,
    });
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
