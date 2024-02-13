const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("mach_glfw");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;
// const triangle_vert = @embedFile("../shaders/triangle_vert.spv");
// const triangle_frag = @embedFile("../shaders/triangle_frag.spv");
const Allocator = std.mem.Allocator;

const app_name = "mach-glfw + vulkan-zig = triangle";

const Vertex = struct {
    const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "color"),
        },
    };

    pos: [2]f32,
    color: [3]f32,
};

const vertices = [_]Vertex{
    .{ .pos = .{ 0, -0.5 }, .color = .{ 1, 0, 0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 1, 0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
};

/// Default GLFW error handling callback
fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    glfw.setErrorCallback(errorCallback);

    if (!glfw.init(.{})) {
        std.log.err("Failed to init GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    var extent = vk.Extent2D {.width = 600, .height = 600};
    extent.width = 800;

    const window = glfw.Window.create(extent.width, extent.height, app_name, null, null, .{
        .client_api = .no_api,
    }) orelse {
        std.log.err("Failed to create window: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    };
    defer window.destroy();

    const allocator = std.heap.page_allocator;
    
    const gc = try GraphicsContext.init(allocator, app_name, window);
    defer gc.deinit();

    std.debug.print("Using device: {?s}\n", .{gc.props.device_name});

    var swapchain = try Swapchain.init(&gc, allocator, extent);
    defer swapchain.deinit();
    
    const pipeline_layout = try gc.vkd.createPipelineLayout(gc.dev, &.{
        .flags = .{},
        .set_layout_count = 0,
        .p_set_layouts = undefined,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    }, null);
    defer gc.vkd.destroyPipelineLayout(gc.dev, pipeline_layout, null);

    while (!window.shouldClose()) {
        glfw.pollEvents();
    }
}