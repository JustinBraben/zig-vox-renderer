const std = @import("std");
const vk = @import("vulkan");
const Dispatch = @import("dispatch.zig");

pub const GraphicsQueue = struct {
    handle: vk.Queue,
    family: u32,

    pub fn init(vkd: Dispatch.Device, dev: vk.Device, family: u32) GraphicsQueue {
        return .{
            .handle = vkd.getDeviceQueue(dev, family, 0),
            .family = family,
        };
    }
};