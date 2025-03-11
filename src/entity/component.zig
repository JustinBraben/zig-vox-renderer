const std = @import("std");
const Allocator = std.mem.Allocator;
const SparseSet = @import("sparse_set.zig").SparseSet;

/// Type-erased component interface
pub fn IComponentStorage(comptime EntityT: type) type {
    return struct {
        const Self = @This();
        
        // Vtable for type-erased operations
        pub const VTable = struct {
            deinit: *const fn(self: *Self) void,
            add: *const fn(self: *Self, entity: EntityT, component: *const anyopaque) error{OutOfMemory}!void,
            remove: *const fn(self: *Self, entity: EntityT) void,
            get: *const fn(self: *Self, entity: EntityT) ?*anyopaque,
            contains: *const fn(self: *Self, entity: EntityT) bool,
        };
        
        vtable: *const VTable,
        ptr: *anyopaque,
        
        pub fn deinit(self: *Self) void {
            self.vtable.deinit(self);
        }
        
        pub fn add(self: *Self, entity: EntityT, component: *const anyopaque) !void {
            return self.vtable.add(self, entity, component);
        }
        
        pub fn remove(self: *Self, entity: EntityT) void {
            self.vtable.remove(self, entity);
        }
        
        pub fn get(self: *Self, entity: EntityT) ?*anyopaque {
            return self.vtable.get(self, entity);
        }
        
        pub fn contains(self: *Self, entity: EntityT) bool {
            return self.vtable.contains(self, entity);
        }
    };
}

/// Concrete implementation of component storage
pub fn ComponentStorage(comptime EntityT: type, comptime ComponentT: type) type {
    return struct {
        const Self = @This();

        entities: SparseSet(EntityT),
        components: std.ArrayList(ComponentT),
        allocator: Allocator,

        // Static vtable for this component type
        const vtable = IComponentStorage(EntityT).VTable{
            .deinit = deinitFn,
            .add = addFn,
            .remove = removeFn,
            .get = getFn,
            .contains = containsFn,
        };

        pub fn init(allocator: Allocator) Self {
            return .{
                .entities = SparseSet(EntityT).init(allocator),
                .components = std.ArrayList(ComponentT).init(allocator),
                .allocator = allocator,
            };
        }

        // Create a type-erased interface
        pub fn interface(self: *Self) IComponentStorage(EntityT) {
            return .{
                .vtable = &vtable,
                .ptr = self,
            };
        }

        // Implementation of vtable functions
        fn deinitFn(component_storage_interface: *IComponentStorage(EntityT)) void {
            const self: *Self = @ptrCast(@alignCast(component_storage_interface.ptr));
            self.entities.deinit();
            self.components.deinit();
            self.allocator.destroy(self);
        }

        fn addFn(component_storage_interface: *IComponentStorage(EntityT), entity: EntityT, component_ptr: *const anyopaque) error{OutOfMemory}!void {
            const self: *Self = @ptrCast(@alignCast(component_storage_interface.ptr));
            const component: ComponentT = @as(*const ComponentT, @ptrCast(@alignCast(component_ptr))).*;
            return self.add(entity, component);
        }
        
        fn removeFn(component_storage_interface: *IComponentStorage(EntityT), entity: EntityT) void {
            const self: *Self = @ptrCast(@alignCast(component_storage_interface.ptr));
            self.remove(entity);
        }
        
        fn getFn(component_storage_interface: *IComponentStorage(EntityT), entity: EntityT) ?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(component_storage_interface.ptr));
            if (self.get(entity)) |component| {
                return component;
            }
            return null;
        }
        
        fn containsFn(component_storage_interface: *IComponentStorage(EntityT), entity: EntityT) bool {
            const self: *Self = @ptrCast(@alignCast(component_storage_interface.ptr));
            return self.entities.contains(entity);
        }
        
        // Actual implementation methods
        pub fn add(self: *Self, entity: EntityT, component: ComponentT) !void {
            if (self.entities.contains(entity)) {
                // Update existing component
                const idx = self.entities.getIndexOfEntity(entity).?;
                self.components.items[idx] = component;
            } else {
                // Add new component
                try self.entities.add(entity);
                try self.components.append(component);
            }
        }
        
        pub fn remove(self: *Self, entity: EntityT) void {
            if (!self.entities.contains(entity)) return;
            
            const idx = self.entities.getIndexOfEntity(entity).?;
            
            // Move the last component to fill the gap
            if (idx < self.components.items.len - 1) {
                self.components.items[idx] = self.components.items[self.components.items.len - 1];
            }
            
            // Remove the last component
            _ = self.components.pop();
            self.entities.remove(entity);
        }
        
        pub fn get(self: *Self, entity: EntityT) ?*ComponentT {
            if (!self.entities.contains(entity)) return null;
            
            const idx = self.entities.getIndexOfEntity(entity).?;
            return &self.components.items[idx];
        }
    };
}