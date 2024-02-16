const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Persistance = struct {
    const Self = @This();

    allocator: Allocator,
    path: [:0]const u8,

    pub fn init(allocator: Allocator, path: [:0]const u8) !Self {
        // TODO: read contents of path and save it in Self

        return Self {
            .allocator = allocator,
            .path = path,
        };
    }
};