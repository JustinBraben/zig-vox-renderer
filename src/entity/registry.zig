const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const SparseSet = @import("sparse_set.zig").SparseSet;
const IComponentStorage = @import("component.zig").IComponentStorage;
const ComponentStorage = @import("component.zig").ComponentStorage;

/// A simple type registry to associate components with their type IDs
fn typeId(comptime T: type) usize {
    return @intFromPtr(@typeName(T));
}

/// Maximum number of component types that can be registered
const MAX_COMPONENT_TYPES = 64;

pub fn BasicRegistry(comptime EntityT: type) type {
   return struct {
        const Self = @This();
        const ComponentInterface = IComponentStorage(EntityT);
        
        allocator: Allocator,
        entity_counter: EntityT,
        component_storages: [MAX_COMPONENT_TYPES]?ComponentInterface,
        component_type_ids: [MAX_COMPONENT_TYPES]usize,
        component_count: usize,
        entities: SparseSet(EntityT),
        
        pub fn init(allocator: Allocator) !Self {
            return .{
                .allocator = allocator,
                .entity_counter = 0,
                .component_storages = @splat(null),
                .component_type_ids = @splat(0),
                .component_count = 0,
                .entities = SparseSet(EntityT).init(allocator),
            };
        }
        
        pub fn deinit(self: *Self) void {
            // Destroy all component storages using the interface
            for (0..self.component_count) |i| {
                if (self.component_storages[i]) |*storage| {
                    storage.deinit();
                }
            }
            
            self.entities.deinit();
        }
        
        /// Register a new component type
        pub fn registerComponent(self: *Self, comptime ComponentT: type) !void {
            const id = typeId(ComponentT);
            
            // Check if already registered
            for (self.component_type_ids[0..self.component_count]) |existing_id| {
                if (existing_id == id) return;
            }
            
            // Create new component storage
            if (self.component_count >= MAX_COMPONENT_TYPES) {
                return error.TooManyComponentTypes;
            }
            
            // Allocate and initialize the concrete component storage
            const storage = try self.allocator.create(ComponentStorage(EntityT, ComponentT));
            storage.* = ComponentStorage(EntityT, ComponentT).init(self.allocator);
            
            // Store the interface
            self.component_storages[self.component_count] = storage.interface();
            self.component_type_ids[self.component_count] = id;
            self.component_count += 1;
        }
        
        /// Create a new entity
        pub fn createEntity(self: *Self) !EntityT {
            const entity = self.entity_counter;
            self.entity_counter += 1;
            
            try self.entities.add(entity);
            return entity;
        }
        
        /// Destroy an entity and remove all its components
        pub fn destroyEntity(self: *Self, entity: EntityT) !void {
            if (!self.entities.contains(entity)) return;
            
            // Remove all components
            for (0..self.component_count) |i| {
                if (self.component_storages[i]) |*storage| {
                    storage.remove(entity);
                }
            }
            
            self.entities.remove(entity);
        }
        
        /// Add a component to an entity
        pub fn addComponent(self: *Self, entity: EntityT, component: anytype) !void {
            const ComponentT = @TypeOf(component);
            try self.registerComponent(ComponentT);
            const id = typeId(ComponentT);
            
            // Find the component storage
            for (0..self.component_count) |i| {
                if (self.component_type_ids[i] == id) {
                    if (self.component_storages[i]) |*storage| {
                        // Pass component by reference to the type-erased interface
                        try storage.add(entity, &component);
                        return;
                    }
                }
            }
            
            return error.ComponentTypeNotRegistered;
        }
        
        /// Remove a component from an entity
        pub fn removeComponent(self: *Self, entity: EntityT, comptime ComponentT: type) !void {
            const id = typeId(ComponentT);
            
            // Find the component storage
            for (0..self.component_count) |i| {
                if (self.component_type_ids[i] == id) {
                    if (self.component_storages[i]) |*storage| {
                        storage.remove(entity);
                        return;
                    }
                }
            }
            
            return error.ComponentTypeNotRegistered;
        }
        
        /// Get a component from an entity
        pub fn getComponent(self: *Self, entity: EntityT, comptime ComponentT: type) ?*ComponentT {
            const id = typeId(ComponentT);
            
            // Find the component storage
            for (0..self.component_count) |i| {
                if (self.component_type_ids[i] == id) {
                    if (self.component_storages[i]) |*storage| {
                        if (storage.get(entity)) |component_ptr| {
                            return @ptrCast(@alignCast(component_ptr));
                        }
                    }
                }
            }
            
            return null;
        }
        
        /// Check if an entity has a component
        pub fn hasComponent(self: *Self, entity: EntityT, comptime ComponentT: type) bool {
            const id = typeId(ComponentT);
            
            // Find the component storage
            for (0..self.component_count) |i| {
                if (self.component_type_ids[i] == id) {
                    if (self.component_storages[i]) |*storage| {
                        return storage.contains(entity);
                    }
                }
            }
            
            return false;
        }
    }; 
}

// Default registry
pub const Registry = BasicRegistry(u32);

test "Registry - basic ECS functionality" {
    const allocator = testing.allocator;
    var world = try Registry.init(allocator);
    defer world.deinit();
    
    const TestPosition = struct {
        x: f32,
        y: f32,
    };
    
    const TestVelocity = struct {
        x: f32,
        y: f32,
    };
    
    const entity = try world.createEntity();
    try world.addComponent(entity, TestPosition{ .x = 1, .y = 2 });
    try world.addComponent(entity, TestVelocity{ .x = 3, .y = 4 });
    
    const pos = world.getComponent(entity, TestPosition) orelse unreachable;
    try testing.expectEqual(@as(f32, 1), pos.x);
    try testing.expectEqual(@as(f32, 2), pos.y);
    
    const vel = world.getComponent(entity, TestVelocity) orelse unreachable;
    try testing.expectEqual(@as(f32, 3), vel.x);
    try testing.expectEqual(@as(f32, 4), vel.y);
    
    try world.removeComponent(entity, TestVelocity);
    try testing.expect(!world.hasComponent(entity, TestVelocity));
    try testing.expect(world.hasComponent(entity, TestPosition));
    
    try world.destroyEntity(entity);
    try testing.expect(!world.hasComponent(entity, TestPosition));
}

test "Registry - Many entities" {
    const allocator = testing.allocator;
    var world = try Registry.init(allocator);
    defer world.deinit();
    
    const Hand = struct {
        fingers: usize,
    };
    
    const TestVelocity = struct {
        x: f32,
        y: f32,
    };

    for (0..100) |idx| {
        const idx_f32: f32 = @floatFromInt(idx);
        const entity = try world.createEntity();
        try world.addComponent(entity, Hand{ .fingers = idx });
        try world.addComponent(entity, TestVelocity{ .x = idx_f32, .y = idx_f32 });
    }
}