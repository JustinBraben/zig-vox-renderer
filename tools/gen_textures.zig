//! Generates the block texture atlas (`assets/textures/blocks.png`) procedurally,
//! so the repository only contains original art. Run with `zig build textures`.
//!
//! Tiles are 16×16, laid out left to right in `Tile` order (src/world/block.zig), 16 per
//! row. Every tile wraps seamlessly (noise lattices and cell points repeat at the tile
//! size). Base colors come from `BlockId.color`, so textured blocks keep the current palette.

const std = @import("std");
const block = @import("block");
const BlockId = block.BlockId;

pub const tile_size = 16;
pub const tiles_per_row = 16;

const Tile = block.Tile;

const tile_count = Tile.count;
const width = tile_size * tiles_per_row;
const height = tile_size * ((tile_count + tiles_per_row - 1) / tiles_per_row);

const Rgba = [4]u8;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.log.err("usage: gen_textures <output.png>", .{});
        return error.InvalidArgs;
    }

    var pixels: [width * height]Rgba = @splat(.{ 0, 0, 0, 0 });
    for (0..tile_count) |t| {
        const tile: Tile = @enumFromInt(t);
        const ox = (t % tiles_per_row) * tile_size;
        const oy = (t / tiles_per_row) * tile_size;
        for (0..tile_size) |y| {
            for (0..tile_size) |x| pixels[(oy + y) * width + ox + x] = texel(tile, @intCast(x), @intCast(y));
        }
    }

    const png = try encodePng(init.arena.allocator(), &pixels, width, height);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = png });
}

fn texel(tile: Tile, x: i32, y: i32) Rgba {
    const seed = @as(u32, @intFromEnum(tile)) *% 0x9e3779b9;
    return switch (tile) {
        .grass_top => grassTop(x, y, seed),
        .grass_side => if (y < fringe(x, seed, 2, 3)) grassTop(x, y, seed) else dirt(x, y, seed),
        .dirt => dirt(x, y, seed),
        .stone => stone(x, y, seed),
        .sand => blk: {
            const grain = hash(seed, x, y);
            const f = 0.93 + 0.1 * fbm(seed, x, y, 4) + @as(f32, if (grain > 0.94) -0.18 else 0);
            break :blk shade(BlockId.sand.color(), f);
        },
        .gravel => gravel(x, y, seed),
        .snow => snow(x, y, seed),
        .snow_side => if (y < fringe(x, seed, 3, 3)) snow(x, y, seed) else dirt(x, y, seed),
        .log_side => blk: {
            // vertical bark ridges: per-column shade, broken up along y
            const ridge = valueNoise(seed, x, y, 8, 2);
            const groove = hash(seed, x, @divFloor(y, 5)) > 0.7;
            const f = 0.75 + 0.4 * ridge + @as(f32, if (groove) -0.2 else 0);
            break :blk shade(BlockId.log.color(), f);
        },
        .log_top => logTop(x, y, seed),
        .leaves => blk: {
            // holes for cutout rendering
            if (hash(seed, x, y) < 0.16) break :blk .{ 0, 0, 0, 0 };
            const f = 0.7 + 0.5 * fbm(seed, x, y, 4) + @as(f32, if (hash(seed +% 1, x, y) > 0.9) 0.2 else 0);
            break :blk shade(BlockId.leaves.color(), f);
        },
        .clay => blk: {
            const band = 0.04 * @sin(@as(f32, @floatFromInt(y)) * std.math.pi / 4.0);
            break :blk shade(BlockId.clay.color(), 0.94 + band + 0.08 * fbm(seed, x, y, 2));
        },
        .cobblestone => cobblestone(x, y, seed),
        .planks => planks(x, y, seed),
        .water => blk: {
            const wave = valueNoise(seed, x, y, 2, 4);
            const f = 0.85 + 0.25 * wave;
            var c = shade(BlockId.water.color(), f);
            c[3] = 170;
            break :blk c;
        },
        .glass => blk: {
            const edge = x == 0 or y == 0 or x == tile_size - 1 or y == tile_size - 1;
            if (edge) break :blk shade(rgb(0xd8, 0xe4, 0xec), 0.9 + 0.1 * hash(seed, x, y));
            // two short diagonal glints
            const d = x - y;
            if ((d == 3 or d == 4) and x > 4 and x < 9) break :blk .{ 0xf4, 0xf8, 0xfc, 200 };
            if (d == -6 and x > 6 and x < 10) break :blk .{ 0xf4, 0xf8, 0xfc, 160 };
            break :blk .{ 0xc8, 0xe0, 0xf0, 36 };
        },
    };
}

