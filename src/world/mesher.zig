//! Face-culled chunk meshing with per-vertex ambient occlusion.
//!
//! Input is a padded (32+2)³ block volume: the chunk plus a one-block border from
//! its neighbors, so faces and AO at chunk edges are correct. Output is one quad
//! (4 vertices) per visible face, drawn with a shared `0,1,2, 2,3,0` index pattern.

const std = @import("std");
const Allocator = std.mem.Allocator;
const chunk = @import("chunk.zig");
const block_mod = @import("block.zig");
const BlockId = block_mod.BlockId;

pub const padded_size = chunk.size + 2;
pub const Padded = [padded_size * padded_size * padded_size]BlockId;

/// Index into a padded volume; coordinates are chunk-local + 1 (0..33).
pub fn paddedIndex(x: usize, y: usize, z: usize) usize {
    return x + z * padded_size + y * padded_size * padded_size;
}

/// 8-byte packed vertex, decoded in voxel.vert.
///   data:  x:6 y:6 z:6 face:3 ao:2   (positions are chunk-local 0..32)
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
};

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

/// Appends the mesh of the padded volume's inner chunk to `out`.
pub fn meshChunk(allocator: Allocator, padded: *const Padded, out: *std.ArrayList(Vertex)) !void {
    for (1..chunk.size + 1) |y| {
        for (1..chunk.size + 1) |z| {
            for (1..chunk.size + 1) |x| {
                const block = padded[paddedIndex(x, y, z)];
                if (!block.isOpaque()) continue;
                const block_materials = &materials[@intFromEnum(block)];
                const origin = paddedIndex(x - 1, y - 1, z - 1);
                const packed_pos = Vertex.init(@intCast(x - 1), @intCast(y - 1), @intCast(z - 1), 0, 0, 0).data;
                try out.ensureUnusedCapacity(allocator, 6 * 4);

                inline for (face_tables, 0..) |t, face_index| {
                    if (!padded[origin + t.front].isOpaque()) {
                        var ao: [4]u32 = undefined;
                        inline for (&ao, t.ao) |*corner_ao, n| {
                            corner_ao.* = vertexAo(padded[origin + n[0]].isOpaque(), padded[origin + n[1]].isOpaque(), padded[origin + n[2]].isOpaque());
                        }

                        // flip the quad diagonal to avoid anisotropic AO interpolation
                        const rotate: usize = if (ao[0] + ao[2] > ao[1] + ao[3]) 1 else 0;
                        const quad = out.addManyAsArrayAssumeCapacity(4);
                        for (quad, 0..) |*vertex, i| {
                            const ci = (i + rotate) % 4;
                            vertex.* = .{ .data = (packed_pos + t.vertex[ci]) | (ao[ci] << 21), .color = block_materials[face_index] };
                        }
                    }
                }
            }
        }
    }
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

/// Sets a block by chunk-local coordinates (-1..32).
fn set(padded: *Padded, x: i32, y: i32, z: i32, block: BlockId) void {
    padded[paddedIndex(@intCast(x + 1), @intCast(y + 1), @intCast(z + 1))] = block;
}

test "lone block has six open faces" {
    const padded = try emptyVolume();
    defer testing.allocator.destroy(padded);
    set(padded, 5, 5, 5, .stone);

    var out: std.ArrayList(Vertex) = .empty;
    defer out.deinit(testing.allocator);
    try meshChunk(testing.allocator, padded, &out);
    try testing.expectEqual(@as(usize, 6 * 4), out.items.len);
    for (out.items) |v| try testing.expectEqual(@as(u2, 3), v.ao());
}

test "adjacent blocks hide the shared faces" {
    const padded = try emptyVolume();
    defer testing.allocator.destroy(padded);
    set(padded, 5, 5, 5, .stone);
    set(padded, 6, 5, 5, .stone);

    var out: std.ArrayList(Vertex) = .empty;
    defer out.deinit(testing.allocator);
    try meshChunk(testing.allocator, padded, &out);
    try testing.expectEqual(@as(usize, 10 * 4), out.items.len);
}

test "neighbor border hides edge faces" {
    const padded = try emptyVolume();
    defer testing.allocator.destroy(padded);
    set(padded, 0, 0, 0, .stone);
    set(padded, -1, 0, 0, .stone); // in the -X neighbor
    set(padded, 0, -1, 0, .stone); // in the -Y neighbor

    var out: std.ArrayList(Vertex) = .empty;
    defer out.deinit(testing.allocator);
    try meshChunk(testing.allocator, padded, &out);
    // only the inner block is meshed, minus the two covered faces
    try testing.expectEqual(@as(usize, 4 * 4), out.items.len);
}

test "ambient occlusion next to a wall" {
    const padded = try emptyVolume();
    defer testing.allocator.destroy(padded);
    // floor block with a block sitting diagonally above and to the +X side of it
    set(padded, 5, 5, 5, .stone);
    set(padded, 6, 6, 5, .stone);

    var out: std.ArrayList(Vertex) = .empty;
    defer out.deinit(testing.allocator);
    try meshChunk(testing.allocator, padded, &out);

    // find the +Y face of the floor block (face 2, y = 6 in chunk space, x in 5..6)
    var found = false;
    var i: usize = 0;
    while (i < out.items.len) : (i += 4) {
        const v0 = out.items[i];
        const face = (v0.data >> 18) & 7;
        const y = (v0.data >> 6) & 63;
        const x = v0.data & 63;
        if (face != 2 or y != 6 or x > 6) continue;
        if (x < 5) continue;
        found = true;
        for (out.items[i..][0..4]) |v| {
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
fn meshChunkReference(allocator: Allocator, padded: *const Padded, out: *std.ArrayList(Vertex)) !void {
    const Ref = struct {
        fn solid(v: *const Padded, p: [3]i32) bool {
            return v[paddedIndex(@intCast(p[0]), @intCast(p[1]), @intCast(p[2]))].isOpaque();
        }
    };
    for (1..chunk.size + 1) |y| {
        for (1..chunk.size + 1) |z| {
            for (1..chunk.size + 1) |x| {
                const block = padded[paddedIndex(x, y, z)];
                if (!block.isOpaque()) continue;
                const p = [3]i32{ @intCast(x), @intCast(y), @intCast(z) };
                for (faces, 0..) |face, face_index| {
                    const front = add(p, face.normal);
                    if (Ref.solid(padded, front)) continue;
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
                        try out.append(allocator, .init(@intCast(pos[0]), @intCast(pos[1]), @intCast(pos[2]), @intCast(face_index), ao[ci], material(block, face_index)));
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
    for (padded) |*b| b.* = if (random.uintLessThan(u8, 100) < 45) .stone else if (random.boolean()) .grass else .air;

    var expected: std.ArrayList(Vertex) = .empty;
    defer expected.deinit(testing.allocator);
    try meshChunkReference(testing.allocator, padded, &expected);
    var actual: std.ArrayList(Vertex) = .empty;
    defer actual.deinit(testing.allocator);
    try meshChunk(testing.allocator, padded, &actual);

    try testing.expect(expected.items.len > 1000);
    try testing.expectEqualSlices(Vertex, expected.items, actual.items);
}

test "faces get their block's texture layers" {
    const padded = try emptyVolume();
    defer testing.allocator.destroy(padded);
    set(padded, 5, 5, 5, .grass);

    var out: std.ArrayList(Vertex) = .empty;
    defer out.deinit(testing.allocator);
    try meshChunk(testing.allocator, padded, &out);
    for (out.items) |v| {
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
