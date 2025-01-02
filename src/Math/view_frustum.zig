const std = @import("std");
const Allocator = std.mem.Allocator;
const zm = @import("zmath");
const Plane = @import("plane.zig");
const PlaneType = Plane.PlaneType;

const ViewFrustum = @This();

planes: std.BoundedArray(Plane, 6),

pub fn update(self: *ViewFrustum, mat: *zm.Mat) void {
    // left
    self.planes[@intFromEnum(PlaneType.Left)].normal.x = mat[0][3] + mat[0][0];
    self.planes[@intFromEnum(PlaneType.Left)].normal.y = mat[1][3] + mat[1][0];
    self.planes[@intFromEnum(PlaneType.Left)].normal.z = mat[2][3] + mat[2][0];
    self.planes[@intFromEnum(PlaneType.Left)].distanceToOrigin = mat[3][3] + mat[3][0];

    // right
    self.planes[@intFromEnum(PlaneType.Right)].normal.x = mat[0][3] - mat[0][0];
    self.planes[@intFromEnum(PlaneType.Right)].normal.y = mat[1][3] - mat[1][0];
    self.planes[@intFromEnum(PlaneType.Right)].normal.z = mat[2][3] - mat[2][0];
    self.planes[@intFromEnum(PlaneType.Right)].distanceToOrigin = mat[3][3] - mat[3][0];

    // bottom
    self.planes[@intFromEnum(PlaneType.Bottom)].normal.x = mat[0][3] + mat[0][1];
    self.planes[@intFromEnum(PlaneType.Bottom)].normal.y = mat[1][3] + mat[1][1];
    self.planes[@intFromEnum(PlaneType.Bottom)].normal.z = mat[2][3] + mat[2][1];
    self.planes[@intFromEnum(PlaneType.Bottom)].distanceToOrigin = mat[3][3] + mat[3][1];

    // top
    self.planes[@intFromEnum(PlaneType.Top)].normal.x = mat[0][3] - mat[0][1];
    self.planes[@intFromEnum(PlaneType.Top)].normal.y = mat[1][3] - mat[1][1];
    self.planes[@intFromEnum(PlaneType.Top)].normal.z = mat[2][3] - mat[2][1];
    self.planes[@intFromEnum(PlaneType.Top)].distanceToOrigin = mat[3][3] - mat[3][1];

    // near
    self.planes[@intFromEnum(PlaneType.Near)].normal.x = mat[0][3] + mat[0][2];
    self.planes[@intFromEnum(PlaneType.Near)].normal.y = mat[1][3] + mat[1][2];
    self.planes[@intFromEnum(PlaneType.Near)].normal.z = mat[2][3] + mat[2][2];
    self.planes[@intFromEnum(PlaneType.Near)].distanceToOrigin = mat[3][3] + mat[3][2];

    // far
    self.planes[@intFromEnum(PlaneType.Far)].normal.x = mat[0][3] - mat[0][2];
    self.planes[@intFromEnum(PlaneType.Far)].normal.y = mat[1][3] - mat[1][2];
    self.planes[@intFromEnum(PlaneType.Far)].normal.z = mat[2][3] - mat[2][2];
    self.planes[@intFromEnum(PlaneType.Far)].distanceToOrigin = mat[3][3] - mat[3][2];

    for (self.planes.buffer) |plane| {
        const length = zm.length3(plane.normal);
        plane.normal /= length;
        plane.distance_to_origin /= length;
    }
}