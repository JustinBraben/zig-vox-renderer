//! The "Renderer" debug window: stats plus every tweakable setting.

const std = @import("std");
const dvui = @import("dvui");

const Settings = @import("../settings.zig").Settings;
const Camera = @import("../camera.zig");
const World = @import("../world/world.zig");
const ChunkPos = @import("../world/chunk.zig").ChunkPos;
const BlockId = @import("../world/block.zig").BlockId;
const raycast = @import("../world/raycast.zig");
const Player = @import("../player.zig");

pub const Stats = struct {
    frame_ms: f32,
    camera: *const Camera,
    world: World.Stats,
    arena_used: u32,
    arena_capacity: u32,
    /// block under the crosshair
    target: ?raycast.Hit,
    selected: BlockId,
};

pub const Actions = struct {
    regenerate: bool = false,
};

pub fn draw(settings: *Settings, player: *Player, stats: Stats) Actions {
    var actions: Actions = .{};

    var float = dvui.floatingWindow(@src(), .{}, .{
        .min_size_content = .{ .w = 300, .h = 400 },
        .rect = .{ .x = 10, .y = 10, .w = 320, .h = 640 },
    });
    defer float.deinit();
    float.dragAreaSet(dvui.windowHeader("Renderer", "", null));

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    var box = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = .all(6) });
    defer box.deinit();

    if (dvui.expander(@src(), "Stats", .{ .default_expanded = true }, .{ .expand = .horizontal })) {
        var section = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 12 } });
        defer section.deinit();
        const fps = if (stats.frame_ms > 0) 1000.0 / stats.frame_ms else 0;
        dvui.label(@src(), "{d:.2} ms ({d:.0} fps)", .{ stats.frame_ms, fps }, .{});
        const p = stats.camera.position;
        const cp = ChunkPos.fromWorld(p);
        dvui.label(@src(), "pos {d:.1} {d:.1} {d:.1}", .{ p[0], p[1], p[2] }, .{});
        dvui.label(@src(), "chunk {d} {d} {d}", .{ cp.x, cp.y, cp.z }, .{});
        const w = stats.world;
        dvui.label(@src(), "chunks: {d} loaded, {d} meshed, {d} drawn", .{ w.loaded, w.meshed, w.drawn }, .{});
        dvui.label(@src(), "pending: {d}  (+{d} gen, +{d} mesh)", .{ w.pending, w.generated_this_frame, w.meshed_this_frame }, .{});
        dvui.label(@src(), "drawn vertices: {d:.2} M", .{@as(f64, @floatFromInt(w.drawn_vertices)) / 1e6}, .{});
        dvui.label(@src(), "cpu: update {d:.2} ms (gen {d:.2}, mesh {d:.2}), draw {d:.2} ms", .{ w.update_ms, w.gen_ms, w.mesh_ms, w.draw_ms }, .{});
        dvui.label(@src(), "avg: gen {d:.0} us/chunk, mesh {d:.0} us/chunk", .{ perChunkUs(w.gen_total_ns, w.gen_total), perChunkUs(w.mesh_total_ns, w.mesh_total) }, .{});
        const used_mib = @as(f64, @floatFromInt(stats.arena_used)) * 8 / (1 << 20);
        const cap_mib = @as(f64, @floatFromInt(stats.arena_capacity)) * 8 / (1 << 20);
        dvui.label(@src(), "mesh arena: {d:.1} / {d:.0} MiB{s}", .{ used_mib, cap_mib, if (w.arena_full) " (FULL)" else "" }, .{});
        _ = dvui.checkbox(@src(), &settings.vsync, "VSync", .{});
        _ = dvui.checkbox(@src(), &settings.show_demo, "dvui demo window", .{});
    }

    if (dvui.expander(@src(), "Player", .{ .default_expanded = true }, .{ .expand = .horizontal })) {
        var section = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 12 } });
        defer section.deinit();
        dvui.labelNoFmt(@src(), "Click the world to play, Esc to release the mouse", .{}, .{});
        dvui.labelNoFmt(@src(), "WASD: move, Space: jump / up, Ctrl: down, Shift: sprint", .{}, .{});
        dvui.labelNoFmt(@src(), "LMB: break, RMB: place, wheel / 1-9: block, F: fly", .{}, .{});
        const p = player.position;
        const v = player.velocity;
        dvui.label(@src(), "feet {d:.2} {d:.2} {d:.2}", .{ p[0], p[1], p[2] }, .{});
        dvui.label(@src(), "velocity {d:.2} {d:.2} {d:.2}{s}", .{ v[0], v[1], v[2], if (player.on_ground) " (on ground)" else "" }, .{});
        dvui.label(@src(), "selected: {s}", .{@tagName(stats.selected)}, .{});
        if (stats.target) |t| {
            dvui.label(@src(), "target: {s} at {d} {d} {d}, face {d} {d} {d}", .{ @tagName(t.id), t.block[0], t.block[1], t.block[2], t.normal[0], t.normal[1], t.normal[2] }, .{});
        } else {
            dvui.labelNoFmt(@src(), "target: none", .{}, .{});
        }
        var flying = player.flying;
        if (dvui.checkbox(@src(), &flying, "Fly (F)", .{})) player.setFlying(flying);
    }

    if (dvui.expander(@src(), "Camera", .{}, .{ .expand = .horizontal })) {
        var section = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 12 } });
        defer section.deinit();
        _ = dvui.sliderEntry(@src(), "FOV: {d:0.0}", .{ .value = &settings.fov_deg, .min = 30, .max = 120, .interval = 1 }, .{ .expand = .horizontal });
        _ = dvui.sliderEntry(@src(), "Fly speed: {d:0.0}", .{ .value = &settings.move_speed, .min = 1, .max = 200, .interval = 1 }, .{ .expand = .horizontal });
        _ = dvui.sliderEntry(@src(), "Mouse: {d:0.02}", .{ .value = &settings.mouse_sensitivity, .min = 0.01, .max = 0.5, .interval = 0.01 }, .{ .expand = .horizontal });
    }

    if (dvui.expander(@src(), "Lighting", .{ .default_expanded = true }, .{ .expand = .horizontal })) {
        var section = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 12 } });
        defer section.deinit();

        _ = dvui.checkbox(@src(), &settings.skybox, "Skybox", .{});

        heading(@src(), "Sun");
        _ = dvui.sliderEntry(@src(), "Azimuth: {d:0.0}", .{ .value = &settings.sun_azimuth, .min = 0, .max = 360, .interval = 1 }, .{ .expand = .horizontal });
        _ = dvui.sliderEntry(@src(), "Elevation: {d:0.0}", .{ .value = &settings.sun_elevation, .min = -10, .max = 90, .interval = 1 }, .{ .expand = .horizontal });
        _ = dvui.sliderEntry(@src(), "Intensity: {d:0.02}", .{ .value = &settings.sun_intensity, .min = 0, .max = 3 }, .{ .expand = .horizontal });
        colorSliders(@src(), &settings.sun_color);

        heading(@src(), "Ambient");
        _ = dvui.sliderEntry(@src(), "Intensity: {d:0.02}", .{ .value = &settings.ambient_intensity, .min = 0, .max = 2 }, .{ .expand = .horizontal });
        dvui.labelNoFmt(@src(), "Sky (also clear + fog color without skybox)", .{}, .{});
        colorSliders(@src(), &settings.sky_color);
        dvui.labelNoFmt(@src(), "Ground", .{}, .{});
        colorSliders(@src(), &settings.ground_color);

        heading(@src(), "Ambient occlusion");
        _ = dvui.checkbox(@src(), &settings.ao_enabled, "Enabled", .{});
        _ = dvui.sliderEntry(@src(), "Strength: {d:0.02}", .{ .value = &settings.ao_strength, .min = 0, .max = 1 }, .{ .expand = .horizontal });

        heading(@src(), "Fog");
        _ = dvui.checkbox(@src(), &settings.fog_enabled, "Enabled", .{});
        _ = dvui.checkbox(@src(), &settings.fog_auto, "Follow render distance", .{});
        if (!settings.fog_auto) {
            _ = dvui.sliderEntry(@src(), "Start: {d:0.0}", .{ .value = &settings.fog_start, .min = 0, .max = 1024, .interval = 1 }, .{ .expand = .horizontal });
            _ = dvui.sliderEntry(@src(), "End: {d:0.0}", .{ .value = &settings.fog_end, .min = 0, .max = 1024, .interval = 1 }, .{ .expand = .horizontal });
        }
    }

    if (dvui.expander(@src(), "World", .{ .default_expanded = true }, .{ .expand = .horizontal })) {
        var section = dvui.box(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 12 } });
        defer section.deinit();
        intSlider(@src(), "Render distance: {d:0.0}", &settings.render_distance, 0, 24);
        intSlider(@src(), "Min chunk y: {d:0.0}", &settings.min_chunk_y, -4, settings.max_chunk_y);
        intSlider(@src(), "Max chunk y: {d:0.0}", &settings.max_chunk_y, settings.min_chunk_y, 8);
        intSlider(@src(), "Gen / frame: {d:0.0}", &settings.gen_budget, 1, 128);
        intSlider(@src(), "Mesh / frame: {d:0.0}", &settings.mesh_budget, 1, 64);
        _ = dvui.checkbox(@src(), &settings.frustum_culling, "Frustum culling", .{});

        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            var seed: f32 = @floatFromInt(settings.seed);
            dvui.labelNoFmt(@src(), "Seed", .{}, .{ .gravity_y = 0.5 });
            if (dvui.textEntryNumber(@src(), f32, .{ .value = &seed, .min = 0, .max = 1e9 }, .{ .expand = .horizontal }).value == .Valid) {
                settings.seed = @intFromFloat(seed);
            }
        }
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            if (dvui.button(@src(), "Regenerate", .{}, .{})) actions.regenerate = true;
            if (dvui.button(@src(), "Random seed", .{}, .{})) {
                settings.seed = @as(u64, @truncate(@as(u128, @bitCast(dvui.frameTimeNS())))) % 1_000_000_000;
                actions.regenerate = true;
            }
            if (dvui.button(@src(), "Reset settings", .{}, .{})) {
                const seed = settings.seed;
                settings.* = .{};
                settings.seed = seed;
            }
        }
    }

    dvui.Examples.show_demo_window = settings.show_demo;
    dvui.Examples.demo(.lite);
    settings.show_demo = dvui.Examples.show_demo_window;

    return actions;
}

