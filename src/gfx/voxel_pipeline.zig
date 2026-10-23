//! Opaque voxel pipeline: packed chunk vertices, depth tested (reverse-Z),
//! lit by a per-frame scene uniform buffer. Its descriptor sets also hold the sky
//! cubemap (binding 1), shared with the sky pipeline.

const std = @import("std");

const VulkanContext = @import("vulkan_context.zig");
const vk = VulkanContext.vk;
const VkMemory = @import("dvui_vulkan_renderer").VkMemory;
const Buffer = @import("buffer.zig");
const MeshArena = @import("mesh_arena.zig");
const Texture = @import("texture.zig");
const Assets = @import("../assets.zig");
const math = @import("../math.zig");

const Self = @This();

/// std140 layout of `Scene` in voxel.vert/frag. Colors are linear.
pub const Scene = extern struct {
    /// camera-relative: the view has no translation
    view_proj: math.Mat4,
    /// xyz: direction towards the sun
    sun_dir: [4]f32,
    /// rgb: sun color * intensity
    sun_color: [4]f32,
    /// rgb: ambient light from above
    sky_color: [4]f32,
    /// rgb: ambient light from below
    ground_color: [4]f32,
    /// rgb: fog color
    fog_color: [4]f32,
    /// x: fog start, y: fog end (0 = no fog), z: ao strength, w: 1 = fog towards the skybox
    params: [4]f32,
};

pub const PushConstants = extern struct {
    /// xyz: mesh origin relative to the camera, w: size of a mesh unit in blocks
    origin: [4]f32,
};

pub const max_frames = 4;

device: vk.DeviceProxy,
set_layout: vk.DescriptorSetLayout,
descriptor_pool: vk.DescriptorPool,
layout: vk.PipelineLayout,
pipeline: vk.Pipeline,
scene_buffers: [max_frames]Buffer = undefined,
descriptor_sets: [max_frames]vk.DescriptorSet = undefined,
frame_count: usize,

pub fn init(device: vk.DeviceProxy, memory: VkMemory, assets: *const Assets, sky: *const Texture, color_format: vk.Format, depth_format: vk.Format, frame_count: usize) !Self {
    std.debug.assert(frame_count <= max_frames);

    const set_layout = try device.createDescriptorSetLayout(&.{
        .binding_count = 2,
        .p_bindings = &.{
            .{
                .binding = 0,
                .descriptor_type = .uniform_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
            },
            .{
                .binding = 1,
                .descriptor_type = .combined_image_sampler,
                .descriptor_count = 1,
                .stage_flags = .{ .fragment_bit = true },
            },
        },
    }, null);
    errdefer device.destroyDescriptorSetLayout(set_layout, null);

    const layout = try device.createPipelineLayout(&.{
        .set_layout_count = 1,
        .p_set_layouts = &.{set_layout},
        .push_constant_range_count = 1,
        .p_push_constant_ranges = &.{.{
            .stage_flags = .{ .vertex_bit = true },
            .offset = 0,
            .size = @sizeOf(PushConstants),
        }},
    }, null);
    errdefer device.destroyPipelineLayout(layout, null);

    const pipeline = try createPipeline(device, assets, layout, color_format, depth_format);
    errdefer device.destroyPipeline(pipeline, null);

    const descriptor_pool = try device.createDescriptorPool(&.{
        .max_sets = @intCast(frame_count),
        .pool_size_count = 2,
        .p_pool_sizes = &.{
            .{ .type = .uniform_buffer, .descriptor_count = @intCast(frame_count) },
            .{ .type = .combined_image_sampler, .descriptor_count = @intCast(frame_count) },
        },
    }, null);
    errdefer device.destroyDescriptorPool(descriptor_pool, null);

    var self: Self = .{
        .device = device,
        .set_layout = set_layout,
        .descriptor_pool = descriptor_pool,
        .layout = layout,
        .pipeline = pipeline,
        .frame_count = frame_count,
    };

    var created: usize = 0;
    errdefer for (self.scene_buffers[0..created]) |*buffer| buffer.deinit();
    for (0..frame_count) |i| {
        self.scene_buffers[i] = try Buffer.init(device, memory, @sizeOf(Scene), .{ .uniform_buffer_bit = true }, .host_visible);
        created += 1;

        try device.allocateDescriptorSets(&.{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &.{set_layout},
        }, @ptrCast(&self.descriptor_sets[i]));

        device.updateDescriptorSets(&.{
            .{
                .dst_set = self.descriptor_sets[i],
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .uniform_buffer,
                .p_image_info = &.{},
                .p_buffer_info = &.{.{ .buffer = self.scene_buffers[i].handle, .offset = 0, .range = @sizeOf(Scene) }},
                .p_texel_buffer_view = &.{},
            },
            .{
                .dst_set = self.descriptor_sets[i],
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .combined_image_sampler,
                .p_image_info = &.{.{ .sampler = sky.sampler, .image_view = sky.view, .image_layout = .shader_read_only_optimal }},
                .p_buffer_info = &.{},
                .p_texel_buffer_view = &.{},
            },
        }, &.{});
    }

    return self;
}

pub fn deinit(self: *Self) void {
    for (self.scene_buffers[0..self.frame_count]) |*buffer| buffer.deinit();
    self.device.destroyDescriptorPool(self.descriptor_pool, null);
    self.device.destroyPipeline(self.pipeline, null);
    self.device.destroyPipelineLayout(self.layout, null);
    self.device.destroyDescriptorSetLayout(self.set_layout, null);
}

