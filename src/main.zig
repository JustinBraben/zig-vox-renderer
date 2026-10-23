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
const SkyPipeline = @import("gfx/sky_pipeline.zig");
const OutlinePipeline = @import("gfx/outline_pipeline.zig");
const Texture = @import("gfx/texture.zig");
const Assets = @import("assets.zig");
const World = @import("world/world.zig");
const Lod = @import("world/lod.zig");
const BlockId = @import("world/block.zig").BlockId;
const raycast = @import("world/raycast.zig");
const Player = @import("player.zig");
const Camera = @import("camera.zig");
const Settings = @import("settings.zig").Settings;
const debug_ui = @import("ui/debug_ui.zig");
const math = @import("math.zig");
const vk = VulkanContext.vk;

const log = std.log.scoped(.app);

const frames_in_flight = 2;
/// 16M vertices = 128 MiB of chunk meshes
const mesh_arena_vertices = 16 * 1024 * 1024;
/// player physics rate
const physics_dt = 1.0 / 60.0;
/// how far away blocks can be broken or placed
const reach = 5;

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

    const vulkan_library_loaded = loadVulkanLibrary(init.environ_map);
    defer if (vulkan_library_loaded) c.SDL_Vulkan_UnloadLibrary();

    var assets = try Assets.init(init.io, gpa);
    defer assets.deinit();

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
    var bench: ?Bench = null;
    for (try init.minimal.args.toSlice(init.arena.allocator())) |arg| {
        if (std.mem.startsWith(u8, arg, "--bench")) {
            bench = .{};
            settings.vsync = false;
            settings.render_distance = 12;
            if (std.mem.startsWith(u8, arg, "--bench=")) settings.render_distance = try std.fmt.parseInt(i32, arg["--bench=".len..], 10);
        }
    }

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

    const command_pool = try device.createCommandPool(&.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = ctx.graphics_queue_index,
    }, null);
    defer device.destroyCommandPool(command_pool, null);

    var sky_texture = try loadSkybox(&assets, .{
        .device = device,
        .memory = memory,
        .queue = ctx.graphics_queue,
        .command_pool = command_pool,
    });
    defer sky_texture.deinit();

    var voxel = try VoxelPipeline.init(device, memory, &assets, &sky_texture, swapchain.surface_format.format, DepthBuffer.format, frames_in_flight);
    defer voxel.deinit();

    var sky_pipeline = try SkyPipeline.init(device, &assets, &voxel, swapchain.surface_format.format, DepthBuffer.format);
    defer sky_pipeline.deinit();

    var outline = try OutlinePipeline.init(device, &assets, &voxel, swapchain.surface_format.format, DepthBuffer.format);
    defer outline.deinit();

    var arena = try MeshArena.init(gpa, device, memory, mesh_arena_vertices, frames_in_flight);
    defer arena.deinit();

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

    var world = try World.init(gpa, init.io, settings.seed);
    defer world.deinit();
    var lod = Lod.init(gpa, init.io);
    defer lod.deinit();

    // stand on the terrain at the origin; the benchmark flies high above it instead
    const ground: f64 = @floatFromInt(world.terrain.height(0, 0) + 1);
    var player = Player.init(.{ 0.5, if (bench != null) ground + 40 else ground, 0.5 });
    if (bench != null) player.setFlying(true);
    var camera: Camera = .{ .position = player.eye(1) };
    var physics_time: f64 = 0;
    // index into `BlockId.placeable`
    var selected: usize = 0;
    var target: ?raycast.Hit = null;

    // wait for the GPU before any of the deferred destruction above runs
    defer device.deviceWaitIdle() catch {};

    var frame_counter: u64 = 0;
    var needs_recreate = false;
    // mouse captured for playing; released for the UI
    var captured = false;
    var break_block = false;
    var place_block = false;
    var last_frame_ns = backend.nanoTime();
    var frame_ms: f32 = 0;

    main_loop: while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            // while playing, input belongs to the game rather than the UI
            const over_ui = if (captured) false else try backend.addEvent(&win, event);
            switch (event.type) {
                c.SDL_EVENT_QUIT => break :main_loop,
                c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => needs_recreate = true,
                c.SDL_EVENT_WINDOW_FOCUS_LOST => captured = setCaptured(window, false),
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (!captured) {
                        if (!over_ui) captured = setCaptured(window, true);
                    } else if (event.button.button == c.SDL_BUTTON_LEFT) {
                        break_block = true;
                    } else if (event.button.button == c.SDL_BUTTON_RIGHT) {
                        place_block = true;
                    }
                },
                c.SDL_EVENT_MOUSE_MOTION => if (captured) {
                    camera.look(event.motion.xrel, event.motion.yrel, settings.mouse_sensitivity);
                },
                c.SDL_EVENT_MOUSE_WHEEL => if (captured and event.wheel.y != 0) {
                    const n = BlockId.placeable.len;
                    selected = if (event.wheel.y < 0) (selected + 1) % n else (selected + n - 1) % n;
                },
                c.SDL_EVENT_KEY_DOWN => if (captured and !event.key.repeat) {
                    const sc = event.key.scancode;
                    if (sc == c.SDL_SCANCODE_ESCAPE) {
                        captured = setCaptured(window, false);
                    } else if (sc == c.SDL_SCANCODE_F) {
                        player.setFlying(!player.flying);
                    } else if (sc >= c.SDL_SCANCODE_1 and sc <= c.SDL_SCANCODE_9) {
                        const i: usize = @intCast(sc - c.SDL_SCANCODE_1);
                        if (i < BlockId.placeable.len) selected = i;
                    }
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

        // player physics at a fixed rate; the camera interpolates between the last two steps
        const input: Player.Input = if (captured) playerInput(&settings) else .{ .fly_speed = settings.move_speed };
        physics_time += @min(dt_ms / 1000, 0.25);
        while (physics_time >= physics_dt) : (physics_time -= physics_dt) {
            player.step(&world, input, camera.yaw, camera.pitch, physics_dt);
        }
        camera.position = player.eye(physics_time / physics_dt);

        // block interaction
        target = raycast.cast(&world, camera.position, camera.forward(), reach);
        if (target) |hit| {
            if (break_block) {
                try world.setBlock(hit.block[0], hit.block[1], hit.block[2], .air);
            } else if (place_block and !std.meta.eql(hit.normal, .{ 0, 0, 0 })) {
                const p = hit.adjacent();
                if (!player.intersectsBlock(p[0], p[1], p[2])) try world.setBlock(p[0], p[1], p[2], BlockId.placeable[selected]);
            }
            if (break_block or place_block) target = raycast.cast(&world, camera.position, camera.forward(), reach);
        }
        break_block = false;
        place_block = false;

        const world_config: World.Config = .{
            .render_distance = settings.render_distance,
            .min_y = settings.min_chunk_y,
            .max_y = settings.max_chunk_y,
            .gen_budget = @intCast(settings.gen_budget),
            .mesh_budget = @intCast(settings.mesh_budget),
        };
        try world.update(&arena, camera.position, world_config, frame_counter);
        if (settings.lod_enabled) {
            try lod.update(&arena, &world, camera.position, world_config, .{
                .max_level = @intCast(settings.lod_levels),
                .root_radius = settings.lod_root_radius,
                .split_dist = settings.lod_split_dist,
                .build_budget = @intCast(settings.lod_budget),
            }, frame_counter);
        } else if (lod.tiles.count() > 0) {
            try lod.clear(&arena, frame_counter);
        }

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
        // near to far, so the chunks fill the depth buffer before the distant terrain
        world.draw(cmd, &voxel, camera.position, frustum, world_config, if (settings.lod_enabled) &lod.columns else null);
        if (settings.lod_enabled) lod.draw(cmd, &voxel, camera.position, frustum);
        if (settings.skybox) sky_pipeline.draw(cmd, &voxel, frame_index, &camera, settings.fov_deg, aspect);
        outline.bind(cmd, &voxel, frame_index);
        if (target) |hit| {
            const corner: @Vector(3, f64) = .{ @floatFromInt(hit.block[0]), @floatFromInt(hit.block[1]), @floatFromInt(hit.block[2]) };
            const rel: math.Vec3 = @floatCast(corner - camera.position);
            outline.drawBlock(cmd, rel);
        }
        if (captured) outline.drawCrosshair(cmd, swapchain.extent);

        // dvui draws on top, inside the same rendering scope
        try renderer.beginFrame(cmd, swapchain.extent);
        try win.begin(backend.nanoTime());
        const actions = debug_ui.draw(&settings, &player, .{
            .frame_ms = frame_ms,
            .camera = &camera,
            .world = world.stats,
            .lod = lod.stats,
            .arena_used = arena.used,
            .arena_capacity = arena.capacity,
            .target = target,
            .selected = BlockId.placeable[selected],
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

        if (actions.regenerate) {
            try world.regenerate(&arena, settings.seed, frame_counter);
            try lod.clear(&arena, frame_counter);
        }
        if (bench) |*b| if (b.frame(&world.stats, &lod.stats, dt_ms, now_ns)) break :main_loop;

        frame_counter += 1;
    }
}

/// SDL3 only `dlopen`s leaf names ("libvulkan.1.dylib", ...) when hunting for the Vulkan
/// loader, and modern dyld no longer searches /usr/local/lib for those, so a LunarG or
/// Homebrew install is never found. Load it from an absolute path ourselves;
/// `SDL_CreateWindow` then reuses the already-loaded library. Returns whether we loaded it.
fn loadVulkanLibrary(environ: *std.process.Environ.Map) bool {
    if (builtin.os.tag != .macos) return false;
    // SDL reads this hint from the environment itself, so let an explicit override win.
    if (environ.get("SDL_VULKAN_LIBRARY") != null) return false;

    if (environ.get("VULKAN_SDK")) |sdk| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrintZ(&buf, "{s}/lib/libvulkan.1.dylib", .{sdk})) |path| {
            if (c.SDL_Vulkan_LoadLibrary(path.ptr)) {
                log.info("loaded Vulkan loader from {s}", .{path});
                return true;
            }
        } else |_| {}
    }

    // A loader is preferred over MoltenVK directly, since it provides the validation
    // layers. Homebrew comes first: it is rolling, while the LunarG system install is a
    // one-shot that tends to go stale, and a MoltenVK below 1.3 only reports Vulkan 1.2
    // and gets rejected by `pickPhysicalDevice`.
    const candidates = [_][*:0]const u8{
        "/opt/homebrew/lib/libvulkan.1.dylib", // brew install vulkan-loader
        "/usr/local/lib/libvulkan.1.dylib", // LunarG SDK, system-global install
        "/opt/homebrew/lib/libMoltenVK.dylib", // brew install molten-vk
        "/usr/local/lib/libMoltenVK.dylib",
    };
    for (candidates) |path| {
        if (c.SDL_Vulkan_LoadLibrary(path)) {
            log.info("loaded Vulkan loader from {s}", .{path});
            return true;
        }
    }

    // fall through: let SDL_CreateWindow try its own defaults and report its own error
    log.warn("no Vulkan loader found; install the Vulkan SDK or set SDL_VULKAN_LIBRARY", .{});
    return false;
}