pub fn perChunkUs(total_ns: u64, count: u64) f64 {
    if (count == 0) return 0;
    return @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(count)) / std.time.ns_per_us;
}

fn heading(src: std.builtin.SourceLocation, text: []const u8) void {
    dvui.labelNoFmt(src, text, .{}, .{ .font = .theme(.heading), .margin = .{ .y = 4 } });
}

fn intSlider(src: std.builtin.SourceLocation, comptime label_fmt: []const u8, value: *i32, min: i32, max: i32) void {
    var f: f32 = @floatFromInt(value.*);
    if (dvui.sliderEntry(src, label_fmt, .{ .value = &f, .min = @floatFromInt(min), .max = @floatFromInt(max), .interval = 1 }, .{ .expand = .horizontal })) {
        value.* = std.math.clamp(@as(i32, @intFromFloat(@round(f))), min, max);
    }
}

fn colorSliders(src: std.builtin.SourceLocation, color: *[3]f32) void {
    var vbox = dvui.box(src, .{}, .{ .expand = .horizontal });
    defer vbox.deinit();
    _ = dvui.sliderEntry(@src(), "R: {d:0.2}", .{ .value = &color[0], .min = 0, .max = 1 }, .{ .expand = .horizontal });
    _ = dvui.sliderEntry(@src(), "G: {d:0.2}", .{ .value = &color[1], .min = 0, .max = 1 }, .{ .expand = .horizontal });
    _ = dvui.sliderEntry(@src(), "B: {d:0.2}", .{ .value = &color[2], .min = 0, .max = 1 }, .{ .expand = .horizontal });
}
