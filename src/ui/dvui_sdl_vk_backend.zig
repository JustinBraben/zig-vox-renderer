//! Custom dvui backend: SDL3 for windowing/input, dvui's Vulkan renderer for drawing.
//!
//! The application owns the Vulkan device, swapchain, command buffers, submission and
//! presentation. Each frame it must call `renderer.beginFrame()` inside an active
//! rendering scope before `dvui.Window.begin()`, and `renderer.endFrame()` after
//! `dvui.Window.end()`.
//!
//! Platform/event code is adapted from dvui's `src/backends/sdl.zig` (SDL3 paths only).

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

pub const VkRenderer = @import("dvui_vulkan_renderer");
pub const c = @import("sdl3-c");

pub const kind: dvui.enums.Backend = .custom;

const Self = @This();
const log = std.log.scoped(.SdlVkBackend);

const cursor_enum_count = @typeInfo(dvui.enums.Cursor).@"enum".fields.len;

io: std.Io,
// allocator that is reset each frame. Passed in via `begin`
arena: std.mem.Allocator = undefined,

window: *c.SDL_Window,
renderer: *VkRenderer,

last_pixel_size: dvui.Size.Physical = .{ .w = 800, .h = 600 },
last_window_size: dvui.Size.Natural = .{ .w = 800, .h = 600 },
cursor_last: dvui.enums.Cursor = .arrow,
text_input_rect_last: ?dvui.Rect.Natural = null,
cursor_backing: [cursor_enum_count]?*c.SDL_Cursor = @splat(null),
cursor_backing_tried: [cursor_enum_count]bool = @splat(false),

pub fn init(io: std.Io, window: *c.SDL_Window, renderer: *VkRenderer) Self {
    dvui.io = io;
    return .{ .io = io, .window = window, .renderer = renderer };
}

pub fn deinit(self: *Self) void {
    for (self.cursor_backing) |cursor| {
        if (cursor) |cur| c.SDL_DestroyCursor(cur);
    }
    self.* = undefined;
}

pub fn backend(self: *Self) dvui.Backend {
    return dvui.Backend.init(self);
}

inline fn toErr(res: bool, what: []const u8) !void {
    if (res) return;
    return logErr(what);
}

inline fn logErr(what: []const u8) dvui.Backend.GenericError {
    log.err("{s} failed, error={s}", .{ what, c.SDL_GetError() });
    return dvui.Backend.GenericError.BackendError;
}

fn mapGenericError(err: anyerror) dvui.Backend.GenericError {
    log.err("Vulkan renderer operation failed: {}", .{err});
    return if (err == error.OutOfMemory) error.OutOfMemory else error.BackendError;
}

//
// Frame
//

pub fn begin(self: *Self, arena: std.mem.Allocator) !void {
    self.arena = arena;
    self.renderer.beginWithSize(arena, self.pixelSize()) catch |err| return mapGenericError(err);
}

/// Submission is owned by the application, which calls `renderer.endFrame()`.
pub fn end(_: *Self) !void {}

/// Presentation is owned by the application.
pub fn renderPresent(_: *Self) void {}

pub fn nanoTime(self: *Self) i128 {
    return std.Io.Clock.awake.now(self.io).nanoseconds;
}

pub fn sleep(self: *Self, ns: u64) void {
    std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromNanoseconds(ns) }, self.io) catch {};
}

pub fn pixelSize(self: *Self) dvui.Size.Physical {
    var w: i32 = undefined;
    var h: i32 = undefined;
    toErr(c.SDL_GetWindowSizeInPixels(self.window, &w, &h), "SDL_GetWindowSizeInPixels in pixelSize") catch return self.last_pixel_size;
    self.last_pixel_size = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
    return self.last_pixel_size;
}

pub fn windowSize(self: *Self) dvui.Size.Natural {
    var w: i32 = undefined;
    var h: i32 = undefined;
    toErr(c.SDL_GetWindowSize(self.window, &w, &h), "SDL_GetWindowSize in windowSize") catch return self.last_window_size;
    self.last_window_size = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
    return self.last_window_size;
}

