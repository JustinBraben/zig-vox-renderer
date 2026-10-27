//! Face-culled chunk meshing with per-vertex ambient occlusion and smooth lighting.
//!
//! Input is a padded (32+2)³ block volume and its light: the chunk plus a one-block
//! border from its neighbors, so faces, AO and light at chunk edges are correct. Output is one quad
//! (4 vertices) per visible face, drawn with a shared `0,1,2, 2,3,0` index pattern,
//! split into the solid mesh (opaque and cutout blocks) and the translucent one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const chunk = @import("chunk.zig");
const block_mod = @import("block.zig");
const BlockId = block_mod.BlockId;

pub const padded_size = chunk.size + 2;
pub const Padded = [padded_size * padded_size * padded_size]BlockId;
/// Packed light levels (see light.zig) of a padded volume.
pub const PaddedLight = [padded_size * padded_size * padded_size]u8;

pub const Options = struct {
    /// mesh leaves as opaque blocks: no faces between them, and their gaps drawn dark
    /// instead of see-through
    fast_leaves: bool = false,
};

/// Index into a padded volume; coordinates are chunk-local + 1 (0..33).
pub fn paddedIndex(x: usize, y: usize, z: usize) usize {
    return x + z * padded_size + y * padded_size * padded_size;
}

/// 8-byte packed vertex, decoded in voxel.vert.
///   data:  x:6 y:6 z:6 face:3 ao:2 sky:4 block:4 solid:1   (positions are chunk-local 0..32;
///          sky and block light 0..15; solid: fill the texture's gaps instead of cutting them out)
///   color: RGB8 sRGB in the low 24 bits, texture layer in the top 8 (`untextured` = flat color)
pub const Vertex = extern struct {
    data: u32,
    color: u32,

    pub fn init(x: u32, y: u32, z: u32, face: u32, occlusion: u32, color: u32) Vertex {
        return .{ .data = x | y << 6 | z << 12 | face << 18 | occlusion << 21, .color = color };
    }

    pub fn ao(self: Vertex) u2 {
        return @truncate(self.data >> 21);
    }

    pub fn skyLight(self: Vertex) u4 {
        return @truncate(self.data >> sky_shift);
    }

    pub fn blockLight(self: Vertex) u4 {
        return @truncate(self.data >> block_light_shift);
    }
};

const sky_shift = 23;
const block_light_shift = 27;
const solid_bit: u32 = 1 << 31;
/// `data` bits of full sky light, for geometry without light data (distant terrain).
pub const full_sky: u32 = 15 << sky_shift;

/// Face order matches the normal table in voxel.vert: +X, -X, +Y, -Y, +Z, -Z.
/// `u` and `v` span the face with cross(u, v) = normal, so corners
/// base, base+u, base+u+v, base+v are counter-clockwise seen from outside.
pub const Face = struct {
    normal: [3]i32,
    u: [3]i32,
    v: [3]i32,
};

pub const faces = [6]Face{
    .{ .normal = .{ 1, 0, 0 }, .u = .{ 0, 1, 0 }, .v = .{ 0, 0, 1 } },
    .{ .normal = .{ -1, 0, 0 }, .u = .{ 0, 0, 1 }, .v = .{ 0, 1, 0 } },
    .{ .normal = .{ 0, 1, 0 }, .u = .{ 0, 0, 1 }, .v = .{ 1, 0, 0 } },
    .{ .normal = .{ 0, -1, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 0, 1 } },
    .{ .normal = .{ 0, 0, 1 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 } },
    .{ .normal = .{ 0, 0, -1 }, .u = .{ 0, 1, 0 }, .v = .{ 1, 0, 0 } },
};

/// Texture layer of a vertex drawn with its flat color (`BlockId.color` has alpha 0xff).
pub const untextured = 0xff;

/// Vertex `color` word of each block's faces, indexed by block id and face.
const materials = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256][6]u32 = undefined;
    for (&table, 0..) |*block_faces, id| {
        const block: BlockId = @enumFromInt(id);
        const rgb = block.color() & 0xffffff;
        for (block_faces, 0..) |*m, face| {
            const layer: u32 = if (block.faceTiles()) |tiles| @intFromEnum(tiles[face]) else untextured;
            m.* = rgb | layer << 24;
        }
    }
    break :blk table;
};

/// `BlockId.isOpaque` by block id, so the inner loop is a load instead of a switch;
/// with fast leaves, leaves count as opaque too.
const OpaqueTable = [256]bool;
const opaque_blocks = opaqueTable(false);
const opaque_blocks_fast_leaves = opaqueTable(true);

