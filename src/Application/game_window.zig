const std = @import("std");
const glfw = @import("mach-glfw");
const vk = @import("vulkan");

const Allocator = std.mem.Allocator;

pub const GameWindow = struct {
    const Self = @This();

    allocator: Allocator,
    window_width: u32 = 1200,
    window_height: u32 = 900,
    app_name: [:0]const u8 = "Vulkan Application",
    window: glfw.Window,

    pub fn init(allocator: Allocator, app_name: [:0]const u8, width: u32, height: u32) !Self {
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

        var game_window: Self = .{
            .allocator = allocator,
            .window_width = width,
            .window_height = height,
            .app_name = app_name,
            .window = window,
        };

        game_window.setupCallbacks();

        return game_window;
    }

    pub fn deinit(self: *GameWindow) void {
        defer glfw.terminate();
        defer self.window.destroy();
    }

    /// Default GLFW error handling callback
    fn onWindowError(error_code: glfw.ErrorCode, description: [:0]const u8) void {
        std.log.err("glfw: {}: {s}\n", .{ error_code, description });
    }

    fn onKeyEvent(window: glfw.Window, codepoint: u21) void {
        _ = window;
        _ = codepoint;
    }

    fn onMouseButtonEvent(window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
        _ = window;
        _ = button;
        _ = action;
        _ = mods;
    }

    fn onCursorPosition(window: glfw.Window, xpos: f64, ypos: f64) void {
        _ = window;
        _ = xpos;
        _ = ypos;
    }

    fn onResized(window: glfw.Window, width: u32, height: u32) void {
        _ = window;
        _ = width;
        _ = height;
    }

    fn setupCallbacks(self: *GameWindow) void {
        glfw.setErrorCallback(onWindowError);
        self.window.setCharCallback(onKeyEvent);
        self.window.setMouseButtonCallback(onMouseButtonEvent);
        self.window.setCursorPosCallback(onCursorPosition);
        self.window.setFramebufferSizeCallback(onResized);
    }

    fn isValid(self: *GameWindow) bool {
        return self.window.isValid();
    }

    pub fn shouldClose(self: *GameWindow) bool {
        return self.window.shouldClose();
    }

    pub fn pollEvents(self: *GameWindow) void {
        _ = self;
        glfw.pollEvents();
    }

    pub fn shouldRender(self: *GameWindow) bool {
        return self.window_width > 0 and self.window_height > 0;
    }

    pub fn beginFrame(self: *GameWindow) void {
        // TODO: Ensure framebufferStack is empty
        self.resetFrame();
        
        // TODO: create framebuffer

        // TODO: push framebuffer to framebufferStack
        self.resetFrame();
    }

    pub fn resetFrame(self: *GameWindow) void {
        _ = self;
    }

    pub fn finalizeFrame(self: *GameWindow) void {
        _ = self;
        // TODO: ensure framebufferStack is size 1

        // ColorRenderPass.renderTexture(framebufferStack.pop().getColorAttachment(0));
    }

    pub fn swapBuffers(self: *GameWindow) void {
        _ = self;
        // TODO: Clear Intermediate Texture References
        // Will need to do this the vulkan way
    }
};