fn grassTop(x: i32, y: i32, seed: u32) Rgba {
    const blade = hash(seed, x, y);
    const f = 0.8 + 0.3 * fbm(seed, x, y, 4) + @as(f32, if (blade > 0.9) 0.15 else if (blade < 0.08) -0.15 else 0);
    return shade(BlockId.grass.color(), f);
}

fn dirt(x: i32, y: i32, seed: u32) Rgba {
    // all dirt shares one pattern so side tiles match the dirt block
    _ = seed;
    const s: u32 = 0x2545f491;
    const speck = hash(s, x, y);
    const f = 0.82 + 0.3 * fbm(s, x, y, 4) + @as(f32, if (speck > 0.93) 0.2 else if (speck < 0.06) -0.2 else 0);
    return shade(BlockId.dirt.color(), f);
}

fn stone(x: i32, y: i32, seed: u32) Rgba {
    // blotches quantized for a pixel-art look, plus a few dark flecks
    const n = fbm(seed, x, y, 4);
    const level = @floor(n * 5) / 5;
    const fleck = hash(seed +% 3, x, y) > 0.93;
    return shade(BlockId.stone.color(), 0.8 + 0.35 * level + @as(f32, if (fleck) -0.15 else 0));
}

fn snow(x: i32, y: i32, seed: u32) Rgba {
    return shade(BlockId.snow.color(), 0.95 + 0.05 * fbm(seed, x, y, 4));
}

fn gravel(x: i32, y: i32, seed: u32) Rgba {
    const cell = cells(seed, x, y, 4);
    if (cell.edge < 0.9) return shade(BlockId.gravel.color(), 0.6);
    const f = 0.75 + 0.4 * hash(seed, cell.id, 0);
    return shade(BlockId.gravel.color(), f);
}

fn cobblestone(x: i32, y: i32, seed: u32) Rgba {
    const cell = cells(seed, x, y, 3);
    if (cell.edge < 1.3) return shade(BlockId.cobblestone.color(), 0.55);
    // stones are lighter towards their middle
    const bulge = @min(cell.edge / 6.0, 1.0);
    const f = 0.8 + 0.25 * hash(seed, cell.id, 0) + 0.15 * bulge;
    return shade(BlockId.cobblestone.color(), f);
}

fn planks(x: i32, y: i32, seed: u32) Rgba {
    const board = @divFloor(y, 4);
    if (@mod(y, 4) == 3) return shade(BlockId.planks.color(), 0.62);
    // one butt joint per board, staggered
    const joint: i32 = @intFromFloat(hash(seed, board, 1) * tile_size);
    if (x == joint) return shade(BlockId.planks.color(), 0.7);
    const grain = valueNoise(seed +% @as(u32, @intCast(board)), x, y, 2, 8);
    const f = 0.85 + 0.12 * (hash(seed, board, 0) - 0.5) + 0.22 * grain;
    return shade(BlockId.planks.color(), f);
}

fn logTop(x: i32, y: i32, seed: u32) Rgba {
    const dx = @as(f32, @floatFromInt(x)) - 7.5;
    const dy = @as(f32, @floatFromInt(y)) - 7.5;
    const d = @max(@abs(dx), @abs(dy)) + 0.6 * (fbm(seed, x, y, 4) - 0.5);
    if (d > 6.6) return shade(BlockId.log.color(), 0.8 + 0.2 * hash(seed, x, y));
    const ring = @sin(d * 2.2) * 0.5 + 0.5;
    return shade(BlockId.planks.color(), 0.82 + 0.2 * ring);
}

/// Rows from the top covered by a fringe (grass, snow) on a side tile.
fn fringe(x: i32, seed: u32, min: i32, extra: i32) i32 {
    return min + @as(i32, @intFromFloat(hash(seed +% 7, x, 0) * @as(f32, @floatFromInt(extra))));
}

const Cell = struct {
    id: i32,
    /// distance to the second-nearest point minus distance to the nearest
    edge: f32,
};

/// Worley cells from one jittered point per square of a `grid`×`grid` layout,
/// repeating every tile; the grid keeps points from bunching up.
fn cells(seed: u32, x: i32, y: i32, grid: i32) Cell {
    const px = @as(f32, @floatFromInt(x)) + 0.5;
    const py = @as(f32, @floatFromInt(y)) + 0.5;
    var best: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
    var id: i32 = 0;
    var i: i32 = 0;
    const step = @as(f32, tile_size) / @as(f32, @floatFromInt(grid));
    while (i < grid * grid) : (i += 1) {
        const cx = (@as(f32, @floatFromInt(@mod(i, grid))) + 0.2 + 0.6 * hash(seed, i, 100)) * step;
        const cy = (@as(f32, @floatFromInt(@divFloor(i, grid))) + 0.2 + 0.6 * hash(seed, i, 200)) * step;
        // nearest wrapped copy
        var ddx = @abs(px - cx);
        var ddy = @abs(py - cy);
        ddx = @min(ddx, tile_size - ddx);
        ddy = @min(ddy, tile_size - ddy);
        const d = @sqrt(ddx * ddx + ddy * ddy);
        if (d < best[0]) {
            best[1] = best[0];
            best[0] = d;
            id = i;
        } else if (d < best[1]) best[1] = d;
    }
    return .{ .id = id, .edge = best[1] - best[0] };
}

