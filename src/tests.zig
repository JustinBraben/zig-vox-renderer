//! Root for `zig build test`. The `world` and `game` namespaces pull in all their
//! files' tests; `gfx` and `ui` need Vulkan, SDL or dvui for most of their files,
//! so only the parts without those are referenced.

test {
    _ = @import("math.zig");
    _ = @import("Player.zig");
    _ = @import("world.zig");
    _ = @import("game.zig");
    _ = @import("gfx.zig").sprites;
    _ = @import("ui.zig").hud;
}
