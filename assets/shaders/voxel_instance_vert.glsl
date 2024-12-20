#version 410 core
layout (location = 0) in vec3 aPos;
layout (location = 1) in vec2 aTexCoords;
layout (location = 2) in mat4 aInstanceMatrix; // This will use locations 2,3,4,5

uniform mat4 view;
uniform mat4 projection;

out vec3 TexCoords; // Changed from vec2 to vec3 for cubemap

void main()
{
    vec4 worldPos = aInstanceMatrix * vec4(aPos, 1.0);
    gl_Position = projection * view * worldPos;
    // Use the vertex position in world space as texture coordinates
    TexCoords = aPos; // Use local position as cubemap direction
}