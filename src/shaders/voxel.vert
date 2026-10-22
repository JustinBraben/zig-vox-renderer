#version 450

// packed vertex, see src/world/mesher.zig
//   data:  x:6 y:6 z:6 face:3 ao:2
//   color: RGBA8 sRGB
layout(location = 0) in uint in_data;
layout(location = 1) in uint in_color;

layout(set = 0, binding = 0) uniform Scene {
    mat4 view_proj;
    vec4 sun_dir;
    vec4 sun_color;
    vec4 sky_color;
    vec4 ground_color;
    vec4 fog_color;
    vec4 params; // x: fog start, y: fog end, z: ao strength, w: 1 = fog towards the skybox
} scene;

layout(push_constant) uniform Push {
    vec4 origin; // chunk origin relative to the camera
} pc;

layout(location = 0) out vec3 v_rel_pos;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec3 v_color;
layout(location = 3) out float v_ao;

const vec3 normals[6] = vec3[](
    vec3(1, 0, 0), vec3(-1, 0, 0),
    vec3(0, 1, 0), vec3(0, -1, 0),
    vec3(0, 0, 1), vec3(0, 0, -1)
);

// light reaching a corner by number of open neighbors (0 = enclosed)
const float ao_curve[4] = float[](0.35, 0.55, 0.78, 1.0);

void main() {
    vec3 local = vec3(in_data & 63u, (in_data >> 6) & 63u, (in_data >> 12) & 63u);
    uint face = (in_data >> 18) & 7u;
    uint ao = (in_data >> 21) & 3u;

    vec3 rel = pc.origin.xyz + local;
    gl_Position = scene.view_proj * vec4(rel, 1.0);

    v_rel_pos = rel;
    v_normal = normals[face];
    v_color = unpackUnorm4x8(in_color).rgb;
    v_ao = ao_curve[ao];
}
