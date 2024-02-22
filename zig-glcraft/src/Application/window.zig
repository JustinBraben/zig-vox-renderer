const std = @import("std");
const glfw = @import("mach-glfw");
const gl = @import("gl");
const Allocator = std.mem.Allocator;

const FramebufferStack = @import("../Rendering/frame_buffer_stack.zig").FramebufferStack;

const log = std.log.scoped(.Window);

pub const Window = struct {
    const Self = @This();

    allocator: Allocator,
    app_name: [:0]const u8,
    width: u32,
    height: u32,
    window: glfw.Window,
    process: glfw.GLProc = undefined,

    pub fn init(allocator: Allocator, app_name: [:0]const u8, width: u32, height: u32) !Self {
        if (!glfw.init(.{})) {
            std.log.err("Failed to init GLFW: {?s}\n", .{glfw.getErrorString()});
            return error.GLFWInitFailed;
        }

        const window = glfw.Window.create( width, height, app_name, null, null, .{
            .opengl_profile = .opengl_core_profile,
            .context_version_major = 4,
            .context_version_minor = 0,
        }) orelse {
            std.log.err("Failed to create window: {?s}\n", .{glfw.getErrorString()});
            return error.GLFWWindowCreateFailed;
        };

        glfw.makeContextCurrent(window);

        const proc: glfw.GLProc = undefined;
        try gl.load(proc, glGetProcAddress);

        var self: Self = .{
            .allocator = allocator,
            .app_name = app_name,
            .width = width,
            .height = height,
            .window = window,
            .process = proc,
        };

        self.setupCallbacks();

        return self;
    }

    pub fn deinit(self: *Self) void {
        defer glfw.terminate();
        defer self.window.destroy();
    }

    fn glGetProcAddress(p: glfw.GLProc, proc: [:0]const u8) ?gl.FunctionPointer {
        _ = p;
        return glfw.getProcAddress(proc);
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
            const cursor_pos = window.getCursorPos();
            std.debug.print("Released mouse button : {} , at x: {}, y: {}\n", .{button, cursor_pos.xpos, cursor_pos.ypos});
        }
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

        glfw.swapInterval(1); // vsync

        // TODO: use this for text input when needed
        //self.window.setCharCallback(onKeyEvent);
    }

    pub fn lockMouse(self: *Self) void {
        self.window.setInputModeCursor(.disabled);
    }

    pub fn unlockMouse(self: *Self) void {
        self.window.setInputModeCursor(.normal);
    }

    pub fn shouldClose(self: *Self) bool {
        return self.window.shouldClose();
    }

    pub fn pollEvents(self: *Self) void {
        _ = self;
        glfw.pollEvents();
    }

    pub fn shouldRender(self: *Self) bool {
        return self.window.getSize().width > 0 and self.window.getSize().height > 0;
    }

    pub fn beginFrame(self: *Self) void {
        // TODO: asset framebuffer is empty
        // then reset frame
        self.resetFrame();

        // TODO: create a framebuffer, make sure it is not as wide as the window, or as tall as the window

        // TODO: push framebuffer onto framebufferstack
        // then reset the level one framebuffer
    }

    pub fn resetFrame(self: *Self) void {
        const window_width = @as(gl.GLsizei, @intCast(self.window.getSize().width));
        const window_height = @as(gl.GLsizei, @intCast(self.window.getSize().height));
        gl.viewport(0, 0, window_width, window_height);
        gl.clearColor(0, 0, 0, 1);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT);
    }

    pub fn finalizeFrame(self: *Self) void {
        _ = self;
        
        // TODO: assert framebuffer is size 1
        // then render texture, and pop framebufferstack
    }

    pub fn swapBuffers(self: *Self) void {
        // TODO: clear intermediate texture references in framebufferstack
        self.window.swapBuffers();
    }
};