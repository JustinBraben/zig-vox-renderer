const std = @import("std");
const Allocator = std.mem.Allocator;
const zm = @import("zmath");
const znoise = @import("znoise");
const Chunk = @import("../chunk.zig");

const WorldGen = @This();

seed: i32,

// pub fn init(seed: i32) WorldGen {

// }

// pub fn generate(chunk: *Chunk) void {

// }