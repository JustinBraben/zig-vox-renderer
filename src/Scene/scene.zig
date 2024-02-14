pub const Scene = struct {
    const Self = @This();

    z_near: f32 = 0.1,
    z_far: f32 = 1000.0,
    delta_time: f32,

    is_menu_open: bool,
    show_intermediate_textures: bool,
};