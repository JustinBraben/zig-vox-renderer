//! Survival and creative rules on top of the world and the player: the hotbar, breaking
//! and placing blocks, dropped items, health and fall damage.
//!
//! In survival, blocks take time to break (`BlockId.breakSeconds`) and drop an item,
//! placing uses up blocks from the hotbar, falls hurt and there is no flying. Creative
//! breaks blocks at once, never runs out of them and can pick any block it points at.

const std = @import("std");
const Allocator = std.mem.Allocator;
const BlockId = @import("../world/block.zig").BlockId;
const raycast = @import("../world/raycast.zig");
const math = @import("../math.zig");
const Player = @import("../player.zig");
const Inventory = @import("inventory.zig");
const Items = @import("items.zig");

const Pos = @Vector(3, f64);

const Self = @This();

pub const Mode = enum { survival, creative };

pub const max_health = 20;
/// falls up to this many blocks don't hurt; each block beyond costs 1 health
const safe_fall = 3;
/// seconds per health point regained
const regen_seconds = 4;
/// seconds the screen flashes red after being hurt
pub const hurt_seconds = 0.5;
/// seconds before a broken block's drop can be picked up
const drop_pickup_delay = 0.25;
/// seconds before a thrown block can be picked up again, and how fast it's thrown
const throw_pickup_delay = 1.5;
const throw_speed = 6;

/// A block being broken in survival.
pub const Mining = struct {
    block: [3]i32,
    /// 0..1 of the block's break time
    progress: f32 = 0,
};

/// What happened in a `step`.
pub const Events = struct {
    /// blocks picked up
    picked: u32 = 0,
    died: bool = false,
};

allocator: Allocator,
mode: Mode = .survival,
inventory: Inventory = .{},
health: u8 = max_health,
items: Items = .{},
mining: ?Mining = null,
regen_timer: f32 = 0,
/// counts down from `hurt_seconds` after taking damage
hurt_timer: f32 = 0,
/// where the player comes back after dying
spawn: Pos,
rng: std.Random.DefaultPrng,

pub fn init(allocator: Allocator, spawn: Pos) Self {
    return .{ .allocator = allocator, .spawn = spawn, .rng = .init(0x5eed) };
}

pub fn deinit(self: *Self) void {
    self.items.deinit(self.allocator);
}

pub fn setMode(self: *Self, mode: Mode, player: *Player) void {
    self.mode = mode;
    self.mining = null;
    switch (mode) {
        .survival => player.setFlying(false),
        .creative => self.inventory.fillEmpty(),
    }
}

/// One fixed step, after the player's: fall damage, dropped items, healing, dying.
/// `world` as for `Items.step`.
pub fn step(self: *Self, world: anytype, player: *Player, dt: f64) Events {
    var events: Events = .{};
    if (player.takeLanding()) |fall| {
        if (self.mode == .survival and fall > safe_fall) self.hurt(@intFromFloat(@ceil(fall - safe_fall)));
    }
    self.items.step(world, dt);
    events.picked = self.items.collect(player, &self.inventory);

    const seconds: f32 = @floatCast(dt);
    self.hurt_timer = @max(self.hurt_timer - seconds, 0);
    if (self.health == 0) {
        self.respawn(player);
        events.died = true;
    } else if (self.health < max_health and self.mode == .survival) {
        self.regen_timer += seconds;
        if (self.regen_timer >= regen_seconds) {
            self.health += 1;
            self.regen_timer = 0;
        }
    } else {
        self.regen_timer = 0;
    }
    return events;
}

pub fn hurt(self: *Self, amount: u32) void {
    self.health -|= @intCast(@min(amount, max_health));
    self.hurt_timer = hurt_seconds;
    self.regen_timer = 0;
}

/// Back at the spawn point with full health; the hotbar is kept.
fn respawn(self: *Self, player: *Player) void {
    player.* = .init(self.spawn);
    self.health = max_health;
    self.mining = null;
}

