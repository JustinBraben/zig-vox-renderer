const std = @import("std");
const Allocator = std.mem.Allocator;
const glm = @import("ziglm");
const Texture = @import("../Rendering/texture.zig").Texture;
const Persistence = @import("../Persistence/persistence.zig").Persistance;
const Skybox = @import("skybox.zig").Skybox;

const Mat4x4 = glm.Mat4x4;

pub const Scene = struct {
    const Self = @This();

    allocator: Allocator,

    persistence: *Persistence,

    skybox: Skybox,

    z_near: f32 = 0.1,
    z_far: f32 = 1000.0,
    projection_matrix: Mat4x4(f32),
    delta_time: f32 = 1.0,

    pub fn init(allocator: Allocator, savePath: [:0]const u8) !Self {
        var persistence = try Persistence.init(allocator, savePath);
        return Self{
            .allocator = allocator,
            .persistence = &persistence,
            .skybox = try Skybox.init(allocator),
            .z_near = 0.1,
            .z_far = 1000.0,
            .projection_matrix = Mat4x4(f32).as(1),
            .delta_time = 1.0,
        };
    }

    pub fn update(self: *Self, deltaTime: f32) void {
        self.delta_time = deltaTime;

        // TODO: update player

        // TODO: update world

        // TODO: update skybox
    }

    pub fn render(self: *const Self) void {
        _ = self;

        // std.debug.print("Rendering scene\n", .{});

        // TODO: render skybox

        // TODO: render world transparent objects if xray mode is enabled

        // TODO: otherwise render opaque objects

        // TODO: render outline

        // TODO render post processing effects
    }
};