/// Two octaves of tileable value noise, in [0, 1]; `freq` lattice cells per tile.
fn fbm(seed: u32, x: i32, y: i32, freq: i32) f32 {
    return 0.65 * valueNoise(seed, x, y, freq, freq) + 0.35 * valueNoise(seed +% 1, x, y, freq * 2, freq * 2);
}

/// Smoothed value noise with `nx`×`ny` lattice cells per tile, so it wraps at the tile edge.
fn valueNoise(seed: u32, x: i32, y: i32, nx: i32, ny: i32) f32 {
    const u = (@as(f32, @floatFromInt(x)) + 0.5) * @as(f32, @floatFromInt(nx)) / tile_size;
    const v = (@as(f32, @floatFromInt(y)) + 0.5) * @as(f32, @floatFromInt(ny)) / tile_size;
    const gx: i32 = @intFromFloat(@floor(u));
    const gy: i32 = @intFromFloat(@floor(v));
    const fx = u - @floor(u);
    const fy = v - @floor(v);
    const v00 = hash(seed, @mod(gx, nx), @mod(gy, ny));
    const v10 = hash(seed, @mod(gx + 1, nx), @mod(gy, ny));
    const v01 = hash(seed, @mod(gx, nx), @mod(gy + 1, ny));
    const v11 = hash(seed, @mod(gx + 1, nx), @mod(gy + 1, ny));
    const sx = fx * fx * (3 - 2 * fx);
    const sy = fy * fy * (3 - 2 * fy);
    return std.math.lerp(std.math.lerp(v00, v10, sx), std.math.lerp(v01, v11, sx), sy);
}

/// Deterministic hash of (seed, a, b) to [0, 1).
fn hash(seed: u32, a: i32, b: i32) f32 {
    var h = seed ^ @as(u32, @bitCast(a)) *% 0x85ebca6b ^ @as(u32, @bitCast(b)) *% 0xc2b2ae35;
    h ^= h >> 16;
    h *%= 0x7feb352d;
    h ^= h >> 15;
    h *%= 0x846ca68b;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h >> 8)) / (1 << 24);
}

fn rgb(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | @as(u32, g) << 8 | @as(u32, b) << 16 | 0xff << 24;
}

/// Packed RGBA8 color (R in the low byte) with RGB scaled by `f`.
fn shade(color: u32, f: f32) Rgba {
    var out: Rgba = undefined;
    for (0..3) |i| {
        const c: f32 = @floatFromInt((color >> @intCast(i * 8)) & 0xff);
        out[i] = @intFromFloat(std.math.clamp(c * f, 0, 255));
    }
    out[3] = @truncate(color >> 24);
    return out;
}

/// Minimal PNG: RGBA8, filter 0 on every row, zlib with stored (uncompressed) blocks.
fn encodePng(gpa: std.mem.Allocator, pixels: []const Rgba, w: u32, h: u32) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    for (0..h) |y| {
        try raw.append(gpa, 0);
        try raw.appendSlice(gpa, std.mem.sliceAsBytes(pixels[y * w ..][0..w]));
    }

    var zlib: std.ArrayList(u8) = .empty;
    try zlib.appendSlice(gpa, &.{ 0x78, 0x01 });
    var rest = raw.items;
    while (true) {
        const len: u16 = @intCast(@min(rest.len, 0xffff));
        const final = len == rest.len;
        try zlib.append(gpa, @intFromBool(final));
        try zlib.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, len)));
        try zlib.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~len)));
        try zlib.appendSlice(gpa, rest[0..len]);
        rest = rest[len..];
        if (final) break;
    }
    try zlib.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Adler32.hash(raw.items))));

    var png: std.ArrayList(u8) = .empty;
    try png.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..].* = .{ 8, 6, 0, 0, 0 }; // 8-bit RGBA, deflate, no filter, no interlace
    try appendChunk(gpa, &png, "IHDR", &ihdr);
    try appendChunk(gpa, &png, "IDAT", zlib.items);
    try appendChunk(gpa, &png, "IEND", "");
    return png.items;
}

fn appendChunk(gpa: std.mem.Allocator, png: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    try png.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(data.len))));
    try png.appendSlice(gpa, kind);
    try png.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try png.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, crc.final())));
}
