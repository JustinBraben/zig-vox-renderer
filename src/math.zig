//! Small vector/matrix helpers built on `@Vector`.
//!
//! Conventions: right-handed world (+Y up, camera looks down -Z), column-major
//! matrices, Vulkan clip space (Y down, depth 0..1). Projections use reverse-Z
//! (near plane at depth 1, infinity at depth 0) for better depth precision.

const std = @import("std");

pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);

pub fn vec3(x: f32, y: f32, z: f32) Vec3 {
    return .{ x, y, z };
}

pub fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

pub fn length(a: Vec3) f32 {
    return @sqrt(dot(a, a));
}

pub fn normalize(a: Vec3) Vec3 {
    const len = length(a);
    if (len == 0) return a;
    return a / @as(Vec3, @splat(len));
}

pub fn scale(a: Vec3, s: f32) Vec3 {
    return a * @as(Vec3, @splat(s));
}

/// Unit vector pointing *towards* a light at the given azimuth/elevation (degrees).
/// Azimuth 0 points down -Z and increases towards +X.
pub fn fromDirection(azimuth_deg: f32, elevation_deg: f32) Vec3 {
    const az = std.math.degreesToRadians(azimuth_deg);
    const el = std.math.degreesToRadians(elevation_deg);
    return .{ @sin(az) * @cos(el), @sin(el), -@cos(az) * @cos(el) };
}

/// Column-major 4x4 matrix: `cols[c][r]`.
pub const Mat4 = extern struct {
    cols: [4]Vec4,

    pub const identity: Mat4 = .{ .cols = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    } };

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var result: Mat4 = undefined;
        for (0..4) |j| result.cols[j] = a.mulVec(b.cols[j]);
        return result;
    }

    pub fn mulVec(m: Mat4, v: Vec4) Vec4 {
        var result: Vec4 = @splat(0);
        inline for (0..4) |k| result += m.cols[k] * @as(Vec4, @splat(v[k]));
        return result;
    }

    pub fn row(m: Mat4, comptime r: usize) Vec4 {
        return .{ m.cols[0][r], m.cols[1][r], m.cols[2][r], m.cols[3][r] };
    }

    /// View matrix looking along `forward` from `eye`.
    pub fn lookTo(eye: Vec3, forward: Vec3, up: Vec3) Mat4 {
        const f = normalize(forward);
        const r = normalize(cross(f, up));
        const u = cross(r, f);
        return .{ .cols = .{
            .{ r[0], u[0], -f[0], 0 },
            .{ r[1], u[1], -f[1], 0 },
            .{ r[2], u[2], -f[2], 0 },
            .{ -dot(r, eye), -dot(u, eye), dot(f, eye), 1 },
        } };
    }

    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        return lookTo(eye, target - eye, up);
    }

    /// Reverse-Z infinite perspective for Vulkan: depth = near / -z_view, so the near
    /// plane maps to 1 and infinity to 0. Use `greater` depth compare and clear to 0.
    pub fn perspectiveReverseZ(fovy_rad: f32, aspect: f32, near: f32) Mat4 {
        const f = 1 / @tan(fovy_rad / 2);
        return .{ .cols = .{
            .{ f / aspect, 0, 0, 0 },
            .{ 0, -f, 0, 0 },
            .{ 0, 0, 0, -1 },
            .{ 0, 0, near, 0 },
        } };
    }
};

/// Frustum planes (a, b, c, d) with normals pointing inwards: a point p is inside
/// when dot(n, p) + d >= 0 for every plane. The infinite far plane is omitted.
pub const Frustum = struct {
    planes: [5]Vec4,

    /// Gribb/Hartmann plane extraction for a reverse-Z projection.
    pub fn fromViewProj(m: Mat4) Frustum {
        const r0 = m.row(0);
        const r1 = m.row(1);
        const r2 = m.row(2);
        const r3 = m.row(3);
        var planes = [5]Vec4{
            r3 + r0, // left
            r3 - r0, // right
            r3 + r1, // top/bottom (Y is flipped, the pair covers both)
            r3 - r1,
            r3 - r2, // near (reverse-Z: depth <= w)
        };
        for (&planes) |*p| {
            const n = length(.{ p[0], p[1], p[2] });
            p.* /= @splat(n);
        }
        return .{ .planes = planes };
    }

    /// Conservative AABB test.
    pub fn intersectsAabb(self: Frustum, min: Vec3, max: Vec3) bool {
        for (self.planes) |p| {
            // the box corner furthest along the plane normal
            const corner: Vec3 = .{
                if (p[0] >= 0) max[0] else min[0],
                if (p[1] >= 0) max[1] else min[1],
                if (p[2] >= 0) max[2] else min[2],
            };
            if (dot(.{ p[0], p[1], p[2] }, corner) + p[3] < 0) return false;
        }
        return true;
    }
};