pub fn contentScale(self: *Self) f32 {
    const display_id = c.SDL_GetDisplayForWindow(self.window);
    const scale = c.SDL_GetDisplayContentScale(display_id);
    if (scale == 0.0) {
        log.err("SDL_GetDisplayContentScale returned 0", .{});
        return 1.0;
    }
    return scale;
}

//
// Rendering, delegated to the Vulkan renderer
//

pub fn drawClippedTriangles(self: *Self, texture: ?dvui.Texture, vtx: []const dvui.Vertex, idx: []const dvui.Vertex.Index, clipr: ?dvui.Rect.Physical) !void {
    if (!self.renderer.frame_active) return;
    self.renderer.drawClippedTriangles(self.last_pixel_size, texture, vtx, idx, clipr) catch |err| return mapGenericError(err);
}

pub fn textureCreate(self: *Self, pixels: [*]const u8, options: dvui.Texture.CreateOptions) dvui.Backend.TextureError!dvui.Texture {
    return self.renderer.textureCreate(pixels, options);
}

pub fn textureDestroy(self: *Self, texture: dvui.Texture) void {
    self.renderer.textureDestroy(texture);
}

pub fn textureCreateTarget(self: *Self, options: dvui.Texture.CreateOptions) dvui.Backend.TextureError!dvui.TextureTarget {
    return self.renderer.textureCreateTarget(options);
}

pub fn textureReadTarget(self: *Self, texture: dvui.TextureTarget, pixels_out: [*]u8) dvui.Backend.TextureError!void {
    return self.renderer.textureReadTarget(texture, pixels_out);
}

pub fn textureClearTarget(self: *Self, texture: dvui.TextureTarget) void {
    self.renderer.textureClearTarget(texture) catch |err| log.err("clearing Vulkan texture target failed: {}", .{err});
}

pub fn textureDestroyTarget(self: *Self, texture: dvui.TextureTarget) void {
    self.renderer.textureDestroyTarget(texture);
}

pub fn textureFromTarget(self: *Self, texture: dvui.TextureTarget) dvui.Backend.TextureError!dvui.Texture {
    return self.renderer.textureFromTarget(texture);
}

pub fn textureFromTargetTemp(_: *Self, texture: dvui.TextureTarget) dvui.Backend.TextureError!dvui.Texture {
    return dvui.Texture.cast(texture);
}

pub fn renderTarget(self: *Self, texture: ?dvui.TextureTarget) dvui.Backend.GenericError!void {
    return self.renderer.renderTarget(texture) catch |err| return mapGenericError(err);
}

//
// Platform
//

pub fn clipboardText(self: *Self) ![]const u8 {
    if (!c.SDL_HasClipboardText()) return &.{};

    const p = c.SDL_GetClipboardText();
    defer c.SDL_free(p); // must free even on error

    const str = std.mem.span(p);
    // Log error, but don't fail the application
    if (str.len == 0) logErr("SDL_GetClipboardText in clipboardText") catch {};

    return try self.arena.dupe(u8, str);
}

pub fn clipboardTextSet(self: *Self, text: []const u8) !void {
    if (text.len == 0) return;
    const c_text = try self.arena.dupeSentinel(u8, text, 0);
    defer self.arena.free(c_text);
    try toErr(c.SDL_SetClipboardText(c_text.ptr), "SDL_SetClipboardText in clipboardTextSet");
}

pub fn openURL(self: *Self, url: []const u8, _: bool) !void {
    const c_url = try self.arena.dupeSentinel(u8, url, 0);
    defer self.arena.free(c_url);
    try toErr(c.SDL_OpenURL(c_url.ptr), "SDL_OpenURL in openURL");
}

pub fn preferredColorScheme(_: *Self) ?dvui.enums.ColorScheme {
    return switch (c.SDL_GetSystemTheme()) {
        c.SDL_SYSTEM_THEME_DARK => .dark,
        c.SDL_SYSTEM_THEME_LIGHT => .light,
        else => null,
    };
}