/// `--bench[=render_distance]`: loads the world around a fixed camera with vsync off,
/// then measures steady-state frames, prints the results and exits (printed rather
/// than logged so it also shows in release builds).
const Bench = struct {
    const steady_frames = 600;

    load_start_ns: ?i128 = null,
    load_ms: f64 = 0,
    frames: u32 = 0,
    frame_ms: f64 = 0,
    update_ms: f64 = 0,
    draw_ms: f64 = 0,

    /// Returns true once the benchmark is done.
    fn frame(self: *Bench, stats: *const World.Stats, lod: *const Lod.Stats, dt_ms: f32, now_ns: i128) bool {
        const start = self.load_start_ns orelse {
            self.load_start_ns = now_ns;
            return false;
        };
        if (self.frames == 0 and self.load_ms == 0) {
            const loading = stats.pending > 0 or stats.generated_this_frame > 0 or stats.meshed_this_frame > 0 or lod.pending > 0 or lod.built_this_frame > 0;
            if (loading) return false;
            self.load_ms = @as(f64, @floatFromInt(now_ns - start)) / std.time.ns_per_ms;
            return false;
        }
        self.frames += 1;
        self.frame_ms += dt_ms;
        self.update_ms += stats.update_ms + lod.update_ms;
        self.draw_ms += stats.draw_ms + lod.draw_ms;
        if (self.frames < steady_frames) return false;

        const n: f64 = steady_frames;
        std.debug.print("bench: loaded {d} chunks ({d} meshed, {d} drawn, {d:.2} M vertices) in {d:.0} ms\n", .{
            stats.loaded, stats.meshed, stats.drawn, @as(f64, @floatFromInt(stats.drawn_vertices)) / 1e6, self.load_ms,
        });
        std.debug.print("bench: distant terrain {d} tiles ({d} leaves, {d} drawn, {d:.2} M vertices)\n", .{
            lod.tiles, lod.leaves, lod.drawn, @as(f64, @floatFromInt(lod.drawn_vertices)) / 1e6,
        });
        const gen_us = debug_ui.perChunkUs(stats.gen_total_ns, stats.gen_total);
        const mesh_us = debug_ui.perChunkUs(stats.mesh_total_ns, stats.mesh_total);
        const gen_ms = @as(f64, @floatFromInt(stats.gen_total_ns)) / std.time.ns_per_ms;
        const mesh_ms = @as(f64, @floatFromInt(stats.mesh_total_ns)) / std.time.ns_per_ms;
        std.debug.print("bench: gen {d} chunks, {d:.1} us/chunk ({d:.0} ms total)\n", .{ stats.gen_total, gen_us, gen_ms });
        std.debug.print("bench: mesh {d} chunks ({d} buried), {d:.1} us/chunk ({d:.0} ms total)\n", .{ stats.mesh_total, stats.mesh_skipped, mesh_us, mesh_ms });
        std.debug.print("bench: steady frame {d:.3} ms, update {d:.3} ms, draw record {d:.3} ms\n", .{ self.frame_ms / n, self.update_ms / n, self.draw_ms / n });
        return true;
    }
};

