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
const Animation = extern struct {
    animation_id: u8,
    size: Vec2,
    world_pos: Vec2,
    sheet_size: Vec2,
    speed: f32,
    loop: bool,
    frames: AnimationFrames,
};
const AnimationFrames = extern struct {
    animation_frame_id: u8,
    pos: Vec2,
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
    animations: []JSONAnimation,
};
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

title_timer: core.Timer,
timer: core.Timer,
fps_timer: core.Timer,
sheet: SpriteSheet,
animations: std.ArrayList(Animation),
animation_frames: std.ArrayList(AnimationFrames),
player_pos: Vec2,
direction: Vec2,

pub fn init(app: *App) !void {
    try core.init(.{});

    const allocator = gpa.allocator();

    const json_path = try std.fs.realpathAlloc(allocator, "../../src/sprites.json");
    defer allocator.free(json_path);

    const sprites_file = try std.fs.cwd().openFile(json_path, .{ .mode = .read_only });
    defer sprites_file.close();
    const file_size = (try sprites_file.stat()).size;
    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);
    try sprites_file.reader().readNoEof(buffer);
    const root = try std.json.parseFromSlice(JSONData, allocator, buffer, .{});
    defer root.deinit();

    app.player_pos = Vec2{ 0, 0 };
    app.direction = Vec2{ 0, 0 };
    app.sheet = root.value.sheet;
    std.log.info("Sheet Dimensions: {} {}", .{ app.sheet.width, app.sheet.height });
    app.animations = std.ArrayList(Animation).init(allocator);
    app.animation_frames = std.ArrayList(AnimationFrames).init(allocator);
    for(root.value.animations) |animation| {
        std.log.info("Animation World Position: {} {}", .{ animation.world_pos[0], animation.world_pos[1] });
        // std.log.info("Animation Texture Position: {} {}", .{  });
    }

    app.title_timer = try core.Timer.start();
    app.timer = try core.Timer.start();
    app.fps_timer = try core.Timer.start();
}

pub fn deinit(app: *App) void {
    defer _ = gpa.deinit();
    defer core.deinit();
    
    app.animations.deinit();
    app.animation_frames.deinit();
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
