// Commonly used types in the project

const std = @import("std");
const glfw = @import("mach-glfw");
const gl = @import("gl");
const glm = @import("ziglm");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Mat4x4 = glm.Mat4x4;
const Mat4f32 = glm.Mat4(f32);

const Vec2u = glm.Vec2(u32);