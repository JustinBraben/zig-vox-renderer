const std = @import("std");
const core = @import("mach-core");
const gpu = core.gpu;
const zm = @import("zmath.zig");
const zigimg = @import("zigimg");
const assets = @import("assets.zig");
const json = std.json;

pub const App = @This();

const speed = 2.0 * 100.0; // pixels per second

const Vec2 = @Vector(2, f32);

const UniformBufferObject = struct {
    mat: zm.Mat,
};
const AnimationFrame = extern struct {
    id: u8,
    pos: Vec2,
};
const Animation = extern struct {
    id: u8,
    size: Vec2,
    world_pos: Vec2,
    sheet_size: Vec2,
    speed: f32,
    loop: bool,
    current_frame: usize,
};
const Sprite = extern struct {
    pos: Vec2,
    size: Vec2,
    world_pos: Vec2,
    sheet_size: Vec2,
};
const SpriteFrames = extern struct {
    up: Vec2,
    down: Vec2,
    left: Vec2,
    right: Vec2,
};
const JSONFrames = struct {
    up: []f32,
    down: []f32,
    left: []f32,
    right: []f32,
};
const JSONSprite = struct {
    pos: []f32,
    size: []f32,
    world_pos: []f32,
    is_player: bool = false,
    frames: JSONFrames,
};
const SpriteSheet = struct {
    width: f32,
    height: f32,
};
const JSONFrame = struct {
    id: u8,
    pos: []f32,
};
const JSONAnimation = struct {
    id: u8,
    size: []f32,
    world_pos: []f32,
    speed: f32,
    loop: bool,
    frames: []JSONFrame,
};
const JSONData = struct {
    sheet: SpriteSheet,
    sprites: []JSONSprite,
    animations: []JSONAnimation,
};
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

title_timer: core.Timer,
timer: core.Timer,
fps_timer: core.Timer,

pub fn init(app: *App) !void {
    try core.init(.{});

    const allocator = gpa.allocator();

    _ = allocator;
    app.title_timer = try core.Timer.start();
    app.timer = try core.Timer.start();
    app.fps_timer = try core.Timer.start();
}

pub fn deinit(app: *App) void {
    defer _ = gpa.deinit();
    defer core.deinit();
    _ = app;
}

pub fn update(app: *App) !bool {
    // Handle input by determining the direction the player wants to go.
    var iter = core.pollEvents();
    while (iter.next()) |event| {
        switch (event) {
            .key_press => |ev| {
                switch (ev.key) {
                    .space => return true,
                    else => {},
                }
            },
            .key_release => |ev| {
                _ = ev;
            },
            .close => return true,
            .mouse_press => |ev| {
                _ = ev;
            },
            else => {},
        }
    }

    // Render the frame
    try app.render();

    // update the window title every second
    if (app.title_timer.read() >= 1.0) {
        app.title_timer.reset();
        try core.printTitle("Sprite2D [ {d}fps ] [ Input {d}hz ]", .{
            core.frameRate(),
            core.inputRate(),
        });
    }

    return false;
}

fn render(app: *App) !void {
    _ = app;
}

fn rgb24ToRgba32(allocator: std.mem.Allocator, in: []zigimg.color.Rgb24) !zigimg.color.PixelStorage {
    const out = try zigimg.color.PixelStorage.init(allocator, .rgba32, in.len);
    var i: usize = 0;
    while (i < in.len) : (i += 1) {
        out.rgba32[i] = zigimg.color.Rgba32{ .r = in[i].r, .g = in[i].g, .b = in[i].b, .a = 255 };
    }
    return out;
}
