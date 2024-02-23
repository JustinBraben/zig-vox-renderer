const std = @import("std");
const testing = std.testing;
const core = @import("mach-core");
const gpu = core.gpu;
const ecs = @import("mach-ecs");
const EntityID = ecs.EntityID;
const zm = @import("zmath.zig");
const zigimg = @import("zigimg");
const Vertex = @import("cube_mesh.zig").Vertex;
const vertices = @import("cube_mesh.zig").vertices;

pub const App = @This();

const Vec2 = @Vector(2, f64);
const Vec3 = @Vector(3, f64);

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
mouse_pos: Vec2,

pub fn init(app: *App) !void {
    try core.init(.{});

    const shader_module = core.device.createShaderModuleWGSL("instanced_cube_shader.wgsl", @embedFile("instanced_cube_shader.wgsl"));

    const vertex_attributes = [_]gpu.VertexAttribute{
        .{ .format = .float32x4, .offset = @offsetOf(Vertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(Vertex, "uv"), .shader_location = 1 },
    };
    const vertex_buffer_layout = gpu.VertexBufferLayout.init(.{
        .array_stride = @sizeOf(Vertex),
        .step_mode = .vertex,
        .attributes = &vertex_attributes,
    });

    const color_target = gpu.ColorTargetState{
        .format = core.descriptor.format,
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

    const bind_group_layouts = [_]*gpu.BindGroupLayout{bgl};
    const pipeline_layout = core.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
        .bind_group_layouts = &bind_group_layouts,
    }));

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

    const x_count = 4;
    const y_count = 4;
    const num_instances = x_count * y_count;

    const uniform_buffer = core.device.createBuffer(&.{
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = @sizeOf(UniformBufferObject) * num_instances,
        .mapped_at_creation = .false,
    });
    const bind_group = core.device.createBindGroup(
        &gpu.BindGroup.Descriptor.init(.{
            .layout = bgl,
            .entries = &.{
                gpu.BindGroup.Entry.buffer(0, uniform_buffer, 0, @sizeOf(UniformBufferObject) * num_instances),
            },
        }),
    );

    app.title_timer = try core.Timer.start();
    app.timer = try core.Timer.start();
    app.pipeline = core.device.createRenderPipeline(&pipeline_descriptor);
    app.vertex_buffer = vertex_buffer;
    app.uniform_buffer = uniform_buffer;
    app.bind_group = bind_group;

    shader_module.release();
    pipeline_layout.release();
    bgl.release();
}

pub fn deinit(app: *App) void {
    defer _ = gpa.deinit();
    defer core.deinit();

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
                    .w => {},
                    .a => {},
                    .s => {},
                    .d => {},
                    else => {},
                }
            },
            .key_release => |ev| {
                switch (ev.key) {
                    .w => {},
                    .a => {},
                    .s => {},
                    .d => {},
                    else => {},
                }
            },
            .mouse_motion => |ev| {
                const x = ev.pos.x;
                const y = ev.pos.x;
                app.mouse_pos = Vec2{ x, y };
                // std.debug.print("Mouse Pos: ({any}, {any})\n", .{ x, y });
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

    const encoder = core.device.createCommandEncoder(null);
    const render_pass_info = gpu.RenderPassDescriptor.init(.{
        .color_attachments = &.{color_attachment},
    });
    
    {
        const proj = zm.perspectiveFovRh(
            (std.math.pi / 3.0), 
            @as(f32, @floatFromInt(core.descriptor.width)) / @as(f32, @floatFromInt(core.descriptor.height)),
            10, 
            30
        );

        const invProj = zm.inverse(proj);
        _ = invProj;

        var ubos: [16]UniformBufferObject = undefined;
        const time = app.timer.read();
        const step: f32 = 4.0;
        var m: u8 = 0;
        var x: u8 = 0;
        while (x < 4) : (x += 1) {
            var y: u8 = 0;
            while (y < 4) : (y += 1) {
                const trans = zm.translation(step * (@as(f32, @floatFromInt(x)) - 2.0 + 0.5), step * (@as(f32, @floatFromInt(y)) - 2.0 + 0.5), -20);
                const localTime = time + @as(f32, @floatFromInt(m)) * 0.5;
                const model = zm.mul(zm.mul(zm.mul(zm.rotationX(localTime * (std.math.pi / 2.1)), zm.rotationY(localTime * (std.math.pi / 0.9))), zm.rotationZ(localTime * (std.math.pi / 1.3))), trans);
                const mvp = zm.mul(model, proj);
                const ubo = UniformBufferObject{
                    .mat = mvp,
                };
                ubos[m] = ubo;
                m += 1;
                //std.debug.print("mvp[0]: {any}\n", .{ mvp[0] });
            }
        }
        encoder.writeBuffer(app.uniform_buffer, 0, &ubos);
    }

    const pass = encoder.beginRenderPass(&render_pass_info);
    pass.setPipeline(app.pipeline);
    pass.setVertexBuffer(0, app.vertex_buffer, 0, @sizeOf(Vertex) * vertices.len);
    pass.setBindGroup(0, app.bind_group, &.{0});
    pass.draw(vertices.len, 16, 0, 0);
    pass.end();
    pass.release();

    var command = encoder.finish(null);
    encoder.release();

    const queue = core.queue;
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

test "example test" {
    try testing.expectEqual(0, 0);
}

test "example add" {
    const num1 = 0;
    const num2 = 2;
    try testing.expectEqual(num1 + 2, num2);
}