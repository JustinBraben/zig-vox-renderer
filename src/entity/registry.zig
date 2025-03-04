const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const TypeId = std.meta.TypeId;

const Registry = @This();

// Interface for type-erased component storage
const StorageInterface = struct {
    ptr: *anyopaque,
    deinitFn: *const fn (ptr: *anyopaque, allocator: Allocator) void,
};

allocator: Allocator,
entities: std.ArrayList(u32),
// Store type-erased component storage interfaces
component_storages: std.StringHashMap(StorageInterface),

pub fn init(allocator: Allocator) Registry {
    return .{
        .allocator = allocator,
        .entities = std.ArrayList(u32).init(allocator),
        .component_storages = std.StringHashMap(StorageInterface).init(allocator),
    };
}

pub fn deinit(self: *Registry) void {
    // Free all component storages
    var it = self.component_storages.iterator();
    while (it.next()) |entry| {
        const storage_interface = entry.value_ptr.*;
        // Call the type-specific destructor through the interface
        storage_interface.deinitFn(storage_interface.ptr, self.allocator);
    }
    
    self.component_storages.deinit();
    self.entities.deinit();
}

pub fn create(self: *Registry) !u32 {
    if (self.entities.items.len < 1) {
        try self.entities.append(1);
    }
    else {
        try self.entities.append(self.entities.getLast() + 1);
    }
    return self.entities.getLast();
}

// Generic component storage container
pub fn ComponentStorage(comptime T: type) type {
    return struct {
        const Self = @This();
        
        allocator: Allocator,
        components: std.AutoHashMap(u32, T),
        
        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .components = std.AutoHashMap(u32, T).init(allocator),
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.components.deinit();
        }

        // Type-erased deinit function for the storage interface
        pub fn deinitStorage(ptr: *anyopaque, allocator: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.deinit();
            allocator.destroy(self);
        }
        
        pub fn add(self: *Self, entity: u32, component: T) !void {
            try self.components.put(entity, component);
        }
        
        pub fn get(self: *Self, entity: u32) ?*T {
            return self.components.getPtr(entity);
        }
        
        pub fn remove(self: *Self, entity: u32) void {
            _ = self.components.remove(entity);
        }
    };
}

pub fn emplace(self: *Registry, entity: u32, component: anytype) !void {
    const ComponentType = @TypeOf(component);
    const type_name = @typeName(ComponentType);
    
    // Try to get existing storage for this component type
    if (!self.component_storages.contains(type_name)) {
        // Create a new storage for this component type
        const new_storage = try self.allocator.create(ComponentStorage(ComponentType));
        new_storage.* = ComponentStorage(ComponentType).init(self.allocator);
        
        // Create the storage interface
        const storage_interface = StorageInterface{
            .ptr = new_storage,
            .deinitFn = ComponentStorage(ComponentType).deinitStorage,
        };
        
        // Store the interface
        try self.component_storages.put(type_name, storage_interface);
    }
    
    // Get the storage interface
    const storage_interface = self.component_storages.get(type_name).?;
    
    // Cast to the correct storage type and add the component
    const typed_storage: *ComponentStorage(ComponentType) = @ptrCast(@alignCast(storage_interface.ptr));
    try typed_storage.add(entity, component);
}

// Utility function to get a component for an entity
pub fn get(self: *Registry, entity: u32, comptime ComponentType: type) ?*ComponentType {
    const type_name = @typeName(ComponentType);
    
    // Get the storage for this component type
    const storage_interface = self.component_storages.get(type_name) orelse return null;
    
    // Cast to the correct storage type and retrieve the component
    const typed_storage: *ComponentStorage(ComponentType) = @ptrCast(@alignCast(storage_interface.ptr));
    return typed_storage.get(entity);
}

