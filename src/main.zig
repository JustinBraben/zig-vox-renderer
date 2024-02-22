const std = @import("std");
const core = @import("mach-core");
const gpu = core.gpu;
const ecs = @import("mach-ecs");
const EntityID = ecs.EntityID;
const zm = @import("zmath.zig");
const zigimg = @import("zigimg");
const Vertex = @import("cube_mesh.zig").Vertex;
const vertices = @import("cube_mesh.zig").vertices;

const Rotation = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

const Input = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
};

const all_components = .{
        .entity = struct {
            pub const id = EntityID;
        },
        .game = struct {
            pub const rotation = Rotation;
            pub const name = []const u8;
            pub const input = Input;
        },
    };

pub const App = @This();

const Vec2 = @Vector(2, f32);

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const UniformBufferObject = struct {
    mat: zm.Mat,
};

title_timer: core.Timer,
timer: core.Timer,
pipeline: *gpu.RenderPipeline,
vertex_buffer: *gpu.Buffer,
uniform_buffer: *gpu.Buffer,
bind_group: *gpu.BindGroup,
texture: *gpu.Texture,
texture_view: *gpu.TextureView,
orientation_x: f32,
orientation_y: f32,
orientation_z: f32,
orientation: zm.Mat,
world: ecs.Entities(all_components),
direction: Vec2,

// const sample_count = 4;

pub fn init(app: *App) !void {
    try core.init(.{});
    app.world = try ecs.Entities(all_components).init(gpa.allocator());
    app.direction = Vec2{ 0, 0 };

    const shader_module = core.device.createShaderModuleWGSL("shader.wgsl", @embedFile("shader.wgsl"));
    // defer shader_module.release();

    const vertex_attributes = [_]gpu.VertexAttribute{
        .{ .format = .float32x4, .offset = @offsetOf(Vertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(Vertex, "uv"), .shader_location = 1 },
    };
    const vertex_buffer_layout = gpu.VertexBufferLayout.init(.{
        .array_stride = @sizeOf(Vertex),
        .step_mode = .vertex,
        .attributes = &vertex_attributes,
    });

    // Fragment state
    const blend = gpu.BlendState{};
    const color_target = gpu.ColorTargetState{
        .format = core.descriptor.format,
        .blend = &blend,
        .write_mask = gpu.ColorWriteMaskFlags.all,
    };
    const fragment = gpu.FragmentState.init(.{
        .module = shader_module,
        .entry_point = "frag_main",
        .targets = &.{color_target},
    });

    const bgle = gpu.BindGroupLayout.Entry.buffer(0, .{ .vertex = true }, .uniform, true, 0);
    const bgl = core.device.createBindGroupLayout(
        &gpu.BindGroupLayout.Descriptor.init(.{
            .entries = &.{bgle},
        }),
    );
    // defer bgl.release();

    const bind_group_layouts = [_]*gpu.BindGroupLayout{bgl};
    const pipeline_layout = core.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
        .bind_group_layouts = &bind_group_layouts,
    }));
    // defer pipeline_layout.release();

    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .fragment = &fragment,
        .layout = pipeline_layout,
        .vertex = gpu.VertexState.init(.{
            .module = shader_module,
            .entry_point = "vertex_main",
            .buffers = &.{vertex_buffer_layout},
        }),
        .primitive = .{
            .cull_mode = .back,
        },
    };

    const vertex_buffer = core.device.createBuffer(&.{
        .usage = .{ .vertex = true },
        .size = @sizeOf(Vertex) * vertices.len,
        .mapped_at_creation = .true,
    });
    const vertex_mapped = vertex_buffer.getMappedRange(Vertex, 0, vertices.len);
    @memcpy(vertex_mapped.?, vertices[0..]);
    vertex_buffer.unmap();

    const uniform_buffer = core.device.createBuffer(&.{
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = @sizeOf(UniformBufferObject),
        .mapped_at_creation = .false,
    });

    const bind_group = core.device.createBindGroup(
        &gpu.BindGroup.Descriptor.init(.{
            .layout = bgl,
            .entries = &.{
                gpu.BindGroup.Entry.buffer(0, uniform_buffer, 0, @sizeOf(UniformBufferObject)),
            },
        }),
    );

    app.title_timer = try core.Timer.start();
    app.timer = try core.Timer.start();
    app.pipeline = core.device.createRenderPipeline(&pipeline_descriptor);
    app.vertex_buffer = vertex_buffer;
    app.uniform_buffer = uniform_buffer;
    app.bind_group = bind_group;
    app.orientation_x = 0.0;
    app.orientation_y = 0.0;
    app.orientation_z = 0.0;
    app.orientation = zm.mul(zm.rotationX((std.math.pi / 2.0)), zm.rotationZ((std.math.pi / 2.0)));

    const cube1 = try app.world.new();
    try app.world.setComponent(cube1, .game, .name, "jane");
    try app.world.setComponent(cube1, .game, .input, .{.up = false, .down = false, .left = false, .right = false});
    try app.world.setComponent(cube1, .game, .rotation, .{.x = 0.0, .y = 0.0, .z = 0.0});

    shader_module.release();
    pipeline_layout.release();
    bgl.release();
}

