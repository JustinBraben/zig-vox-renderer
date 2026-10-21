//! One big host-visible vertex buffer that chunk meshes are sub-allocated from,
//! plus a shared quad index buffer.
//!
//! Freed ranges are only reused once every frame that could still be drawing
//! from them has finished on the GPU.

const std = @import("std");
const Allocator = std.mem.Allocator;

const VulkanContext = @import("vulkan_context.zig");
const vk = VulkanContext.vk;
const VkMemory = @import("dvui_vulkan_renderer").VkMemory;
const Buffer = @import("buffer.zig");
const mesher = @import("../world/mesher.zig");
const chunk = @import("../world/chunk.zig");

pub const Vertex = mesher.Vertex;
pub const Range = chunk.MeshRange;

/// Worst case for a 32³ chunk is a 3D checkerboard: half the blocks with 6 open faces.
pub const max_quads_per_chunk = chunk.volume / 2 * 6;

const Self = @This();

allocator: Allocator,
vertices: Buffer,
indices: Buffer,
capacity: u32,
used: u32 = 0,
/// sorted by `first`, adjacent ranges merged
free_list: std.ArrayList(Range) = .empty,
pending: std.ArrayList(Pending) = .empty,
frames_in_flight: u64,

const Pending = struct {
    range: Range,
    frame: u64,
};

pub fn init(allocator: Allocator, device: vk.DeviceProxy, memory: VkMemory, vertex_capacity: u32, frames_in_flight: u64) !Self {
    var vertices = try Buffer.init(device, memory, @as(vk.DeviceSize, vertex_capacity) * @sizeOf(Vertex), .{ .vertex_buffer_bit = true }, .host_visible);
    errdefer vertices.deinit();

    var indices = try Buffer.init(device, memory, max_quads_per_chunk * 6 * @sizeOf(u32), .{ .index_buffer_bit = true }, .host_visible);
    errdefer indices.deinit();
    for (indices.slice([6]u32), 0..) |*quad, i| {
        const base: u32 = @intCast(i * 4);
        quad.* = .{ base, base + 1, base + 2, base + 2, base + 3, base };
    }

    var self: Self = .{
        .allocator = allocator,
        .vertices = vertices,
        .indices = indices,
        .capacity = vertex_capacity,
        .frames_in_flight = frames_in_flight,
    };
    try self.free_list.append(allocator, .{ .first = 0, .count = vertex_capacity });
    return self;
}

pub fn deinit(self: *Self) void {
    self.free_list.deinit(self.allocator);
    self.pending.deinit(self.allocator);
    self.vertices.deinit();
    self.indices.deinit();
}

/// Copies `data` into a newly allocated range. Returns null when the arena is full.
pub fn upload(self: *Self, data: []const Vertex) !?Range {
    std.debug.assert(data.len > 0 and data.len <= max_quads_per_chunk * 4);
    const count: u32 = @intCast(data.len);
    for (self.free_list.items, 0..) |*hole, i| {
        if (hole.count < count) continue;
        const range: Range = .{ .first = hole.first, .count = count };
        hole.first += count;
        hole.count -= count;
        if (hole.count == 0) _ = self.free_list.orderedRemove(i);
        self.used += count;
        @memcpy(self.vertices.slice(Vertex)[range.first..][0..count], data);
        return range;
    }
    return null;
}

/// Releases `range` once `frame` and every earlier frame have completed.
pub fn free(self: *Self, range: Range, frame: u64) !void {
    try self.pending.append(self.allocator, .{ .range = range, .frame = frame });
}

/// Call after waiting on the fence for `frame`'s slot; returns ranges that the GPU is done with.
pub fn retire(self: *Self, frame: u64) !void {
    var i: usize = 0;
    while (i < self.pending.items.len) {
        const p = self.pending.items[i];
        if (p.frame + self.frames_in_flight <= frame) {
            try self.release(p.range);
            _ = self.pending.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

/// Releases every pending range immediately; only valid while the GPU is idle.
pub fn retireAll(self: *Self) !void {
    for (self.pending.items) |p| try self.release(p.range);
    self.pending.clearRetainingCapacity();
}

fn release(self: *Self, range: Range) !void {
    self.used -= range.count;
    const items = self.free_list.items;
    // first free range that starts after this one
    var i: usize = 0;
    while (i < items.len and items[i].first < range.first) i += 1;

    const merges_prev = i > 0 and items[i - 1].first + items[i - 1].count == range.first;
    const merges_next = i < items.len and range.first + range.count == items[i].first;
    if (merges_prev and merges_next) {
        items[i - 1].count += range.count + items[i].count;
        _ = self.free_list.orderedRemove(i);
    } else if (merges_prev) {
        items[i - 1].count += range.count;
    } else if (merges_next) {
        items[i].first = range.first;
        items[i].count += range.count;
    } else {
        try self.free_list.insert(self.allocator, i, range);
    }
}
