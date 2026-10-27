//! Overlay geometry built on the CPU every frame: textured or flat-colored triangles,
//! either in camera-relative world space (dropped items, the crack on a block being
//! broken) or in window pixels (the HUD). Drawn by overlay_pipeline.zig.

const std = @import("std");
const block = @import("../world/block.zig");
const BlockId = block.BlockId;
const Tile = block.Tile;

/// See overlay.vert.
pub const Vertex = extern struct {
    pos: [3]f32,
    uv: [2]f32,
    /// texture layer (a `Tile`), or `no_texture` for a flat color
    layer: u32,
    /// sRGB RGBA8 (R in the low byte), multiplied with the texel
    color: u32,
};

pub const no_texture = 0xffff_ffff;

pub const white = rgba(255, 255, 255, 255);

/// Vertices `first..first + count` of a batch.
pub const Range = struct {
    first: u32,
    count: u32,
};

/// Fills `vertices`; whatever doesn't fit is dropped.
pub const Batch = struct {
    vertices: []Vertex,
    len: u32 = 0,

    /// The vertices added since `first` (an earlier `len`).
    pub fn since(self: *const Batch, first: u32) Range {
        return .{ .first = first, .count = self.len - first };
    }

    /// A quad from its corners in order around the edge, starting at the one where the
    /// texture's top-left goes.
    pub fn quad(self: *Batch, corners: [4][3]f32, layer: u32, color: u32) void {
        const uvs = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        if (self.len + 6 > self.vertices.len) return;
        for ([6]usize{ 0, 1, 2, 0, 2, 3 }) |i| {
            self.vertices[self.len] = .{ .pos = corners[i], .uv = uvs[i], .layer = layer, .color = color };
            self.len += 1;
        }
    }

    /// Axis-aligned rectangle in pixels (y down).
    pub fn rect(self: *Batch, x: f32, y: f32, w: f32, h: f32, layer: u32, color: u32) void {
        self.quad(.{ .{ x, y, 0 }, .{ x + w, y, 0 }, .{ x + w, y + h, 0 }, .{ x, y + h, 0 } }, layer, color);
    }

    /// A cube of half size `half` around `center`, turned `yaw` radians about the
    /// vertical axis. `layers` and `colors` are per face in mesher order (+X, -X, +Y,
    /// -Y, +Z, -Z), textured the way the chunk meshes are.
    pub fn cube(self: *Batch, center: [3]f32, half: f32, yaw: f32, layers: [6]u32, colors: [6]u32) void {
        const s = @sin(yaw);
        const c = @cos(yaw);
        var corners: [8][3]f32 = undefined;
        for (&corners, 0..) |*corner, i| {
            const x = if (i & 1 != 0) half else -half;
            const y = if (i & 2 != 0) half else -half;
            const z = if (i & 4 != 0) half else -half;
            corner.* = .{ center[0] + x * c - z * s, center[1] + y, center[2] + x * s + z * c };
        }
        for (cube_faces, layers, colors) |face, layer, color| {
            self.quad(.{ corners[face[0]], corners[face[1]], corners[face[2]], corners[face[3]] }, layer, color);
        }
    }
};

/// Corners (bit 0: +x, bit 1: +y, bit 2: +z) of each cube face, starting at the
/// texture's top-left as seen from outside, matching voxel.vert's face_u / face_v.
const cube_faces = [6][4]u8{
    .{ 7, 3, 1, 5 },
    .{ 2, 6, 4, 0 },
    .{ 2, 3, 7, 6 },
    .{ 4, 5, 1, 0 },
    .{ 6, 7, 5, 4 },
    .{ 3, 2, 0, 1 },
};

/// Texture layer and color of each face of a block, unshaded.
pub const Faces = struct {
    layers: [6]u32,
    colors: [6]u32,

    pub fn of(id: BlockId) Faces {
        const tiles = id.faceTiles() orelse return .{ .layers = @splat(no_texture), .colors = @splat(id.color()) };
        var faces: Faces = .{ .layers = undefined, .colors = @splat(white) };
        for (tiles, &faces.layers) |tile, *layer| layer.* = @intFromEnum(tile);
        return faces;
    }

    /// Every face darkened by `per_face` times `light`.
    pub fn shaded(self: Faces, per_face: [6]f32, light: f32) Faces {
        var out = self;
        for (&out.colors, per_face) |*color, f| color.* = shade(color.*, f * light);
        return out;
    }
};

/// Simple directional shading per face (+X, -X, +Y, -Y, +Z, -Z), brightest on top.
pub const face_shade = [6]f32{ 0.7, 0.7, 1.0, 0.5, 0.85, 0.85 };

pub fn rgba(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, r) | @as(u32, g) << 8 | @as(u32, b) << 16 | @as(u32, a) << 24;
}

/// `color` with its RGB scaled by `f` (clamped), alpha unchanged.
pub fn shade(color: u32, f: f32) u32 {
    var out = color & 0xff00_0000;
    for (0..3) |i| {
        const shift: u5 = @intCast(i * 8);
        const ch: f32 = @floatFromInt((color >> shift) & 0xff);
        out |= @as(u32, @intFromFloat(std.math.clamp(ch * f, 0, 255))) << shift;
    }
    return out;
}

/// `color` with its alpha replaced.
pub fn withAlpha(color: u32, a: u8) u32 {
    return (color & 0x00ff_ffff) | @as(u32, a) << 24;
}

const testing = std.testing;

test "quads past the end are dropped whole" {
    var storage: [8]Vertex = undefined;
    var batch: Batch = .{ .vertices = &storage };
    batch.rect(0, 0, 1, 1, no_texture, white);
    batch.rect(0, 0, 1, 1, no_texture, white);
    try testing.expectEqual(6, batch.len);
    try testing.expectEqual(Range{ .first = 0, .count = 6 }, batch.since(0));
}

test "cube faces point outwards" {
    var storage: [36]Vertex = undefined;
    var batch: Batch = .{ .vertices = &storage };
    batch.cube(.{ 0, 0, 0 }, 0.5, 0, @splat(no_texture), @splat(white));
    const normals = [6][3]f32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
    for (normals, 0..) |n, f| {
        const v = storage[f * 6 ..][0..3];
        // every corner lies on the face's side, and the first triangle winds counterclockwise seen from outside
        for (v) |p| try testing.expectEqual(0.5, p.pos[0] * n[0] + p.pos[1] * n[1] + p.pos[2] * n[2]);
        const a: @Vector(3, f32) = v[1].pos - @as(@Vector(3, f32), v[0].pos);
        const b: @Vector(3, f32) = v[2].pos - @as(@Vector(3, f32), v[0].pos);
        const cross = [3]f32{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
        // texture u runs right and v down, so (u, v) is clockwise seen from outside
        try testing.expect(cross[0] * n[0] + cross[1] * n[1] + cross[2] * n[2] < 0);
    }
}

test "shade scales color, keeps alpha" {
    try testing.expectEqual(rgba(50, 100, 127, 7), shade(rgba(100, 200, 255, 7), 0.5));
    try testing.expectEqual(rgba(255, 0, 0, 255), shade(rgba(200, 0, 0, 255), 2));
}
