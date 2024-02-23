const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const builtin = @import("builtin");
const assert = std.debug.assert;
const ecs = @import("mach-ecs");
const EntityID = ecs.EntityID;

const Vec2 = @Vector(2, f32);

const Rotation = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

const Input = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
};

const all_components = .{
    .entity = struct {
        pub const id = EntityID;
    },
    .game = struct {
        pub const rotation = Rotation;
        pub const name = []const u8;
        pub const input = Input;
    },
};

test "ref all decls" {
    testing.refAllDecls(ecs.Entities(.{}));
}

test "entity ID size" {
    
}

test "create world" {
    const allocator = testing.allocator;

    // Create a world.
    var world = try ecs.Entities(.{}).init(allocator);
    defer world.deinit();

    // Create an entity and add dynamic components.
    const player1 = try world.new();
    try world.setComponentDynamic(player1, world.componentName("game.name"), "jane", @alignOf([]const u8), 100);
    try world.setComponentDynamic(player1, world.componentName("game.name"), "joey", @alignOf([]const u8), 100);

    // Get components
    try testing.expect(world.getComponentDynamic(player1, world.componentName("game.rotation"), @sizeOf(Rotation), @alignOf(Rotation), 102) == null);
}