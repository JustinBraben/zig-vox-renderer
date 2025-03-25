const std = @import("std");
const Allocator = std.mem.Allocator;
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const Window = @import("window.zig");

const Input = @This();

pub const GameAction = enum {
    move_forward,
    move_backward,
    move_left,
    move_right,
    jump,
    attack,
    place_block,
    inventory,
    crouch,
    sprint,
    exit,
};

pub const InputSource = enum {
    keyboard,
    mouse,
    gamepad,
};

pub const InputState = enum {
    pressed,
    released,
    held,
};

pub const InputBinding = struct {
    source: InputSource,
    // Use union to store different types of inputs
    value: union(InputSource) {
        keyboard: glfw.Key,
        mouse: glfw.MouseButton,
        gamepad: u8, // Button or axis ID
    },
};

pub const Pos = struct {
    x: f64,
    y: f64,
};

allocator: Allocator,
window: *glfw.Window,
// Map from action to its current state
action_states: std.AutoHashMap(GameAction, InputState),
// Map from action to its bindings
action_bindings: std.AutoHashMap(GameAction, std.ArrayList(InputBinding)),
// Previous key/button states for detecting changes
prev_key_states: [@intFromEnum(glfw.Key.menu) + 1]bool,
prev_mouse_states: [@intFromEnum(glfw.MouseButton.eight) + 1]bool,

// Cursor position
cursor_pos: Pos,
cursor_delta: Pos,
last_cursor_pos: Pos,

pub fn init(allocator: Allocator, window: *Window) !Input {
    // Initialize with default bindings
    var input = Input{
        .window = window.window,
        .action_states = std.AutoHashMap(GameAction, InputState).init(allocator),
        .action_bindings = std.AutoHashMap(GameAction, std.ArrayList(InputBinding)).init(allocator),
        .prev_key_states = @splat(false),
        .prev_mouse_states = @splat(false),
        .cursor_pos = .{ .x = 0, .y = 0 },
        .cursor_delta = .{ .x = 0, .y = 0 },
        .last_cursor_pos = .{ .x = 0, .y = 0 },
        .allocator = allocator,
    };

    try input.setupDefaultBindings();

    // Get initial cursor position to avoid a large initial delta
    const cursor_pos = window.window.getCursorPos();
    input.cursor_pos.x = cursor_pos[0];
    input.cursor_pos.y = cursor_pos[1];
    input.last_cursor_pos = input.cursor_pos;
        
    // Register GLFW callback for cursor position
    _ = glfw.setCursorPosCallback(window.window, cursorPosCallback);
    try window.window.setInputMode(.cursor, glfw.Cursor.Mode.disabled);
    window.window.setUserPointer(&input);

    return input;
}

pub fn deinit(self: *Input) void {
    var it = self.action_bindings.valueIterator();
    while (it.next()) |bindings| {
        bindings.deinit();
    }
    
    self.action_states.deinit();
    self.action_bindings.deinit();
}

fn setupDefaultBindings(self: *Input) !void {
    // Movement
    try self.bindAction(.move_forward, .{ .source = .keyboard, .value = .{.keyboard = glfw.Key.w} });
    try self.bindAction(.move_backward, .{ .source = .keyboard, .value = .{.keyboard = glfw.Key.s} });
    try self.bindAction(.move_left, .{ .source = .keyboard, .value = .{.keyboard = glfw.Key.a} });
    try self.bindAction(.move_right, .{ .source = .keyboard, .value = .{.keyboard = glfw.Key.d} });
    try self.bindAction(.jump, .{ .source = .keyboard, .value = .{.keyboard = glfw.Key.space} });
    
    // Actions
    try self.bindAction(.exit, .{ .source = .keyboard, .value = .{.keyboard = glfw.Key.escape} });
    // try self.bindAction(.attack, .mouse, .{ .mouse = glfw.MouseButton.left });
    // try self.bindAction(.place_block, .mouse, .{ .mouse = glfw.MouseButton.right });
    // try self.bindAction(.inventory, .keyboard, .{ .keyboard = glfw.Key.e });
    // try self.bindAction(.crouch, .keyboard, .{ .keyboard = glfw.Key.left_control });
    // try self.bindAction(.sprint, .keyboard, .{ .keyboard = glfw.Key.left_shift });
}

