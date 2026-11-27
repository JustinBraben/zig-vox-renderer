//! Root for `zig build test`: pulls in the modules that have no GPU/SDL dependencies.

test {
    _ = @import("math.zig");
    _ = @import("Player.zig");
    _ = @import("world/Chunk.zig");
    _ = @import("world/Terrain.zig");
    _ = @import("world/worms.zig");
    _ = @import("world/mesher.zig");
    _ = @import("world/raycast.zig");
    _ = @import("world/Lod.zig");
    _ = @import("world/light.zig");
    _ = @import("world/World.zig");
    _ = @import("world/Pool.zig");
    _ = @import("world/Save.zig");
    _ = @import("gfx/sprites.zig");
    _ = @import("ui/hud.zig");
    _ = @import("game/Inventory.zig");
    _ = @import("game/Items.zig");
    _ = @import("game/Game.zig");
}