pub fn prefersReducedMotion(_: *Self) bool {
    return false;
}

pub fn refresh(_: *Self) void {
    var ue = std.mem.zeroes(c.SDL_Event);
    ue.type = c.SDL_EVENT_USER;
    toErr(c.SDL_PushEvent(&ue), "SDL_PushEvent in refresh") catch {};
}

pub fn native(self: *Self, _: *dvui.Window) dvui.Window.Native {
    const props = c.SDL_GetWindowProperties(self.window);
    switch (builtin.os.tag) {
        .windows => return .{ .hwnd = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null) },
        .macos => return .{ .cocoa_window = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) },
        else => return {},
    }
}

pub fn title(self: *Self, _: *dvui.Window, new_title: []const u8) void {
    var buf: [300]u8 = @splat(0);
    const c_text: []const u8 = std.fmt.bufPrintSentinel(&buf, "{s}", .{new_title}, 0) catch "title: Error";
    _ = c.SDL_SetWindowTitle(self.window, c_text.ptr);
}

pub fn windowStateSet(self: *Self, _: *dvui.Window, state: dvui.enums.WindowState) void {
    switch (state) {
        .fullscreen => _ = c.SDL_SetWindowFullscreen(self.window, true),
        .maximize => {
            _ = c.SDL_SetWindowFullscreen(self.window, false);
            _ = c.SDL_MaximizeWindow(self.window);
        },
        .normal => {
            _ = c.SDL_SetWindowFullscreen(self.window, false);
            _ = c.SDL_RestoreWindow(self.window);
        },
    }
}

fn cursorShow(_: *Self, value: ?bool) bool {
    const prev = c.SDL_CursorVisible();
    if (value) |val| {
        if (val) {
            if (!c.SDL_ShowCursor()) logErr("SDL_ShowCursor in cursorShow") catch return false;
        } else {
            if (!c.SDL_HideCursor()) logErr("SDL_HideCursor in cursorShow") catch return false;
        }
    }
    return prev;
}

pub fn setCursor(self: *Self, cursor: dvui.enums.Cursor) void {
    if (cursor == self.cursor_last) return;
    defer self.cursor_last = cursor;
    const new_shown_state = if (cursor == .hidden) false else if (self.cursor_last == .hidden) true else null;
    if (new_shown_state) |new_state| {
        if (self.cursorShow(new_state) == new_state) {
            log.err("Cursor shown state was out of sync", .{});
        }
        // Return early if we are hiding
        if (new_state == false) return;
    }

    const enum_int = @intFromEnum(cursor);
    if (!self.cursor_backing_tried[enum_int]) {
        self.cursor_backing_tried[enum_int] = true;
        self.cursor_backing[enum_int] = switch (cursor) {
            .arrow => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT),
            .ibeam => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_TEXT),
            .wait => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_WAIT),
            .wait_arrow => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_PROGRESS),
            .crosshair => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_CROSSHAIR),
            .arrow_nw_se => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_NWSE_RESIZE),
            .arrow_ne_sw => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_NESW_RESIZE),
            .arrow_w_e => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_EW_RESIZE),
            .arrow_n_s => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_NS_RESIZE),
            .arrow_all => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_MOVE),
            .bad => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_NOT_ALLOWED),
            .hand => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER),
            .hidden => unreachable,
        };
    }

    if (self.cursor_backing[enum_int]) |cur| {
        toErr(c.SDL_SetCursor(cur), "SDL_SetCursor in setCursor") catch return;
    } else {
        log.err("setCursor \"{s}\" failed", .{@tagName(cursor)});
        logErr("SDL_CreateSystemCursor in setCursor") catch return;
    }
}

