const std = @import("std");
const Allocator = std.mem.Allocator;
const zm = @import("zmath");
const znoise = @import("znoise");
const Utils = @import("../utils.zig");
const Chunk = @import("Chunk/chunk.zig");

const World = @This();

allocator: Allocator,
chunk: Chunk,
model_matrices: std.ArrayList([16]f32),
flattened_matrices: []f32,
height_range: f32,
rng: std.Random.Xoshiro256,
seed: i32,
gen: znoise.FnlGenerator,

pub fn init(gpa: Allocator, height_range: f32) !World {
    var rng = std.Random.Xoshiro256.init(@intCast(std.time.timestamp()));
    const seed = rng.random().int(i32);
    const gen = znoise.FnlGenerator{
        .seed = @intCast(seed)
    };
    return .{
        .allocator = gpa,
        .chunk = .{},
        .model_matrices = std.ArrayList([16]f32).init(gpa),
        .flattened_matrices = undefined,
        .height_range = height_range,
        .rng = rng,
        .seed = seed,
        .gen = gen,
    };
}

pub fn generate(self: *World) !void {
    // for (0..1000) |x_pos| {
    //     for (0..1000) |z_pos| {
    //         const x = @mod(@as(f32, @floatFromInt(x_pos)), 1000.0);
    //         const z = @mod(@as(f32, @floatFromInt(z_pos)), 1000.0);

    //         const y = @floor(self.gen.noise2(x, z) * self.height_range);

    //         // const position = zm.translation(x, y, z);
    //         try self.model_matrices.append(zm.matToArr(zm.translation(x, y, z)));
    //     }
    // }

    // TODO: Fix chunk generation
    // for (0..10) |x_pos| {
    //     for (0..10) |y_pos| {
    //         for (0..10) |z_pos| {
    //             const x = @as(f32, @floatFromInt(x_pos));
    //             const y = @as(f32, @floatFromInt(y_pos));
    //             const z = @as(f32, @floatFromInt(z_pos));

    //             self.chunk.setBlock(.Cube, @intFromFloat(x), @intFromFloat(y), @intFromFloat(z));
    //             try self.model_matrices.append(zm.matToArr(zm.translation(x, y, z)));
    //         }
    //     }
    // }

    for (0..200) |x_pos| {
        for (0..100) |y_pos| {
            for (0..100) |z_pos| {
                const x = @mod(@as(f32, @floatFromInt(x_pos)), 1000.0);
                const y = @mod(@as(f32, @floatFromInt(y_pos)), 1000.0);
                const z = @mod(@as(f32, @floatFromInt(z_pos)), 1000.0);
                
                const noise = self.gen.noise3(x, y, z);
                if (noise > 0) {
                    try self.model_matrices.append(zm.matToArr(zm.translation(x, y, z)));
                }
            }
        }
    }

    self.flattened_matrices = try Utils.flattenMatrices(self.model_matrices.items, self.allocator);
}

pub fn deinit(self: *World) void {
    self.allocator.free(self.flattened_matrices);
    self.model_matrices.deinit();
}