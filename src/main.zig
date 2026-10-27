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
const OverlayPipeline = @import("gfx/overlay_pipeline.zig");
const sprites = @import("gfx/sprites.zig");
const Texture = @import("gfx/texture.zig");
const Assets = @import("assets.zig");
const World = @import("world/world.zig");
const Lod = @import("world/lod.zig");
const Tile = @import("world/block.zig").Tile;
const raycast = @import("world/raycast.zig");
const Player = @import("player.zig");
const Camera = @import("camera.zig");
const Settings = @import("settings.zig").Settings;
const debug_ui = @import("ui/debug_ui.zig");
const hud = @import("ui/hud.zig");
const Game = @import("game/game.zig");
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

    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO)) {
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

    var wave_spec: c.SDL_AudioSpec = .{};
    var wave_sound: ?[*]u8 = null;
    var wave_soundlen: u32 = 0;
    var stream: *c.SDL_AudioStream = undefined;
    const audio_sample_path = "./assets/audio/MouthPop_AP1.1188.wav";

    if (!c.SDL_LoadWAV(audio_sample_path, &wave_spec, &wave_sound, &wave_soundlen)) {
        log.err("SDL_LoadWAV failed: {s}, with file: {s}", .{ c.SDL_GetError(), audio_sample_path });
        return error.SdlAudioFailed;
    }
    defer c.SDL_free(@ptrCast(wave_sound));

    stream = c.SDL_OpenAudioDeviceStream(
        c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
        &wave_spec,
        null,
        null,
    ) orelse {
        log.err("Failed to open audio stream: {s}", .{c.SDL_GetError()});
        return error.SdlAudioFailed;
    };
    defer c.SDL_DestroyAudioStream(stream);
    _ = c.SDL_SetAudioStreamGain(stream, settings.master_volume);

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

    const uploader: Texture.Uploader = .{
        .device = device,
        .memory = memory,
        .queue = ctx.graphics_queue,
        .command_pool = command_pool,
    };
    var sky_texture = try loadSkybox(&assets, uploader);
    defer sky_texture.deinit();

    var block_textures = try loadBlockTextures(&assets, uploader);
    defer block_textures.deinit();

    var voxel = try VoxelPipeline.init(device, memory, &assets, &sky_texture, &block_textures, swapchain.surface_format.format, DepthBuffer.format, frames_in_flight);
    defer voxel.deinit();

    var sky_pipeline = try SkyPipeline.init(device, &assets, &voxel, swapchain.surface_format.format, DepthBuffer.format);
    defer sky_pipeline.deinit();

    var outline = try OutlinePipeline.init(device, &assets, &voxel, swapchain.surface_format.format, DepthBuffer.format);
    defer outline.deinit();

    var overlay = try OverlayPipeline.init(device, memory, &assets, &voxel, swapchain.surface_format.format, DepthBuffer.format, frames_in_flight);
    defer overlay.deinit();

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
    world.startWorkers(World.defaultWorkerCount());
    // the benchmark always starts from fresh terrain, and doesn't save
    const saves_dir: ?std.Io.Dir = if (bench == null) openSavesDir(init.io, gpa) else null;
    defer if (saves_dir) |dir| dir.close(init.io);
    if (saves_dir) |dir| world.openSave(dir) catch |err| log.err("opening the saved world failed: {t}; edits won't be saved", .{err});
    var lod = Lod.init(gpa, init.io);
    defer lod.deinit();

    // stand on the terrain at the origin; the benchmark flies high above it instead
    var game = Game.init(gpa, spawnPoint(&world));
    defer game.deinit();
    var player = Player.init(game.spawn);
    var camera: Camera = .{ .position = player.eye(1) };
    if (bench != null) {
        game.setMode(.creative, &player);
        player = .init(game.spawn + @Vector(3, f64){ 0, 40, 0 });
        player.setFlying(true);
        camera.position = player.eye(1);
    } else {
        restorePlayer(&world, &player, &camera, &settings, &game);
    }
    // saved again on the way out, and every `autosave_interval_ns`
    defer saveGame(&world, &player, &camera, &settings, &game);
    var last_save_ns = backend.nanoTime();
    var physics_time: f64 = 0;
    var target: ?raycast.Hit = null;

    // wait for the GPU before any of the deferred destruction above runs
    defer device.deviceWaitIdle() catch {};

    var frame_counter: u64 = 0;
    var needs_recreate = false;
    // mouse captured for playing; released for the UI
    var captured = false;
    // left button: clicked this frame (creative breaks), held (survival digs)
    var break_click = false;
    var break_held = false;
    var place_block = false;
    var pick_block = false;
    var throw_block = false;
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
                        break_click = true;
                        break_held = true;
                    } else if (event.button.button == c.SDL_BUTTON_RIGHT) {
                        place_block = true;
                    } else if (event.button.button == c.SDL_BUTTON_MIDDLE) {
                        pick_block = true;
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => if (event.button.button == c.SDL_BUTTON_LEFT) {
                    break_held = false;
                },
                c.SDL_EVENT_MOUSE_MOTION => if (captured) {
                    camera.look(event.motion.xrel, event.motion.yrel, settings.mouse_sensitivity);
                },
                c.SDL_EVENT_MOUSE_WHEEL => if (captured and event.wheel.y != 0) {
                    game.inventory.scroll(if (event.wheel.y < 0) 1 else -1);
                },
                c.SDL_EVENT_KEY_DOWN => if (captured and !event.key.repeat) {
                    const sc = event.key.scancode;
                    if (sc == c.SDL_SCANCODE_ESCAPE) {
                        captured = setCaptured(window, false);
                    } else if (sc == c.SDL_SCANCODE_F) {
                        if (game.mode == .creative) player.setFlying(!player.flying);
                    } else if (sc == c.SDL_SCANCODE_G) {
                        game.setMode(if (game.mode == .creative) .survival else .creative, &player);
                    } else if (sc == c.SDL_SCANCODE_Q) {
                        throw_block = true;
                    } else if (sc >= c.SDL_SCANCODE_1 and sc <= c.SDL_SCANCODE_9) {
                        game.inventory.selected = @intCast(sc - c.SDL_SCANCODE_1);
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
        if (settings.day_cycle) {
            const hours = @min(dt_ms, 250) / 1000 / (settings.day_minutes * 60) * 24;
            settings.time_of_day = @mod(settings.time_of_day + hours, 24);
        }
        while (physics_time >= physics_dt) : (physics_time -= physics_dt) {
            player.step(&world, input, camera.yaw, camera.pitch, physics_dt);
            _ = game.step(&world, &player, physics_dt);
        }
        camera.position = player.eye(physics_time / physics_dt);
        if (!captured) break_held = false;

        // block interaction
        target = raycast.cast(&world, camera.position, camera.forward(), reach);
        var changed = false;
        if (try game.dig(&world, target, break_held, break_click, @min(dt_ms, 250) / 1000)) {
            changed = true;
            _ = c.SDL_PutAudioStreamData(stream, wave_sound, @intCast(wave_soundlen));
            _ = c.SDL_ResumeAudioDevice(c.SDL_GetAudioStreamDevice(stream));
        }
        if (target) |hit| {
            if (place_block and !changed) changed = try game.place(&world, &player, hit);
            if (pick_block) game.pick(hit);
        }
        if (throw_block) try game.throwHeld(&player, camera.forward());
        if (changed) target = raycast.cast(&world, camera.position, camera.forward(), reach);
        break_click = false;
        place_block = false;
        pick_block = false;
        throw_block = false;

        const world_config: World.Config = .{
            .render_distance = settings.render_distance,
            .min_y = settings.min_chunk_y,
            .max_y = settings.max_chunk_y,
            .gen_budget = @intCast(settings.gen_budget),
            .mesh_budget = @intCast(settings.mesh_budget),
        };
        world.setFastLeaves(settings.fast_leaves);
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
        const eye_block = [3]i32{ @intFromFloat(@floor(camera.position[0])), @intFromFloat(@floor(camera.position[1])), @intFromFloat(@floor(camera.position[2])) };
        const underwater = world.isWater(eye_block[0], eye_block[1], eye_block[2]);
        voxel.setScene(frame_index, sceneUniforms(&settings, view_proj, underwater));

        // overlays: dropped items, the crack on the block being broken, the HUD
        var batch = overlay.batch(frame_index);
        game.items.draw(&batch, camera.position, physics_time / physics_dt, ItemLight{ .world = &world, .daylight = settings.daylight() });
        const items_range = batch.since(0);
        const crack_first = batch.len;
        if (game.crack()) |crack| {
            const center: @Vector(3, f64) = .{ @as(f64, @floatFromInt(crack.block[0])) + 0.5, @as(f64, @floatFromInt(crack.block[1])) + 0.5, @as(f64, @floatFromInt(crack.block[2])) + 0.5 };
            const rel: math.Vec3 = @floatCast(center - camera.position);
            // a little larger than the block, so it doesn't z-fight with its faces
            batch.cube(rel, 0.502, 0, @splat(@intFromEnum(Tile.crack(crack.stage))), @splat(sprites.white));
        }
        const crack_range = batch.since(crack_first);
        const hud_first = batch.len;
        if (bench == null) hud.build(&batch, @floatFromInt(swapchain.extent.width), @floatFromInt(swapchain.extent.height), .{
            .inventory = &game.inventory,
            .survival = game.mode == .survival,
            .health = game.health,
            .max_health = Game.max_health,
            .hurt = game.hurt_timer / Game.hurt_seconds,
        });
        const hud_range = batch.since(hud_first);

        // record
        const cmd = frame.cmd;
        try device.resetCommandBuffer(cmd, .{});
        try device.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });

        transitionImage(device, cmd, swapchain.images[image_index], .undefined, .color_attachment_optimal);
        depth.transition(cmd);

        // the clear color is written as is (sRGB): scale it roughly like the linear sky
        const sky_scale = std.math.pow(f32, skyBrightness(&settings), 1.0 / 2.2);
        const sky = [3]f32{ settings.sky_color[0] * sky_scale, settings.sky_color[1] * sky_scale, settings.sky_color[2] * sky_scale };
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

        voxel.bind(cmd, frame_index, swapchain.extent, &arena, .solid);
        const frustum: ?math.Frustum = if (settings.frustum_culling) .fromViewProj(view_proj) else null;
        // near to far, so the chunks fill the depth buffer before the distant terrain
        world.draw(cmd, &voxel, camera.position, frustum, world_config, if (settings.lod_enabled) &lod.columns else null);
        if (settings.lod_enabled) lod.draw(cmd, &voxel, camera.position, frustum);
        overlay.draw(cmd, &voxel, frame_index, swapchain.extent, .world, items_range);
        if (settings.skybox) sky_pipeline.draw(cmd, &voxel, frame_index, &camera, settings.fov_deg, aspect);
        // blended last, over the sky too
        voxel.bind(cmd, frame_index, swapchain.extent, &arena, .translucent);
        world.drawTranslucent(cmd, &voxel);
        overlay.draw(cmd, &voxel, frame_index, swapchain.extent, .decal, crack_range);
        outline.bind(cmd, &voxel, frame_index);
        if (target) |hit| {
            const corner: @Vector(3, f64) = .{ @floatFromInt(hit.block[0]), @floatFromInt(hit.block[1]), @floatFromInt(hit.block[2]) };
            const rel: math.Vec3 = @floatCast(corner - camera.position);
            outline.drawBlock(cmd, rel);
        }
        if (captured) outline.drawCrosshair(cmd, swapchain.extent);
        overlay.draw(cmd, &voxel, frame_index, swapchain.extent, .screen, hud_range);

        // dvui draws on top, inside the same rendering scope
        try renderer.beginFrame(cmd, swapchain.extent);
        try win.begin(backend.nanoTime());
        const actions = debug_ui.draw(&settings, &player, &game, .{
            .frame_ms = frame_ms,
            .camera = &camera,
            .world = world.stats,
            .lod = lod.stats,
            .arena_used = arena.used,
            .arena_capacity = arena.capacity,
            .target = target,
            .target_light = if (target) |hit| blk: {
                const p = hit.adjacent();
                break :blk world.getLight(p[0], p[1], p[2]);
            } else null,
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
            // the player stays with the world it was in, and returns to where it was in the new one
            saveGame(&world, &player, &camera, &settings, &game);
            try world.regenerate(&arena, settings.seed, frame_counter);
            try lod.clear(&arena, frame_counter);
            game.spawn = spawnPoint(&world);
            restorePlayer(&world, &player, &camera, &settings, &game);
            last_save_ns = now_ns;
        }
        if (now_ns - last_save_ns > autosave_interval_ns) {
            saveGame(&world, &player, &camera, &settings, &game);
            last_save_ns = now_ns;
        }
        if (actions.volume_changed) _ = c.SDL_SetAudioStreamGain(stream, settings.master_volume);
        if (bench) |*b| if (b.frame(&world.stats, &lod.stats, dt_ms, now_ns)) break :main_loop;

        frame_counter += 1;
    }
}

