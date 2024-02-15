const std = @import("std");
const glfw = @import("mach-glfw");
const vk = @import("vulkan");
const GraphicsContext = @import("../Rendering/graphics_context.zig").GraphicsContext;
const Swapchain = @import("../Rendering/swapchain.zig").Swapchain;
const RenderPass = @import("../Rendering/render_pass.zig");
const Pipeline = @import("../Rendering/pipeline.zig");
const FrameBuffers = @import("../Rendering/framebuffers.zig");

const Allocator = std.mem.Allocator;

pub const GameWindow = struct {
    const Self = @This();

    allocator: Allocator = undefined,
    window_width: u32 = 1200,
    window_height: u32 = 900,
    app_name: [:0]const u8 = "Vulkan Application",
    window: glfw.Window = undefined,
    gc: GraphicsContext = undefined,
    swapchain: Swapchain = undefined,
    pipeline_layout: vk.PipelineLayout = undefined,
    render_pass: vk.RenderPass = undefined,
    pipeline: vk.Pipeline = undefined,
    framebuffers: []vk.Framebuffer = undefined,
    pool: vk.CommandPool = undefined,

    pub fn init(allocator: Allocator, app_name: [:0]const u8, width: u32, height: u32) !Self {
        if (!glfw.init(.{})) {
            std.log.err("Failed to init GLFW: {?s}", .{glfw.getErrorString()});
            std.process.exit(1);
        }

        var extent: vk.Extent2D = undefined;
        extent = vk.Extent2D {.width = width, .height = height};

        const window = glfw.Window.create(width, height, app_name, null, null, .{
            .client_api = .no_api,
        }) orelse {
            std.log.err("Failed to create window: {?s}", .{glfw.getErrorString()});
            return error.GLFWWindowCreationFailed;
        };

        const gc = try GraphicsContext.init(allocator, app_name, window);

        std.debug.print("Using device: {?s}\n", .{gc.props.device_name});

        // var swapchain: Swapchain = undefined;
        // swapchain = try Swapchain.init(&gc, allocator, extent);

        // const pipeline_layout = try gc.vkd.createPipelineLayout(gc.dev, &.{
        //     .flags = .{},
        //     .set_layout_count = 0,
        //     .p_set_layouts = undefined,
        //     .push_constant_range_count = 0,
        //     .p_push_constant_ranges = undefined,
        // }, null);
        // defer gc.vkd.destroyPipelineLayout(gc.dev, pipeline_layout, null);

        // const render_pass = try RenderPass.create(&gc, swapchain);
        // defer gc.vkd.destroyRenderPass(gc.dev, render_pass, null);

        // const pipeline = try Pipeline.create(&gc, pipeline_layout, render_pass);
        // defer gc.vkd.destroyPipeline(gc.dev, pipeline, null);

        // var frame_buffers: []vk.Framebuffer = undefined;
        // frame_buffers = try FrameBuffers.create(&gc, allocator, render_pass, swapchain);
        // defer FrameBuffers.destroy(&gc, allocator, framebuffers);

        // const pool = try gc.vkd.createCommandPool(
        //     gc.dev,
        //     &.{
        //         .flags = .{},
        //         .queue_family_index = gc.graphics_queue.family,
        //     }, null);
        // defer gc.vkd.destroyCommandPool(gc.dev, pool, null);

        // const buffer = try gc.vkd.createBuffer(gc.dev, &.{
        //     .flags = .{},
        //     .size = @sizeOf(@TypeOf(vertices)),
        //     .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        //     .sharing_mode = .exclusive,
        //     .queue_family_index_count = 0,
        //     .p_queue_family_indices = undefined,
        // }, null);
        // defer gc.vkd.destroyBuffer(gc.dev, buffer, null);

        // const mem_reqs = gc.vkd.getBufferMemoryRequirements(gc.dev, buffer);
        // const memory = try gc.allocate(mem_reqs, .{ .device_local_bit = true });
        // defer gc.vkd.freeMemory(gc.dev, memory, null);
        // try gc.vkd.bindBufferMemory(gc.dev, buffer, memory, 0);

        // try uploadVertices(&gc, pool, buffer);

        // var cmdbufs = try createCommandBuffers(
        //     &gc,
        //     pool,
        //     allocator,
        //     buffer,
        //     swapchain.extent,
        //     render_pass,
        //     pipeline,
        //     framebuffers,
        // );
        // defer destroyCommandBuffers(&gc, pool, allocator, cmdbufs);

        var game_window = Self{
            .allocator = allocator,
            .window_width = width,
            .window_height = height,
            .app_name = app_name,
            .window = window,
            .gc = gc,
            .swapchain = undefined,
            .pipeline_layout = undefined,
            .render_pass = undefined,
            .pipeline = undefined,
            .framebuffers = undefined,
            .pool = undefined,
        };

        game_window.setupCallbacks();

        return game_window;
    }

    pub fn deinit(self: *GameWindow) void {
        defer glfw.terminate();
        defer self.window.destroy();
        defer self.gc.deinit();
        // defer self.swapchain.deinit();
        // defer self.gc.vkd.destroyPipelineLayout(self.gc.dev, self.pipeline_layout, null);
        // defer self.gc.vkd.destroyRenderPass(self.gc.dev, self.render_pass, null);
        // defer self.gc.vkd.destroyPipeline(self.gc.dev, self.pipeline, null);
        // defer FrameBuffers.destroy(&self.gc, self.allocator, self.framebuffers);
        // defer self.gc.vkd.destroyCommandPool(self.gc.dev, self.pool, null);
        // defer self.gc.vkd.destroyBuffer(self.gc.dev, buffer, null);
        // defer self.gc.vkd.freeMemory(self.gc.dev, memory, null);
        // defer CommandBuffers.destroy(self.gc, pool, allocator, cmdbufs);
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

    fn setupCallbacks(self: *GameWindow) void {
        glfw.setErrorCallback(onWindowError);
        self.window.setKeyCallback(onKeyEvent);
        self.window.setMouseButtonCallback(onMouseButtonEvent);
        self.window.setCursorPosCallback(onCursorPositionEvent);
        self.window.setFramebufferSizeCallback(onResizedEvent);
        self.window.setRefreshCallback(onRefreshWindowEvent);

        // TODO: use this for text input when needed
        //self.window.setCharCallback(onKeyEvent);
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