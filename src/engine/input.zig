const std = @import("std");
const Allocator = std.mem.Allocator;
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const Window = @import("window.zig");

const Input = @This();

window: *glfw.Window,

pub fn init(window: *Window) !Input {
    return .{
        .window = window.window,
    };
}

pub fn deinit(self: *Input) void {
    _ = &self;
}

pub fn update(self: *Input) void {
    glfw.pollEvents();
    if (self.window.getKey(.escape) == .press) {
        self.window.setShouldClose(true);
    }
}

pub fn isKeyPressed(self: *Input, key: glfw.Key) bool {
    if (key == .escape and self.window.getKey(key) == .press) {
        return true;
    }

    return false;
}