const autosave_interval_ns = 30 * std.time.ns_per_s;

/// `saves/` next to the executable, created when missing; null (logged) when that fails.
fn openSavesDir(io: std.Io, gpa: std.mem.Allocator) ?std.Io.Dir {
    const exe_path = std.process.executableDirPathAlloc(io, gpa) catch |err| {
        log.err("finding the executable's folder failed: {t}; the world won't be saved", .{err});
        return null;
    };
    defer gpa.free(exe_path);
    const exe_dir = std.Io.Dir.openDirAbsolute(io, exe_path, .{}) catch |err| {
        log.err("opening {s} failed: {t}; the world won't be saved", .{ exe_path, err });
        return null;
    };
    defer exe_dir.close(io);
    exe_dir.createDirPath(io, "saves") catch {};
    const dir = exe_dir.openDir(io, "saves", .{}) catch |err| {
        log.err("opening {s}/saves failed: {t}; the world won't be saved", .{ exe_path, err });
        return null;
    };
    log.info("saving worlds in {s}/saves", .{exe_path});
    return dir;
}

/// Writes the edited chunks and the player; failures are logged, not fatal.
fn saveGame(world: *World, player: *const Player, camera: *const Camera, settings: *const Settings, game: *const Game) void {
    world.saveAll() catch |err| log.err("saving the world failed: {t}", .{err});
    world.savePlayer(.{
        .position = player.position,
        .yaw = camera.yaw,
        .pitch = camera.pitch,
        .flying = player.flying,
        .time_of_day = settings.time_of_day,
        .creative = game.mode == .creative,
        .health = game.health,
        .inventory = game.inventory,
    }) catch |err| log.err("saving the player failed: {t}", .{err});
}

