#version 450

layout(set = 0, binding = 0) uniform Scene {
    mat4 view_proj;
    vec4 sun_dir;
    vec4 sun_color;
    vec4 sky_color;
    vec4 ground_color;
    vec4 fog_color;
    vec4 params;
    vec4 light; // w: sky brightness (daylight)
} scene;

layout(set = 0, binding = 1) uniform samplerCube sky;

layout(location = 0) in vec3 v_dir;

layout(location = 0) out vec4 out_color;

// the swapchain is UNORM (dvui expects that), so encode to sRGB ourselves
vec3 linearToSrgb(vec3 c) {
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

void main() {
    // the cubemap is sRGB, so this is linear
    vec3 color = texture(sky, normalize(v_dir)).rgb * scene.light.w;
    out_color = vec4(linearToSrgb(color), 1.0);
}
