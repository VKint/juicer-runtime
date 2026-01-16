#version 450

layout(location = 0) in vec2 fragUV;
layout(location = 1) in vec3 fragPosition;
layout(location = 2) in mat3 fragTBN;

layout(location = 0) out vec4 fragColor;

layout(set = 2, binding = 0) uniform sampler2D texSampler;
layout(set = 2, binding = 1) uniform sampler2D normalSampler;

#define MAX_LIGHTS 16

struct Light {
    vec4 header;
    vec4 positionRange;
    vec4 colorIntensity;
};

layout(set = 3, binding = 0) uniform LightsBlock {
    Light lights[MAX_LIGHTS];
    int lightCount;
};

void main() {
    // 1. Sample and Transform Normal
    vec3 normalMap = texture(normalSampler, fragUV).rgb;
    // Flip Y channel for DirectX-style normal map compatibility / UV coordinate fix
    normalMap.g = 1.0 - normalMap.g;
    vec3 normal = normalize(fragTBN * (normalMap * 2.0 - 1.0));

    // 2. Base Color
    vec4 baseColor = texture(texSampler, fragUV);
    if (baseColor.a < 0.5) discard; // Simple alpha test

    vec3 texColor = baseColor.rgb;
    vec3 totalDiffuse = vec3(0.0);

    // 3. Lighting Loop
    for (int i = 0; i < lightCount; i++) {
        vec3 lightPos = lights[i].positionRange.xyz;
        float lightRange = lights[i].positionRange.w;
        vec3 lightColor = lights[i].colorIntensity.xyz;
        float lightIntensity = lights[i].colorIntensity.w;
        // Shadow logic omitted for now

        vec3 toLight = lightPos - fragPosition;
        float distance = length(toLight);
        vec3 lightDir = toLight / distance;

        float attenuation = clamp(1.0 - distance / lightRange, 0.0, 1.0);
        attenuation *= attenuation;

        float diff = max(dot(normal, lightDir), 0.0);
        float scaledIntensity = lightIntensity * 0.0001; // Magic scaler

        totalDiffuse += lightColor * scaledIntensity * diff * attenuation;
    }

    vec3 ambient = vec3(0.05); // Lower ambient to see lights better
    fragColor = vec4(texColor * (ambient + totalDiffuse), 1.0);
}
