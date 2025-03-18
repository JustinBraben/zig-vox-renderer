// math.zig - A basic math library for Zig inspired by GLM

const std = @import("std");
const math = std.math;
const testing = std.testing;

/// Vector types using Zig's built-in vector capabilities
pub fn Vec(comptime T: type, comptime dim: comptime_int) type {
    return struct {
        const Self = @This();
        data: @Vector(dim, T),

        /// Create a vector with all components set to the same value
        pub fn splat(value: T) Self {
            return .{
                .data = @splat(value)
            };
        }

        /// Create a vector from individual components
        pub fn init(values: [dim]T) Self {
            var result: Self = undefined;
            result.data = values;
            return result;
        }

        /// Add two vectors
        pub fn add(self: Self, other: Self) Self {
            var result: Self = undefined;
            result.data = self.data + other.data;
            return result;
        }

        /// Subtract two vectors
        pub fn sub(self: Self, other: Self) Self {
            var result: Self = undefined;
            result.data = self.data - other.data;
            return result;
        }

        /// Multiply vector by scalar
        pub fn scale(self: Self, scalar: T) Self {
            var result: Self = undefined;
            result.data = self.data * @as(@Vector(dim, T), @splat(scalar));
            return result;
        }

        /// Dot product
        pub fn dot(self: Self, other: Self) T {
            const products = self.data * other.data;
            var sum: T = 0;
            inline for (0..dim) |i| {
                sum += @reduce(.Add, @Vector(1, T){products[i]});
            }
            return sum;
        }

        /// Calculate vector length squared
        pub fn lengthSquared(self: Self) T {
            return self.dot(self);
        }

        /// Calculate vector length
        pub fn length(self: Self) T {
            return @sqrt(self.lengthSquared());
        }

        /// Normalize vector
        pub fn normalize(self: Self) Self {
            const len = self.length();
            if (len == 0) {
                return self;
            }
            return self.scale(1 / len);
        }

        /// Component-wise multiplication
        pub fn multiply(self: Self, other: Self) Self {
            var result: Self = undefined;
            result.data = self.data * other.data;
            return result;
        }

        /// Cross product (only for 3D vectors)
        pub fn cross(self: Self, other: Self) Self {
            comptime if (dim != 3) {
                @compileError("Cross product is only defined for 3D vectors");
            };

            var result: Self = undefined;
            result.data[0] = self.data[1] * other.data[2] - self.data[2] * other.data[1];
            result.data[1] = self.data[2] * other.data[0] - self.data[0] * other.data[2];
            result.data[2] = self.data[0] * other.data[1] - self.data[1] * other.data[0];
            return result;
        }
    };
}

/// Type aliases for common vector types
pub const Vec2f = Vec(f32, 2);
pub const Vec3f = Vec(f32, 3);
pub const Vec4f = Vec(f32, 4);
pub const Vec2i = Vec(i32, 2);
pub const Vec3i = Vec(i32, 3);
pub const Vec4i = Vec(i32, 4);

test "Vec3f operations" {
    const v1 = Vec3f.init(.{ 1, 2, 3 });
    const v2 = Vec3f.init(.{ 4, 5, 6 });
    
    // Test addition
    const sum = v1.add(v2);
    try testing.expectEqual(@Vector(3, f32){ 5, 7, 9 }, sum.data);
    
    // Test dot product
    const dot_product = v1.dot(v2);
    try testing.expectEqual(@as(f32, 32), dot_product);
    
    // Test cross product
    const cross_product = v1.cross(v2);
    try testing.expectEqual(@Vector(3, f32){ -3, 6, -3 }, cross_product.data);
    
    // Test normalization
    const v = Vec3f.init(.{ 3, 0, 0 });
    const normalized = v.normalize();
    try testing.expectEqual(@Vector(3, f32){ 1, 0, 0 }, normalized.data);
}

/// Matrix implementation using Zig vectors
pub fn Mat(comptime T: type, comptime rows: comptime_int, comptime cols: comptime_int) type {
    return struct {
        const Self = @This();
        // Store matrix as an array of column vectors for column-major storage
        data: [cols]@Vector(rows, T),

        /// Create identity matrix
        pub fn identity() Self {
            comptime if (rows != cols) {
                @compileError("Identity matrix must be square");
            };

            var result = Self.zeros();
            inline for (0..rows) |i| {
                result.data[i][i] = 1;
            }
            return result;
        }

        /// Create zero matrix
        pub fn zeros() Self {
            var result: Self = undefined;
            inline for (0..cols) |i| {
                result.data[i] = @splat(0);
            }
            return result;
        }

        /// Create matrix from array of column vectors
        pub fn fromColumns(columns: [cols]@Vector(rows, T)) Self {
            var result: Self = undefined;
            result.data = @as([cols]@Vector(rows, T), columns);
            return result;
        }

        pub fn mul(self: Self, other: anytype) blk: {
            const R = @TypeOf(other.data);
            const other_cols = @typeInfo(R).@"array".len;
            
            const ResultType = Mat(T, rows, other_cols);
            break :blk ResultType;
        } {
            const R = @TypeOf(other.data);
            const other_cols = @typeInfo(R).@"array".len;
            var result = Mat(T, rows, other_cols).zeros();

            inline for (0..other_cols) |j| {
                inline for (0..rows) |i| {
                    var sum: T = 0;
                    inline for (0..cols) |k| {
                        sum += self.data[k][i] * other.data[j][k];
                    }
                    result.data[j][i] = sum;
                }
            }

            return result;
        }
    };
}

/// Type aliases for common matrix types
pub const Mat2f = Mat(f32, 2, 2);
pub const Mat3f = Mat(f32, 3, 3);
pub const Mat4f = Mat(f32, 4, 4);

test "Matrix identity" {
    const m_mat2f = Mat2f.identity();
    try testing.expectEqual(@Vector(2, f32){ 1, 0 }, m_mat2f.data[0]);
    try testing.expectEqual(@Vector(2, f32){ 0, 1 }, m_mat2f.data[1]);

    const m_mat3f = Mat3f.identity();
    try testing.expectEqual(@Vector(3, f32){ 1, 0, 0 }, m_mat3f.data[0]);
    try testing.expectEqual(@Vector(3, f32){ 0, 1, 0 }, m_mat3f.data[1]);
    try testing.expectEqual(@Vector(3, f32){ 0, 0, 1 }, m_mat3f.data[2]);

    const m_mat4f = Mat4f.identity();
    try testing.expectEqual(@Vector(4, f32){ 1, 0, 0, 0 }, m_mat4f.data[0]);
    try testing.expectEqual(@Vector(4, f32){ 0, 1, 0, 0 }, m_mat4f.data[1]);
    try testing.expectEqual(@Vector(4, f32){ 0, 0, 1, 0 }, m_mat4f.data[2]);
    try testing.expectEqual(@Vector(4, f32){ 0, 0, 0, 1 }, m_mat4f.data[3]);
}

test "Matrix operations" {
    const m1 = Mat2f.identity();
    const m2 = Mat2f.fromColumns(.{
        .{ 2, 3 },
        .{ 4, 5 }
    });
    
    // Test matrix multiplication
    const m3 = m1.mul(m2);
    try testing.expectEqual(m2.data[0], m3.data[0]);
    try testing.expectEqual(2, m1.data.len);
    try testing.expectEqual(2, m2.data.len);
    try testing.expectEqual(2, m3.data.len);
    try testing.expectEqual(m2.data[1], m3.data[1]);
    try testing.expectEqual(m2.data, m3.data);
}