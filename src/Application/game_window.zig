const std = @import("std");
const glfw = @import("mach-glfw");
const vk = @import("vulkan");

pub const GameWindow = struct {
    const Self = @This();

    window_width: u32 = 1200,
    window_height: u32 = 900,
    app_name: [:0]const u8 = "Vulkan Application",
    window: glfw.Window,

    /// Default GLFW error handling callback
    fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
        std.log.err("glfw: {}: {s}\n", .{ error_code, description });
    }

    pub fn init(app_name: [:0]const u8, width: u32, height: u32) !Self {
        //glfw.setErrorCallback(errorCallback);

        if (!glfw.init(.{})) {
            std.log.err("Failed to init GLFW: {?s}", .{glfw.getErrorString()});
            std.process.exit(1);
        }

        const window = glfw.Window.create(width, height, app_name, null, null, .{
            .client_api = .no_api,
        }) orelse {
            std.log.err("Failed to create window: {?s}", .{glfw.getErrorString()});
            return error.GLFWWindowCreationFailed;
        };

        return Self{
            .window_width = width,
            .window_height = height,
            .app_name = app_name,
            .window = window,
        };
    }

    pub fn deinit() void {
        defer glfw.terminate();
    }

    /// Default GLFW error handling callback
    fn onWindowError(error_code: glfw.ErrorCode, description: [:0]const u8) void {
        std.log.err("glfw: {}: {s}\n", .{ error_code, description });
    }

    fn onKeyEvent(window: glfw.Window, codepoint: u21) void {
        _ = window;
        _ = codepoint;
    }

    fn setupCallbacks(self: *GameWindow) void {
        glfw.setErrorCallback(errorCallback);
        self.window.setCharCallback(onKeyEvent);
        // self.window.setKeyCallback(keyCallback);
        // self.window.setMouseButtonCallback(mouseButtonCallback);
        // self.window.setCursorPosCallback(cursorPosCallback);
        // self.window.setScrollCallback(scrollCallback);
    }

    fn isValid(self: *GameWindow) bool {
        return self.window.isValid();
    }

    pub fn shouldClose(self: *GameWindow) bool {
        return self.window.shouldClose();
    }

    pub fn pollEvents(self: *GameWindow) void {
        std.debug.print("Gamewindow width is: {}\n", .{self.window_width});
        glfw.pollEvents();
    }
};