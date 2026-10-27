//! Root for `zig build test`: pulls in the modules that have no GPU/SDL dependencies.

test {
    _ = @import("math.zig");
    _ = @import("player.zig");
    _ = @import("world/chunk.zig");
    _ = @import("world/terrain.zig");
    _ = @import("world/mesher.zig");
    _ = @import("world/raycast.zig");
    _ = @import("world/lod.zig");
    _ = @import("world/light.zig");
    _ = @import("world/world.zig");
    _ = @import("world/workers.zig");
    _ = @import("world/save.zig");
}
