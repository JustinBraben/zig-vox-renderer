//! Sampled GPU image (2D array or cubemap) uploaded once from encoded image files.

const std = @import("std");
const dvui = @import("dvui");

const VulkanContext = @import("vulkan_context.zig");
const vk = VulkanContext.vk;
const VkMemory = @import("dvui_vulkan_renderer").VkMemory;
const Buffer = @import("buffer.zig");

const log = std.log.scoped(.vulkan);

const Self = @This();

/// Images are stored as sRGB, so sampling returns linear colors.
pub const format: vk.Format = .r8g8b8a8_srgb;

/// What `upload` needs to record and submit the one-off copy.
pub const Uploader = struct {
    device: vk.DeviceProxy,
    memory: VkMemory,
    queue: vk.Queue,
    command_pool: vk.CommandPool,
};

device: vk.DeviceProxy,
image: vk.Image,
memory: vk.DeviceMemory,
view: vk.ImageView,
sampler: vk.Sampler,
width: u32,
height: u32,

/// Cubemap from six encoded images (PNG, JPG, ... anything stb_image reads) in
/// Vulkan layer order: +X, -X, +Y, -Y, +Z, -Z. All faces must be the same square size.
pub fn initCube(up: Uploader, faces: [6][]const u8) !Self {
    return init(up, &faces, true);
}

pub fn deinit(self: *Self) void {
    self.device.destroySampler(self.sampler, null);
    self.device.destroyImageView(self.view, null);
    self.device.destroyImage(self.image, null);
    self.device.freeMemory(self.memory, null);
}

fn init(up: Uploader, layers: []const []const u8, cube: bool) !Self {
    const device = up.device;

    // decode each layer straight into the staging buffer, so only one decoded image is alive at a time
    var first = try Decoded.init(layers[0]);
    const width = first.width;
    const height = first.height;
    if (cube and width != height) {
        first.deinit();
        return error.CubeFaceNotSquare;
    }
    const layer_size = @as(usize, width) * height * 4;

    var staging = Buffer.init(device, up.memory, layer_size * layers.len, .{ .transfer_src_bit = true }, .host_visible) catch |err| {
        first.deinit();
        return err;
    };
    defer staging.deinit();
    const dst = staging.slice(u8);

    for (layers, 0..) |encoded, i| {
        var decoded = if (i == 0) first else try Decoded.init(encoded);
        defer decoded.deinit();
        if (decoded.width != width or decoded.height != height) return error.LayerSizeMismatch;
        @memcpy(dst[i * layer_size ..][0..layer_size], decoded.pixels);
    }

    const image = try device.createImage(&.{
        .flags = .{ .cube_compatible_bit = cube },
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = @intCast(layers.len),
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);
    errdefer device.destroyImage(image, null);

    const requirements = device.getImageMemoryRequirements(image);
    const type_index = up.memory.findMemoryType(requirements.memory_type_bits, .{ .device_local_bit = true }, .{}) orelse
        return error.NoCompatibleMemoryType;
    const memory = try device.allocateMemory(&.{
        .allocation_size = requirements.size,
        .memory_type_index = type_index,
    }, null);
    errdefer device.freeMemory(memory, null);
    try device.bindImageMemory(image, memory, 0);

    const range: vk.ImageSubresourceRange = .{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = @intCast(layers.len),
    };
    try copyToImage(up, staging.handle, image, .{ .width = width, .height = height, .depth = 1 }, range);

    const view = try device.createImageView(&.{
        .image = image,
        .view_type = if (cube) .cube else .@"2d_array",
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = range,
    }, null);
    errdefer device.destroyImageView(view, null);

    const sampler = try device.createSampler(&.{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1,
        .compare_enable = .false,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = .false,
    }, null);

    log.info("uploaded {d}x{d}x{d} texture", .{ width, height, layers.len });
    return .{
        .device = device,
        .image = image,
        .memory = memory,
        .view = view,
        .sampler = sampler,
        .width = width,
        .height = height,
    };
}

/// Copies tightly packed layers from `src` into `image` and leaves it ready for sampling.
/// Blocks until the GPU is done.
fn copyToImage(up: Uploader, src: vk.Buffer, image: vk.Image, extent: vk.Extent3D, range: vk.ImageSubresourceRange) !void {
    const device = up.device;
    var cmd: vk.CommandBuffer = undefined;
    try device.allocateCommandBuffers(&.{
        .command_pool = up.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmd));
    defer device.freeCommandBuffers(up.command_pool, &.{cmd});

    try device.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });
    device.cmdPipelineBarrier2(cmd, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &.{.{
            .src_stage_mask = .{},
            .src_access_mask = .{},
            .dst_stage_mask = .{ .copy_bit = true },
            .dst_access_mask = .{ .transfer_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = range,
        }},
    });
    device.cmdCopyBufferToImage(cmd, src, image, .transfer_dst_optimal, &.{.{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = range.aspect_mask,
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = range.layer_count,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = extent,
    }});
    device.cmdPipelineBarrier2(cmd, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &.{.{
            .src_stage_mask = .{ .copy_bit = true },
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .fragment_shader_bit = true },
            .dst_access_mask = .{ .shader_sampled_read_bit = true },
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = range,
        }},
    });
    try device.endCommandBuffer(cmd);

    try device.queueSubmit2(up.queue, &.{.{
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = &.{.{ .command_buffer = cmd, .device_mask = 0 }},
    }}, .null_handle);
    try device.queueWaitIdle(up.queue);
}

/// RGBA8 pixels decoded by stb_image.
const Decoded = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    fn init(encoded: []const u8) !Decoded {
        var w: c_int = 0;
        var h: c_int = 0;
        var channels: c_int = 0;
        const data = dvui.c.stbi_load_from_memory(encoded.ptr, @intCast(encoded.len), &w, &h, &channels, 4) orelse
            return error.ImageDecodeFailed;
        const width: u32 = @intCast(w);
        const height: u32 = @intCast(h);
        return .{ .pixels = data[0 .. @as(usize, width) * height * 4], .width = width, .height = height };
    }

    fn deinit(self: *Decoded) void {
        dvui.c.stbi_image_free(self.pixels.ptr);
    }
};
