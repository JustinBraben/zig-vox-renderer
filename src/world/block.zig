//! Block
//! fundemental block data structure
const std = @import("std");

const Block = @This();

pub const BlockId = enum(u16) {
    AIR = 0,
    GRASS = 1,
    DIRT = 2,
    STONE = 3,
    SAND = 4,
    WATER = 5,
    GLASS = 6,
    LOG = 7,
    LEAVES = 8,
    ROSE = 9,
    BUTTERCUP = 10,
    COAL = 11,
    COPPER = 12,
    LAVA = 13,
    CLAY = 14,
    GRAVEL = 15,
    PLANKS = 16,
    TORCH = 17,
    COBBLESTONE = 18,
    SNOW = 19,
    PODZOL = 20,
    SHRUB = 21,
    TALLGRASS = 22,
    PINE_LOG = 23,
    PINE_LEAVES = 24
};

id: BlockId,

pub fn isTransparent(self: Block) bool {
    return self.id == .AIR or self.id == .WATER; // Air and water are transparent
}