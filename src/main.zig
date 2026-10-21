const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

const c = @import("sdl3-c");
const SdlVkBackend = @import("sdl_vk_backend");
const VkRenderer = @import("dvui_vulkan_renderer");
const VulkanContext = @import("gfx/vulkan_context.zig");
const Swapchain = @import("gfx/swapchain.zig");
const TrianglePipeline = @import("gfx/triangle_pipeline.zig");
const vk = VulkanContext.vk;

const log = std.log.scoped(.app);

const frames_in_flight = 2;

const Frame = struct {
    cmd: vk.CommandBuffer,
    image_available: vk.Semaphore,
    in_flight: vk.Fence,
};

/// State tweaked from the UI
const Settings = struct {
    clear_color: [3]f32 = .{ 0.05, 0.05, 0.08 },
    tint: [3]f32 = .{ 1, 1, 1 },
    vsync: bool = true,
    show_demo: bool = false,
};

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .windows) {
        // on windows graphical apps have no console, so output goes to nowhere - attach it manually. related: https://github.com/ziglang/zig/issues/4196
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }
    const gpa = init.gpa;

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "zig-vox-renderer",
        1280,
        720,
        c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    ) orelse {
        log.err("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
        return error.SdlWindowFailed;
    };
    defer c.SDL_DestroyWindow(window);

    var settings: Settings = .{};

    // Vulkan setup
    var ctx = try VulkanContext.init(gpa, window);
    defer ctx.deinit();
    const device = ctx.device;

    var swapchain = try Swapchain.init(&ctx, windowExtent(window), settings.vsync);
    defer swapchain.deinit();

    var triangle = try TrianglePipeline.init(device, swapchain.surface_format.format);
    defer triangle.deinit();

    const command_pool = try device.createCommandPool(&.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = ctx.graphics_queue_index,
    }, null);
    defer device.destroyCommandPool(command_pool, null);

    var frames: [frames_in_flight]Frame = undefined;
    for (&frames) |*frame| {
        try device.allocateCommandBuffers(&.{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&frame.cmd));
        frame.image_available = try device.createSemaphore(&.{}, null);
        frame.in_flight = try device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
    }
    defer for (frames) |frame| {
        device.destroySemaphore(frame.image_available, null);
        device.destroyFence(frame.in_flight, null);
    };

    // dvui setup
    const memory = VkRenderer.VkMemory.init(
        ctx.memory_properties,
        ctx.properties.limits.non_coherent_atom_size,
    ) orelse return error.NoCompatibleMemoryType;

    var renderer = try VkRenderer.init(gpa, .{
        .dev = device,
        .gpu_allocator = .{ .builtin = memory },
        .render_pass = .{ .dynamic = .{ .info = .{
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachment_formats = &.{swapchain.surface_format.format},
            .depth_attachment_format = .undefined,
            .stencil_attachment_format = .undefined,
        } } },
        .graphics_queue_family_index = ctx.graphics_queue_index,
        .max_frames_in_flight = frames_in_flight,
    });
    defer renderer.deinit();

    var backend = SdlVkBackend.init(init.io, window, &renderer);
    defer backend.deinit();

    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{});
    defer win.deinit();

    // wait for the GPU before any of the deferred destruction above runs
    defer device.deviceWaitIdle() catch {};

    var frame_index: usize = 0;
    var needs_recreate = false;
    var last_frame_ns = backend.nanoTime();
    var frame_ms: f32 = 0;

    main_loop: while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            _ = try backend.addEvent(&win, event);
            switch (event.type) {
                c.SDL_EVENT_QUIT => break :main_loop,
                c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => needs_recreate = true,
                else => {},
            }
        }

        // nothing to render to while minimized
        const extent = windowExtent(window);
        const minimized = c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_MINIMIZED != 0;
        if (minimized or extent.width == 0 or extent.height == 0) {
            _ = c.SDL_WaitEvent(null);
            continue;
        }

        if (needs_recreate or settings.vsync != swapchain.vsync) {
            swapchain.vsync = settings.vsync;
            swapchain.recreate(extent) catch |err| switch (err) {
                error.ZeroExtent => {
                    needs_recreate = true;
                    _ = c.SDL_WaitEvent(null);
                    continue;
                },
                else => return err,
            };
            needs_recreate = false;
        }

        const frame = &frames[frame_index];
        _ = try device.waitForFences(&.{frame.in_flight}, .true, std.math.maxInt(u64));

        const acquired = device.acquireNextImageKHR(swapchain.handle, std.math.maxInt(u64), frame.image_available, .null_handle) catch |err| switch (err) {
            error.OutOfDateKHR => {
                needs_recreate = true;
                continue;
            },
            else => return err,
        };
        if (acquired.result == .suboptimal_khr) needs_recreate = true;
        const image_index = acquired.image_index;

        // only reset once we know we will submit work that signals it
        try device.resetFences(&.{frame.in_flight});

        const now_ns = backend.nanoTime();
        const dt_ms: f32 = @floatCast(@as(f64, @floatFromInt(now_ns - last_frame_ns)) / std.time.ns_per_ms);
        frame_ms = if (frame_ms == 0) dt_ms else frame_ms * 0.95 + dt_ms * 0.05;
        last_frame_ns = now_ns;

        // record
        const cmd = frame.cmd;
        try device.resetCommandBuffer(cmd, .{});
        try device.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });

        transitionImage(device, cmd, swapchain.images[image_index], .undefined, .color_attachment_optimal);

        const cc = settings.clear_color;
        device.cmdBeginRendering(cmd, &.{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = swapchain.extent },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = &.{.{
                .image_view = swapchain.image_views[image_index],
                .image_layout = .color_attachment_optimal,
                .resolve_mode = .{},
                .resolve_image_layout = .undefined,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .color = .{ .float_32 = .{ cc[0], cc[1], cc[2], 1 } } },
            }},
        });

        triangle.draw(cmd, swapchain.extent, .{ .tint = .{ settings.tint[0], settings.tint[1], settings.tint[2], 1 } });

        // dvui draws on top, inside the same rendering scope
        try renderer.beginFrame(cmd, swapchain.extent);
        try win.begin(backend.nanoTime());
        drawUi(&settings, frame_ms);
        _ = try win.end(.{});
        const recorded = try renderer.endFrame();

        device.cmdEndRendering(cmd);
        transitionImage(device, cmd, swapchain.images[image_index], .color_attachment_optimal, .present_src_khr);
        try device.endCommandBuffer(cmd);

        // submit (dvui's texture upload prepass, if any, goes first)
        var cmd_infos: [2]vk.CommandBufferSubmitInfo = undefined;
        var cmd_count: u32 = 0;
        if (recorded.prepass) |prepass| {
            cmd_infos[cmd_count] = .{ .command_buffer = prepass, .device_mask = 0 };
            cmd_count += 1;
        }
        cmd_infos[cmd_count] = .{ .command_buffer = recorded.main, .device_mask = 0 };
        cmd_count += 1;

        const render_finished = swapchain.render_finished[image_index];
        try device.queueSubmit2(ctx.graphics_queue, &.{.{
            .wait_semaphore_info_count = 1,
            .p_wait_semaphore_infos = &.{.{
                .semaphore = frame.image_available,
                .value = 0,
                .stage_mask = .{ .color_attachment_output_bit = true },
                .device_index = 0,
            }},
            .command_buffer_info_count = cmd_count,
            .p_command_buffer_infos = &cmd_infos,
            .signal_semaphore_info_count = 1,
            .p_signal_semaphore_infos = &.{.{
                .semaphore = render_finished,
                .value = 0,
                .stage_mask = .{ .all_commands_bit = true },
                .device_index = 0,
            }},
        }}, frame.in_flight);

        const present_result = device.queuePresentKHR(ctx.present_queue, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = &.{render_finished},
            .swapchain_count = 1,
            .p_swapchains = &.{swapchain.handle},
            .p_image_indices = &.{image_index},
        }) catch |err| switch (err) {
            error.OutOfDateKHR => vk.Result.error_out_of_date_khr,
            else => return err,
        };
        if (present_result != .success) needs_recreate = true;

        frame_index = (frame_index + 1) % frames_in_flight;
    }
}

