#version 450

// packed vertex, see src/world/mesher.zig
//   data:  x:6 y:6 z:6 face:3 ao:2 sky:4 block:4 solid:1
//   color: RGB8 sRGB in the low 24 bits, texture layer in the top 8 (255 = flat color)
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
    vec4 light;  // rgb: block light color, w: sky brightness (daylight)
} scene;

layout(push_constant) uniform Push {
    vec4 origin; // xyz: mesh origin relative to the camera, w: size of a mesh unit in blocks
} pc;

layout(location = 0) out vec3 v_rel_pos;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec3 v_color;
layout(location = 3) out float v_ao;
layout(location = 4) out vec2 v_uv;
layout(location = 5) flat out uint v_layer;
layout(location = 6) out vec2 v_light; // sky and block light, 0..1
layout(location = 7) flat out uint v_solid;

const vec3 normals[6] = vec3[](
    vec3(1, 0, 0), vec3(-1, 0, 0),
    vec3(0, 1, 0), vec3(0, -1, 0),
    vec3(0, 0, 1), vec3(0, 0, -1)
);

// texture axes per face, as rows of (x, y, z) weights: u points right and v down when
// looking at the face from outside
const vec3 face_u[6] = vec3[](
    vec3(0, 0, -1), vec3(0, 0, 1),
    vec3(1, 0, 0), vec3(1, 0, 0),
    vec3(1, 0, 0), vec3(-1, 0, 0)
);
const vec3 face_v[6] = vec3[](
    vec3(0, -1, 0), vec3(0, -1, 0),
    vec3(0, 0, 1), vec3(0, 0, -1),
    vec3(0, -1, 0), vec3(0, -1, 0)
);

// light reaching a corner by number of open neighbors (0 = enclosed)
const float ao_curve[4] = float[](0.35, 0.55, 0.78, 1.0);

void main() {
    vec3 local = vec3(in_data & 63u, (in_data >> 6) & 63u, (in_data >> 12) & 63u);
    uint face = (in_data >> 18) & 7u;
    uint ao = (in_data >> 21) & 3u;

    vec3 rel = pc.origin.xyz + local * pc.origin.w;
    gl_Position = scene.view_proj * vec4(rel, 1.0);

    v_rel_pos = rel;
    v_normal = normals[face];
    v_color = unpackUnorm4x8(in_color).rgb;
    v_ao = ao_curve[ao];
    // block coordinates on the face; the sampler repeats, so each block shows one whole tile
    v_uv = vec2(dot(local, face_u[face]), dot(local, face_v[face]));
    v_layer = in_color >> 24;
    v_light = vec2((in_data >> 23) & 15u, (in_data >> 27) & 15u) / 15.0;
    v_solid = in_data >> 31;
}
