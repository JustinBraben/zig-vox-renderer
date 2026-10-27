//! The player's hotbar: `size` slots of stacked blocks, one of them selected.

const std = @import("std");
const block = @import("../world/block.zig");
const BlockId = block.BlockId;
const Stack = block.Stack;

const Self = @This();

pub const size = 9;

slots: [size]Stack = @splat(.{}),
selected: usize = 0,

/// Adds `count` of `id`, topping up its stacks first, then filling empty slots from
/// the left. Returns how many didn't fit.
pub fn add(self: *Self, id: BlockId, count: u8) u8 {
    var left = count;
    for (&self.slots) |*slot| {
        if (left == 0) break;
        if (slot.count == 0 or slot.block != id) continue;
        const n = @min(left, Stack.max - slot.count);
        slot.count += n;
        left -= n;
    }
    for (&self.slots) |*slot| {
        if (left == 0) break;
        if (slot.count != 0) continue;
        const n = @min(left, Stack.max);
        slot.* = .{ .block = id, .count = n };
        left -= n;
    }
    return left;
}

/// The block in the selected slot, if any.
pub fn held(self: *const Self) ?BlockId {
    const slot = self.slots[self.selected];
    return if (slot.count > 0) slot.block else null;
}

/// Removes one block from the selected slot and returns it, or null when it's empty.
pub fn takeOne(self: *Self) ?BlockId {
    const id = self.held() orelse return null;
    const slot = &self.slots[self.selected];
    slot.count -= 1;
    if (slot.count == 0) slot.* = .{};
    return id;
}

/// Selects the next (`delta` > 0) or previous slot, wrapping around.
pub fn scroll(self: *Self, delta: i32) void {
    self.selected = @intCast(@mod(@as(i32, @intCast(self.selected)) + delta, size));
}

/// Creative mode's pick block: selects `id` if the hotbar has it, otherwise puts one in
/// the selected slot.
pub fn pick(self: *Self, id: BlockId) void {
    for (self.slots, 0..) |slot, i| {
        if (slot.count > 0 and slot.block == id) {
            self.selected = i;
            return;
        }
    }
    self.slots[self.selected] = .{ .block = id, .count = 1 };
}

/// Puts a block from the palette (`BlockId.placeable`) that the hotbar doesn't have yet
/// into every empty slot, so creative mode has something to build with.
pub fn fillEmpty(self: *Self) void {
    var next: usize = 0;
    for (&self.slots) |*slot| {
        if (slot.count > 0) continue;
        while (next < BlockId.placeable.len and self.has(BlockId.placeable[next])) next += 1;
        if (next == BlockId.placeable.len) return;
        slot.* = .{ .block = BlockId.placeable[next], .count = 1 };
    }
}

fn has(self: *const Self, id: BlockId) bool {
    for (self.slots) |slot| {
        if (slot.count > 0 and slot.block == id) return true;
    }
    return false;
}

/// Empties slots holding something that isn't a block (from a damaged save) and keeps
/// counts and the selection in range.
pub fn sanitize(self: *Self) void {
    for (&self.slots) |*slot| {
        const named = std.enums.tagName(BlockId, slot.block) != null;
        if (slot.count == 0 or !named or slot.block == .air) {
            slot.* = .{};
        } else {
            slot.count = @min(slot.count, Stack.max);
        }
    }
    self.selected = @min(self.selected, size - 1);
}

const testing = std.testing;

test "adds onto existing stacks before empty slots, up to a full stack" {
    var inv: Self = .{};
    inv.slots[3] = .{ .block = .dirt, .count = 60 };
    try testing.expectEqual(0, inv.add(.dirt, 10));
    try testing.expectEqual(Stack{ .block = .dirt, .count = 64 }, inv.slots[3]);
    try testing.expectEqual(Stack{ .block = .dirt, .count = 6 }, inv.slots[0]);

    try testing.expectEqual(0, inv.add(.stone, 1));
    try testing.expectEqual(Stack{ .block = .stone, .count = 1 }, inv.slots[1]);
}

test "returns what doesn't fit" {
    var inv: Self = .{};
    for (0..size) |_| try testing.expectEqual(0, inv.add(.sand, 64));
    try testing.expectEqual(5, inv.add(.sand, 5));
    try testing.expectEqual(3, inv.add(.dirt, 3));
}

test "taking the last one empties the slot" {
    var inv: Self = .{};
    _ = inv.add(.planks, 2);
    try testing.expectEqual(BlockId.planks, inv.takeOne().?);
    try testing.expectEqual(BlockId.planks, inv.takeOne().?);
    try testing.expectEqual(null, inv.takeOne());
    try testing.expectEqual(Stack{}, inv.slots[0]);
}

test "scrolling wraps, picking selects or replaces" {
    var inv: Self = .{};
    inv.scroll(-1);
    try testing.expectEqual(size - 1, inv.selected);
    inv.scroll(1);
    try testing.expectEqual(0, inv.selected);

    _ = inv.add(.dirt, 1);
    _ = inv.add(.stone, 1);
    inv.selected = 4;
    inv.pick(.stone);
    try testing.expectEqual(1, inv.selected);
    inv.pick(.glass);
    try testing.expectEqual(Stack{ .block = .glass, .count = 1 }, inv.slots[1]);
}

test "fills empty slots with blocks it doesn't have" {
    var inv: Self = .{};
    inv.slots[2] = .{ .block = .grass, .count = 5 };
    inv.fillEmpty();
    for (inv.slots, 0..) |slot, i| {
        try testing.expect(slot.count > 0);
        for (inv.slots[i + 1 ..]) |other| try testing.expect(other.block != slot.block);
    }
    try testing.expectEqual(5, inv.slots[2].count);
}
