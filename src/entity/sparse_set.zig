const std = @import("std");
const testing = std.testing;
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
            // Immediate return if entity already in set
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
            // Immediate return if entity not already in set
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

test "SparseSet - basic functionality" {
    const allocator = testing.allocator;
    {
        var ss = SparseSet(u32).init(allocator);
        defer ss.deinit();

        for (0..5) |id| {
            try ss.add(@intCast(id));
        }

        try testing.expectEqual(5, ss.size());
        try testing.expect(!ss.contains(5));

        for (0..5) |id| {
            try testing.expect(ss.contains(@intCast(id)));
        }
    }
}

test "SparseSet - remove entities" {
    const allocator = testing.allocator;
    {
        var ss = SparseSet(u32).init(allocator);
        defer ss.deinit();

        try ss.add(0);
        try ss.add(1);
        try ss.add(2);
        try ss.add(3);
        try ss.add(4);

        try testing.expectEqualDeep(@as(usize, 5), ss.size());

        // Remove middle entity
        ss.remove(2);
        try testing.expectEqualDeep(@as(usize, 4), ss.size());
        try testing.expect(ss.contains(0));
        try testing.expect(ss.contains(1));
        try testing.expect(!ss.contains(2));
        try testing.expect(ss.contains(3));
        try testing.expect(ss.contains(4));

        // Check the dense array order
        // Entity 4 should now be at index 2 (replacing entity 2)
        try testing.expectEqualDeep(@as(u32, 4), ss.getEntityAtIndex(2).?);
        try testing.expectEqualDeep(@as(usize, 2), ss.getIndexOfEntity(4).?);

        // Remove last entity
        ss.remove(3);
        try testing.expectEqualDeep(@as(usize, 3), ss.size());
        try testing.expect(!ss.contains(3));

        // Remove entity that doesn't exist
        ss.remove(10);
        try testing.expectEqualDeep(@as(usize, 3), ss.size());
    }
}

test "SparseSet - clear" {
    const allocator = testing.allocator;
    {
        var ss = SparseSet(u32).init(allocator);
        defer ss.deinit();

        try ss.add(0);
        try ss.add(5);
        try ss.add(10);
        
        try testing.expectEqualDeep(@as(usize, 3), ss.size());
        
        ss.clear();
        
        try testing.expectEqualDeep(@as(usize, 0), ss.size());
        try testing.expect(!ss.contains(0));
        try testing.expect(!ss.contains(5));
        try testing.expect(!ss.contains(10));
    }
}

test "SparseSet - add existing entity" {
    const allocator = testing.allocator;
    {
        var ss = SparseSet(u32).init(allocator);
        defer ss.deinit();

        try ss.add(42);
        try testing.expectEqual(@as(usize, 1), ss.size());
        
        // Try adding the same entity again
        try ss.add(42);
        try testing.expectEqual(@as(usize, 1), ss.size());
    }
}

test "SparseSet - sparse holes" {
    const allocator = testing.allocator;
    {
        var ss = SparseSet(u32).init(allocator);
        defer ss.deinit();

        // Add entities with gaps
        try ss.add(0);
        try ss.add(100);
        try ss.add(1000);
        
        try testing.expectEqualDeep(@as(usize, 3), ss.size());
        try testing.expect(ss.contains(0));
        try testing.expect(ss.contains(100));
        try testing.expect(ss.contains(1000));
        
        // Check that entities in the gaps don't exist
        try testing.expect(!ss.contains(1));
        try testing.expect(!ss.contains(50));
        try testing.expect(!ss.contains(500));
    }
}

test "SparseSet - getEntityAtIndex and getIndexOfEntity" {
    const allocator = testing.allocator;
    {
        var ss = SparseSet(u32).init(allocator);
        defer ss.deinit();

        try ss.add(10);
        try ss.add(20);
        try ss.add(30);
        
        // Check getter functions
        try testing.expectEqual(@as(u32, 10), ss.getEntityAtIndex(0).?);
        try testing.expectEqual(@as(u32, 20), ss.getEntityAtIndex(1).?);
        try testing.expectEqual(@as(u32, 30), ss.getEntityAtIndex(2).?);
        
        try testing.expectEqual(@as(usize, 0), ss.getIndexOfEntity(10).?);
        try testing.expectEqual(@as(usize, 1), ss.getIndexOfEntity(20).?);
        try testing.expectEqual(@as(usize, 2), ss.getIndexOfEntity(30).?);
        
        // Out of bounds index
        try testing.expect(ss.getEntityAtIndex(3) == null);
        
        // Non-existent entity
        try testing.expect(ss.getIndexOfEntity(15) == null);
    }
}

test "SparseSet - mixed operations" {
    const allocator = testing.allocator;
    {
        var ss = SparseSet(u32).init(allocator);
        defer ss.deinit();

        // Add entities
        try ss.add(5);
        try ss.add(10);
        try ss.add(15);
        try testing.expectEqual(@as(usize, 3), ss.size());
        
        // Remove middle entity
        ss.remove(10);
        try testing.expectEqual(@as(usize, 2), ss.size());
        try testing.expect(ss.contains(5));
        try testing.expect(!ss.contains(10));
        try testing.expect(ss.contains(15));
        
        // Add new entities
        try ss.add(20);
        try ss.add(25);
        try testing.expectEqual(@as(usize, 4), ss.size());
        
        // Re-add removed entity
        try ss.add(10);
        try testing.expectEqual(@as(usize, 5), ss.size());
        
        // Check order in dense array (10 should be last)
        try testing.expectEqual(@as(u32, 10), ss.getEntityAtIndex(4).?);
    }
}

test "SparseSet - stress test with many entities" {
    const allocator = testing.allocator;
    {
        var ss = SparseSet(u32).init(allocator);
        defer ss.deinit();

        // Add a lot of entities
        const count = 1000;
        for (0..count) |i| {
            try ss.add(@intCast(i));
        }
        
        try testing.expectEqual(@as(usize, count), ss.size());
        
        // Remove every other entity
        var i: u32 = 0;
        while (i < count) : (i += 2) {
            ss.remove(i);
        }
        
        try testing.expectEqual(@as(usize, count / 2), ss.size());
        
        // Verify remaining entities
        i = 1;
        while (i < count) : (i += 2) {
            try testing.expect(ss.contains(i));
        }
    }
}