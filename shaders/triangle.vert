#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec2 inUV;
layout(location = 2) in vec3 inNormal;
layout(location = 3) in vec4 inTangent; // NEW

layout(set = 1, binding = 0) uniform CameraBlock {
    mat4 mvp;
    mat4 model;
};

layout(location = 0) out vec2 fragUV;
layout(location = 1) out vec3 fragPosition;
layout(location = 2) out mat3 fragTBN; // Pass the whole matrix

void main() {
    gl_Position = mvp * vec4(inPosition, 1.0);
    fragPosition = (model * vec4(inPosition, 1.0)).xyz; 
    fragUV = inUV;

    // Calculate TBN in World Space
    vec3 T = normalize(mat3(model) * inTangent.xyz);
    vec3 N = normalize(mat3(model) * inNormal);
    
    // Gram-Schmidt re-orthogonalization
    T = normalize(T - dot(T, N) * N);
    
    // Calculate Bitangent
    vec3 B = cross(N, T) * inTangent.w;
    
    fragTBN = mat3(T, B, N);
}
