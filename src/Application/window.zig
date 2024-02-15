const std = @import("std");
const glfw = @import("mach-glfw");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.Window);

pub const Window = struct {
    const Self = @This();

    allocator: Allocator,
    app_name: [:0]const u8,
    width: u32,
    height: u32,
    window: glfw.Window,

    pub fn init(allocator: Allocator, app_name: [:0]const u8, width: u32, height: u32) !Self {
        if (!glfw.init(.{})) {
            std.log.err("Failed to init GLFW: {?s}\n", .{glfw.getErrorString()});
            return error.GLFWInitFailed;
        }

        const window = glfw.Window.create( width, height, app_name, null, null, .{
            .client_api = .opengl_api
        }) orelse {
            std.log.err("Failed to create window: {?s}\n", .{glfw.getErrorString()});
            return error.GLFWWindowCreateFailed;
        };

        var self: Self = .{
            .allocator = allocator,
            .app_name = app_name,
            .width = width,
            .height = height,
            .window = window,
        };

        self.setupCallbacks();

        return self;
    }

    pub fn deinit(self: *Self) void {
        defer glfw.terminate();
        defer self.window.destroy();
    }

    pub fn shouldClose(self: *Self) bool {
        return self.window.shouldClose();
    }

    pub fn pollEvents(self: *Self) void {
        _ = self;
        glfw.pollEvents();
    }

    /// Default GLFW error handling callback
    fn onWindowError(error_code: glfw.ErrorCode, description: [:0]const u8) void {
        std.log.err("glfw: {}: {s}\n", .{ error_code, description });
    }

    fn onKeyEvent(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
        if (action == glfw.Action.press) {
            // Debug print
            std.debug.print("Pressed key : {}\n", .{key});
        }
        if (action == glfw.Action.release) {
            // Debug print
            std.debug.print("Released key : {}\n", .{key});

            // Press Escape to close out of the window
            if (key == glfw.Key.escape) {
                window.setShouldClose(true);
            }
        }
        _ = scancode;
        _ = mods;
    }

    fn onMouseButtonEvent(window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
        if (action == glfw.Action.press) {
            // Debug print
            std.debug.print("Pressed mouse button : {}\n", .{button});
        }
        if (action == glfw.Action.release) {
            // Debug print
            std.debug.print("Released mouse button : {}\n", .{button});
        }
        _ = window;
        _ = mods;
    }

    fn onCursorPositionEvent(window: glfw.Window, xpos: f64, ypos: f64) void {
        _ = window;
        _ = xpos;
        _ = ypos;
    }

    fn onResizedEvent(window: glfw.Window, width: u32, height: u32) void {
        _ = window;
        _ = width;
        _ = height;
    }

    fn onRefreshWindowEvent(window: glfw.Window) void {
        _ = window;
    }

    fn setupCallbacks(self: *Self) void {
        glfw.setErrorCallback(onWindowError);
        self.window.setKeyCallback(onKeyEvent);
        self.window.setMouseButtonCallback(onMouseButtonEvent);
        self.window.setCursorPosCallback(onCursorPositionEvent);
        self.window.setFramebufferSizeCallback(onResizedEvent);
        self.window.setRefreshCallback(onRefreshWindowEvent);

        // TODO: use this for text input when needed
        //self.window.setCharCallback(onKeyEvent);
    }
};