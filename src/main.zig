const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

const c = @import("sdl3-c");
const SdlVkBackend = @import("sdl_vk_backend");
const VkRenderer = @import("dvui_vulkan_renderer");
const VulkanContext = @import("gfx/vulkan_context.zig");
const Swapchain = @import("gfx/swapchain.zig");
const DepthBuffer = @import("gfx/depth_buffer.zig");
const MeshArena = @import("gfx/mesh_arena.zig");
const VoxelPipeline = @import("gfx/voxel_pipeline.zig");
const World = @import("world/world.zig");
const Camera = @import("camera.zig");
const Settings = @import("settings.zig").Settings;
const debug_ui = @import("ui/debug_ui.zig");
const math = @import("math.zig");
const vk = VulkanContext.vk;

const log = std.log.scoped(.app);

const frames_in_flight = 2;
/// 16M vertices = 128 MiB of chunk meshes
const mesh_arena_vertices = 16 * 1024 * 1024;

const Frame = struct {
    cmd: vk.CommandBuffer,
    image_available: vk.Semaphore,
    in_flight: vk.Fence,
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
        1600,
        900,
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

    const memory = VkRenderer.VkMemory.init(
        ctx.memory_properties,
        ctx.properties.limits.non_coherent_atom_size,
    ) orelse return error.NoCompatibleMemoryType;

    var swapchain = try Swapchain.init(&ctx, windowExtent(window), settings.vsync);
    defer swapchain.deinit();

    var depth = try DepthBuffer.init(device, memory, swapchain.extent);
    defer depth.deinit();

    var voxel = try VoxelPipeline.init(device, memory, swapchain.surface_format.format, DepthBuffer.format, frames_in_flight);
    defer voxel.deinit();

    var arena = try MeshArena.init(gpa, device, memory, mesh_arena_vertices, frames_in_flight);
    defer arena.deinit();

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

    // dvui setup; it draws in the same rendering scope as the world, so it must know the depth format
    var renderer = try VkRenderer.init(gpa, .{
        .dev = device,
        .gpu_allocator = .{ .builtin = memory },
        .render_pass = .{ .dynamic = .{ .info = .{
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachment_formats = &.{swapchain.surface_format.format},
            .depth_attachment_format = DepthBuffer.format,
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

    var world = try World.init(gpa, settings.seed);
    defer world.deinit();

    var camera: Camera = .{};
    // start above the terrain
    camera.position[1] = @floatFromInt(world.terrain.height(0, 0) + 40);

    // wait for the GPU before any of the deferred destruction above runs
    defer device.deviceWaitIdle() catch {};

    var frame_counter: u64 = 0;
    var needs_recreate = false;
    var looking = false;
    var last_frame_ns = backend.nanoTime();
    var frame_ms: f32 = 0;

    main_loop: while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            const over_ui = try backend.addEvent(&win, event);
            switch (event.type) {
                c.SDL_EVENT_QUIT => break :main_loop,
                c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => needs_recreate = true,
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => if (event.button.button == c.SDL_BUTTON_RIGHT and !over_ui) {
                    looking = true;
                    _ = c.SDL_SetWindowRelativeMouseMode(window, true);
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => if (event.button.button == c.SDL_BUTTON_RIGHT and looking) {
                    looking = false;
                    _ = c.SDL_SetWindowRelativeMouseMode(window, false);
                },
                c.SDL_EVENT_MOUSE_MOTION => if (looking) {
                    camera.look(event.motion.xrel, event.motion.yrel, settings.mouse_sensitivity);
                },
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
            // swapchain.recreate waited for the device to go idle
            try depth.recreate(swapchain.extent);
            needs_recreate = false;
        }

        const frame_index: usize = @intCast(frame_counter % frames_in_flight);
        const frame = &frames[frame_index];
        _ = try device.waitForFences(&.{frame.in_flight}, .true, std.math.maxInt(u64));
        try arena.retire(frame_counter);

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

        // camera + world
        if (looking) moveCamera(&camera, &settings, @min(dt_ms, 100) / 1000);
        const world_config: World.Config = .{
            .render_distance = settings.render_distance,
            .min_y = settings.min_chunk_y,
            .max_y = settings.max_chunk_y,
            .gen_budget = @intCast(settings.gen_budget),
            .mesh_budget = @intCast(settings.mesh_budget),
        };
        try world.update(&arena, camera.position, world_config, frame_counter);

        const aspect = @as(f32, @floatFromInt(swapchain.extent.width)) / @as(f32, @floatFromInt(swapchain.extent.height));
        const view_proj = Camera.projection(settings.fov_deg, aspect).mul(camera.view());
        voxel.setScene(frame_index, sceneUniforms(&settings, view_proj));

        // record
        const cmd = frame.cmd;
        try device.resetCommandBuffer(cmd, .{});
        try device.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });

        transitionImage(device, cmd, swapchain.images[image_index], .undefined, .color_attachment_optimal);
        depth.transition(cmd);

        const sky = settings.sky_color;
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
                .clear_value = .{ .color = .{ .float_32 = .{ sky[0], sky[1], sky[2], 1 } } },
            }},
            .p_depth_attachment = &.{
                .image_view = depth.view,
                .image_layout = .depth_attachment_optimal,
                .resolve_mode = .{},
                .resolve_image_layout = .undefined,
                .load_op = .clear,
                .store_op = .dont_care,
                // reverse-Z: 0 is infinitely far away
                .clear_value = .{ .depth_stencil = .{ .depth = 0, .stencil = 0 } },
            },
        });

        voxel.bind(cmd, frame_index, swapchain.extent, &arena);
        const frustum: ?math.Frustum = if (settings.frustum_culling) .fromViewProj(view_proj) else null;
        world.draw(cmd, &voxel, camera.position, frustum, world_config);

        // dvui draws on top, inside the same rendering scope
        try renderer.beginFrame(cmd, swapchain.extent);
        try win.begin(backend.nanoTime());
        const actions = debug_ui.draw(&settings, .{
            .frame_ms = frame_ms,
            .camera = &camera,
            .world = world.stats,
            .arena_used = arena.used,
            .arena_capacity = arena.capacity,
        });
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

        if (actions.regenerate) try world.regenerate(&arena, settings.seed, frame_counter);

        frame_counter += 1;
    }
}

