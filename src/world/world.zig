const std = @import("std");
const Allocator = std.mem.Allocator;
const zm = @import("zmath");
const znoise = @import("znoise");
const Chunk = @import("chunk.zig");
const Atlas = @import("../gfx/atlas.zig");
const Utils = @import("../utils.zig");

const World = @This();

allocator: Allocator,
rng: std.Random.DefaultPrng,
seed: i32,
gen: znoise.FnlGenerator,
chunks: std.ArrayList(Chunk),

pub fn init(gpa: Allocator) !World {
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const seed = rng.random().int(i32);
    const gen = znoise.FnlGenerator{
        .seed = @intCast(seed)
    };
    return .{
        .allocator = gpa,
        .rng = rng,
        .seed = seed,
        .gen = gen,
        .chunks = std.ArrayList(Chunk).init(gpa),
    };
}

// pub fn generate(self: *World, atlas: *const Atlas) !void {
//     try self.chunks.append(Chunk.init(self.allocator, .{ .x = 0, .z = -1 }));
//     var basic_chunk = self.chunks.getLast();
//     basic_chunk.setBlock(1, 1, 1, .{ .id = 1 });
//     basic_chunk.setBlock(5, 5, 5, .{ .id = 1 });
//     basic_chunk.setBlock(6, 6, 6, .{ .id = 1 });
//     basic_chunk.setBlock(8, 10, 10, .{ .id = 1 });
//     basic_chunk.setBlock(10, 10, 10, .{ .id = 1 });
//     try basic_chunk.generateMesh(atlas);
// }

// pub fn generate(self: *World) !void {
//     // for (0..1000) |x_pos| {
//     //     for (0..1000) |z_pos| {
//     //         const x = @mod(@as(f32, @floatFromInt(x_pos)), 1000.0);
//     //         const z = @mod(@as(f32, @floatFromInt(z_pos)), 1000.0);

//     //         const y = @floor(self.gen.noise2(x, z) * self.height_range);

//     //         // const position = zm.translation(x, y, z);
//     //         try self.model_matrices.append(zm.matToArr(zm.translation(x, y, z)));
//     //     }
//     // }

//     // TODO: Fix chunk generation
//     // for (0..10) |x_pos| {
//     //     for (0..10) |y_pos| {
//     //         for (0..10) |z_pos| {
//     //             const x = @as(f32, @floatFromInt(x_pos));
//     //             const y = @as(f32, @floatFromInt(y_pos));
//     //             const z = @as(f32, @floatFromInt(z_pos));

//     //             self.chunk.setBlock(.Cube, @intFromFloat(x), @intFromFloat(y), @intFromFloat(z));
//     //             try self.model_matrices.append(zm.matToArr(zm.translation(x, y, z)));
//     //         }
//     //     }
//     // }

//     for (0..200) |x_pos| {
//         for (0..100) |y_pos| {
//             for (0..100) |z_pos| {
//                 const x = @mod(@as(f32, @floatFromInt(x_pos)), 1000.0);
//                 const y = @mod(@as(f32, @floatFromInt(y_pos)), 1000.0);
//                 const z = @mod(@as(f32, @floatFromInt(z_pos)), 1000.0);
                
//                 const noise = self.gen.noise3(x, y, z);
//                 if (noise > 0) {
//                     try self.model_matrices.append(zm.matToArr(zm.translation(x, y, z)));
//                 }
//             }
//         }
//     }

//     self.flattened_matrices = try Utils.flattenMatrices(self.model_matrices.items, self.allocator);
// }

pub fn deinit(self: *World) void {
    for (self.chunks.items) |*chunk| {
        chunk.deinit();
    }
    self.chunks.deinit();
}

pub fn draw(self: *World) void {
    for (self.chunks.items) |chunk| {
        if (chunk.mesh) |*mesh| {
            _ = mesh;
            // const chunk_offset = chunk.pos.worldOffset();

            // const chunk_model = zm.translation(
            //     chunk_offset[0],
            //     0.0,
            //     chunk_offset[2]
            // );
            
            // // Set the model matrix for the chunk
            // basic_voxel_mesh_shader.setMat4f("u_model", zm.matToArr(chunk_model));

            // gl.activeTexture(gl.TEXTURE0);
            // texture_atlas.texture.bind();
            // mesh.draw();
        }
    }
}