#version 410 core

// Vertex attributes
layout (location = 0) in vec3 a_position;
layout (location = 1) in vec3 a_normal;
layout (location = 2) in vec2 a_texCoord;

// Uniforms
uniform mat4 u_model;
uniform mat4 u_view;
uniform mat4 u_projection;

// Outputs to fragment shader
out vec3 v_normal;
out vec2 v_texCoord;
out vec3 v_position;

void main() {
    // Calculate final position in clip space
    gl_Position = u_projection * u_view * u_model * vec4(a_position, 1.0);
    
    // Pass normal to fragment shader (in world space)
    v_normal = mat3(transpose(inverse(u_model))) * a_normal;
    
    // Pass texture coordinates to fragment shader
    v_texCoord = a_texCoord;
    
    // Calculate position in world space for lighting
    v_position = vec3(u_model * vec4(a_position, 1.0));
}