fn moveCamera(camera: *Camera, settings: *const Settings, dt: f32) void {
    const keys = c.SDL_GetKeyboardState(null);
    var dir: math.Vec3 = .{ 0, 0, 0 };
    if (keys[c.SDL_SCANCODE_D]) dir[0] += 1;
    if (keys[c.SDL_SCANCODE_A]) dir[0] -= 1;
    if (keys[c.SDL_SCANCODE_SPACE]) dir[1] += 1;
    if (keys[c.SDL_SCANCODE_LCTRL]) dir[1] -= 1;
    if (keys[c.SDL_SCANCODE_W]) dir[2] += 1;
    if (keys[c.SDL_SCANCODE_S]) dir[2] -= 1;
    if (math.length(dir) == 0) return;
    const speed = settings.move_speed * @as(f32, if (keys[c.SDL_SCANCODE_LSHIFT]) 4 else 1);
    camera.move(math.scale(math.normalize(dir), speed * dt));
}

fn sceneUniforms(settings: *const Settings, view_proj: math.Mat4) VoxelPipeline.Scene {
    const sun_dir = math.fromDirection(settings.sun_azimuth, settings.sun_elevation);
    const fog = settings.fogRange() orelse .{ 0, 0 };
    return .{
        .view_proj = view_proj,
        .sun_dir = .{ sun_dir[0], sun_dir[1], sun_dir[2], 0 },
        .sun_color = linearColor(settings.sun_color, settings.sun_intensity),
        .sky_color = linearColor(settings.sky_color, settings.ambient_intensity),
        .ground_color = linearColor(settings.ground_color, settings.ambient_intensity),
        .fog_color = linearColor(settings.sky_color, 1),
        .params = .{ fog[0], fog[1], if (settings.ao_enabled) settings.ao_strength else 0, 0 },
    };
}

/// sRGB UI color to linear, scaled.
fn linearColor(srgb: [3]f32, intensity: f32) [4]f32 {
    var out: [4]f32 = .{ 0, 0, 0, 1 };
    for (srgb, 0..) |v, i| {
        const linear = if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
        out[i] = linear * intensity;
    }
    return out;
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
