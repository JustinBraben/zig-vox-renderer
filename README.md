# zig-vox-renderer

Voxel renderer written in Zig, using Vulkan 1.3 (dynamic rendering), SDL3 and dvui for the debug UI.

# Build the Project

You will need Zig 0.16.0 and `glslc` (from the Vulkan SDK) on your `PATH` to compile the shaders.

```
zig build run
```

Run `zig build run -- --bench[=render_distance]` to measure world loading and frame times.

Shaders and textures are loaded at startup from an `assets/` folder next to the executable. `zig build` installs it to `zig-out/bin/assets` (compiled shaders in `shaders/`, a copy of `assets/textures` in `textures/`), so keep that folder with the executable when moving it.
