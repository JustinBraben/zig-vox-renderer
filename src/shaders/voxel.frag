#version 450

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

layout(set = 0, binding = 1) uniform samplerCube sky;
// block textures, one layer per tile (sRGB, so samples are linear)
layout(set = 0, binding = 2) uniform sampler2DArray blocks;

layout(location = 0) in vec3 v_rel_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec3 v_color;
layout(location = 3) in float v_ao;
layout(location = 4) in vec2 v_uv;
layout(location = 5) flat in uint v_layer;
layout(location = 6) in vec2 v_light;
layout(location = 7) flat in uint v_solid;

layout(location = 0) out vec4 out_color;

// 0: solid pass (alpha-tested, opaque output), 1: translucent pass (blended)
layout(constant_id = 0) const bool translucent = false;

vec3 srgbToLinear(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

// light level (0..1) to brightness: steep, so light falls off quickly from its source
float brightness(float level) {
    return level / (4.0 - 3.0 * level);
}

// the swapchain is UNORM (dvui expects that), so encode to sRGB ourselves
vec3 linearToSrgb(vec3 c) {
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

void main() {
    vec3 albedo = srgbToLinear(v_color);
    float alpha = 1.0;
    if (v_layer != 255u) {
        vec4 texel = texture(blocks, vec3(v_uv, float(v_layer)));
        if (v_solid != 0u) {
            // fast leaves: gaps show a dark shade of the block's color
            albedo = mix(albedo * 0.25, texel.rgb, texel.a);
        } else {
            albedo = texel.rgb;
            alpha = texel.a;
        }
    }
    // cutout: leaf gaps
    if (!translucent && alpha < 0.5) discard;
    vec3 n = normalize(v_normal);

    float sun = max(dot(n, scene.sun_dir.xyz), 0.0);
    vec3 ambient = mix(scene.ground_color.rgb, scene.sky_color.rgb, n.y * 0.5 + 0.5);
    float ao = mix(1.0, v_ao, scene.params.z);
    // sun and sky reach a block as far as its sky light says; lamps add their own
    vec3 outdoor = (scene.sun_color.rgb * sun + ambient) * brightness(v_light.x);
    vec3 indoor = scene.light.rgb * brightness(v_light.y);
    // a little light everywhere, so caves aren't pitch black
    vec3 color = albedo * (outdoor + indoor + vec3(0.02)) * ao;

    float fog_start = scene.params.x;
    float fog_end = scene.params.y;
    if (fog_end > 0.0) {
        float t = smoothstep(fog_start, fog_end, length(v_rel_pos));
        // fade into whatever sky is behind the block (the cubemap is sRGB, so this is linear)
        vec3 fog = scene.params.w > 0.0 ? texture(sky, normalize(v_rel_pos)).rgb * scene.light.w : scene.fog_color.rgb;
        color = mix(color, fog, t);
    }

    out_color = vec4(linearToSrgb(color), translucent ? alpha : 1.0);
}