pub fn textInputRect(self: *Self, rect: ?dvui.Rect.Natural) void {
    // Only call through on an actual change, SDL_StartTextInput re-applies
    // text input properties every call.
    if (std.meta.eql(rect, self.text_input_rect_last)) return;
    defer self.text_input_rect_last = rect;

    if (rect) |r| {
        toErr(c.SDL_SetTextInputArea(
            self.window,
            &c.SDL_Rect{
                .x = @trunc(r.x),
                .y = @trunc(r.y),
                .w = @trunc(r.w),
                .h = @trunc(r.h),
            },
            0,
        ), "SDL_SetTextInputArea in textInputRect") catch return;
        toErr(c.SDL_StartTextInput(self.window), "SDL_StartTextInput in textInputRect") catch return;
    } else {
        toErr(c.SDL_StopTextInput(self.window), "SDL_StopTextInput in textInputRect") catch return;
    }
}

//
// Events
//

/// Send an SDL_Event to a dvui.Window
///
/// Return true if the event is to be handled by dvui (e.g. the mouse is over a
/// dvui window), so the application can ignore it.
pub fn addEvent(self: *Self, win: *dvui.Window, event: c.SDL_Event) !bool {
    switch (event.type) {
        c.SDL_EVENT_KEY_DOWN => {
            return try win.addEventKey(.{
                .code = SDL_keysym_to_dvui(@intCast(event.key.key)),
                .action = if (event.key.repeat) .repeat else .down,
                .mod = SDL_keymod_to_dvui(@intCast(event.key.mod)),
            });
        },
        c.SDL_EVENT_KEY_UP => {
            return try win.addEventKey(.{
                .code = SDL_keysym_to_dvui(@intCast(event.key.key)),
                .action = .up,
                .mod = SDL_keymod_to_dvui(@intCast(event.key.mod)),
            });
        },
        c.SDL_EVENT_TEXT_INPUT => {
            return try win.addEventText(.{ .text = std.mem.sliceTo(event.text.text, 0) });
        },
        c.SDL_EVENT_TEXT_EDITING => {
            const strlen: u8 = @intCast(c.SDL_strlen(event.edit.text));
            return try win.addEventText(.{ .text = event.edit.text[0..strlen], .selected = true });
        },
        c.SDL_EVENT_MOUSE_MOTION => {
            if (event.motion.which == c.SDL_TOUCH_MOUSEID) return false;

            // sdl gives us mouse coords in "window coords" which is kind of
            // like natural coords but ignores content scaling
            const window_w = self.windowSize().w;
            const scale = if (window_w == 0) 1.0 else (self.pixelSize().w / window_w);
            return try win.addEventMouseMotion(.{
                .pt = .{ .x = event.motion.x * scale, .y = event.motion.y * scale },
            });
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            if (event.button.which == c.SDL_TOUCH_MOUSEID) return false;
            return try win.addEventMouseButton(SDL_mouse_button_to_dvui(event.button.button), .press);
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            if (event.button.which == c.SDL_TOUCH_MOUSEID) return false;
            return try win.addEventMouseButton(SDL_mouse_button_to_dvui(event.button.button), .release);
        },
        c.SDL_EVENT_MOUSE_WHEEL => {
            const ticks_x = event.wheel.x;
            const ticks_y = event.wheel.y;
            var mouse_type: dvui.enums.MouseType = .unknown;

            var ret = false;
            // sdl says x positive means to the right, where as y positive
            // means up, so we negate x so that down and right match
            if (ticks_x != 0) {
                const min = win.mouseWheelBatch(.horizontal, ticks_x);
                mouse_type = if (min == 1.0) .mouse else .trackpad;
                ret = try win.addEventMouseWheel(-ticks_x * dvui.scroll_speed, .horizontal, mouse_type);
            }
            if (ticks_y != 0) {
                if (mouse_type == .unknown) {
                    const min = win.mouseWheelBatch(.vertical, ticks_y);
                    mouse_type = if (min == 1.0) .mouse else .trackpad;
                }
                ret = try win.addEventMouseWheel(ticks_y * dvui.scroll_speed, .vertical, mouse_type);
            }
            return ret;
        },
        c.SDL_EVENT_FINGER_DOWN => {
            return try win.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = event.tfinger.x, .y = event.tfinger.y } });
        },
        c.SDL_EVENT_FINGER_UP => {
            return try win.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = event.tfinger.x, .y = event.tfinger.y } });
        },
        c.SDL_EVENT_FINGER_MOTION => {
            return try win.addEventTouchMotion(.touch0, event.tfinger.x, event.tfinger.y, event.tfinger.dx, event.tfinger.dy);
        },
        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
            try win.addEventWindow(.{ .action = .close });
            return false;
        },
        c.SDL_EVENT_QUIT => {
            try win.addEventApp(.{ .action = .quit });
            return false;
        },
        c.SDL_EVENT_WINDOW_MOUSE_LEAVE => {
            try win.addEventWindow(.{ .action = .leave });
            return false;
        },
        else => return false,
    }
}