pub fn bindAction(self: *Input, action: GameAction, input_binding: InputBinding) !void {
    var entry = try self.action_bindings.getOrPut(action);
    if (!entry.found_existing) {
        entry.value_ptr.* = std.ArrayList(InputBinding).init(self.allocator);
    }
    
    try entry.value_ptr.append(input_binding);
}

pub fn update(self: *Input) !void {
    // Store the previous cursor position
    const prev_pos = self.cursor_pos;

    glfw.pollEvents();

    // Get the current cursor position directly
    const cursor_pos = self.window.getCursorPos();
    self.cursor_pos.x = cursor_pos[0];
    self.cursor_pos.y = cursor_pos[1];
    
    // Calculate delta
    self.cursor_delta.x = self.cursor_pos.x - prev_pos.x;
    self.cursor_delta.y = prev_pos.y - self.cursor_pos.y; // Y is inverted

    // Update all action states
    var it = self.action_bindings.iterator();
    while (it.next()) |entry| {
        const action = entry.key_ptr.*;
        const bindings = entry.value_ptr.*;
        
        var action_triggered = false;
        
        for (bindings.items) |binding| {
            switch (binding.source) {
                .keyboard => {
                    const key = binding.value.keyboard;
                    const is_pressed = glfw.getKey(self.window, key) == .press;
                    const was_pressed = self.prev_key_states[@intCast(@intFromEnum(key))];
                    
                    if (is_pressed and !was_pressed) {
                        try self.action_states.put(action, .pressed);
                        action_triggered = true;
                    } else if (is_pressed and was_pressed) {
                        try self.action_states.put(action, .held);
                        action_triggered = true;
                    } else if (!is_pressed and was_pressed) {
                        try self.action_states.put(action, .released);
                        action_triggered = true;
                    }
                    
                    self.prev_key_states[@intCast(@intFromEnum(key))] = is_pressed;
                },
                .mouse => {
                    const button = binding.value.mouse;
                    const is_pressed = glfw.getMouseButton(self.window, button) == .press;
                    const was_pressed = self.prev_mouse_states[@intCast(@intFromEnum(button))];
                    
                    if (is_pressed and !was_pressed) {
                        try self.action_states.put(action, .pressed);
                        action_triggered = true;
                    } else if (is_pressed and was_pressed) {
                        try self.action_states.put(action, .held);
                        action_triggered = true;
                    } else if (!is_pressed and was_pressed) {
                        try self.action_states.put(action, .released);
                        action_triggered = true;
                    }
                    
                    self.prev_mouse_states[@intCast(@intFromEnum(button))] = is_pressed;
                },
                .gamepad => {
                    // Gamepad input handling would go here
                    // Similar to keyboard and mouse but with gamepad state queries
                },
            }
            
            if (action_triggered) break;
        }
        
        if (!action_triggered and self.action_states.get(action) == .released) {
            // If action was released last frame and not triggered this frame, remove it
            _ = self.action_states.remove(action);
        }
    }

    if (self.window.getKey(.escape) == .press) {
        self.window.setShouldClose(true);
    }
}

pub fn isActionPressed(self: *const Input, action: GameAction) bool {
    return if (self.action_states.get(action)) |state| state == .pressed else false;
}

pub fn isActionHeld(self: *const Input, action: GameAction) bool {
    return if (self.action_states.get(action)) |state| state == .held or state == .pressed else false;
}

pub fn isActionReleased(self: *const Input, action: GameAction) bool {
    return if (self.action_states.get(action)) |state| state == .released else false;
}

pub fn getCursorDelta(self: *Input) Pos {
    return self.cursor_delta;
}

fn cursorPosCallback(window: *glfw.Window, x: f64, y: f64) callconv(.C) void {
    if (window.getUserPointer(Input)) |input_ptr| {
        // Just update the current position
        input_ptr.*.cursor_pos.x = x;
        input_ptr.*.cursor_pos.y = y;
    }
}