pub fn deinit(app: *App) void {
    defer _ = gpa.deinit();
    defer core.deinit();
    defer app.world.deinit();

    app.vertex_buffer.release();
    app.uniform_buffer.release();
    app.bind_group.release();
    app.pipeline.release();
}

pub fn update(app: *App) !bool {
    var iter = core.pollEvents();
    while (iter.next()) |event| {
        switch (event) {
            .key_press => |ev| {
                switch (ev.key) {
                    .escape => return true,
                    .w => app.direction[1] += 0.01,
                    .a => app.direction[0] += 0.01,
                    .s => app.direction[1] -= 0.01,
                    .d => app.direction[0] -= 0.01,
                    else => {},
                }
            },
            .key_release => |ev| {
                switch (ev.key) {
                    .w => app.direction[1] = 0,
                    .a => app.direction[0] = 0,
                    .s => app.direction[1] = 0,
                    .d => app.direction[0] = 0,
                    else => {},
                }
            },
            .close => return true,
            else => {},
        }
    }

    const back_buffer_view = core.swap_chain.getCurrentTextureView().?;
    const color_attachment = gpu.RenderPassColorAttachment{
        .view = back_buffer_view,
        .clear_value = std.mem.zeroes(gpu.Color),
        .load_op = .clear,
        .store_op = .store,
    };

    const queue = core.queue;
    const encoder = core.device.createCommandEncoder(null);
    const render_pass_info = gpu.RenderPassDescriptor.init(.{
        .color_attachments = &.{color_attachment},
    });
    // {
    //     const time = app.timer.read();
    //     const model = zm.mul(zm.rotationX(time * (std.math.pi / 2.0)), zm.rotationZ(time * (std.math.pi / 2.0)));
    //     const view = zm.lookAtRh(
    //         zm.Vec{ 0, 4, 2, 1 },
    //         zm.Vec{ 0, 0, 0, 1 },
    //         zm.Vec{ 0, 0, 1, 0 },
    //     );
    //     const proj = zm.perspectiveFovRh(
    //         (std.math.pi / 4.0),
    //         @as(f32, @floatFromInt(core.descriptor.width)) / @as(f32, @floatFromInt(core.descriptor.height)),
    //         0.1,
    //         10,
    //     );
    //     const mvp = zm.mul(zm.mul(model, view), proj);
    //     const ubo = UniformBufferObject{
    //         .mat = zm.transpose(mvp),
    //     };
    //     queue.writeBuffer(app.uniform_buffer, 0, &[_]UniformBufferObject{ubo});
    // }
    // const model = zm.mul(zm.rotationX((std.math.pi / 2.0)), zm.rotationZ(app.orientation_z + (std.math.pi / 2.0)));
    app.orientation_z += app.direction[0];
    app.orientation_y += app.direction[1];
    app.orientation =  zm.mul(zm.rotationY(app.orientation_y + (std.math.pi / 2.0)), zm.rotationZ(app.orientation_z + (std.math.pi / 2.0)));
    const view = zm.lookAtRh(
            zm.Vec{ 0, 4, 2, 1 },
            zm.Vec{ 0, 0, 0, 1 },
            zm.Vec{ 0, 0, 1, 0 },
        );
    const proj = zm.perspectiveFovRh(
            (std.math.pi / 4.0),
            @as(f32, @floatFromInt(core.descriptor.width)) / @as(f32, @floatFromInt(core.descriptor.height)),
            0.1,
            10,
        );
    const mvp = zm.mul(zm.mul(app.orientation, view), proj);
        const ubo = UniformBufferObject{
            .mat = zm.transpose(mvp),
        };
    queue.writeBuffer(app.uniform_buffer, 0, &[_]UniformBufferObject{ubo});

    const pass = encoder.beginRenderPass(&render_pass_info);
    pass.setPipeline(app.pipeline);
    pass.setVertexBuffer(0, app.vertex_buffer, 0, @sizeOf(Vertex) * vertices.len);
    pass.setBindGroup(0, app.bind_group, &.{0});
    pass.draw(vertices.len, 1, 0, 0);
    pass.end();
    pass.release();

    var command = encoder.finish(null);
    encoder.release();

    queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();
    core.swap_chain.present();
    back_buffer_view.release();

    if (app.title_timer.read() >= 1.0) {
        app.title_timer.reset();
        try core.printTitle("Rotating Cube [ {d}fps ] [ Input {d}hz ]", .{
            core.frameRate(),
            core.inputRate(),
        });
    }

    return false;
}