fn loadSkybox(assets: *const Assets, uploader: Texture.Uploader) !Texture {
    // Vulkan cube layer order: +X, -X, +Y, -Y, +Z, -Z
    const names = [6][]const u8{ "right", "left", "top", "bottom", "front", "back" };
    var faces: [6][]const u8 = undefined;
    var loaded: usize = 0;
    defer for (faces[0..loaded]) |face| assets.gpa.free(face);
    for (names, &faces) |name, *face| {
        var buf: [64]u8 = undefined;
        face.* = try assets.read(try std.fmt.bufPrint(&buf, "textures/skybox/{s}.jpg", .{name}));
        loaded += 1;
    }
    return Texture.initCube(uploader, faces);
}

fn playerInput(settings: *const Settings) Player.Input {
    const keys = c.SDL_GetKeyboardState(null);
    var input: Player.Input = .{ .fly_speed = settings.move_speed };
    if (keys[c.SDL_SCANCODE_D]) input.right += 1;
    if (keys[c.SDL_SCANCODE_A]) input.right -= 1;
    if (keys[c.SDL_SCANCODE_W]) input.forward += 1;
    if (keys[c.SDL_SCANCODE_S]) input.forward -= 1;
    if (keys[c.SDL_SCANCODE_SPACE]) input.up += 1;
    if (keys[c.SDL_SCANCODE_LCTRL]) input.up -= 1;
    input.jump = keys[c.SDL_SCANCODE_SPACE];
    input.sprint = keys[c.SDL_SCANCODE_LSHIFT];
    return input;
}

/// Captures or releases the mouse; returns the new state.
fn setCaptured(window: *c.SDL_Window, capture: bool) bool {
    _ = c.SDL_SetWindowRelativeMouseMode(window, capture);
    return capture;
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
        .params = .{ fog[0], fog[1], if (settings.ao_enabled) settings.ao_strength else 0, if (settings.skybox) 1 else 0 },
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