const testing = std.testing;

fn expectVecApprox(expected: anytype, actual: @TypeOf(expected)) !void {
    const n = @typeInfo(@TypeOf(expected)).vector.len;
    inline for (0..n) |i| try testing.expectApproxEqAbs(expected[i], actual[i], 1e-5);
}

test "vector basics" {
    try testing.expectEqual(@as(f32, 32), dot(vec3(1, 2, 3), vec3(4, 5, 6)));
    try expectVecApprox(vec3(-3, 6, -3), cross(vec3(1, 2, 3), vec3(4, 5, 6)));
    try expectVecApprox(vec3(1, 0, 0), normalize(vec3(3, 0, 0)));
    try expectVecApprox(vec3(0, 1, 0), fromDirection(0, 90));
    try expectVecApprox(vec3(0, 0, -1), fromDirection(0, 0));
    try expectVecApprox(vec3(1, 0, 0), fromDirection(90, 0));
}

test "matrix multiply" {
    const m: Mat4 = .{ .cols = .{
        .{ 1, 2, 3, 4 },
        .{ 5, 6, 7, 8 },
        .{ 9, 10, 11, 12 },
        .{ 13, 14, 15, 16 },
    } };
    try testing.expectEqual(m, Mat4.identity.mul(m));
    try testing.expectEqual(m, m.mul(Mat4.identity));
    try expectVecApprox(Vec4{ 1, 2, 3, 4 }, m.mulVec(.{ 1, 0, 0, 0 }));
}

test "lookTo maps forward to -Z" {
    const view = Mat4.lookTo(vec3(1, 2, 3), vec3(1, 0, 0), vec3(0, 1, 0));
    try expectVecApprox(Vec4{ 0, 0, 0, 1 }, view.mulVec(.{ 1, 2, 3, 1 }));
    try expectVecApprox(Vec4{ 0, 0, -5, 1 }, view.mulVec(.{ 6, 2, 3, 1 }));
    try expectVecApprox(Vec4{ 0, 1, 0, 1 }, view.mulVec(.{ 1, 3, 3, 1 }));
}

test "reverse-Z perspective depth range" {
    const proj = Mat4.perspectiveReverseZ(std.math.degreesToRadians(90), 1, 0.1);
    const near = proj.mulVec(.{ 0, 0, -0.1, 1 });
    try testing.expectApproxEqAbs(@as(f32, 1), near[2] / near[3], 1e-5);
    const far = proj.mulVec(.{ 0, 0, -1000, 1 });
    try testing.expect(far[2] / far[3] < 1e-3);
    // +Y in view space goes up the screen, which is -Y in Vulkan clip space
    const up = proj.mulVec(.{ 0, 1, -1, 1 });
    try testing.expect(up[1] < 0);
}

test "frustum culling" {
    const view = Mat4.lookTo(vec3(0, 0, 0), vec3(0, 0, -1), vec3(0, 1, 0));
    const proj = Mat4.perspectiveReverseZ(std.math.degreesToRadians(90), 1, 0.1);
    const frustum = Frustum.fromViewProj(proj.mul(view));
    try testing.expect(frustum.intersectsAabb(vec3(-1, -1, -11), vec3(1, 1, -9)));
    try testing.expect(!frustum.intersectsAabb(vec3(-1, -1, 9), vec3(1, 1, 11))); // behind
    try testing.expect(!frustum.intersectsAabb(vec3(20, -1, -11), vec3(22, 1, -9))); // right
    try testing.expect(!frustum.intersectsAabb(vec3(-1, 20, -11), vec3(1, 22, -9))); // above
}
