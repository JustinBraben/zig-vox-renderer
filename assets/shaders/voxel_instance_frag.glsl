#version 410 core
out vec4 FragColor;

in vec3 TexCoords;

uniform samplerCube texture_diffuse1;

// Function to sample neighboring voxel colors
vec4 sampleVoxel(vec3 texCoords) {
    return texture(texture_diffuse1, texCoords);
}

void main()
{
    FragColor = texture(texture_diffuse1, TexCoords);
}