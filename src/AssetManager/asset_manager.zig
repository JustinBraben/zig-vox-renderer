const std = @import("std");
const Allocator = std.mem.Allocator;
const CubeMapRegistry = @import("cubemap_registry.zig").CubeMapRegistry;

pub const AssetManager = struct {
    allocator: Allocator,
    cube_map_registry: CubeMapRegistry,

    pub fn init(allocator: *Allocator) AssetManager {
        return AssetManager {
            .cube_map_registry = try CubeMapRegistry.init(allocator),
        };
    }

    pub fn removeCubeMapFromRegistry(self: *AssetManager, name: [:0]const u8) void {
        self.cube_map_registry.remove(name);
    }
};