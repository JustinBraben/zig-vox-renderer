const std = @import("std");
const Allocator = std.mem.Allocator;
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const Shader = @import("../shader.zig");

const Mesh = @This();

allocator: Allocator,
vertex_positions = std.ArrayList(gl.Float),
normal_positions = std.ArrayList(gl.Float),
texture_coords = std.ArrayList(gl.Float),

pub fn init(gpa: Allocator) Mesh {
    return .{
        .allocator = gpa,
        .vertex_positions = std.ArrayList(gl.Float).init(gpa),
        .normal_positions = std.ArrayList(gl.Float).init(gpa),
        .texture_coords = std.ArrayList(gl.Float).init(gpa),
    };
}

pub fn deinit(self: *Mesh) void {
    self.vertex_positions.deinit();
    self.normal_positions.deinit();
    self.texture_coords.deinit();
}