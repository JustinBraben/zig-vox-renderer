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
    _,

    /// Every named block except air, in declaration order (the player's block palette).
    pub const placeable = blk: {
        const fields = @typeInfo(BlockId).@"enum".fields;
        var list: [fields.len - 1]BlockId = undefined;
        for (fields[1..], &list) |field, *block| block.* = @enumFromInt(field.value);
        break :blk list;
    };

    pub fn isOpaque(self: BlockId) bool {
        return self != .air;
    }

    /// sRGB albedo, packed as RGBA8 (R in the low byte).
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
            _ => rgb(0xff, 0x00, 0xff),
        };
    }
};

fn rgb(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | @as(u32, g) << 8 | @as(u32, b) << 16 | 0xff << 24;
}