/// Puts the player where the world's save left it, or at the spawn point with an empty
/// hotbar in a new world (keeping the game mode).
fn restorePlayer(world: *World, player: *Player, camera: *Camera, settings: *Settings, game: *Game) void {
    game.items.items.clearRetainingCapacity();
    game.mining = null;
    game.hurt_timer = 0;
    const saved = world.savedPlayer() orelse {
        player.* = .init(game.spawn);
        camera.position = player.eye(1);
        game.health = Game.max_health;
        game.inventory = .{};
        game.setMode(game.mode, player);
        return;
    };
    player.* = .init(saved.position);
    camera.yaw = saved.yaw;
    camera.pitch = saved.pitch;
    camera.position = player.eye(1);
    settings.time_of_day = saved.time_of_day;
    game.health = if (saved.health == 0) Game.max_health else @min(saved.health, Game.max_health);
    game.inventory = saved.inventory;
    game.setMode(if (saved.creative) .creative else .survival, player);
    if (game.mode == .creative) player.setFlying(saved.flying);
}

/// On the terrain at the origin.
fn spawnPoint(world: *const World) @Vector(3, f64) {
    return .{ 0.5, @floatFromInt(world.terrain.height(0, 0) + 1), 0.5 };
}

/// Brightness of dropped items from the light where they are, like the chunk shader's.
const ItemLight = struct {
    world: *const World,
    daylight: f32,

    pub fn at(self: ItemLight, p: @Vector(3, f64)) f32 {
        const x: i32 = @intFromFloat(@floor(p[0]));
        const y: i32 = @intFromFloat(@floor(p[1] + 0.1));
        const z: i32 = @intFromFloat(@floor(p[2]));
        const light = self.world.getLight(x, y, z) orelse 0xf0;
        const sky = @as(f32, @floatFromInt(light >> 4)) / 15 * std.math.lerp(night_ambient, 1, self.daylight);
        const block = @as(f32, @floatFromInt(light & 0xf)) / 15;
        const level = @max(sky, block);
        return 0.05 + 0.95 * level / (4 - 3 * level);
    }
};

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
            const loading = stats.pending > 0 or stats.gen_jobs > 0 or stats.mesh_jobs > 0 or stats.generated_this_frame > 0 or stats.meshed_this_frame > 0 or lod.pending > 0 or lod.built_this_frame > 0;
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

