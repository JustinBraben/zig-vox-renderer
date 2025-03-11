const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn SparseSet(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: Allocator,
        sparse: std.ArrayList(usize),
        dense: std.ArrayList(T),

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .sparse = std.ArrayList(usize).init(allocator),
                .dense = std.ArrayList(T).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.sparse.deinit();
            self.dense.deinit();
        }

        pub fn contains(self: *Self, entity: T) bool {
            if (entity >= self.sparse.items.len) return false;
            const idx = self.sparse.items[entity];
            return idx < self.dense.items.len and self.dense.items[idx] == entity;
        }

        pub fn add(self: *Self, entity: T) !void {
            if (self.contains(entity)) return;

            // Ensure sparse array is large enough
            if (entity >= self.sparse.items.len) {
                try self.sparse.resize(entity + 1);
            }

            // Add entity to dense array and update sparse array
            self.sparse.items[entity] = self.dense.items.len;
            try self.dense.append(entity);
        }

        pub fn remove(self: *Self, entity: T) void {
            if (!self.contains(entity)) return;

            // Get the index in the dense array
            const idx = self.sparse.items[entity];

            // Move the last entity to fill the gap
            const last_entity = self.dense.items[self.dense.items.len - 1];
            
            if (idx < self.dense.items.len - 1) {
                self.dense.items[idx] = last_entity;
                self.sparse.items[last_entity] = idx;
            }

            // Remove the last entity
            _ = self.dense.pop();
        }

        pub fn clear(self: *Self) void {
            self.sparse.clearRetainingCapacity();
            self.dense.clearRetainingCapacity();
        }

        pub fn size(self: *Self) usize {
            return self.dense.items.len;
        }

        pub fn getEntityAtIndex(self: *Self, index: usize) ?T {
            if (index >= self.dense.items.len) return null;
            return self.dense.items[index];
        }

        pub fn getIndexOfEntity(self: *Self, entity: T) ?usize {
            if (!self.contains(entity)) return null;
            return self.sparse.items[entity];
        }
    };
}