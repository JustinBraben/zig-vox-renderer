const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pipeline = struct {
    allocator: Allocator,
    vert_file_path: []const u8,
    frag_file_path: []const u8,

    pub fn init(allocator: Allocator, vert_file_path: []const u8, frag_file_path: []const u8) !Pipeline {
        return Pipeline {
            .allocator = allocator,
            .vert_file_path = vert_file_path,
            .frag_file_path = frag_file_path,
        };
    }
};