fn opaqueTable(fast_leaves: bool) OpaqueTable {
    @setEvalBranchQuota(10_000);
    var table: OpaqueTable = undefined;
    for (&table, 0..) |*o, id| {
        const block: BlockId = @enumFromInt(id);
        o.* = block.isOpaque() or (fast_leaves and block == .leaves);
    }
    return table;
}

/// The vertex `color` word for `face` of `block`.
pub fn material(block: BlockId, face: usize) u32 {
    return materials[@intFromEnum(block)][face];
}

pub const corner_uv = [4][2]i32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };

/// Per-face lookups for the mesher, precomputed so the inner loop is just
/// index arithmetic. All offsets are relative to the padded index of the
/// block's (-1, -1, -1) neighbor, which keeps them non-negative.
const FaceTable = struct {
    /// the block the face looks into
    front: usize,
    /// per corner: side1, side2 and corner blocks for AO
    ao: [4][3]usize,
    /// per corner: packed position delta + face index, added to the block's packed position
    vertex: [4]u32,
};

const face_tables = blk: {
    var tables: [6]FaceTable = undefined;
    for (faces, &tables, 0..) |face, *t, face_index| {
        const front = face.normal;
        t.front = paddedOffset(front);
        for (corner_uv, 0..) |uv, ci| {
            const du = scale(face.u, uv[0] * 2 - 1);
            const dv = scale(face.v, uv[1] * 2 - 1);
            t.ao[ci] = .{ paddedOffset(add(front, du)), paddedOffset(add(front, dv)), paddedOffset(add(add(front, du), dv)) };
            // face plane sits at the far side of the block for positive normals
            const pos = add(add(.{ @max(face.normal[0], 0), @max(face.normal[1], 0), @max(face.normal[2], 0) }, scale(face.u, uv[0])), scale(face.v, uv[1]));
            t.vertex[ci] = Vertex.init(pos[0], pos[1], pos[2], face_index, 0, 0).data;
        }
    }
    break :blk tables;
};

/// Padded-index offset of `d` (each component -1..1) from the block's (-1, -1, -1) neighbor.
fn paddedOffset(d: [3]i32) usize {
    return paddedIndex(d[0] + 1, d[1] + 1, d[2] + 1);
}

/// The two meshes of a chunk.
pub const Output = struct {
    /// opaque and cutout blocks
    solid: std.ArrayList(Vertex) = .empty,
    /// blended blocks (water, glass)
    translucent: std.ArrayList(Vertex) = .empty,

    pub fn clear(self: *Output) void {
        self.solid.clearRetainingCapacity();
        self.translucent.clearRetainingCapacity();
    }

    pub fn deinit(self: *Output, allocator: Allocator) void {
        self.solid.deinit(allocator);
        self.translucent.deinit(allocator);
    }
};

/// Appends the meshes of the padded volume's inner chunk to `out`.
pub fn meshChunk(allocator: Allocator, padded: *const Padded, light: *const PaddedLight, options: Options, out: *Output) !void {
    const opaque_table = if (options.fast_leaves) &opaque_blocks_fast_leaves else &opaque_blocks;
    for (1..chunk.size + 1) |y| {
        for (1..chunk.size + 1) |z| {
            for (1..chunk.size + 1) |x| {
                const block = padded[paddedIndex(x, y, z)];
                const list = switch (block.layer()) {
                    .none => continue,
                    .opaque_cube, .cutout => &out.solid,
                    .translucent => &out.translucent,
                };
                const block_materials = &materials[@intFromEnum(block)];
                const translucent = block.layer() == .translucent;
                const flags: u32 = if (options.fast_leaves and block == .leaves) solid_bit else 0;
                const origin = paddedIndex(x - 1, y - 1, z - 1);
                const packed_pos = Vertex.init(@intCast(x - 1), @intCast(y - 1), @intCast(z - 1), 0, 0, 0).data;
                try list.ensureUnusedCapacity(allocator, 6 * 4);

                inline for (face_tables, 0..) |t, face_index| {
                    // `BlockId.faceVisible`, unrolled
                    const front = padded[origin + t.front];
                    if (!opaque_table[@intFromEnum(front)] and (front != block or !translucent)) {
                        var ao: [4]u32 = undefined;
                        var corner_light: [4]u32 = undefined;
                        inline for (&ao, &corner_light, t.ao) |*corner_ao, *lit, n| {
                            const side1 = opaque_table[@intFromEnum(padded[origin + n[0]])];
                            const side2 = opaque_table[@intFromEnum(padded[origin + n[1]])];
                            const corner = opaque_table[@intFromEnum(padded[origin + n[2]])];
                            corner_ao.* = vertexAo(side1, side2, corner);
                            lit.* = vertexLight(light, origin + t.front, origin + n[0], origin + n[1], origin + n[2], side1, side2, corner);
                        }

                        // flip the quad diagonal to avoid anisotropic AO interpolation
                        const rotate: usize = if (ao[0] + ao[2] > ao[1] + ao[3]) 1 else 0;
                        const quad = list.addManyAsArrayAssumeCapacity(4);
                        for (quad, 0..) |*vertex, i| {
                            const ci = (i + rotate) % 4;
                            vertex.* = .{ .data = (packed_pos + t.vertex[ci]) | (ao[ci] << 21) | corner_light[ci] | flags, .color = block_materials[face_index] };
                        }
                    }
                }
            }
        }
    }
}

