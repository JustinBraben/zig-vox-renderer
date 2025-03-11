const std = @import("std");
const ztracy = @import("ztracy");
const Application = @import("application.zig");

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const tracy_zone_app_init = ztracy.ZoneNC(@src(), "Initialize application", 0x00_ff_00_00);
    var app = try Application.init(gpa, .{});
    defer app.deinit();
    tracy_zone_app_init.End();
    const tracy_zone = ztracy.ZoneN(@src(), "runLoop");
    defer tracy_zone.End();
    try app.runLoop();
}

comptime {
    _ = @import("entity/registry.zig");
}