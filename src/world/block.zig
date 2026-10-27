//! Block ids and their per-block properties.

const std = @import("std");

pub const BlockId = enum(u8) {
    air = 0,
    grass,
    dirt,
    stone,
    sand,
    gravel,
    snow,
    log,
    leaves,
    clay,
    cobblestone,
    planks,
    water,
    glass,
    lamp,
    _,

    /// Every named block except air, in declaration order (the player's block palette).
    pub const placeable = blk: {
        const fields = @typeInfo(BlockId).@"enum".fields;
        var list: [fields.len - 1]BlockId = undefined;
        for (fields[1..], &list) |field, *block| block.* = @enumFromInt(field.value);
        break :blk list;
    };

    pub const Layer = enum {
        /// not drawn
        none,
        /// a full cube that hides whatever is behind it
        opaque_cube,
        /// fully opaque or fully clear texels (leaves), drawn with the opaque blocks
        cutout,
        /// blended, drawn after everything opaque
        translucent,
    };

    pub fn layer(self: BlockId) Layer {
        return switch (self) {
            .air => .none,
            .leaves => .cutout,
            .water, .glass => .translucent,
            else => .opaque_cube,
        };
    }

    /// Hides the faces of blocks next to it, and darkens their corners (ambient occlusion).
    pub fn isOpaque(self: BlockId) bool {
        return self.layer() == .opaque_cube;
    }

    /// Blocks movement.
    pub fn isSolid(self: BlockId) bool {
        return self != .air and self != .water;
    }

    /// Can be targeted (broken, built against); rays pass through the rest.
    pub fn isTargetable(self: BlockId) bool {
        return self != .air and self != .water;
    }

    /// How much light loses passing into this block, beyond the usual 1 per block;
    /// 15 stops it.
    pub fn lightOpacity(self: BlockId) u4 {
        return switch (self.layer()) {
            .none => 0,
            .opaque_cube => 15,
            .cutout => 1,
            .translucent => if (self == .water) 1 else 0,
        };
    }

    /// Seconds to break by hand in survival; there are no tools yet, so the hard blocks
    /// take less than they would bare-handed in other games.
    pub fn breakSeconds(self: BlockId) f32 {
        return switch (self) {
            .leaves, .snow => 0.3,
            .glass, .lamp => 0.45,
            .dirt, .sand => 0.75,
            .grass, .gravel, .clay => 0.9,
            .log, .planks => 2.0,
            .stone => 2.25,
            .cobblestone => 2.5,
            else => 1,
        };
    }

    /// What breaking the block in survival gives, if anything.
    pub fn drop(self: BlockId) ?BlockId {
        return switch (self) {
            .air, .water, .leaves, .glass => null,
            .grass => .dirt,
            .stone => .cobblestone,
            else => self,
        };
    }

    /// Block light given off, 0..15.
    pub fn lightEmission(self: BlockId) u4 {
        return if (self == .lamp) 15 else 0;
    }

    /// Whether the face of `self` towards `neighbor` is drawn.
    pub fn faceVisible(self: BlockId, neighbor: BlockId) bool {
        if (neighbor.isOpaque()) return false;
        // no inner surfaces in a body of water or a glass wall; leaves keep theirs so
        // a canopy doesn't look hollow through its gaps
        return neighbor != self or self.layer() != .translucent;
    }

    /// Texture tile per face in mesher order (+X, -X, +Y, -Y, +Z, -Z), or null to draw
    /// the block with its flat `color`.
    pub fn faceTiles(self: BlockId) ?[6]Tile {
        return switch (self) {
            .air => null,
            .grass => sided(.grass_side, .grass_top, .dirt),
            .dirt => all(.dirt),
            .stone => all(.stone),
            .sand => all(.sand),
            .gravel => all(.gravel),
            .snow => all(.snow),
            .log => sided(.log_side, .log_top, .log_top),
            .leaves => all(.leaves),
            .clay => all(.clay),
            .cobblestone => all(.cobblestone),
            .planks => all(.planks),
            .water => all(.water),
            .glass => all(.glass),
            .lamp => all(.lamp),
            _ => null,
        };
    }

    /// sRGB albedo, packed as RGBA8 (R in the low byte). Textured blocks use it where
    /// textures aren't drawn (distant terrain).
    pub fn color(self: BlockId) u32 {
        return switch (self) {
            .air => 0,
            .grass => rgb(0x5d, 0x9e, 0x3a),
            .dirt => rgb(0x86, 0x60, 0x43),
            .stone => rgb(0x80, 0x80, 0x84),
            .sand => rgb(0xdb, 0xcf, 0x8e),
            .gravel => rgb(0x8a, 0x80, 0x7a),
            .snow => rgb(0xf0, 0xf4, 0xf8),
            .log => rgb(0x6b, 0x4f, 0x2c),
            .leaves => rgb(0x3b, 0x7a, 0x2a),
            .clay => rgb(0x9f, 0xa4, 0xb0),
            .cobblestone => rgb(0x6c, 0x6c, 0x6c),
            .planks => rgb(0xb0, 0x8c, 0x56),
            .water => rgb(0x3a, 0x6e, 0xc8),
            .glass => rgb(0xc8, 0xe0, 0xf0),
            .lamp => rgb(0xf4, 0xc8, 0x6a),
            _ => rgb(0xff, 0x00, 0xff),
        };
    }
};

/// Tiles of `assets/textures/blocks.png` in atlas order (left to right, 16 per row);
/// the atlas is generated from this list by tools/gen_textures.zig.
pub const Tile = enum(u8) {
    grass_top,
    grass_side,
    dirt,
    stone,
    sand,
    gravel,
    snow,
    snow_side,
    log_side,
    log_top,
    leaves,
    clay,
    cobblestone,
    planks,
    water,
    glass,
    lamp,
    /// overlay on a block being broken, from just started to almost done
    crack_0,
    crack_1,
    crack_2,
    crack_3,
    crack_4,
    crack_5,
    crack_6,
    crack_7,
    crack_8,
    crack_9,

    pub const count = @typeInfo(Tile).@"enum".fields.len;
    pub const crack_stages = 10;

    /// Crack overlay for `stage` in 0..crack_stages.
    pub fn crack(stage: usize) Tile {
        return @enumFromInt(@intFromEnum(Tile.crack_0) + @min(stage, crack_stages - 1));
    }
};

/// Some number of one block, as held in an inventory slot; empty when `count` is 0.
pub const Stack = struct {
    block: BlockId = .air,
    count: u8 = 0,

    pub const max = 64;
};

fn all(tile: Tile) [6]Tile {
    return @splat(tile);
}

fn sided(side: Tile, top: Tile, bottom: Tile) [6]Tile {
    return .{ side, side, top, bottom, side, side };
}

fn rgb(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | @as(u32, g) << 8 | @as(u32, b) << 16 | 0xff << 24;
}
