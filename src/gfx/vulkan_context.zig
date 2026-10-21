//! Vulkan instance, surface, physical/logical device and queues.
//!
//! Vulkan 1.3 with dynamic rendering and synchronization2. All vk types come from
//! dvui's Vulkan renderer so handles are interchangeable with it.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const c = @import("sdl3-c");
const VkRenderer = @import("dvui_vulkan_renderer");
pub const vk = VkRenderer.vulkan;

const log = std.log.scoped(.vulkan);

const Self = @This();

pub const api_version = vk.API_VERSION_1_3;
const enable_validation = builtin.mode == .Debug;
const validation_layer = "VK_LAYER_KHRONOS_validation";

allocator: Allocator,

vkb: vk.BaseWrapper,
vki: *vk.InstanceWrapper,
vkd: *vk.DeviceWrapper,

instance: vk.InstanceProxy,
debug_messenger: vk.DebugUtilsMessengerEXT = .null_handle,
surface: vk.SurfaceKHR,

physical_device: vk.PhysicalDevice,
properties: vk.PhysicalDeviceProperties,
memory_properties: vk.PhysicalDeviceMemoryProperties,

device: vk.DeviceProxy,
graphics_queue_index: u32,
present_queue_index: u32,
graphics_queue: vk.Queue,
present_queue: vk.Queue,

var get_instance_proc_addr: vk.PfnGetInstanceProcAddr = undefined;

fn loader(instance: vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction {
    return get_instance_proc_addr(instance, name);
}

pub fn init(allocator: Allocator, window: *c.SDL_Window) !Self {
    get_instance_proc_addr = @ptrCast(c.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse return error.VulkanLoaderNotFound);

    var self: Self = undefined;
    self.allocator = allocator;
    self.vkb = .load(loader);

    try self.createInstance();
    errdefer self.destroyInstance();

    if (!c.SDL_Vulkan_CreateSurface(window, @ptrFromInt(@intFromEnum(self.instance.handle)), null, @ptrCast(&self.surface))) {
        log.err("SDL_Vulkan_CreateSurface failed: {s}", .{c.SDL_GetError()});
        return error.SurfaceCreationFailed;
    }
    errdefer self.instance.destroySurfaceKHR(self.surface, null);

    try self.pickPhysicalDevice();
    self.properties = self.instance.getPhysicalDeviceProperties(self.physical_device);
    self.memory_properties = self.instance.getPhysicalDeviceMemoryProperties(self.physical_device);
    log.info("using GPU: {s}", .{std.mem.sliceTo(&self.properties.device_name, 0)});

    try self.createLogicalDevice();

    return self;
}

pub fn deinit(self: *Self) void {
    self.device.destroyDevice(null);
    self.allocator.destroy(self.vkd);
    self.instance.destroySurfaceKHR(self.surface, null);
    self.destroyInstance();
}

fn createInstance(self: *Self) !void {
    var enabled_layers: std.ArrayList([*:0]const u8) = .empty;
    defer enabled_layers.deinit(self.allocator);

    var enabled_extensions: std.ArrayList([*:0]const u8) = .empty;
    defer enabled_extensions.deinit(self.allocator);

    var sdl_extension_count: u32 = 0;
    const sdl_extensions = c.SDL_Vulkan_GetInstanceExtensions(&sdl_extension_count) orelse {
        log.err("SDL_Vulkan_GetInstanceExtensions failed: {s}", .{c.SDL_GetError()});
        return error.MissingInstanceExtensions;
    };
    for (sdl_extensions[0..sdl_extension_count]) |ext| {
        try enabled_extensions.append(self.allocator, @ptrCast(ext));
    }

    var has_validation = false;
    if (enable_validation) {
        const layers = try self.vkb.enumerateInstanceLayerPropertiesAlloc(self.allocator);
        defer self.allocator.free(layers);
        for (layers) |layer| {
            if (std.mem.eql(u8, std.mem.sliceTo(&layer.layer_name, 0), validation_layer)) {
                try enabled_layers.append(self.allocator, validation_layer);
                try enabled_extensions.append(self.allocator, vk.extensions.ext_debug_utils.name);
                has_validation = true;
                break;
            }
        }
        if (!has_validation) log.warn("{s} not available, running without validation", .{validation_layer});
    }

    var has_portability = false;
    const extensions = try self.vkb.enumerateInstanceExtensionPropertiesAlloc(null, self.allocator);
    defer self.allocator.free(extensions);
    for (extensions) |extension| {
        const name = std.mem.sliceTo(&extension.extension_name, 0);
        if (std.mem.eql(u8, name, vk.extensions.khr_portability_enumeration.name)) {
            try enabled_extensions.append(self.allocator, vk.extensions.khr_portability_enumeration.name);
            has_portability = true;
        }
    }

    const debug_info = debugMessengerCreateInfo();
    const handle = try self.vkb.createInstance(&.{
        .p_next = if (has_validation) &debug_info else null,
        .flags = .{ .enumerate_portability_bit_khr = has_portability },
        .p_application_info = &.{
            .p_application_name = "zig-vox-renderer",
            .application_version = 0,
            .p_engine_name = "zig-vox-renderer",
            .engine_version = 0,
            .api_version = @bitCast(api_version),
        },
        .enabled_layer_count = @intCast(enabled_layers.items.len),
        .pp_enabled_layer_names = enabled_layers.items.ptr,
        .enabled_extension_count = @intCast(enabled_extensions.items.len),
        .pp_enabled_extension_names = enabled_extensions.items.ptr,
    }, null);

    self.vki = try self.allocator.create(vk.InstanceWrapper);
    self.vki.* = .load(handle, loader);
    self.instance = .init(handle, self.vki);

    self.debug_messenger = .null_handle;
    if (has_validation) {
        self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&debug_info, null);
    }
}

