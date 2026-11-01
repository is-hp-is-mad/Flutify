#version 460 core
#include <flutter/runtime_effect.glsl>
// HyperOS View.setMiShadow: libhwui.so embedded SkSL (rom/design/hwui_sksl/076_3204.sksl), liteShadow off.
// Interface changes only. All lengths are in the canvas's local units.
uniform vec2 rectCenterLoc;
uniform vec4 shadowColor;
uniform vec2 shadowOffset;
uniform float shadowRadius;
uniform float cornerRadius;
uniform float shadowDispersion;
uniform vec2 halfRectSize;
uniform float viewAlpha;

out vec4 fragColor;

float getGaussWeight(float currentPos) {
    return exp(-(currentPos * currentPos) * 2.0);
}

float mapNormalized(float value, float min1, float max1) {
    return (value - min1) / (max1 - min1);
}

vec4 shadow(vec2 xy, float radius, float viewCornerRadius) {
    float blurRadius = radius * 2.8;
    vec2 coord = abs(xy - rectCenterLoc);
    vec2 cornerCoord = halfRectSize - viewCornerRadius;

    float moreThanCorner = max(0.0, blurRadius - viewCornerRadius);
    vec2 shadowCornerCoord = cornerCoord - moreThanCorner / sqrt(2.0);

    float overSize = max(0.0, max(-shadowCornerCoord.x, -shadowCornerCoord.y));
    shadowCornerCoord += overSize;

    coord = max(coord, shadowCornerCoord);

    float dist = length(coord - shadowCornerCoord) + overSize * sqrt(2.0);
    float startRadius = viewCornerRadius - (blurRadius - moreThanCorner);

    float progress = mapNormalized(dist, startRadius, startRadius + 2.0 * blurRadius);
    progress = max(progress, 0.0);
    progress = getGaussWeight(progress);

    return vec4(shadowColor.rgb, shadowColor.a * progress);
}

float blurMap(vec2 xy) {
    return length((xy - rectCenterLoc) / halfRectSize);
}

float random(vec2 st) {
    return fract(sin(dot(st.xy, vec2(12.9898, 78.233))) * 43758.5453);
}

void main() {
    vec2 xy = FlutterFragCoord().xy;
    float halfMinSize = min(halfRectSize.x, halfRectSize.y);
    float viewCornerRadius = min(cornerRadius, halfMinSize);

    float dispersion = min(1.0, (halfMinSize / shadowRadius) * 0.5) * shadowDispersion;

    float blurRatio = blurMap(xy);
    blurRatio = max(1.0, 1.0 + (blurRatio - 1.0) * dispersion);

    vec2 texCoord = xy - shadowOffset;
    float radius = shadowRadius * 0.5 * blurRatio;

    vec4 col = shadow(texCoord, radius, viewCornerRadius);
    col.a = smoothstep(0.1, 1.0, col.a);
    col.rgb *= col.a;
    col.a *= viewAlpha;
    col.a += col.a != 0.0 ? (smoothstep(0.0, 0.005, col.a) * (random(xy) - 0.5) * 0.0175) : 0.0;
    fragColor = vec4(col.rgb * viewAlpha, col.a);
}
