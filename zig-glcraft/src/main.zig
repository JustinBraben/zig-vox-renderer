const std = @import("std");
const glfw = @import("mach-glfw");
const gl = @import("gl");
const Application = @import("Application/application.zig").Application;

const app_name = "Soon to be minecraft clone!";

const log = std.log.scoped(.Main);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() ==  .leak) {
        @panic("Memory leak detected");
    };

    var app = try Application.init(gpa.allocator(), app_name, 1200, 800);
    defer app.deinit();

    app.run();
}