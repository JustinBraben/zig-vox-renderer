//! The in-game HUD, built as sprites in window pixels: the hotbar with block icons and
//! counts, hearts in survival, and a red flash when hurt. Sizes are in HUD units,
//! a whole number of pixels that grows with the window.

const std = @import("std");
const sprites = @import("../gfx/sprites.zig");
const Batch = sprites.Batch;
const rgba = sprites.rgba;
const Inventory = @import("../game/inventory.zig");
const BlockId = @import("../world/block.zig").BlockId;

pub const State = struct {
    inventory: *const Inventory,
    survival: bool,
    health: u8,
    max_health: u8,
    /// 1 right after being hurt, fading to 0
    hurt: f32,
};

const slot = 20;
const hotbar_w = Inventory.size * slot + 2;
const hotbar_h = slot + 2;

const no_texture = sprites.no_texture;

/// HUD unit in pixels for a window `height` pixels tall.
pub fn unit(height: f32) f32 {
    return @max(1, @floor(height / 400));
}

pub fn build(batch: *Batch, width: f32, height: f32, state: State) void {
    if (state.hurt > 0) batch.rect(0, 0, width, height, no_texture, rgba(200, 0, 0, @intFromFloat(90 * @min(state.hurt, 1))));

    const u = unit(height);
    const x0 = @floor((width - hotbar_w * u) / 2);
    const y0 = height - (hotbar_h + 2) * u;
    batch.rect(x0, y0, hotbar_w * u, hotbar_h * u, no_texture, rgba(0, 0, 0, 120));
    for (state.inventory.slots, 0..) |stack, i| {
        const sx = x0 + (1 + @as(f32, @floatFromInt(i)) * slot) * u;
        const sy = y0 + u;
        batch.rect(sx + u, sy + u, (slot - 2) * u, (slot - 2) * u, no_texture, rgba(110, 110, 110, 90));
        if (stack.count == 0) continue;
        icon(batch, stack.block, sx + slot / 2 * u, sy + slot / 2 * u, 7 * u);
        if (state.survival and stack.count > 1) number(batch, stack.count, sx + (slot - 1) * u, sy + (slot - 1) * u, u);
    }
    const selected = x0 + @as(f32, @floatFromInt(state.inventory.selected)) * slot * u;
    frame(batch, selected, y0, (slot + 2) * u, (slot + 2) * u, u, rgba(240, 240, 240, 255));

    if (state.survival) hearts(batch, x0, y0 - 9 * u, u, state.health, state.max_health);
}

/// An isometric cube `2 * w` across centered on (cx, cy): top, front (+Z) and right (+X) faces.
pub fn icon(batch: *Batch, id: BlockId, cx: f32, cy: f32, w: f32) void {
    const faces = sprites.Faces.of(id);
    const t = [3]f32{ cx, cy - w, 0 };
    const l = [3]f32{ cx - w, cy - w / 2, 0 };
    const r = [3]f32{ cx + w, cy - w / 2, 0 };
    const c = [3]f32{ cx, cy, 0 };
    const bl = [3]f32{ cx - w, cy + w / 2, 0 };
    const br = [3]f32{ cx + w, cy + w / 2, 0 };
    const b = [3]f32{ cx, cy + w, 0 };
    batch.quad(.{ t, r, c, l }, faces.layers[2], faces.colors[2]);
    batch.quad(.{ l, c, b, bl }, faces.layers[4], sprites.shade(faces.colors[4], 0.8));
    batch.quad(.{ c, r, br, b }, faces.layers[0], sprites.shade(faces.colors[0], 0.6));
}

/// A rectangle outline `u` thick.
fn frame(batch: *Batch, x: f32, y: f32, w: f32, h: f32, u: f32, color: u32) void {
    batch.rect(x, y, w, u, no_texture, color);
    batch.rect(x, y + h - u, w, u, no_texture, color);
    batch.rect(x, y + u, u, h - 2 * u, no_texture, color);
    batch.rect(x + w - u, y + u, u, h - 2 * u, no_texture, color);
}

/// 3×5 pixel digits, rows top to bottom, bit 2 the left column.
const digits = [10][5]u3{
    .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
    .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
    .{ 0b111, 0b001, 0b111, 0b100, 0b111 },
    .{ 0b111, 0b001, 0b111, 0b001, 0b111 },
    .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
    .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
    .{ 0b111, 0b100, 0b111, 0b101, 0b111 },
    .{ 0b111, 0b001, 0b001, 0b001, 0b001 },
    .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
    .{ 0b111, 0b101, 0b111, 0b001, 0b111 },
};

/// `value` in white with a shadow, its bottom-right corner at (right, bottom).
fn number(batch: *Batch, value: u32, right: f32, bottom: f32, u: f32) void {
    var v = value;
    var x = right - 3 * u;
    while (true) {
        const d = digits[v % 10];
        for (d, 0..) |row, ry| {
            for (0..3) |rx| {
                if (row & (@as(u3, 4) >> @intCast(rx)) == 0) continue;
                const px = x + @as(f32, @floatFromInt(rx)) * u;
                const py = bottom - (5 - @as(f32, @floatFromInt(ry))) * u;
                batch.rect(px + u, py + u, u, u, no_texture, rgba(40, 40, 40, 255));
                batch.rect(px, py, u, u, no_texture, rgba(255, 255, 255, 255));
            }
        }
        v /= 10;
        if (v == 0) break;
        x -= 4 * u;
    }
}

const heart = [6]*const [7]u8{
    ".XX.XX.",
    "XXXXXXX",
    "XXXXXXX",
    ".XXXXX.",
    "..XXX..",
    "...X...",
};

/// One heart per 2 health, left to right; an odd point is half a heart.
fn hearts(batch: *Batch, x0: f32, y0: f32, u: f32, health: u8, max_health: u8) void {
    var i: u8 = 0;
    while (i < max_health / 2) : (i += 1) {
        const hx = x0 + @as(f32, @floatFromInt(i)) * 8 * u;
        // left columns red up to here
        const filled: usize = if (health >= 2 * i + 2) 7 else if (health == 2 * i + 1) 4 else 0;
        for (heart, 0..) |row, ry| {
            for (row, 0..) |ch, rx| {
                if (ch != 'X') continue;
                const shine = rx == 1 and ry == 1;
                const color = if (rx < filled) (if (shine) rgba(255, 170, 170, 255) else rgba(215, 30, 30, 255)) else rgba(45, 12, 12, 200);
                batch.rect(hx + @as(f32, @floatFromInt(rx)) * u, y0 + @as(f32, @floatFromInt(ry)) * u, u, u, no_texture, color);
            }
        }
    }
}

test "everything fits in a frame's batch" {
    var storage: [8192]sprites.Vertex = undefined;
    var batch: Batch = .{ .vertices = &storage };
    var inv: Inventory = .{};
    for (0..Inventory.size) |_| _ = inv.add(.dirt, 64);
    build(&batch, 1600, 900, .{ .inventory = &inv, .survival = true, .health = 13, .max_health = 20, .hurt = 0.5 });
    try std.testing.expect(batch.len > 0 and batch.len < storage.len);
}
