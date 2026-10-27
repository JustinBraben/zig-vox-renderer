//! Draws the CPU-built triangles of sprites.zig: dropped items, the crack on a block
//! being broken, and the HUD. One host-visible vertex buffer per frame in flight,
//! refilled every frame. Shares the voxel pipeline's descriptor sets for the scene's
//! view_proj and the block textures.

const std = @import("std");

const VulkanContext = @import("vulkan_context.zig");
const vk = VulkanContext.vk;
const VkMemory = @import("dvui_vulkan_renderer").VkMemory;
const VoxelPipeline = @import("voxel_pipeline.zig");
const Pipeline = @import("pipeline.zig");
const Buffer = @import("buffer.zig");
const Assets = @import("../assets.zig");
const sprites = @import("sprites.zig");
const Vertex = sprites.Vertex;

const Self = @This();

/// vertices per frame
const capacity = 1 << 15;

/// See overlay.vert.
const PushConstants = extern struct {
    /// xy: 2 / window size in pixels, z: 1 = positions are pixels
    params: [4]f32,
};

pub const Pass = enum {
    /// in the world, depth tested and written (dropped items)
    world,
    /// on top of world surfaces, depth tested but not written (cracks)
    decal,
    /// window pixels over everything (the HUD)
    screen,
};

device: vk.DeviceProxy,
layout: vk.PipelineLayout,
pipelines: std.EnumArray(Pass, vk.Pipeline),
buffers: [VoxelPipeline.max_frames]Buffer = undefined,
frame_count: usize,

pub fn init(device: vk.DeviceProxy, memory: VkMemory, assets: *const Assets, voxel: *const VoxelPipeline, color_format: vk.Format, depth_format: vk.Format, frame_count: usize) !Self {
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

    const vertex_input: vk.PipelineVertexInputStateCreateInfo = .{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = &.{.{ .binding = 0, .stride = @sizeOf(Vertex), .input_rate = .vertex }},
        .vertex_attribute_description_count = 4,
        .p_vertex_attribute_descriptions = &.{
            .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(Vertex, "pos") },
            .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "uv") },
            .{ .location = 2, .binding = 0, .format = .r32_uint, .offset = @offsetOf(Vertex, "layer") },
            .{ .location = 3, .binding = 0, .format = .r8g8b8a8_unorm, .offset = @offsetOf(Vertex, "color") },
        },
    };

    var pipelines: std.EnumArray(Pass, vk.Pipeline) = undefined;
    var created: usize = 0;
    errdefer for (pipelines.values[0..created]) |pipeline| device.destroyPipeline(pipeline, null);
    for (std.enums.values(Pass)) |pass| {
        pipelines.set(pass, try Pipeline.create(device, assets, layout, color_format, depth_format, .{
            .vert = "overlay.vert",
            .frag = "overlay.frag",
            .topology = .triangle_list,
            // reverse-Z: hidden behind closer geometry
            .depth_compare = .greater_or_equal,
            .depth_test = pass != .screen,
            .depth_write = pass == .world,
            .blend = true,
            .vertex_input = &vertex_input,
        }));
        created += 1;
    }

    var self: Self = .{ .device = device, .layout = layout, .pipelines = pipelines, .frame_count = frame_count };
    var buffers: usize = 0;
    errdefer for (self.buffers[0..buffers]) |*buffer| buffer.deinit();
    for (self.buffers[0..frame_count]) |*buffer| {
        buffer.* = try Buffer.init(device, memory, capacity * @sizeOf(Vertex), .{ .vertex_buffer_bit = true }, .host_visible);
        buffers += 1;
    }
    return self;
}

pub fn deinit(self: *Self) void {
    for (self.buffers[0..self.frame_count]) |*buffer| buffer.deinit();
    for (self.pipelines.values) |pipeline| self.device.destroyPipeline(pipeline, null);
    self.device.destroyPipelineLayout(self.layout, null);
}

/// An empty batch over `frame`'s vertex buffer (whose previous use must have completed).
pub fn batch(self: *const Self, frame: usize) sprites.Batch {
    return .{ .vertices = self.buffers[frame].slice(Vertex) };
}

/// Draws `range` of `frame`'s batch. Viewport and scissor are expected to be set
/// already (`VoxelPipeline.bind` does that).
pub fn draw(self: *const Self, cmd: vk.CommandBuffer, voxel: *const VoxelPipeline, frame: usize, extent: vk.Extent2D, pass: Pass, range: sprites.Range) void {
    if (range.count == 0) return;
    const device = self.device;
    device.cmdBindPipeline(cmd, .graphics, self.pipelines.get(pass));
    device.cmdBindDescriptorSets(cmd, .graphics, self.layout, 0, &.{voxel.descriptor_sets[frame]}, &.{});
    device.cmdBindVertexBuffers(cmd, 0, &.{self.buffers[frame].handle}, &.{0});
    const w: f32 = @floatFromInt(@max(extent.width, 1));
    const h: f32 = @floatFromInt(@max(extent.height, 1));
    const push: PushConstants = .{ .params = .{ 2 / w, 2 / h, if (pass == .screen) 1 else 0, 0 } };
    device.cmdPushConstants(cmd, self.layout, .{ .vertex_bit = true }, 0, @sizeOf(PushConstants), &push);
    device.cmdDraw(cmd, range.count, 1, range.first, 0);
}
