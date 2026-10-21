//! Swapchain, its image views, and a render-finished semaphore per image.

const std = @import("std");
const Allocator = std.mem.Allocator;

const VulkanContext = @import("vulkan_context.zig");
const vk = VulkanContext.vk;

const Self = @This();

ctx: *const VulkanContext,

handle: vk.SwapchainKHR = .null_handle,
surface_format: vk.SurfaceFormatKHR,
extent: vk.Extent2D,
vsync: bool,

images: []vk.Image = &.{},
image_views: []vk.ImageView = &.{},
/// Indexed by swapchain image, signaled by the frame's submit and waited on by present.
render_finished: []vk.Semaphore = &.{},

pub fn init(ctx: *const VulkanContext, extent: vk.Extent2D, vsync: bool) !Self {
    var self: Self = .{
        .ctx = ctx,
        .surface_format = try chooseSurfaceFormat(ctx),
        .extent = extent,
        .vsync = vsync,
    };
    try self.create(extent);
    return self;
}

pub fn deinit(self: *Self) void {
    self.destroy();
    self.ctx.device.destroySwapchainKHR(self.handle, null);
    self.handle = .null_handle;
}

/// Waits for the device to go idle and rebuilds the swapchain at `extent`.
pub fn recreate(self: *Self, extent: vk.Extent2D) !void {
    try self.ctx.device.deviceWaitIdle();
    self.destroy();
    try self.create(extent);
}

fn create(self: *Self, requested: vk.Extent2D) !void {
    const ctx = self.ctx;
    const allocator = ctx.allocator;
    const device = ctx.device;
    const capabilities = try ctx.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, ctx.surface);

    self.extent = if (capabilities.current_extent.width != std.math.maxInt(u32)) capabilities.current_extent else .{
        .width = std.math.clamp(requested.width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
        .height = std.math.clamp(requested.height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
    };
    // e.g. minimized on Windows; caller should wait and retry
    if (self.extent.width == 0 or self.extent.height == 0) return error.ZeroExtent;

    var image_count = capabilities.min_image_count + 1;
    if (capabilities.max_image_count > 0) image_count = @min(image_count, capabilities.max_image_count);

    const concurrent = ctx.graphics_queue_index != ctx.present_queue_index;
    const old_swapchain = self.handle;
    self.handle = try device.createSwapchainKHR(&.{
        .surface = ctx.surface,
        .min_image_count = image_count,
        .image_format = self.surface_format.format,
        .image_color_space = self.surface_format.color_space,
        .image_extent = self.extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = if (concurrent) .concurrent else .exclusive,
        .queue_family_index_count = if (concurrent) 2 else 0,
        .p_queue_family_indices = &.{ ctx.graphics_queue_index, ctx.present_queue_index },
        .pre_transform = capabilities.current_transform,
        .composite_alpha = if (capabilities.supported_composite_alpha.opaque_bit_khr) .{ .opaque_bit_khr = true } else .{ .inherit_bit_khr = true },
        .present_mode = try self.choosePresentMode(),
        .clipped = .true,
        .old_swapchain = old_swapchain,
    }, null);
    if (old_swapchain != .null_handle) device.destroySwapchainKHR(old_swapchain, null);

    self.images = try device.getSwapchainImagesAllocKHR(self.handle, allocator);

    self.image_views = try allocator.alloc(vk.ImageView, self.images.len);
    for (self.images, self.image_views) |image, *view| {
        view.* = try device.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = self.surface_format.format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = color_subresource_range,
        }, null);
    }

    self.render_finished = try allocator.alloc(vk.Semaphore, self.images.len);
    for (self.render_finished) |*semaphore| {
        semaphore.* = try device.createSemaphore(&.{}, null);
    }
}

/// Destroys everything except the swapchain handle, which is reused as `old_swapchain`.
fn destroy(self: *Self) void {
    const allocator = self.ctx.allocator;
    const device = self.ctx.device;
    for (self.render_finished) |semaphore| device.destroySemaphore(semaphore, null);
    allocator.free(self.render_finished);
    for (self.image_views) |view| device.destroyImageView(view, null);
    allocator.free(self.image_views);
    allocator.free(self.images);
    self.render_finished = &.{};
    self.image_views = &.{};
    self.images = &.{};
}

pub const color_subresource_range: vk.ImageSubresourceRange = .{
    .aspect_mask = .{ .color_bit = true },
    .base_mip_level = 0,
    .level_count = 1,
    .base_array_layer = 0,
    .layer_count = 1,
};

/// dvui works in sRGB space without linearizing, so prefer UNORM formats.
fn chooseSurfaceFormat(ctx: *const VulkanContext) !vk.SurfaceFormatKHR {
    const formats = try ctx.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(ctx.physical_device, ctx.surface, ctx.allocator);
    defer ctx.allocator.free(formats);
    const preferred = [_]vk.Format{ .b8g8r8a8_unorm, .r8g8b8a8_unorm };
    for (preferred) |want| {
        for (formats) |format| {
            if (format.format == want and format.color_space == .srgb_nonlinear_khr) return format;
        }
    }
    return formats[0];
}

fn choosePresentMode(self: *const Self) !vk.PresentModeKHR {
    if (self.vsync) return .fifo_khr;
    const ctx = self.ctx;
    const modes = try ctx.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(ctx.physical_device, ctx.surface, ctx.allocator);
    defer ctx.allocator.free(modes);
    for ([_]vk.PresentModeKHR{ .mailbox_khr, .immediate_khr }) |want| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, modes, want) != null) return want;
    }
    return .fifo_khr;
}
