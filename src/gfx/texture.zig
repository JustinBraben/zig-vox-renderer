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

/// 2D array from an encoded atlas of `tile`×`tile` tiles, one layer per tile, read left
/// to right and top to bottom; only the first `count` tiles are used. Mipmapped down to
/// 1×1 and sampled with nearest magnification, for pixel-art block textures.
pub fn initAtlas(up: Uploader, encoded: []const u8, tile: u32, count: u32) !Self {
    std.debug.assert(std.math.isPowerOfTwo(tile));
    var atlas = try Decoded.init(encoded);
    defer atlas.deinit();
    const columns = atlas.width / tile;
    if (columns * (atlas.height / tile) < count) return error.AtlasTooSmall;

    const levels = std.math.log2_int(u32, tile) + 1;
    var size: usize = 0;
    for (0..levels) |level| size += mipSize(tile, level) * count;

    var staging = try Buffer.init(up.device, up.memory, size, .{ .transfer_src_bit = true }, .host_visible);
    defer staging.deinit();
    const dst = staging.slice(u8);

    // level 0: copy each tile into its layer; each further level: 2×2 box filter of the previous one
    var regions: [16]vk.BufferImageCopy = undefined;
    std.debug.assert(levels <= regions.len);
    var offset: usize = 0;
    for (0..levels) |level| {
        const dim = tile >> @intCast(level);
        const layer_size = mipSize(tile, level);
        for (0..count) |layer| {
            const out = dst[offset + layer * layer_size ..][0..layer_size];
            if (level == 0) {
                const tx = (layer % columns) * tile;
                const ty = (layer / columns) * tile;
                for (0..tile) |y| {
                    const row = atlas.pixels[((ty + y) * atlas.width + tx) * 4 ..][0 .. tile * 4];
                    @memcpy(out[y * tile * 4 ..][0 .. tile * 4], row);
                }
            } else {
                const prev_size = mipSize(tile, level - 1);
                const prev = dst[offset - prev_size * count + layer * prev_size ..][0..prev_size];
                downsample(prev, out, dim);
            }
        }
        regions[level] = .{
            .buffer_offset = offset,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = @intCast(level), .base_array_layer = 0, .layer_count = count },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = dim, .height = dim, .depth = 1 },
        };
        offset += layer_size * count;
    }

    return create(up, staging.handle, regions[0..levels], .{
        .width = tile,
        .height = tile,
        .layers = count,
        .levels = levels,
        .cube = false,
        .mag_filter = .nearest,
        .address_mode = .repeat,
    });
}

/// Bytes in one layer of mip `level`.
fn mipSize(tile: u32, level: usize) usize {
    const dim: usize = tile >> @intCast(level);
    return dim * dim * 4;
}

/// Halves `src` (2·`dim` square) into `dst` (`dim` square), averaging in linear light and
/// weighting color by alpha so transparent texels don't darken their neighbors.
fn downsample(src: []const u8, dst: []u8, dim: u32) void {
    const src_dim = dim * 2;
    for (0..dim) |y| {
        for (0..dim) |x| {
            var rgb: [3]f32 = .{ 0, 0, 0 };
            var alpha: f32 = 0;
            for ([_][2]usize{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |d| {
                const p = src[((y * 2 + d[1]) * src_dim + x * 2 + d[0]) * 4 ..][0..4];
                const a = @as(f32, @floatFromInt(p[3])) / 255;
                for (&rgb, p[0..3]) |*sum, c| sum.* += srgbToLinear(c) * a;
                alpha += a;
            }
            const out = dst[(y * dim + x) * 4 ..][0..4];
            for (out[0..3], rgb) |*c, sum| c.* = if (alpha > 0) linearToSrgb(sum / alpha) else 0;
            out[3] = @intFromFloat(@round(alpha / 4 * 255));
        }
    }
}

fn srgbToLinear(c: u8) f32 {
    const f = @as(f32, @floatFromInt(c)) / 255;
    return if (f <= 0.04045) f / 12.92 else std.math.pow(f32, (f + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(f: f32) u8 {
    const s = if (f <= 0.0031308) f * 12.92 else 1.055 * std.math.pow(f32, f, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(std.math.clamp(s, 0, 1) * 255));
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

    const region: vk.BufferImageCopy = .{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = @intCast(layers.len) },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    };
    return create(up, staging.handle, &.{region}, .{
        .width = width,
        .height = height,
        .layers = @intCast(layers.len),
        .levels = 1,
        .cube = cube,
        .mag_filter = .linear,
        .address_mode = .clamp_to_edge,
    });
}

const CreateOptions = struct {
    width: u32,
    height: u32,
    layers: u32,
    levels: u32,
    cube: bool,
    mag_filter: vk.Filter,
    address_mode: vk.SamplerAddressMode,
};

/// Creates the image, fills it from `staging` with `regions` (which must cover every
/// level and layer), and creates its view and sampler.
fn create(up: Uploader, staging: vk.Buffer, regions: []const vk.BufferImageCopy, options: CreateOptions) !Self {
    const device = up.device;
    const image = try device.createImage(&.{
        .flags = .{ .cube_compatible_bit = options.cube },
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = options.width, .height = options.height, .depth = 1 },
        .mip_levels = options.levels,
        .array_layers = options.layers,
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
        .level_count = options.levels,
        .base_array_layer = 0,
        .layer_count = options.layers,
    };
    try copyToImage(up, staging, image, regions, range);

    const view = try device.createImageView(&.{
        .image = image,
        .view_type = if (options.cube) .cube else .@"2d_array",
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = range,
    }, null);
    errdefer device.destroyImageView(view, null);

    const sampler = try device.createSampler(&.{
        .mag_filter = options.mag_filter,
        .min_filter = .linear,
        .mipmap_mode = if (options.levels > 1) .linear else .nearest,
        .address_mode_u = options.address_mode,
        .address_mode_v = options.address_mode,
        .address_mode_w = options.address_mode,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1,
        .compare_enable = .false,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = @floatFromInt(options.levels - 1),
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = .false,
    }, null);

    log.info("uploaded {d}x{d}x{d} texture ({d} mip levels)", .{ options.width, options.height, options.layers, options.levels });
    return .{
        .device = device,
        .image = image,
        .memory = memory,
        .view = view,
        .sampler = sampler,
        .width = options.width,
        .height = options.height,
    };
}

/// Copies `regions` of `src` into `image` and leaves `range` ready for sampling.
/// Blocks until the GPU is done.
fn copyToImage(up: Uploader, src: vk.Buffer, image: vk.Image, regions: []const vk.BufferImageCopy, range: vk.ImageSubresourceRange) !void {
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
    device.cmdCopyBufferToImage(cmd, src, image, .transfer_dst_optimal, regions);
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
