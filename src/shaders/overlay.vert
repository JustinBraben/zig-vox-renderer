#version 450

// Overlay triangles built on the CPU (src/gfx/sprites.zig): camera-relative world
// positions, or window pixels (y down) for the HUD.

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in uint in_layer;
layout(location = 3) in vec4 in_color;

layout(set = 0, binding = 0) uniform Scene {
    mat4 view_proj;
} scene;

layout(push_constant) uniform Push {
    vec4 params; // xy: 2 / window size in pixels, z: 1 = positions are pixels
} pc;

layout(location = 0) out vec2 v_uv;
layout(location = 1) flat out uint v_layer;
layout(location = 2) out vec4 v_color;

void main() {
    if (pc.params.z > 0.5) {
        gl_Position = vec4(in_pos.xy * pc.params.xy - 1.0, 0.0, 1.0);
    } else {
        gl_Position = scene.view_proj * vec4(in_pos, 1.0);
    }
    v_uv = in_uv;
    v_layer = in_layer;
    v_color = in_color;
}
