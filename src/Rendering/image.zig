const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Image = struct {

    width: u32,
    height: u32,
    data: std.ArrayList(u8),
};