fn drawUi(settings: *Settings, frame_ms: f32) void {
    var float = dvui.floatingWindow(@src(), .{}, .{ .min_size_content = .{ .w = 260 } });
    defer float.deinit();
    float.dragAreaSet(dvui.windowHeader("Renderer", "", null));

    var box = dvui.box(@src(), .{}, .{ .expand = .both, .padding = .all(6) });
    defer box.deinit();

    const fps = if (frame_ms > 0) 1000.0 / frame_ms else 0;
    dvui.label(@src(), "{d:.2} ms ({d:.0} fps)", .{ frame_ms, fps }, .{});

    _ = dvui.checkbox(@src(), &settings.vsync, "VSync", .{});
    _ = dvui.checkbox(@src(), &settings.show_demo, "dvui demo window", .{});

    dvui.label(@src(), "Clear color", .{}, .{ .font = .theme(.heading) });
    colorSliders(@src(), &settings.clear_color);

    dvui.label(@src(), "Triangle tint", .{}, .{ .font = .theme(.heading) });
    colorSliders(@src(), &settings.tint);

    dvui.Examples.show_demo_window = settings.show_demo;
    dvui.Examples.demo(.lite);
    settings.show_demo = dvui.Examples.show_demo_window;
}

fn colorSliders(src: std.builtin.SourceLocation, color: *[3]f32) void {
    var vbox = dvui.box(src, .{}, .{ .expand = .horizontal });
    defer vbox.deinit();
    _ = dvui.sliderEntry(@src(), "R: {d:0.2}", .{ .value = &color[0], .min = 0, .max = 1 }, .{ .expand = .horizontal });
    _ = dvui.sliderEntry(@src(), "G: {d:0.2}", .{ .value = &color[1], .min = 0, .max = 1 }, .{ .expand = .horizontal });
    _ = dvui.sliderEntry(@src(), "B: {d:0.2}", .{ .value = &color[2], .min = 0, .max = 1 }, .{ .expand = .horizontal });
}

fn windowExtent(window: *c.SDL_Window) vk.Extent2D {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window, &w, &h);
    return .{ .width = @intCast(@max(w, 0)), .height = @intCast(@max(h, 0)) };
}

fn transitionImage(device: vk.DeviceProxy, cmd: vk.CommandBuffer, image: vk.Image, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) void {
    const to_attachment = new_layout == .color_attachment_optimal;
    device.cmdPipelineBarrier2(cmd, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &.{.{
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = if (to_attachment) .{} else .{ .color_attachment_write_bit = true },
            .dst_stage_mask = if (to_attachment) .{ .color_attachment_output_bit = true } else .{},
            .dst_access_mask = if (to_attachment) .{ .color_attachment_write_bit = true, .color_attachment_read_bit = true } else .{},
            .old_layout = old_layout,
            .new_layout = new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = Swapchain.color_subresource_range,
        }},
    });
}