fn loadBlockTextures(assets: *const Assets, uploader: Texture.Uploader) !Texture {
    const atlas = try assets.read("textures/blocks.png");
    defer assets.gpa.free(atlas);
    return Texture.initAtlas(uploader, atlas, 16, Tile.count);
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

/// Fog color and distance (in blocks) with the camera underwater.
const underwater_fog_color = [3]f32{ 0.02, 0.08, 0.2 };
const underwater_fog_end = 24;

/// Brightness of the sky and the ambient light at night, relative to the day.
const night_sky = 0.05;
const night_ambient = 0.08;

fn skyBrightness(settings: *const Settings) f32 {
    return std.math.lerp(night_sky, 1, settings.daylight());
}

fn sceneUniforms(settings: *const Settings, view_proj: math.Mat4, underwater: bool) VoxelPipeline.Scene {
    const sun_dir = math.fromDirection(settings.sunAzimuth(), settings.sunElevation());
    const fog = settings.fogRange() orelse .{ 0, 0 };
    const sky = skyBrightness(settings);
    const ambient = settings.ambient_intensity * std.math.lerp(night_ambient, 1, settings.daylight());
    if (underwater) {
        var scene = sceneUniforms(settings, view_proj, false);
        scene.fog_color = .{ underwater_fog_color[0] * sky, underwater_fog_color[1] * sky, underwater_fog_color[2] * sky, 1 };
        scene.params[0] = 0;
        scene.params[1] = underwater_fog_end;
        // flat fog color instead of the skybox
        scene.params[3] = 0;
        return scene;
    }
    return .{
        .view_proj = view_proj,
        .sun_dir = .{ sun_dir[0], sun_dir[1], sun_dir[2], 0 },
        .sun_color = linearColor(settings.sun_color, settings.sun_intensity * settings.sunlight()),
        .sky_color = linearColor(settings.sky_color, ambient),
        .ground_color = linearColor(settings.ground_color, ambient),
        .fog_color = linearColor(settings.sky_color, sky),
        .params = .{ fog[0], fog[1], if (settings.ao_enabled) settings.ao_strength else 0, if (settings.skybox) 1 else 0 },
        .light = blk: {
            var light = linearColor(settings.block_light_color, settings.block_light_intensity);
            light[3] = sky;
            break :blk light;
        },
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
