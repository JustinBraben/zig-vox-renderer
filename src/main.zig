const std = @import("std");
const math = std.math;
const zgui = @import("zgui");
const glfw = @import("zglfw");
const zstbi = @import("zstbi");
const zm = @import("zmath");
const Application = @import("application.zig");

pub fn main() !void {
    var app = try Application.init(.{});
    defer app.deinit();
    try app.runLoop();
}