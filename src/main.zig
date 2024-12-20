const std = @import("std");
const math = std.math;
const zgui = @import("zgui");
const glfw = @import("zglfw");
const zstbi = @import("zstbi");
const zm = @import("zmath");
const Application = @import("application.zig");

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var app = try Application.init(gpa, .{});
    defer app.deinit();
    try app.runLoop();
}