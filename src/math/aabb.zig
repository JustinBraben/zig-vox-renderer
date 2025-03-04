const std = @import("std");
const Allocator = std.mem.Allocator;
const zm = @import("zmath");

const AABB = @This();

position: zm.F32x4 = undefined,
dimensions: zm.F32x4 = undefined,

pub fn update(self: *AABB, location: *zm.F32x4) void {
    self.position = location;
}

pub fn getViewNormal(self: *AABB, normal: *zm.F32x4) zm.F32x4 {
    var res = self.position;

    if (normal.x < 0) {
        res.x += self.dimensions[0];
    }
    if (normal.y < 0) {
        res.y += self.dimensions[1];
    }
    if (normal.z < 0) {
        res.z += self.dimensions[2];
    }

    return res;
}

pub fn getViewPosition(self: *AABB, normal: *zm.F32x4) zm.F32x4 {
    var res = self.position;

    if (normal.x > 0) {
        res.x += self.dimensions[0];
    }
    if (normal.y > 0) {
        res.y += self.dimensions[1];
    }
    if (normal.z > 0) {
        res.z += self.dimensions[2];
    }

    return res;
}