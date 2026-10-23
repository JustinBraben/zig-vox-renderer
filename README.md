# zig-vox-renderer

Voxel renderer written in Zig, using Vulkan 1.3 (dynamic rendering), SDL3 and dvui for the debug UI.

# Build the Project

You will need Zig 0.16.0 and `glslc` (from the Vulkan SDK) on your `PATH` to compile the shaders.

On macOS you also need a Vulkan loader and **MoltenVK 1.3 or newer** (older versions only report Vulkan 1.2
and will be rejected with `NoSuitableDevice`). `brew install vulkan-loader molten-vk` is the easiest way to get
a current one; the LunarG Vulkan SDK works too if it is recent enough (1.4.309 still bundles MoltenVK 1.2.11,
which is too old). SDL3 cannot find the loader by name on recent macOS, so the app looks for it at the usual
absolute paths, preferring Homebrew's; set `SDL_VULKAN_LIBRARY=/path/to/libvulkan.1.dylib` to pick a different one.

```
zig build run
```

## Controls

Click the world to capture the mouse, Esc releases it for the debug UI.

- WASD: move, Space: jump (up while flying), Ctrl: down while flying, Shift: sprint
- Left mouse: break block, right mouse: place block, mouse wheel / 1-9: pick block
- F: toggle flying

## Benchmark

Run `zig build run -- --bench[=render_distance]` to measure world loading and frame times.

Shaders and textures are loaded at startup from an `assets/` folder next to the executable. `zig build` installs it to `zig-out/bin/assets` (compiled shaders in `shaders/`, a copy of `assets/textures` in `textures/`), so keep that folder with the executable when moving it.
