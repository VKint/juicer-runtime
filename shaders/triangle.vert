#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec2 inUV;
layout(location = 2) in vec3 inNormal;

layout(set = 1, binding = 0) uniform CameraBlock {
    mat4 mvp;
    mat4 model;
};

layout(location = 0) out vec2 fragUV;
layout(location = 1) out vec3 fragPosition;
layout(location = 2) out vec3 fragNormal;

void main() {
    gl_Position = mvp * vec4(inPosition, 1.0);
    fragPosition = (model * vec4(inPosition, 1.0)).xyz; // world space
    fragUV = inUV;
    fragNormal = mat3(model) * inNormal; // transform normal too!
}