/// Breaks the block at `target`: in survival over time while `held` (returning to 0
/// when the target changes or the button is let go), in creative at once when
/// `clicked`. Returns whether it broke. `world.setBlock(x, y, z, BlockId) !void`.
pub fn dig(self: *Self, world: anytype, target: ?raycast.Hit, held: bool, clicked: bool, dt: f32) !bool {
    const hit = target orelse {
        self.mining = null;
        return false;
    };
    const b = hit.block;
    if (self.mode == .creative) {
        self.mining = null;
        if (!clicked) return false;
        try world.setBlock(b[0], b[1], b[2], .air);
        return true;
    }
    if (!held) {
        self.mining = null;
        return false;
    }
    var mining: Mining = .{ .block = b };
    if (self.mining) |m| {
        if (std.meta.eql(m.block, b)) mining = m;
    }
    mining.progress += dt / hit.id.breakSeconds();
    if (mining.progress < 1) {
        self.mining = mining;
        return false;
    }
    self.mining = null;
    try world.setBlock(b[0], b[1], b[2], .air);
    if (hit.id.drop()) |id| {
        const random = self.rng.random();
        const center: Pos = .{ @as(f64, @floatFromInt(b[0])) + 0.5, @as(f64, @floatFromInt(b[1])) + 0.25, @as(f64, @floatFromInt(b[2])) + 0.5 };
        const velocity: Pos = .{ random.float(f64) * 2 - 1, 3, random.float(f64) * 2 - 1 };
        try self.items.spawn(self.allocator, .{ .block = id, .count = 1 }, center, velocity, drop_pickup_delay);
    }
    return true;
}

/// The crack stage (0..`Tile.crack_stages`) of the block being broken, if any.
pub fn crack(self: *const Self) ?struct { block: [3]i32, stage: usize } {
    const m = self.mining orelse return null;
    return .{ .block = m.block, .stage = @intFromFloat(m.progress * 10) };
}

/// Places the selected block against the face of `hit`, using one up in survival.
/// Returns whether it was placed. `world.getBlock(x, y, z) ?BlockId` as well.
pub fn place(self: *Self, world: anytype, player: *const Player, hit: raycast.Hit) !bool {
    if (std.meta.eql(hit.normal, .{ 0, 0, 0 })) return false;
    const id = self.inventory.held() orelse return false;
    const p = hit.adjacent();
    if (world.getBlock(p[0], p[1], p[2]) == null) return false;
    if (id.isSolid() and player.intersectsBlock(p[0], p[1], p[2])) return false;
    try world.setBlock(p[0], p[1], p[2], id);
    if (self.mode == .survival) _ = self.inventory.takeOne();
    return true;
}

/// Creative's pick block: the targeted block into the hotbar.
pub fn pick(self: *Self, hit: raycast.Hit) void {
    if (self.mode == .creative) self.inventory.pick(hit.id);
}

/// Throws one of the selected block the way the player looks.
pub fn throwHeld(self: *Self, player: *const Player, forward: math.Vec3) !void {
    const id = (if (self.mode == .survival) self.inventory.takeOne() else self.inventory.held()) orelse return;
    const dir: Pos = @floatCast(forward);
    const from = player.eye(1) - Pos{ 0, 0.3, 0 } + dir * @as(Pos, @splat(0.3));
    const velocity = dir * @as(Pos, @splat(throw_speed)) + Pos{ 0, 1.5, 0 };
    try self.items.spawn(self.allocator, .{ .block = id, .count = 1 }, from, velocity, throw_pickup_delay);
}

/// Stone below y = 0, plus whatever was set.
const TestWorld = struct {
    blocks: std.AutoHashMapUnmanaged([3]i32, BlockId) = .empty,

    fn deinit(self: *TestWorld) void {
        self.blocks.deinit(std.testing.allocator);
    }

    pub fn getBlock(self: *const TestWorld, x: i32, y: i32, z: i32) ?BlockId {
        return self.blocks.get(.{ x, y, z }) orelse if (y < 0) .stone else .air;
    }

    pub fn setBlock(self: *TestWorld, x: i32, y: i32, z: i32, id: BlockId) !void {
        try self.blocks.put(std.testing.allocator, .{ x, y, z }, id);
    }

    pub fn isSolid(self: *const TestWorld, x: i32, y: i32, z: i32) bool {
        return self.getBlock(x, y, z).?.isSolid();
    }

    pub fn isWater(self: *const TestWorld, x: i32, y: i32, z: i32) bool {
        return self.getBlock(x, y, z).? == .water;
    }
};

const testing = std.testing;
const test_dt = 1.0 / 60.0;

fn hitAt(block: [3]i32, id: BlockId) raycast.Hit {
    return .{ .block = block, .normal = .{ 0, 1, 0 }, .id = id, .distance = 2 };
}

test "survival: digging takes the block's time, and its drop is picked up" {
    var world: TestWorld = .{};
    defer world.deinit();
    var game = Self.init(testing.allocator, .{ 0.5, 0, 0.5 });
    defer game.deinit();
    var player = Player.init(.{ 0.5, 0, 0.5 });
    const target = hitAt(.{ 1, -1, 0 }, .stone);

    const steps: usize = @intFromFloat(@ceil(BlockId.stone.breakSeconds() / test_dt));
    for (0..steps - 1) |_| try testing.expect(!try game.dig(&world, target, true, false, test_dt));
    try testing.expectEqual(BlockId.stone, world.getBlock(1, -1, 0).?);
    try testing.expect(try game.dig(&world, target, true, false, 2 * test_dt));
    try testing.expectEqual(BlockId.air, world.getBlock(1, -1, 0).?);
    try testing.expectEqual(null, game.mining);

    for (0..120) |_| {
        player.step(&world, .{}, 0, 0, test_dt);
        _ = game.step(&world, &player, test_dt);
    }
    try testing.expectEqual(BlockId.cobblestone, game.inventory.held().?);
    try testing.expectEqual(0, game.items.items.items.len);
}

