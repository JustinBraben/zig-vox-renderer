const std = @import("std");
const glfw = @import("mach-glfw");
const gl = @import("gl");
const glm = @import("ziglm");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Mat4x4 = glm.Mat4x4;
const Mat4f32 = glm.Mat4(f32);

const Vec2u = glm.Vec2(u32);

pub const ComponentType = union {
    UShort: gl.UNSIGNED_SHORT,
    Int: gl.INT,
    Uint: gl.UNSIGNED_INT,
    Byte: gl.BYTE,
    Float: gl.FLOAT,
};

pub const VertexAttribute = struct {
    component_count: u8,
    component_type: ComponentType,
    should_be_normalized: bool = false,
    vertex_size: i32,
    offset: u32,

    pub fn init(component_count: u8, component_type: ComponentType, vertex_size: i32, offset: u32) VertexAttribute {
        return .{
            .component_count = component_count,
            .component_type = component_type,
            .vertex_size = vertex_size,
            .offset = offset,
        };
    }
};

pub const VertexArray = struct {
    id: u32 = 0,
};