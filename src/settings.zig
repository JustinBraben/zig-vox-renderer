//! Everything tweakable from the debug UI. Colors are sRGB.

pub const Settings = struct {
    vsync: bool = true,
    show_demo: bool = false,

    // camera
    fov_deg: f32 = 70,
    move_speed: f32 = 24,
    mouse_sensitivity: f32 = 0.12,

    // lighting
    sun_azimuth: f32 = 35,
    sun_elevation: f32 = 45,
    sun_color: [3]f32 = .{ 1.0, 0.94, 0.82 },
    sun_intensity: f32 = 1.1,
    sky_color: [3]f32 = .{ 0.62, 0.76, 0.92 },
    ground_color: [3]f32 = .{ 0.55, 0.50, 0.44 },
    ambient_intensity: f32 = 0.9,
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

    /// fog (start, end) in blocks, or null when disabled
    pub fn fogRange(self: *const Settings) ?[2]f32 {
        if (!self.fog_enabled) return null;
        if (self.fog_auto) {
            const end: f32 = @floatFromInt(self.render_distance * 32);
            return .{ end * 0.45, end - 8 };
        }
        return .{ self.fog_start, @max(self.fog_end, self.fog_start + 1) };
    }
};
