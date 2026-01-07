#version 450

layout(location = 0) in vec2 fragUV;
layout(location = 1) in vec3 fragPosition;
layout(location = 2) in vec3 fragNormal;

layout(location = 0) out vec4 fragColor;

layout(set = 2, binding = 0) uniform sampler2D texSampler;

#define MAX_LIGHTS 16

struct Light {
    vec4 header;           // x = type, y = uses shadows, zw = unused
    vec4 positionRange;    // xyz = position, w = range
    vec4 colorIntensity;   // xyz = color, w = intensity
};

layout(set = 3, binding = 0) uniform LightsBlock {
    Light lights[MAX_LIGHTS];
    int lightCount;
};

void main() {
    vec3 normal = normalize(fragNormal);
    vec3 texColor = texture(texSampler, fragUV).rgb;

    vec3 totalDiffuse = vec3(0.0);

    for (int i = 0; i < lightCount; i++) {
        vec3 lightPos = lights[i].positionRange.xyz;
        float lightRange = lights[i].positionRange.w;
        vec3 lightColor = lights[i].colorIntensity.xyz;
        float lightIntensity = lights[i].colorIntensity.w;
        bool useShadows = lights[i].header.y > 0.5;

        vec3 toLight = lightPos - fragPosition;
        float distance = length(toLight);
        vec3 lightDir = toLight / distance;

        float attenuation = clamp(1.0 - distance / lightRange, 0.0, 1.0);
        attenuation *= attenuation;

        float diff = max(dot(normal, lightDir), 0.0);
        float scaledIntensity = lightIntensity * 0.0001;

        totalDiffuse += lightColor * scaledIntensity * diff * attenuation;
    }

    vec3 ambient = vec3(0.25);
    fragColor = vec4(texColor * (ambient + totalDiffuse), 1.0);
    // fragColor = vec4(1.0, 1.0, 1.0, 1.0); //temporary
}
