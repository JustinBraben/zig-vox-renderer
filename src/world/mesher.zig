//! Face-culled chunk meshing with per-vertex ambient occlusion.
//!
//! Input is a padded (32+2)³ block volume: the chunk plus a one-block border from
//! its neighbors, so faces and AO at chunk edges are correct. Output is one quad
//! (4 vertices) per visible face, drawn with a shared `0,1,2, 2,3,0` index pattern.

const std = @import("std");
const Allocator = std.mem.Allocator;
const chunk = @import("chunk.zig");
const BlockId = @import("block.zig").BlockId;

pub const padded_size = chunk.size + 2;
pub const Padded = [padded_size * padded_size * padded_size]BlockId;

/// Index into a padded volume; coordinates are chunk-local + 1 (0..33).
pub fn paddedIndex(x: usize, y: usize, z: usize) usize {
    return x + z * padded_size + y * padded_size * padded_size;
}

/// 8-byte packed vertex, decoded in voxel.vert.
///   data:  x:6 y:6 z:6 face:3 ao:2   (positions are chunk-local 0..32)
///   color: RGBA8 sRGB
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
const Face = struct {
    normal: [3]i32,
    u: [3]i32,
    v: [3]i32,
};

const faces = [6]Face{
    .{ .normal = .{ 1, 0, 0 }, .u = .{ 0, 1, 0 }, .v = .{ 0, 0, 1 } },
    .{ .normal = .{ -1, 0, 0 }, .u = .{ 0, 0, 1 }, .v = .{ 0, 1, 0 } },
    .{ .normal = .{ 0, 1, 0 }, .u = .{ 0, 0, 1 }, .v = .{ 1, 0, 0 } },
    .{ .normal = .{ 0, -1, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 0, 1 } },
    .{ .normal = .{ 0, 0, 1 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 } },
    .{ .normal = .{ 0, 0, -1 }, .u = .{ 0, 1, 0 }, .v = .{ 1, 0, 0 } },
};

const corner_uv = [4][2]i32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };

/// Appends the mesh of the padded volume's inner chunk to `out`.
pub fn meshChunk(allocator: Allocator, padded: *const Padded, out: *std.ArrayList(Vertex)) !void {
    for (1..chunk.size + 1) |y| {
        for (1..chunk.size + 1) |z| {
            for (1..chunk.size + 1) |x| {
                const block = padded[paddedIndex(x, y, z)];
                if (!block.isOpaque()) continue;
                const color = block.color();
                const p = [3]i32{ @intCast(x), @intCast(y), @intCast(z) };

                for (faces, 0..) |face, face_index| {
                    // the layer of blocks the face looks into
                    const front = add(p, face.normal);
                    if (solid(padded, front)) continue;

                    var ao: [4]u32 = undefined;
                    for (corner_uv, &ao) |uv, *corner_ao| {
                        const du = scale(face.u, uv[0] * 2 - 1);
                        const dv = scale(face.v, uv[1] * 2 - 1);
                        const side1 = solid(padded, add(front, du));
                        const side2 = solid(padded, add(front, dv));
                        const corner = solid(padded, add(add(front, du), dv));
                        corner_ao.* = vertexAo(side1, side2, corner);
                    }

                    // flip the quad diagonal to avoid anisotropic AO interpolation
                    const rotate: usize = if (ao[0] + ao[2] > ao[1] + ao[3]) 1 else 0;

                    // face plane sits at the far side of the block for positive normals
                    const base = [3]i32{
                        p[0] - 1 + @max(face.normal[0], 0),
                        p[1] - 1 + @max(face.normal[1], 0),
                        p[2] - 1 + @max(face.normal[2], 0),
                    };
                    const quad = try out.addManyAsArray(allocator, 4);
                    for (quad, 0..) |*vertex, i| {
                        const ci = (i + rotate) % 4;
                        const uv = corner_uv[ci];
                        const pos = add(add(base, scale(face.u, uv[0])), scale(face.v, uv[1]));
                        vertex.* = .init(@intCast(pos[0]), @intCast(pos[1]), @intCast(pos[2]), @intCast(face_index), ao[ci], color);
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

fn solid(padded: *const Padded, p: [3]i32) bool {
    return padded[paddedIndex(@intCast(p[0]), @intCast(p[1]), @intCast(p[2]))].isOpaque();
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