/// Light of a face corner, as vertex `data` bits: the average of the block in front of
/// the face and those of the corner's three other blocks that light can be in (the
/// corner block only when it isn't walled off by both sides).
inline fn vertexLight(light: *const PaddedLight, front: usize, s1: usize, s2: usize, c: usize, side1: bool, side2: bool, corner: bool) u32 {
    // sky and block light summed side by side: sky in bits 4..9, block in bits 0..5
    var sum: u32 = spreadNibbles(light[front]);
    var count: u32 = 1;
    if (!side1) {
        sum += spreadNibbles(light[s1]);
        count += 1;
    }
    if (!side2) {
        sum += spreadNibbles(light[s2]);
        count += 1;
    }
    if (!corner and !(side1 and side2)) {
        sum += spreadNibbles(light[c]);
        count += 1;
    }
    // rounded averages
    const sky = ((sum >> 8) * 2 + count) / (count * 2);
    const block = ((sum & 0xff) * 2 + count) / (count * 2);
    return sky << sky_shift | block << block_light_shift;
}

/// A packed light byte with the sky level moved up to bit 8, so sums of up to 4 can't
/// carry into it.
inline fn spreadNibbles(light: u8) u32 {
    return @as(u32, light >> 4) << 8 | (light & 0xf);
}

/// 0 = fully occluded, 3 = open.
fn vertexAo(side1: bool, side2: bool, corner: bool) u32 {
    if (side1 and side2) return 0;
    return 3 - @as(u32, @intFromBool(side1)) - @intFromBool(side2) - @intFromBool(corner);
}

fn add(a: [3]i32, b: [3]i32) [3]i32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn scale(a: [3]i32, s: i32) [3]i32 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}

const testing = std.testing;

fn emptyVolume() !*Padded {
    const padded = try testing.allocator.create(Padded);
    @memset(padded, .air);
    return padded;
}

/// Meshes with no light and default options.
fn meshDark(padded: *const Padded, out: *Output) !void {
    const light = try testing.allocator.create(PaddedLight);
    defer testing.allocator.destroy(light);
    @memset(light, 0);
    try meshChunk(testing.allocator, padded, light, .{}, out);
}

/// Sets a block by chunk-local coordinates (-1..32).
fn set(padded: *Padded, x: i32, y: i32, z: i32, block: BlockId) void {
    padded[paddedIndex(@intCast(x + 1), @intCast(y + 1), @intCast(z + 1))] = block;
}

test "lone block has six open faces" {
    const padded = try emptyVolume();
    defer testing.allocator.destroy(padded);
    set(padded, 5, 5, 5, .stone);

    var out: Output = .{};
    defer out.deinit(testing.allocator);
    try meshDark(padded, &out);
    try testing.expectEqual(@as(usize, 6 * 4), out.solid.items.len);
    for (out.solid.items) |v| try testing.expectEqual(@as(u2, 3), v.ao());
}

test "adjacent blocks hide the shared faces" {
    const padded = try emptyVolume();
    defer testing.allocator.destroy(padded);
    set(padded, 5, 5, 5, .stone);
    set(padded, 6, 5, 5, .stone);

    var out: Output = .{};
    defer out.deinit(testing.allocator);
    try meshDark(padded, &out);
    try testing.expectEqual(@as(usize, 10 * 4), out.solid.items.len);
}

test "neighbor border hides edge faces" {
    const padded = try emptyVolume();
    defer testing.allocator.destroy(padded);
    set(padded, 0, 0, 0, .stone);
    set(padded, -1, 0, 0, .stone); // in the -X neighbor
    set(padded, 0, -1, 0, .stone); // in the -Y neighbor

    var out: Output = .{};
    defer out.deinit(testing.allocator);
    try meshDark(padded, &out);
    // only the inner block is meshed, minus the two covered faces
    try testing.expectEqual(@as(usize, 4 * 4), out.solid.items.len);
}