// View implementation to iterate over entities with specific components
pub fn View(comptime ComponentsIncluded: type, comptime ComponentsExcluded: type) type {
    return struct {
        const Self = @This();
        
        registry: *Registry,
        entities_with_components: std.ArrayList(u32),
        current_index: usize,

        // pub fn init(registry: *Registry, allocator: Allocator) !Self {
        //     return .{
        //         .registry = registry,
        //         .entities_with_components = std.ArrayList(u32).init(allocator),
        //         .current_index = 0,
        //     };
        // }

        pub fn init(registry: *Registry, allocator: Allocator) Self {
            var self = Self{
                .registry = registry,
                .entities_with_components = std.ArrayList(u32).init(allocator),
                .current_index = 0,
            };
            _ = &self;
            
            // // Find all entities that have ALL required components
            // if (registry.entities.items.len > 0) {
            //     for (registry.entities.items) |entity| {
            //         if (self.entityHasComponents(entity)) {
            //             try self.entities_with_components.append(entity);
            //         }
            //     }
            // }
            
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.entities_with_components.deinit();
        }

        // Check if an entity has all the required components
        fn entityHasComponents(self: *Self, entity: u32) bool {
            // This is the only function that needs to do the comptime iteration
            // over the component types, and it's being called from a runtime context
            {
                // Check components included
                inline for (std.meta.fields(ComponentsIncluded)) |field| {
                    // Direct call to registry.get instead of using @call
                    if (self.registry.get(entity, field.type) == null) {
                        return false;
                    }
                }
                
                // Check components excluded
                inline for (std.meta.fields(ComponentsExcluded)) |field| {
                    // Direct call to registry.get instead of using @call
                    if (self.registry.get(entity, field.type) == null) {
                        return false;
                    }
                }
                
                return true;
            }
        }

        pub const ComponentsIncludedStruct = blk: {
            var fields: [std.meta.fields(ComponentsIncluded).len]std.builtin.Type.StructField = undefined;
            
            for (std.meta.fields(ComponentsIncluded), 0..) |field, i| {
                fields[i] = .{
                    .name = std.fmt.comptimePrint("c{d}", .{i}),
                    .type = field.type,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(field.type),
                };
            }
            
            const struct_fields = fields[0..std.meta.fields(ComponentsIncluded).len];
            break :blk @Type(.{
                .@"struct" = .{
                    .layout = .auto,
                    .fields = struct_fields,
                    .decls = &.{},
                    .is_tuple = false,
                },
            });
        };

        pub const ComponentsExcludedStruct = blk: {
            var fields: [std.meta.fields(ComponentsExcluded).len]std.builtin.Type.StructField = undefined;
            
            for (std.meta.fields(ComponentsExcluded), 0..) |field, i| {
                fields[i] = .{
                    .name = std.fmt.comptimePrint("v{d}", .{i}),
                    .type = *field.type,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(*field.type),
                };
            }
            
            const struct_fields = fields[0..std.meta.fields(ComponentsExcluded).len];
            break :blk @Type(.{
                .@"struct" = .{
                    .layout = .auto,
                    .fields = struct_fields,
                    .decls = &.{},
                    .is_tuple = false,
                },
            });
        };

        // Define our return type for the iterator
        pub const IterResult = struct {
            entity: u32,
            // Use structs for components instead of tuples
            components: ComponentsIncludedStruct,
            var_components: ComponentsExcludedStruct,
        };

        // Iterator to get the next entity and its components
        pub fn next(self: *Self) ?IterResult {
            if (self.current_index >= self.entities_with_components.items.len) {
                return null;
            }
            
            const entity = self.entities_with_components.items[self.current_index];
            self.current_index += 1;
            
            // Get constant components (read-only)
            var const_components: ComponentsIncludedStruct = undefined;
            inline for (std.meta.fields(ComponentsIncluded), 0..) |field, i| {
                const component_type = field.type;
                const component_ptr = self.registry.get(entity, component_type).?;
                
                const field_name = comptime std.fmt.comptimePrint("c{d}", .{i});
                @field(const_components, field_name) = component_ptr.*;
            }
            
            // Get variable components (mutable)
            var var_components: ComponentsExcludedStruct = undefined;
            inline for (std.meta.fields(ComponentsExcluded), 0..) |field, i| {
                const component_type = field.type;
                const component_ptr = self.registry.get(entity, component_type).?;
                
                const field_name = comptime std.fmt.comptimePrint("v{d}", .{i});
                @field(var_components, field_name) = component_ptr;
            }
            
            return IterResult{
                .entity = entity,
                .const_components = const_components,
                .var_components = var_components,
            };
        }
    };
}

// Function to create a view
pub fn view(self: *Registry, comptime components_included: anytype, comptime components_excluded: anytype) View(
    @TypeOf(components_included),
    @TypeOf(components_excluded)
) {
    return View(
        @TypeOf(components_included),
        @TypeOf(components_excluded)
    ).init(self, self.allocator);
}

test "basic" {
    const Position = struct {
        x: f32,
        y: f32,
    };

    const Velocity = struct {
        dx: f32,
        dy: f32,
    };

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const entity = try registry.create();
    try testing.expectEqual(1, entity);

    try registry.emplace(entity, Position{ .x = 1.5, .y = 3.0});
    try registry.emplace(entity, Velocity{ .dx = 5.5, .dy = 10.0});
    
    // Test component retrieval
    const pos = registry.get(entity, Position);
    try testing.expect(pos != null);
    try testing.expectEqual(1.5, pos.?.x);
    try testing.expectEqual(3.0, pos.?.y);
    
    const vel = registry.get(entity, Velocity);
    try testing.expect(vel != null);
    try testing.expectEqual(5.5, vel.?.dx);
    try testing.expectEqual(10.0, vel.?.dy);
}

test "view components" {
    const Position = struct {
        x: f32,
        y: f32,
    };

    const Velocity = struct {
        dx: f32,
        dy: f32,
    };

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    // Create multiple entities
    const entity1 = try registry.create();
    const entity2 = try registry.create();
    const entity3 = try registry.create();
    
    // Emplace components
    try registry.emplace(entity1, Position{ .x = 1.0, .y = 2.0 });
    try registry.emplace(entity1, Velocity{ .dx = 1.0, .dy = 1.0 });
    
    try registry.emplace(entity2, Position{ .x = 3.0, .y = 4.0 });
    try registry.emplace(entity2, Velocity{ .dx = 2.0, .dy = 2.0 });
    
    // Entity3 only has Position
    try registry.emplace(entity3, Position{ .x = 5.0, .y = 6.0 });

    // Create a view for entities with Position (const) and Velocity (var)
    var entity_view = registry.view(.{Position}, .{Velocity});
    defer entity_view.deinit();

    // TODO: Add iterating functionality
    // var iter = entity_view.entityIterator();
    // while (iter.next()) |e| {

    // }
}