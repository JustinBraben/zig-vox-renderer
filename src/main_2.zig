// main.zig
const std = @import("std");
const Window = @import("engine/window.zig");
const Input = @import("engine/input.zig");
const Time = @import("engine/time.zig");
// const Audio = @import("engine/audio.zig");
// const GameState = @import("game/game_state.zig");
const Renderer = @import("renderer/renderer.zig");
// const World = @import("game/world/world.zig");
// const Player = @import("game/player.zig");

pub fn main() !void {
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    // Initialize core systems
    var window = try Window.init(.{});
    defer window.deinit();
    
    var input = try Input.init(gpa, &window);
    defer input.deinit();
    
    var time = Time.init();
    
    // var audio = try Audio.init();
    // defer audio.deinit();
    
    // Initialize game systems
    var renderer = try Renderer.init(gpa, &window);
    defer renderer.deinit();
    
    // var world = try World.init();
    // defer world.deinit();
    
    // var player = try Player.init(&world);
    // defer player.deinit();
    
    // var game_state = GameState.init();
    
    // Main game loop
    while (!window.shouldClose()) {
        time.updateDeltaTime();
        
        try input.update();
        
        // // Game logic update
        // try game_state.update(time.deltaTime);
        // try world.update(time.deltaTime);
        // try player.update(time.deltaTime, &input, &world);
        
        // Render
        renderer.beginFrame();
        renderer.renderSkybox();
        // try renderer.renderWorld(&world, &player);
        renderer.endFrame();
        
        window.swapBuffers();
    }
}