fn destroyInstance(self: *Self) void {
    if (self.debug_messenger != .null_handle) self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
    self.instance.destroyInstance(null);
    self.allocator.destroy(self.vki);
}

fn debugMessengerCreateInfo() vk.DebugUtilsMessengerCreateInfoEXT {
    return .{
        .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true },
        .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
        .pfn_user_callback = debugCallback,
    };
}

fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    _: vk.DebugUtilsMessageTypeFlagsEXT,
    data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    const message: [*:0]const u8 = if (data) |d| d.p_message orelse "(null)" else "(null)";
    if (severity.error_bit_ext) {
        log.err("{s}", .{message});
    } else {
        log.warn("{s}", .{message});
    }
    return .false;
}

fn pickPhysicalDevice(self: *Self) !void {
    const physical_devices = try self.instance.enumeratePhysicalDevicesAlloc(self.allocator);
    defer self.allocator.free(physical_devices);

    var fallback: ?struct { device: vk.PhysicalDevice, graphics: u32, present: u32 } = null;

    for (physical_devices) |handle| {
        const props = self.instance.getPhysicalDeviceProperties(handle);
        if (props.api_version < @as(u32, @bitCast(api_version))) continue;

        var has_swapchain = false;
        const extensions = try self.instance.enumerateDeviceExtensionPropertiesAlloc(handle, null, self.allocator);
        defer self.allocator.free(extensions);
        for (extensions) |extension| {
            if (std.mem.eql(u8, std.mem.sliceTo(&extension.extension_name, 0), vk.extensions.khr_swapchain.name)) {
                has_swapchain = true;
            }
        }
        if (!has_swapchain) continue;

        var surface_format_count: u32 = 0;
        _ = try self.instance.getPhysicalDeviceSurfaceFormatsKHR(handle, self.surface, &surface_format_count, null);
        var present_mode_count: u32 = 0;
        _ = try self.instance.getPhysicalDeviceSurfacePresentModesKHR(handle, self.surface, &present_mode_count, null);
        if (surface_format_count == 0 or present_mode_count == 0) continue;

        var graphics: ?u32 = null;
        var present: ?u32 = null;
        const queue_families = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(handle, self.allocator);
        defer self.allocator.free(queue_families);
        for (queue_families, 0..) |queue_family, i| {
            const index: u32 = @intCast(i);
            const supports_graphics = queue_family.queue_flags.graphics_bit;
            const supports_present = try self.instance.getPhysicalDeviceSurfaceSupportKHR(handle, index, self.surface) == .true;
            // prefer a single family that does both
            if (supports_graphics and supports_present) {
                graphics = index;
                present = index;
                break;
            }
            if (graphics == null and supports_graphics) graphics = index;
            if (present == null and supports_present) present = index;
        }
        if (graphics == null or present == null) continue;

        // prefer discrete GPUs
        if (props.device_type == .discrete_gpu) {
            self.physical_device = handle;
            self.graphics_queue_index = graphics.?;
            self.present_queue_index = present.?;
            return;
        }
        if (fallback == null) fallback = .{ .device = handle, .graphics = graphics.?, .present = present.? };
    }

    const f = fallback orelse return error.NoSuitableDevice;
    self.physical_device = f.device;
    self.graphics_queue_index = f.graphics;
    self.present_queue_index = f.present;
}

fn createLogicalDevice(self: *Self) !void {
    var enabled_extensions: std.ArrayList([*:0]const u8) = .empty;
    defer enabled_extensions.deinit(self.allocator);
    try enabled_extensions.append(self.allocator, vk.extensions.khr_swapchain.name);

    const extensions = try self.instance.enumerateDeviceExtensionPropertiesAlloc(self.physical_device, null, self.allocator);
    defer self.allocator.free(extensions);
    for (extensions) |extension| {
        if (std.mem.eql(u8, std.mem.sliceTo(&extension.extension_name, 0), vk.extensions.khr_portability_subset.name)) {
            try enabled_extensions.append(self.allocator, vk.extensions.khr_portability_subset.name);
        }
    }

    const priorities = [_]f32{1};
    const queue_infos = [_]vk.DeviceQueueCreateInfo{
        .{ .queue_family_index = self.graphics_queue_index, .queue_count = 1, .p_queue_priorities = &priorities },
        .{ .queue_family_index = self.present_queue_index, .queue_count = 1, .p_queue_priorities = &priorities },
    };

    var vulkan13_features = vk.PhysicalDeviceVulkan13Features{
        .dynamic_rendering = .true,
        .synchronization_2 = .true,
    };

    const handle = try self.instance.createDevice(self.physical_device, &.{
        .p_next = &vulkan13_features,
        .queue_create_info_count = if (self.graphics_queue_index == self.present_queue_index) 1 else 2,
        .p_queue_create_infos = &queue_infos,
        .enabled_extension_count = @intCast(enabled_extensions.items.len),
        .pp_enabled_extension_names = enabled_extensions.items.ptr,
    }, null);

    self.vkd = try self.allocator.create(vk.DeviceWrapper);
    errdefer self.allocator.destroy(self.vkd);
    self.vkd.* = .load(handle, self.vki.dispatch.vkGetDeviceProcAddr.?);
    self.device = .init(handle, self.vkd);

    self.graphics_queue = self.device.getDeviceQueue(self.graphics_queue_index, 0);
    self.present_queue = self.device.getDeviceQueue(self.present_queue_index, 0);
}
