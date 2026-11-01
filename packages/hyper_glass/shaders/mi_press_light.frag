#version 460 core
#include <flutter/runtime_effect.glsl>
// HyperOS glass press light: libhwui.so embedded SkSL (renderGlassShape). The body is the original;
// uView/uRadius add the rounded-rect mask the system gets from clipping the glass layer.
uniform vec3 uView; // w, h, corner radius (local px)
uniform vec4 iColor;
uniform vec2 iCenterPx;
uniform vec2 iGeoPxSize;
uniform float uPressLightCenterFall;
uniform float uPressLightCenterStrength;
uniform float uPressLightCenterPeak;
uniform vec2 uPressRingStrength;
uniform float uOpacity;

out vec4 fragColor;

// The glass's own outline (mi_glass_sdf.frag): G2 corner reaching 1.52866 r, plain circle for capsules.
float glassBoxSDF(vec2 xy, vec2 size, float radius) {
    if (min(size.x, size.y) - radius <= 1.0) {
        vec2 d = xy - size + radius;
        return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - radius;
    }
    float k = 1.52866494655609130859375 * radius;
    vec2 q = xy - size + k;
    vec2 v = max(vec2(0.0), q / k);
    float m = max(v.x, v.y);
    float t = m == 0.0 ? 0.0 : clamp(min(v.x, v.y) / m, 0.0, 1.0);
    float l = length(v);
    float p = (((((-0.739119708538055419921875 * t) + 2.4034926891326904296875) * t) - 2.4907319545745849609375) * t + 0.47687089443206787109375) * t + 0.4747847616672515869140625;
    float e = (l + 1.0) - 1.0 / (1.0 - t * t * clamp(l, 0.0, 1.0) * p);
    return min(max(q.x, q.y), 0.0) + k * (e - 1.0);
}

float circle(vec2 p, float r) {
    return length(p) - r;
}

vec4 renderGlassShape(vec2 uvPx, vec2 centerPx, vec2 sizePx) {
    vec2 halfSizePx = sizePx * 0.5;
    vec2 posFromCenter = uvPx - centerPx;
    float circleRadius = (halfSizePx.x + halfSizePx.y) * 0.5;
    float sdf = circle(posFromCenter, circleRadius);
    float finalAlpha = 0.0;
    float t = 1.0 + sdf / circleRadius;

    float lit = exp(-t * t * uPressLightCenterFall);
    finalAlpha += lit * uPressLightCenterStrength;

    // pow() of a negative base is undefined; the original's max(..., 0.0) wants this
    float b = max(0.5 - t * uPressLightCenterFall * 1.3 * 0.5, 0.0);
    lit = 1.0 - b * b * b;
    finalAlpha += lit * uPressLightCenterPeak;

    lit = 1.0 - smoothstep(0.0, 1.0, abs((t - 0.73) * 2.0));
    finalAlpha += lit * uPressRingStrength.x;
    lit = 1.0 - smoothstep(0.0, 1.0, abs((t - 0.49) * 5.0));
    finalAlpha += lit * uPressRingStrength.y;

    // artistic mapping
    finalAlpha = finalAlpha * finalAlpha;
    finalAlpha = clamp(finalAlpha, 0.0, 1.0);
    finalAlpha *= max(1.0 - pow(max(t, 0.0), 8.0), 0.0);

    vec4 finalColor = iColor;
    finalColor.a *= finalAlpha;
    return finalColor;
}

void main() {
    vec2 uvPx = FlutterFragCoord().xy;
    vec4 color = clamp(renderGlassShape(uvPx, iCenterPx, iGeoPxSize), 0.0, 1.0);
    vec2 h = uView.xy * 0.5;
    float mask = clamp(0.5 - glassBoxSDF(abs(uvPx - h), h, uView.z), 0.0, 1.0);
    float a = color.a * mask * uOpacity;
    fragColor = vec4(color.rgb * a, a);
}
