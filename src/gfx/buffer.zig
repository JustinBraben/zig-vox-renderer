//! A VkBuffer with its own memory allocation, persistently mapped when host-visible.

const std = @import("std");

const VulkanContext = @import("vulkan_context.zig");
const vk = VulkanContext.vk;
const VkMemory = @import("dvui_vulkan_renderer").VkMemory;

const log = std.log.scoped(.vulkan);

const Self = @This();

pub const MemoryKind = enum {
    /// host-visible + coherent, preferring device-local (ReBAR) memory when there is room
    host_visible,
    device_local,
};

device: vk.DeviceProxy,
handle: vk.Buffer,
memory: vk.DeviceMemory,
size: vk.DeviceSize,
mapped: ?[*]u8 = null,

pub fn init(device: vk.DeviceProxy, memory: VkMemory, size: vk.DeviceSize, usage: vk.BufferUsageFlags, kind: MemoryKind) !Self {
    const handle = try device.createBuffer(&.{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer device.destroyBuffer(handle, null);

    const requirements = device.getBufferMemoryRequirements(handle);
    const required: vk.MemoryPropertyFlags = switch (kind) {
        .host_visible => .{ .host_visible_bit = true, .host_coherent_bit = true },
        .device_local => .{ .device_local_bit = true },
    };
    const preferred: vk.MemoryPropertyFlags = switch (kind) {
        .host_visible => .{ .host_visible_bit = true, .host_coherent_bit = true, .device_local_bit = true },
        .device_local => .{ .device_local_bit = true },
    };

    const device_memory = allocate(device, memory, requirements, preferred) catch |err| switch (err) {
        // the device-local + host-visible heap is small without resizable BAR
        error.OutOfDeviceMemory => blk: {
            log.info("falling back to non-device-local memory for a {d} MiB buffer", .{size >> 20});
            break :blk try allocate(device, memory, requirements, required);
        },
        else => return err,
    };
    errdefer device.freeMemory(device_memory, null);
    try device.bindBufferMemory(handle, device_memory, 0);

    var mapped: ?[*]u8 = null;
    if (kind == .host_visible) {
        mapped = @ptrCast(try device.mapMemory(device_memory, 0, vk.WHOLE_SIZE, .{}));
    }

    return .{ .device = device, .handle = handle, .memory = device_memory, .size = size, .mapped = mapped };
}

pub fn deinit(self: *Self) void {
    if (self.mapped != null) self.device.unmapMemory(self.memory);
    self.device.destroyBuffer(self.handle, null);
    self.device.freeMemory(self.memory, null);
}

/// The mapped memory viewed as a slice of `T`.
pub fn slice(self: *const Self, comptime T: type) []T {
    const ptr: [*]T = @ptrCast(@alignCast(self.mapped.?));
    return ptr[0 .. self.size / @sizeOf(T)];
}

fn allocate(device: vk.DeviceProxy, memory: VkMemory, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
    const type_index = memory.findMemoryType(requirements.memory_type_bits, flags, .{}) orelse return error.NoCompatibleMemoryType;
    return device.allocateMemory(&.{
        .allocation_size = requirements.size,
        .memory_type_index = type_index,
    }, null);
}
