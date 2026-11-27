//! Gameplay rules on top of the world: creative/survival, digging and placing,
//! the inventory, and dropped items.

pub const Game = @import("game/Game.zig");
pub const Inventory = @import("game/Inventory.zig");
pub const Items = @import("game/Items.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
