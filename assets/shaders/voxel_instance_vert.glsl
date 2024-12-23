#version 410 core
layout (location = 0) in vec3 aPos;
layout (location = 1) in vec3 aNormal;
layout (location = 2) in vec2 aTexCoords;
layout (location = 3) in mat4 aInstanceMatrix; // This will use locations 3,4,5,6

out vec3 FragPos;
out vec3 Normal;
out vec3 TexCoords; // Changed from vec2 to vec3 for cubemap

uniform mat4 view;
uniform mat4 projection;

void main()
{
    FragPos = vec3(aInstanceMatrix * vec4(aPos, 1.0));
    Normal = mat3(transpose(inverse(aInstanceMatrix))) * aNormal;
    TexCoords = aPos; // Use local position as cubemap direction

    // Use the vertex position in world space as texture coordinates
    vec4 worldPos = aInstanceMatrix * vec4(aPos, 1.0);
    gl_Position = projection * view * worldPos;
}