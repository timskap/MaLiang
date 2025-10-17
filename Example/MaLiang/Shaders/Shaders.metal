#include <metal_stdlib>
using namespace metal;

// Define the vertex output structure
struct VertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
};

// Halftone shader parameters
struct HalftoneParams {
    float dotSize;      // Size of halftone dots (4.0-20.0)
    float smoothing;    // Edge smoothing factor (default 12.0)
    int blendMode;      // Blend mode (0-7)
};

// Vertex shader for simple texture rendering
vertex VertexOut halftone_vertex(
    uint vertexID [[vertex_id]],
    constant float2 *positions [[buffer(0)]],
    constant float2 *texCoords [[buffer(1)]]
) {
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.textureCoordinate = texCoords[vertexID];
    return out;
}

// Greyscale weights for luminance calculation
constant float3 GREY_WEIGHTS = float3(0.299, 0.587, 0.114);

// Overlay blend mode
float overlayChannel(float a, float b) {
    if (a < 0.5) {
        return 2.0 * a * b;
    }
    return 1.0 - 2.0 * (1.0 - a) * (1.0 - b);
}

float3 overlay(float3 a, float3 b) {
    float red = overlayChannel(a.r, b.r);
    float green = overlayChannel(a.g, b.g);
    float blue = overlayChannel(a.b, b.b);
    return float3(red, green, blue);
}

// Screen blend mode
float3 screenBlend(float3 a, float3 b) {
    return 1.0 - (1.0 - a) * (1.0 - b);
}

// Circle distance field
float circleDistance(float2 pos, float radius) {
    return length(pos) - radius;
}

// Fragment shader for halftone effect
fragment float4 halftone_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> texture [[texture(0)]],
    constant HalftoneParams &params [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Get texture size
    float2 resolution = float2(texture.get_width(), texture.get_height());
    
    // Convert normalized texture coordinate to pixel coordinate
    float2 fragCoord = in.textureCoordinate * resolution;
    
    // Calculate aspect ratio corrected width
    float w = 1.0 / min(resolution.x, resolution.y);
    
    // Aspect ratio corrected UV coordinates
    float2 uv = fragCoord * w;
    
    // Position and number of circles based on dot size
    float total = min(resolution.x, resolution.y) / params.dotSize;
    float2 pos = fract(uv * total);
    pos -= 0.5;
    
    // Sample current pixel color
    float4 pixel = texture.sample(textureSampler, in.textureCoordinate);
    
    // Convert to greyscale
    float greyValue = dot(pixel.rgb, GREY_WEIGHTS);
    
    // Get the distance to the circle center
    float radius = 1.0 - greyValue;
    float c = circleDistance(pos, radius);
    
    // Apply smoothing with anti-aliasing
    float s = params.smoothing * w;
    c = 1.0 - smoothstep(s, -s, c);
    
    // Output color based on blend mode
    float3 result;

            // Black and white multiply
            result = float3(greyValue * c);

    
   
    
    
    // Preserve original alpha
    return float4(result, pixel.a);
}
