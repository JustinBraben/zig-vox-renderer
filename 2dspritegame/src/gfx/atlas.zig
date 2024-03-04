const Sprite = @import("sprite.zig").Sprite;
const Animation = @import("animation.zig").Animation;

pub const Atlas = struct {
    sprites: []Sprite,
    animations: []Animation,
};