test "ambient occlusion next to a wall" {
    const padded = try emptyVolume();
    defer testing.allocator.destroy(padded);
    // floor block with a block sitting diagonally above and to the +X side of it
    set(padded, 5, 5, 5, .stone);
    set(padded, 6, 6, 5, .stone);

    var out: Output = .{};
    defer out.deinit(testing.allocator);
    try meshDark(padded, &out);

    // find the +Y face of the floor block (face 2, y = 6 in chunk space, x in 5..6)
    var found = false;
    var i: usize = 0;
    while (i < out.solid.items.len) : (i += 4) {
        const v0 = out.solid.items[i];
        const face = (v0.data >> 18) & 7;
        const y = (v0.data >> 6) & 63;
        const x = v0.data & 63;
        if (face != 2 or y != 6 or x > 6) continue;
        if (x < 5) continue;
        found = true;
        for (out.solid.items[i..][0..4]) |v| {
            const vx = v.data & 63;
            // corners on the wall side are darkened by one side neighbor
            const expected: u2 = if (vx == 6) 2 else 3;
            try testing.expectEqual(expected, v.ao());
        }
        break;
    }
    try testing.expect(found);
}

/// The original straightforward mesher, kept to check the table-driven one against.
fn meshChunkReference(allocator: Allocator, padded: *const Padded, out: *Output) !void {
    const Ref = struct {
        fn solid(v: *const Padded, p: [3]i32) bool {
            return v[paddedIndex(@intCast(p[0]), @intCast(p[1]), @intCast(p[2]))].isOpaque();
        }
    };
    for (1..chunk.size + 1) |y| {
        for (1..chunk.size + 1) |z| {
            for (1..chunk.size + 1) |x| {
                const block = padded[paddedIndex(x, y, z)];
                if (block.layer() == .none) continue;
                const list = if (block.layer() == .translucent) &out.translucent else &out.solid;
                const p = [3]i32{ @intCast(x), @intCast(y), @intCast(z) };
                for (faces, 0..) |face, face_index| {
                    const front = add(p, face.normal);
                    if (!block.faceVisible(padded[paddedIndex(@intCast(front[0]), @intCast(front[1]), @intCast(front[2]))])) continue;
                    var ao: [4]u32 = undefined;
                    for (corner_uv, &ao) |uv, *corner_ao| {
                        const du = scale(face.u, uv[0] * 2 - 1);
                        const dv = scale(face.v, uv[1] * 2 - 1);
                        corner_ao.* = vertexAo(Ref.solid(padded, add(front, du)), Ref.solid(padded, add(front, dv)), Ref.solid(padded, add(add(front, du), dv)));
                    }
                    const rotate: usize = if (ao[0] + ao[2] > ao[1] + ao[3]) 1 else 0;
                    const base = [3]i32{
                        p[0] - 1 + @max(face.normal[0], 0),
                        p[1] - 1 + @max(face.normal[1], 0),
                        p[2] - 1 + @max(face.normal[2], 0),
                    };
                    for (0..4) |i| {
                        const ci = (i + rotate) % 4;
                        const uv = corner_uv[ci];
                        const pos = add(add(base, scale(face.u, uv[0])), scale(face.v, uv[1]));
                        try list.append(allocator, .init(@intCast(pos[0]), @intCast(pos[1]), @intCast(pos[2]), @intCast(face_index), ao[ci], material(block, face_index)));
                    }
                }
            }
        }
    }
}

test "table-driven mesher matches the reference on a random volume" {
    const padded = try emptyVolume();
    defer testing.allocator.destroy(padded);
    var prng: std.Random.DefaultPrng = .init(42);
    const random = prng.random();
    const palette = [_]BlockId{ .stone, .stone, .grass, .leaves, .water, .glass, .air, .air, .air };
    for (padded) |*b| b.* = palette[random.uintLessThan(usize, palette.len)];

    var expected: Output = .{};
    defer expected.deinit(testing.allocator);
    try meshChunkReference(testing.allocator, padded, &expected);
    var actual: Output = .{};
    defer actual.deinit(testing.allocator);
    try meshDark(padded, &actual);

    try testing.expect(expected.solid.items.len > 1000);
    try testing.expect(expected.translucent.items.len > 1000);
    try testing.expectEqualSlices(Vertex, expected.solid.items, actual.solid.items);
    try testing.expectEqualSlices(Vertex, expected.translucent.items, actual.translucent.items);
}

