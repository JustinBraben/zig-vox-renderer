const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const zopengl = @import("zopengl");
const gl = zopengl.bindings;

pub const BUFFER_SIZE: isize = 5e8; // 500 mb
pub const QUAD_SIZE: i32 = 8;
pub const MAX_DRAW_COMMANDS: usize = 100000;

/// chunk size (max 62)
pub const CS = 62;

/// Padded chunk size
pub const CS_P = CS + 2;
pub const CS_2 = CS * CS;
pub const CS_P2 = CS_P * CS_P;
pub const CS_P3 = CS_P * CS_P * CS_P;

pub const BufferSlot = struct {
    start_byte: u32,
    size_bytes: u32,
};

pub const DrawElementsIndirectCommand = struct {
    /// (count) Quad count * 6
    index_count: u32,
    /// 1
    instance_count: u32,
    /// 0
    first_index: u32,
    /// (baseVertex) Starting index in the SSBO
    base_quad: u32,
    /// Chunk x, y z, face index
    base_instance: u32,
};

pub const BufferFit = struct {
    pos: u32,
    space: u32,
    iter: std.ArrayList(BufferSlot),
};

allocator: Allocator,
VAO: gl.Uint = 0,
IBO: gl.Uint = 0,
SSBO: gl.Uint = 0,
command_buffer: gl.Uint = 0,
used_slots: std.ArrayList(BufferSlot),
draw_commands: std.ArrayList(DrawElementsIndirectCommand),

const ChunkRenderer = @This();

pub fn init(gpa: Allocator) !ChunkRenderer {
    var VAO: gl.Uint = undefined;
    var IBO: gl.Uint = undefined;
    var SSBO: gl.Uint = undefined;
    var command_buffer: gl.Uint = undefined;

    gl.genVertexArrays(1, &VAO);
    gl.bindVertexArray(VAO);
    gl.genBuffers(1, &command_buffer);
    gl.genBuffers(1, &SSBO);
    gl.bindBuffer(gl.SHADER_STORAGE_BUFFER, SSBO);
    gl.bufferData(gl.SHADER_STORAGE_BUFFER, BUFFER_SIZE, null, gl.DYNAMIC_DRAW);

    gl.genBuffers(1, &IBO);
    const max_quads = CS * CS * CS * 6;
    var indices = std.ArrayList(usize).init(gpa);
    defer indices.deinit();

    for (0..max_quads) |i| {
        try indices.append((i << 2) | 2);
        try indices.append((i << 2) | 0);
        try indices.append((i << 2) | 1);
        try indices.append((i << 2) | 1);
        try indices.append((i << 2) | 3);
        try indices.append((i << 2) | 2);
    }
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, IBO);
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(indices.items.len), indices.items.ptr, gl.DYNAMIC_DRAW);

    gl.bindVertexArray(VAO);
    gl.bindBuffer(gl.DRAW_INDIRECT_BUFFER, command_buffer);
    gl.bufferData(gl.DRAW_INDIRECT_BUFFER, MAX_DRAW_COMMANDS * @sizeOf(DrawElementsIndirectCommand), null, gl.DYNAMIC_DRAW);
    gl.bindVertexArray(0);

    // var res: ChunkRenderer = .{
    //     .allocator = gpa,
    //     .VAO = VAO,
    //     .IBO = IBO,
    //     .SSBO = SSBO,
    //     .command_buffer = command_buffer,
    //     .used_slots = std.ArrayList(BufferSlot).init(gpa),
    //     .draw_commands = std.ArrayList(DrawElementsIndirectCommand).init(gpa),
    // };

    return .{
        .allocator = gpa,
        .VAO = VAO,
        .IBO = IBO,
        .SSBO = SSBO,
        .command_buffer = command_buffer,
        .used_slots = std.ArrayList(BufferSlot).init(gpa),
        .draw_commands = std.ArrayList(DrawElementsIndirectCommand).init(gpa),
    };
}

pub fn deinit(self: *ChunkRenderer) void {
    gl.deleteVertexArrays(1, &self.VAO);
    gl.deleteBuffers(1, &self.command_buffer);
    gl.deleteBuffers(1, &self.SSBO);
    gl.deleteBuffers(1, &self.IBO);
    self.used_slots.deinit();
    self.draw_commands.deinit();
}

pub fn getDrawCommand(self: *ChunkRenderer, quad_count: i32, base_instance: u32) DrawElementsIndirectCommand {
    _ = &self;
    _ = quad_count;
    _ = base_instance;

    return .{

    };
}

fn createCommand(slot: *BufferSlot, base_instance: u32) DrawElementsIndirectCommand {
    return .{
        .index_count = (slot.size_bytes / QUAD_SIZE) * 6,
        .instance_count = 1,
        .first_index = 0,
        .base_quad = (slot.startByte / QUAD_SIZE) << 2,
        .base_instance = base_instance
    };
}