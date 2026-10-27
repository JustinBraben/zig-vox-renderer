#version 450

// block textures, one layer per tile (sRGB, so samples are linear)
layout(set = 0, binding = 2) uniform sampler2DArray blocks;

layout(location = 0) in vec2 v_uv;
layout(location = 1) flat in uint v_layer;
layout(location = 2) in vec4 v_color; // sRGB

layout(location = 0) out vec4 out_color;

vec3 srgbToLinear(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

// the swapchain is UNORM (dvui expects that), so encode to sRGB ourselves
vec3 linearToSrgb(vec3 c) {
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

void main() {
    vec4 texel = v_layer == 0xffffffffu ? vec4(1.0) : texture(blocks, vec3(v_uv, float(v_layer)));
    float alpha = texel.a * v_color.a;
    // clear texels (leaf gaps, around cracks) shouldn't write depth
    if (alpha < 0.01) discard;
    out_color = vec4(linearToSrgb(texel.rgb * srgbToLinear(v_color.rgb)), alpha);
}