pub fn SDL_mouse_button_to_dvui(button: u8) dvui.enums.Button {
    return switch (button) {
        c.SDL_BUTTON_LEFT => .left,
        c.SDL_BUTTON_MIDDLE => .middle,
        c.SDL_BUTTON_RIGHT => .right,
        c.SDL_BUTTON_X1 => .four,
        c.SDL_BUTTON_X2 => .five,
        else => blk: {
            log.debug("SDL_mouse_button_to_dvui.unknown button {d}", .{button});
            break :blk .six;
        },
    };
}

pub fn SDL_keymod_to_dvui(keymod: u16) dvui.enums.Mod {
    if (keymod == c.SDL_KMOD_NONE) return dvui.enums.Mod.none;

    var m: u16 = 0;
    if (keymod & c.SDL_KMOD_LSHIFT > 0) m |= @intFromEnum(dvui.enums.Mod.lshift);
    if (keymod & c.SDL_KMOD_RSHIFT > 0) m |= @intFromEnum(dvui.enums.Mod.rshift);
    if (keymod & c.SDL_KMOD_LCTRL > 0) m |= @intFromEnum(dvui.enums.Mod.lcontrol);
    if (keymod & c.SDL_KMOD_RCTRL > 0) m |= @intFromEnum(dvui.enums.Mod.rcontrol);
    if (keymod & c.SDL_KMOD_LALT > 0) m |= @intFromEnum(dvui.enums.Mod.lalt);
    if (keymod & c.SDL_KMOD_RALT > 0) m |= @intFromEnum(dvui.enums.Mod.ralt);
    if (keymod & c.SDL_KMOD_LGUI > 0) m |= @intFromEnum(dvui.enums.Mod.lcommand);
    if (keymod & c.SDL_KMOD_RGUI > 0) m |= @intFromEnum(dvui.enums.Mod.rcommand);

    return @as(dvui.enums.Mod, @enumFromInt(m));
}

