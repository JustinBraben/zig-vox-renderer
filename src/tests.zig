//! Root for `zig build test`: pulls in the modules that have no GPU/SDL dependencies.

test {
    _ = @import("math.zig");
    _ = @import("player.zig");
    _ = @import("world/chunk.zig");
    _ = @import("world/terrain.zig");
    _ = @import("world/mesher.zig");
    _ = @import("world/raycast.zig");
}
