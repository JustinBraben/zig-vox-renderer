#version 450

// Lines from gl_VertexIndex, no vertex buffer:
//   mode 0: the 12 edges of a block (24 vertices), slightly enlarged
//   mode 1: a screen-centered crosshair (4 vertices)

layout(set = 0, binding = 0) uniform Scene {
    mat4 view_proj;
} scene;

layout(push_constant) uniform Push {
    vec4 origin; // xyz: block minimum corner relative to the camera, w: mode
    vec4 params; // xy: crosshair half-size in NDC
} pc;

layout(location = 0) out vec3 v_color;

// corner i is (i & 1, (i >> 1) & 1, (i >> 2) & 1); each edge joins corners one bit apart
const ivec2 edges[12] = ivec2[](
    ivec2(0, 1), ivec2(2, 3), ivec2(4, 5), ivec2(6, 7),
    ivec2(0, 2), ivec2(1, 3), ivec2(4, 6), ivec2(5, 7),
    ivec2(0, 4), ivec2(1, 5), ivec2(2, 6), ivec2(3, 7)
);

const vec2 crosshair[4] = vec2[](vec2(-1, 0), vec2(1, 0), vec2(0, -1), vec2(0, 1));

void main() {
    if (pc.origin.w < 0.5) {
        ivec2 edge = edges[gl_VertexIndex / 2];
        int corner = (gl_VertexIndex & 1) == 0 ? edge.x : edge.y;
        vec3 p = vec3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1);
        // grow a little around the center so the lines don't z-fight with the faces
        p = (p - 0.5) * 1.004 + 0.5;
        gl_Position = scene.view_proj * vec4(pc.origin.xyz + p, 1.0);
        v_color = vec3(0.02);
    } else {
        // depth 1 is the near plane in reverse-Z, so it is never hidden
        gl_Position = vec4(crosshair[gl_VertexIndex] * pc.params.xy, 1.0, 1.0);
        v_color = vec3(1.0);
    }
}
