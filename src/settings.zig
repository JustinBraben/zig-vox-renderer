//! Everything tweakable from the debug UI. Colors are sRGB.

const std = @import("std");

pub const Settings = struct {
    vsync: bool = true,
    show_demo: bool = false,

    // camera
    fov_deg: f32 = 70,
    /// fly mode speed, blocks per second
    move_speed: f32 = 24,
    mouse_sensitivity: f32 = 0.12,

    // lighting
    /// draw the skybox and fade fog into it; otherwise the sky is `sky_color`
    skybox: bool = true,
    /// hours, 0..24; the sun is at `sun_azimuth`, `sun_elevation` at noon
    time_of_day: f32 = 12,
    /// advance `time_of_day`, one day every `day_minutes`
    day_cycle: bool = false,
    day_minutes: f32 = 10,
    sun_azimuth: f32 = 35,
    sun_elevation: f32 = 45,
    sun_color: [3]f32 = .{ 1.0, 0.94, 0.82 },
    sun_intensity: f32 = 1.1,
    sky_color: [3]f32 = .{ 0.62, 0.76, 0.92 },
    ground_color: [3]f32 = .{ 0.55, 0.50, 0.44 },
    ambient_intensity: f32 = 0.9,
    /// light given off by lamps
    block_light_color: [3]f32 = .{ 1.0, 0.85, 0.62 },
    block_light_intensity: f32 = 1.3,
    ao_enabled: bool = true,
    ao_strength: f32 = 1.0,
    fog_enabled: bool = true,
    /// derive fog start/end from the render distance
    fog_auto: bool = true,
    fog_start: f32 = 120,
    fog_end: f32 = 250,

    // world
    render_distance: i32 = 8,
    min_chunk_y: i32 = 0,
    max_chunk_y: i32 = 3,
    seed: u64 = 1337,
    gen_budget: i32 = 16,
    mesh_budget: i32 = 8,
    frustum_culling: bool = true,
    /// leaves drawn solid, without the faces between them (cheaper)
    fast_leaves: bool = false,

    // distant terrain
    lod_enabled: bool = true,
    /// coarsest level; a level-k cell is 2^k blocks wide
    lod_levels: i32 = 6,
    /// root tiles in each direction around the camera
    lod_root_radius: i32 = 3,
    /// tiles split when closer than this many of their own widths
    lod_split_dist: i32 = 3,
    lod_budget: i32 = 8,

    master_volume: f32 = 0.5,

    /// Sun azimuth at `time_of_day`, in degrees: 15 per hour.
    pub fn sunAzimuth(self: *const Settings) f32 {
        return self.sun_azimuth + (self.time_of_day - 12) * 15;
    }

    /// Sun elevation at `time_of_day`, in degrees: rising at 6, `sun_elevation` at noon,
    /// setting at 18 and as far below the horizon at midnight.
    pub fn sunElevation(self: *const Settings) f32 {
        return self.sun_elevation * @sin(std.math.pi * (self.time_of_day - 6) / 12);
    }

    /// 1 by day, 0 by night, ramping up through dawn and down through dusk.
    pub fn daylight(self: *const Settings) f32 {
        return smoothstep(-6, 10, self.sunElevation());
    }

    /// Sunlight reaching the ground: none once the sun is below the horizon.
    pub fn sunlight(self: *const Settings) f32 {
        return smoothstep(-2, 6, self.sunElevation());
    }

    /// guaranteed view distance in blocks: the voxel chunks, or the distant terrain when enabled
    pub fn viewDistance(self: *const Settings) f32 {
        const chunks: f32 = @floatFromInt(self.render_distance * 32);
        if (!self.lod_enabled) return chunks;
        const lod: f32 = @floatFromInt(self.lod_root_radius * (@as(i32, 32) << @intCast(self.lod_levels)));
        return @max(chunks, lod);
    }

    /// fog (start, end) in blocks, or null when disabled
    pub fn fogRange(self: *const Settings) ?[2]f32 {
        if (!self.fog_enabled) return null;
        if (self.fog_auto) {
            const end = self.viewDistance();
            return .{ end * 0.45, end - 8 };
        }
        return .{ self.fog_start, @max(self.fog_end, self.fog_start + 1) };
    }
};

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0, 1);
    return t * t * (3 - 2 * t);
}
