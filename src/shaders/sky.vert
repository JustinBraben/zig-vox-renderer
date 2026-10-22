#version 450

// Full-screen triangle at the far plane; each corner carries its world-space view ray.

layout(push_constant) uniform Push {
    vec4 right;   // xyz: camera right, w: tan(fov / 2) * aspect
    vec4 up;      // xyz: camera up, w: tan(fov / 2)
    vec4 forward; // xyz: camera forward
} pc;

layout(location = 0) out vec3 v_dir;

void main() {
    vec2 ndc = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2) * 2.0 - 1.0;
    // reverse-Z: depth 0 is infinitely far away
    gl_Position = vec4(ndc, 0.0, 1.0);
    // Vulkan NDC y points down
    v_dir = pc.forward.xyz + ndc.x * pc.right.w * pc.right.xyz - ndc.y * pc.up.w * pc.up.xyz;
}