pub fn SDL_keysym_to_dvui(keysym: i32) dvui.enums.Key {
    return switch (keysym) {
        c.SDLK_A => .a,
        c.SDLK_B => .b,
        c.SDLK_C => .c,
        c.SDLK_D => .d,
        c.SDLK_E => .e,
        c.SDLK_F => .f,
        c.SDLK_G => .g,
        c.SDLK_H => .h,
        c.SDLK_I => .i,
        c.SDLK_J => .j,
        c.SDLK_K => .k,
        c.SDLK_L => .l,
        c.SDLK_M => .m,
        c.SDLK_N => .n,
        c.SDLK_O => .o,
        c.SDLK_P => .p,
        c.SDLK_Q => .q,
        c.SDLK_R => .r,
        c.SDLK_S => .s,
        c.SDLK_T => .t,
        c.SDLK_U => .u,
        c.SDLK_V => .v,
        c.SDLK_W => .w,
        c.SDLK_X => .x,
        c.SDLK_Y => .y,
        c.SDLK_Z => .z,

        c.SDLK_0 => .zero,
        c.SDLK_1 => .one,
        c.SDLK_2 => .two,
        c.SDLK_3 => .three,
        c.SDLK_4 => .four,
        c.SDLK_5 => .five,
        c.SDLK_6 => .six,
        c.SDLK_7 => .seven,
        c.SDLK_8 => .eight,
        c.SDLK_9 => .nine,

        c.SDLK_F1 => .f1,
        c.SDLK_F2 => .f2,
        c.SDLK_F3 => .f3,
        c.SDLK_F4 => .f4,
        c.SDLK_F5 => .f5,
        c.SDLK_F6 => .f6,
        c.SDLK_F7 => .f7,
        c.SDLK_F8 => .f8,
        c.SDLK_F9 => .f9,
        c.SDLK_F10 => .f10,
        c.SDLK_F11 => .f11,
        c.SDLK_F12 => .f12,

        c.SDLK_KP_DIVIDE => .kp_divide,
        c.SDLK_KP_MULTIPLY => .kp_multiply,
        c.SDLK_KP_MINUS => .kp_subtract,
        c.SDLK_KP_PLUS => .kp_add,
        c.SDLK_KP_ENTER => .kp_enter,
        c.SDLK_KP_0 => .kp_0,
        c.SDLK_KP_1 => .kp_1,
        c.SDLK_KP_2 => .kp_2,
        c.SDLK_KP_3 => .kp_3,
        c.SDLK_KP_4 => .kp_4,
        c.SDLK_KP_5 => .kp_5,
        c.SDLK_KP_6 => .kp_6,
        c.SDLK_KP_7 => .kp_7,
        c.SDLK_KP_8 => .kp_8,
        c.SDLK_KP_9 => .kp_9,
        c.SDLK_KP_PERIOD => .kp_decimal,

        c.SDLK_RETURN => .enter,
        c.SDLK_ESCAPE => .escape,
        c.SDLK_TAB => .tab,
        c.SDLK_LSHIFT => .left_shift,
        c.SDLK_RSHIFT => .right_shift,
        c.SDLK_LCTRL => .left_control,
        c.SDLK_RCTRL => .right_control,
        c.SDLK_LALT => .left_alt,
        c.SDLK_RALT => .right_alt,
        c.SDLK_LGUI => .left_command,
        c.SDLK_RGUI => .right_command,
        c.SDLK_MENU => .menu,
        c.SDLK_NUMLOCKCLEAR => .num_lock,
        c.SDLK_CAPSLOCK => .caps_lock,
        c.SDLK_PRINTSCREEN => .print,
        c.SDLK_SCROLLLOCK => .scroll_lock,
        c.SDLK_PAUSE => .pause,
        c.SDLK_DELETE => .delete,
        c.SDLK_HOME => .home,
        c.SDLK_END => .end,
        c.SDLK_PAGEUP => .page_up,
        c.SDLK_PAGEDOWN => .page_down,
        c.SDLK_INSERT => .insert,
        c.SDLK_LEFT => .left,
        c.SDLK_RIGHT => .right,
        c.SDLK_UP => .up,
        c.SDLK_DOWN => .down,
        c.SDLK_BACKSPACE => .backspace,
        c.SDLK_SPACE => .space,
        c.SDLK_MINUS => .minus,
        c.SDLK_EQUALS => .equal,
        c.SDLK_LEFTBRACKET => .left_bracket,
        c.SDLK_RIGHTBRACKET => .right_bracket,
        c.SDLK_BACKSLASH => .backslash,
        c.SDLK_SEMICOLON => .semicolon,
        c.SDLK_APOSTROPHE => .apostrophe,
        c.SDLK_COMMA => .comma,
        c.SDLK_PERIOD => .period,
        c.SDLK_SLASH => .slash,
        c.SDLK_GRAVE => .grave,

        else => blk: {
            log.debug("SDL_keysym_to_dvui unknown keysym {d}", .{keysym});
            break :blk .unknown;
        },
    };
}
