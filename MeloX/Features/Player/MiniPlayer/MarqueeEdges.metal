#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 marqueeEdges(float2 position, SwiftUI::Layer layer, float4 bounds,
                                    float leadingStrength, float rightToLeft) {
    float width = bounds.z;
    float edgeWidth = min(14.0f, width * 0.25f);
    half4 center = layer.sample(position);
    if (edgeWidth <= 0) return center;

    float x = position.x - bounds.x;
    float leading = rightToLeft > 0 ? width - x : x;
    float trailing = width - leading;
    float strength = max(leadingStrength * (1 - smoothstep(0.0f, edgeWidth, leading)),
                         1 - smoothstep(0.0f, edgeWidth, trailing));
    if (strength <= 0) return center;

    // A small tent kernel widens as the glyph approaches the viewport edge.
    float radius = 2 * strength;
    half4 sum = center * 4.0h;
    for (int y = -1; y <= 1; ++y) {
        for (int xOffset = -1; xOffset <= 1; ++xOffset) {
            if (xOffset == 0 && y == 0) continue;
            half weight = xOffset == 0 || y == 0 ? 2.0h : 1.0h;
            sum += weight * layer.sample(position + float2(xOffset, y) * radius);
        }
    }
    return (sum / 16.0h) * half(1 - strength);
}
