//! Depth attachment matching the swapchain extent.

const std = @import("std");

const VulkanContext = @import("vulkan_context.zig");
const vk = VulkanContext.vk;
const VkMemory = @import("dvui_vulkan_renderer").VkMemory;

const Self = @This();

pub const format: vk.Format = .d32_sfloat;

pub const subresource_range: vk.ImageSubresourceRange = .{
    .aspect_mask = .{ .depth_bit = true },
    .base_mip_level = 0,
    .level_count = 1,
    .base_array_layer = 0,
    .layer_count = 1,
};

device: vk.DeviceProxy,
memory_types: VkMemory,
image: vk.Image = .null_handle,
memory: vk.DeviceMemory = .null_handle,
view: vk.ImageView = .null_handle,

pub fn init(device: vk.DeviceProxy, memory_types: VkMemory, extent: vk.Extent2D) !Self {
    var self: Self = .{ .device = device, .memory_types = memory_types };
    try self.create(extent);
    return self;
}

pub fn deinit(self: *Self) void {
    self.destroy();
}

/// Caller must make sure the GPU is no longer using the old image.
pub fn recreate(self: *Self, extent: vk.Extent2D) !void {
    self.destroy();
    try self.create(extent);
}

fn create(self: *Self, extent: vk.Extent2D) !void {
    const device = self.device;
    self.image = try device.createImage(&.{
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .depth_stencil_attachment_bit = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);

    const requirements = device.getImageMemoryRequirements(self.image);
    const type_index = self.memory_types.findMemoryType(requirements.memory_type_bits, .{ .device_local_bit = true }, .{}) orelse
        return error.NoCompatibleMemoryType;
    self.memory = try device.allocateMemory(&.{
        .allocation_size = requirements.size,
        .memory_type_index = type_index,
    }, null);
    try device.bindImageMemory(self.image, self.memory, 0);

    self.view = try device.createImageView(&.{
        .image = self.image,
        .view_type = .@"2d",
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = subresource_range,
    }, null);
}

fn destroy(self: *Self) void {
    if (self.view != .null_handle) self.device.destroyImageView(self.view, null);
    if (self.image != .null_handle) self.device.destroyImage(self.image, null);
    if (self.memory != .null_handle) self.device.freeMemory(self.memory, null);
    self.view = .null_handle;
    self.image = .null_handle;
    self.memory = .null_handle;
}

/// Discards the previous contents and prepares the image for depth writes.
pub fn transition(self: *const Self, cmd: vk.CommandBuffer) void {
    self.device.cmdPipelineBarrier2(cmd, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &.{.{
            // wait for the previous frame's depth writes before reusing the image
            .src_stage_mask = .{ .late_fragment_tests_bit = true },
            .src_access_mask = .{ .depth_stencil_attachment_write_bit = true },
            .dst_stage_mask = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
            .dst_access_mask = .{ .depth_stencil_attachment_read_bit = true, .depth_stencil_attachment_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .depth_attachment_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresource_range = subresource_range,
        }},
    });
}