test "survival: letting go or looking away starts over" {
    var world: TestWorld = .{};
    defer world.deinit();
    var game = Self.init(testing.allocator, .{ 0.5, 0, 0.5 });
    defer game.deinit();
    _ = try game.dig(&world, hitAt(.{ 0, -1, 0 }, .stone), true, false, 1);
    try testing.expect(game.crack().?.stage > 0);
    _ = try game.dig(&world, hitAt(.{ 1, -1, 0 }, .stone), true, false, test_dt);
    try testing.expectEqual(0, game.crack().?.stage);
    _ = try game.dig(&world, hitAt(.{ 1, -1, 0 }, .stone), false, false, test_dt);
    try testing.expectEqual(null, game.crack());
}

test "creative: breaks on click, drops nothing, places without using up" {
    var world: TestWorld = .{};
    defer world.deinit();
    var game = Self.init(testing.allocator, .{ 0.5, 0, 0.5 });
    defer game.deinit();
    var player = Player.init(.{ 0.5, 0, 0.5 });
    game.setMode(.creative, &player);
    const target = hitAt(.{ 3, -1, 0 }, .stone);
    try testing.expect(!try game.dig(&world, target, true, false, 10));
    try testing.expect(try game.dig(&world, target, true, true, 0));
    try testing.expectEqual(0, game.items.items.items.len);

    const held = game.inventory.held().?;
    try testing.expect(try game.place(&world, &player, hitAt(.{ 3, -1, 2 }, .stone)));
    try testing.expectEqual(held, world.getBlock(3, 0, 2).?);
    try testing.expectEqual(held, game.inventory.held().?);
}

test "survival: placing uses up blocks, and not inside the player" {
    var world: TestWorld = .{};
    defer world.deinit();
    var game = Self.init(testing.allocator, .{ 0.5, 0, 0.5 });
    defer game.deinit();
    const player = Player.init(.{ 0.5, 0, 0.5 });
    try testing.expect(!try game.place(&world, &player, hitAt(.{ 3, -1, 0 }, .stone)));
    _ = game.inventory.add(.planks, 1);
    try testing.expect(!try game.place(&world, &player, hitAt(.{ 0, -1, 0 }, .stone)));
    try testing.expect(try game.place(&world, &player, hitAt(.{ 3, -1, 0 }, .stone)));
    try testing.expectEqual(BlockId.planks, world.getBlock(3, 0, 0).?);
    try testing.expectEqual(null, game.inventory.held());
}

test "falls hurt in survival only; dying respawns with full health" {
    var world: TestWorld = .{};
    defer world.deinit();
    var game = Self.init(testing.allocator, .{ 0.5, 0, 0.5 });
    defer game.deinit();
    var player = Player.init(.{ 0.5, 10, 0.5 });
    for (0..120) |_| {
        player.step(&world, .{}, 0, 0, test_dt);
        _ = game.step(&world, &player, test_dt);
    }
    try testing.expectEqual(max_health - 7, game.health);

    game.setMode(.creative, &player);
    player = Player.init(.{ 0.5, 10, 0.5 });
    for (0..120) |_| {
        player.step(&world, .{}, 0, 0, test_dt);
        _ = game.step(&world, &player, test_dt);
    }
    try testing.expectEqual(max_health - 7, game.health);

    game.setMode(.survival, &player);
    player = Player.init(.{ 30.5, 40, 30.5 });
    var died = false;
    for (0..240) |_| {
        player.step(&world, .{}, 0, 0, test_dt);
        died = died or game.step(&world, &player, test_dt).died;
    }
    try testing.expect(died);
    try testing.expectEqual(max_health, game.health);
    try testing.expectEqual(0.5, player.position[0]);
}

test "heals over time in survival" {
    var world: TestWorld = .{};
    defer world.deinit();
    var game = Self.init(testing.allocator, .{ 0.5, 0, 0.5 });
    defer game.deinit();
    var player = Player.init(.{ 0.5, 0, 0.5 });
    game.hurt(3);
    try testing.expectEqual(max_health - 3, game.health);
    for (0..@as(usize, regen_seconds) * 60 + 5) |_| _ = game.step(&world, &player, test_dt);
    try testing.expectEqual(max_health - 2, game.health);
}