/// Writes the scene uniforms for `frame` (whose previous use must have completed).
pub fn setScene(self: *Self, frame: usize, scene: Scene) void {
    self.scene_buffers[frame].slice(Scene)[0] = scene;
}

/// Binds everything shared by the chunk draws. Expects to be inside a rendering scope.
pub fn bind(self: *const Self, cmd: vk.CommandBuffer, frame: usize, extent: vk.Extent2D, arena: *const MeshArena) void {
    const device = self.device;
    device.cmdBindPipeline(cmd, .graphics, self.pipeline);
    device.cmdSetViewport(cmd, 0, &.{.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0,
        .max_depth = 1,
    }});
    device.cmdSetScissor(cmd, 0, &.{.{ .offset = .{ .x = 0, .y = 0 }, .extent = extent }});
    device.cmdBindDescriptorSets(cmd, .graphics, self.layout, 0, &.{self.descriptor_sets[frame]}, &.{});
    device.cmdBindVertexBuffers(cmd, 0, &.{arena.vertices.handle}, &.{0});
    device.cmdBindIndexBuffer(cmd, arena.indices.handle, 0, .uint32);
}

/// `scale` is the size of a mesh unit in blocks: 1 for chunks, larger for distant terrain tiles.
pub fn drawChunk(self: *const Self, cmd: vk.CommandBuffer, origin: math.Vec3, range: MeshArena.Range, scale: f32) void {
    const push: PushConstants = .{ .origin = .{ origin[0], origin[1], origin[2], scale } };
    self.device.cmdPushConstants(cmd, self.layout, .{ .vertex_bit = true }, 0, @sizeOf(PushConstants), &push);
    self.device.cmdDrawIndexed(cmd, range.count / 4 * 6, 1, 0, @intCast(range.first), 0);
}

fn createPipeline(device: vk.DeviceProxy, assets: *const Assets, layout: vk.PipelineLayout, color_format: vk.Format, depth_format: vk.Format) !vk.Pipeline {
    const vertex_module = try loadShaderModule(device, assets, "voxel.vert");
    defer device.destroyShaderModule(vertex_module, null);
    const fragment_module = try loadShaderModule(device, assets, "voxel.frag");
    defer device.destroyShaderModule(fragment_module, null);

    const rendering_info = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = &.{color_format},
        .depth_attachment_format = depth_format,
        .stencil_attachment_format = .undefined,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try device.createGraphicsPipelines(.null_handle, &.{.{
        .p_next = &rendering_info,
        .stage_count = 2,
        .p_stages = &.{
            .{ .stage = .{ .vertex_bit = true }, .module = vertex_module, .p_name = "main" },
            .{ .stage = .{ .fragment_bit = true }, .module = fragment_module, .p_name = "main" },
        },
        .p_vertex_input_state = &.{
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = &.{.{
                .binding = 0,
                .stride = @sizeOf(MeshArena.Vertex),
                .input_rate = .vertex,
            }},
            .vertex_attribute_description_count = 2,
            .p_vertex_attribute_descriptions = &.{
                .{ .location = 0, .binding = 0, .format = .r32_uint, .offset = @offsetOf(MeshArena.Vertex, "data") },
                .{ .location = 1, .binding = 0, .format = .r32_uint, .offset = @offsetOf(MeshArena.Vertex, "color") },
            },
        },
        .p_input_assembly_state = &.{
            .topology = .triangle_list,
            .primitive_restart_enable = .false,
        },
        .p_viewport_state = &.{
            .viewport_count = 1,
            .scissor_count = 1,
        },
        .p_rasterization_state = &.{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = .{ .back_bit = true },
            .front_face = .counter_clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        },
        .p_multisample_state = &.{
            .sample_shading_enable = .false,
            .rasterization_samples = .{ .@"1_bit" = true },
            .min_sample_shading = 1,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        },
        .p_depth_stencil_state = &.{
            .depth_test_enable = .true,
            .depth_write_enable = .true,
            // reverse-Z: larger depth is closer
            .depth_compare_op = .greater,
            .depth_bounds_test_enable = .false,
            .stencil_test_enable = .false,
            .front = std.mem.zeroes(vk.StencilOpState),
            .back = std.mem.zeroes(vk.StencilOpState),
            .min_depth_bounds = 0,
            .max_depth_bounds = 1,
        },
        .p_color_blend_state = &.{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = &.{.{
                .blend_enable = .false,
                .src_color_blend_factor = .one,
                .dst_color_blend_factor = .zero,
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .zero,
                .alpha_blend_op = .add,
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            }},
            .blend_constants = .{ 0, 0, 0, 0 },
        },
        .p_dynamic_state = &.{
            .dynamic_state_count = 2,
            .p_dynamic_states = &.{ .viewport, .scissor },
        },
        .layout = layout,
        .render_pass = .null_handle,
        .subpass = 0,
        .base_pipeline_index = -1,
    }}, null, @ptrCast(&pipeline));
    return pipeline;
}

/// Shader module from `assets/shaders/<name>.spv`.
pub fn loadShaderModule(device: vk.DeviceProxy, assets: *const Assets, name: []const u8) !vk.ShaderModule {
    const spv = try assets.readShader(name);
    defer assets.gpa.free(spv);
    return createShaderModule(device, spv);
}

fn createShaderModule(device: vk.DeviceProxy, spv: []align(@alignOf(u32)) const u8) !vk.ShaderModule {
    return device.createShaderModule(&.{
        .code_size = spv.len,
        .p_code = @ptrCast(spv.ptr),
    }, null);
}