test "faces get their block's texture layers" {
    const padded = try emptyVolume();
    defer testing.allocator.destroy(padded);
    set(padded, 5, 5, 5, .grass);

    var out: Output = .{};
    defer out.deinit(testing.allocator);
    try meshDark(padded, &out);
    for (out.solid.items) |v| {
        const face = (v.data >> 18) & 7;
        const expected: block_mod.Tile = switch (face) {
            2 => .grass_top,
            3 => .dirt,
            else => .grass_side,
        };
        try testing.expectEqual(@as(u32, @intFromEnum(expected)), v.color >> 24);
        try testing.expectEqual(BlockId.grass.color() & 0xffffff, v.color & 0xffffff);
    }
}

test "water and glass hide their inner faces but not what they cover" {
    const padded = try emptyVolume();
    defer testing.allocator.destroy(padded);
    // a 2×1×1 pool of water on a stone floor, with a glass pane next to it
    set(padded, 5, 5, 5, .water);
    set(padded, 6, 5, 5, .water);
    set(padded, 5, 4, 5, .stone);
    set(padded, 7, 5, 5, .glass);

    var out: Output = .{};
    defer out.deinit(testing.allocator);
    try meshDark(padded, &out);
    // stone: all six faces (water doesn't hide them)
    try testing.expectEqual(@as(usize, 6 * 4), out.solid.items.len);
    // water: 10 outer faces of the pair minus the bottom of the block on stone;
    // glass: all six, including the one against the water
    try testing.expectEqual(@as(usize, (9 + 6) * 4), out.translucent.items.len);
}

test "leaves keep the faces between them" {
    const padded = try emptyVolume();
    defer testing.allocator.destroy(padded);
    set(padded, 5, 5, 5, .leaves);
    set(padded, 6, 5, 5, .leaves);

    var out: Output = .{};
    defer out.deinit(testing.allocator);
    try meshDark(padded, &out);
    try testing.expectEqual(@as(usize, 12 * 4), out.solid.items.len);
    try testing.expectEqual(@as(usize, 0), out.translucent.items.len);
}

test "corners average the light of the open blocks around them" {
    const padded = try emptyVolume();
    defer testing.allocator.destroy(padded);
    const light = try testing.allocator.create(PaddedLight);
    defer testing.allocator.destroy(light);
    // full sky everywhere, except one block touching the top face's -X, -Z corner
    @memset(light, 0xf0);
    set(padded, 5, 5, 5, .stone);
    light[paddedIndex(5, 7, 5)] = 0x3f; // sky 3, block 15, at (4, 6, 4)

    var out: Output = .{};
    defer out.deinit(testing.allocator);
    try meshChunk(testing.allocator, padded, light, .{}, &out);
    var checked: usize = 0;
    for (out.solid.items) |v| {
        if ((v.data >> 18) & 7 != 2) continue;
        const x = v.data & 63;
        const z = (v.data >> 12) & 63;
        if (x == 5 and z == 5) {
            // (15 * 3 + 3) / 4 and 15 / 4, rounded
            try testing.expectEqual(@as(u4, 12), v.skyLight());
            try testing.expectEqual(@as(u4, 4), v.blockLight());
        } else {
            try testing.expectEqual(@as(u4, 15), v.skyLight());
            try testing.expectEqual(@as(u4, 0), v.blockLight());
        }
        checked += 1;
    }
    try testing.expectEqual(@as(usize, 4), checked);
}

test "fast leaves hide the faces between leaves and draw their gaps" {
    const padded = try emptyVolume();
    defer testing.allocator.destroy(padded);
    const light = try testing.allocator.create(PaddedLight);
    defer testing.allocator.destroy(light);
    @memset(light, 0);
    set(padded, 5, 5, 5, .leaves);
    set(padded, 6, 5, 5, .leaves);
    set(padded, 5, 4, 5, .stone);

    var out: Output = .{};
    defer out.deinit(testing.allocator);
    try meshChunk(testing.allocator, padded, light, .{ .fast_leaves = true }, &out);
    // leaves: 10 outer faces but the one on the stone; stone: 5 (its top is covered by leaves)
    try testing.expectEqual(@as(usize, (9 + 5) * 4), out.solid.items.len);
    for (out.solid.items) |v| {
        const is_leaves = v.color >> 24 == @intFromEnum(block_mod.Tile.leaves);
        try testing.expectEqual(is_leaves, v.data & solid_bit != 0);
    }
}
