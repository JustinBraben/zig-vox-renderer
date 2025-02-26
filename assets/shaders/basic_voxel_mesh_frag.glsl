#version 410 core

// Inputs from vertex shader
in vec3 v_normal;
in vec2 v_texCoord;
in vec3 v_position;

// Output
out vec4 FragColor;

// Uniforms
uniform sampler2D u_texture;
uniform vec3 u_lightPos = vec3(1000.0, 1000.0, 1000.0); // Default light position
uniform vec3 u_viewPos;  // Camera position for specular calculation

void main() {
    // Texture color
    vec4 texColor = texture(u_texture, v_texCoord);
    
    // Basic lighting calculation
    // Ambient component
    float ambientStrength = 0.3;
    vec3 ambient = ambientStrength * vec3(1.0);
    
    // Diffuse component
    vec3 norm = normalize(v_normal);
    vec3 lightDir = normalize(u_lightPos - v_position);
    float diff = max(dot(norm, lightDir), 0.0);
    vec3 diffuse = diff * vec3(1.0);
    
    // Specular component (optional, for a bit of shine)
    float specularStrength = 0.1;
    vec3 viewDir = normalize(u_viewPos - v_position);
    vec3 reflectDir = reflect(-lightDir, norm);
    float spec = pow(max(dot(viewDir, reflectDir), 0.0), 32);
    vec3 specular = specularStrength * spec * vec3(1.0);
    
    // Combine lighting components
    vec3 lighting = ambient + diffuse + specular;
    
    // Apply lighting to texture color
    FragColor = vec4(lighting * texColor.rgb, texColor.a);
}