const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CubeMapRegistry = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) !CubeMapRegistry {
        return .{
            .allocator = allocator,
        };
    }

    pub fn remove(self: *CubeMapRegistry, name: [:0]const u8) void {
        // TODO: Implement remove
        _ = self;
        _ = name;
    }
};