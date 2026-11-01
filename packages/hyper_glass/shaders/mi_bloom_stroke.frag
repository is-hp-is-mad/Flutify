#version 460 core
#include <flutter/runtime_effect.glsl>
// HyperOS bloom stroke: libhwui.so MiBloomStrokeFilter SkSL (main / getNormal / roundedBoxSDF), round
// corner branch. The system adds it to its own opaque blurred backdrop (blend() below keeps dst.rgb and
// only adds), so the shader outputs the added light and is drawn with BlendMode.plus. Stroke and clip
// follow the glass's outline; the normal keeps the original's round-box distance.
uniform vec2 uHalfView;
uniform float uRadius;
uniform float uStrokeWidth;
uniform vec4 uStrokeColor;
uniform float uInnerBlurRadius;
uniform vec3 uLightDir1;
uniform vec3 uLightDir2;
uniform vec4 uLightColor1;
uniform vec4 uLightColor2;
uniform float uOpacity;
uniform float uStrokeFade;

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

float roundedBoxSDF(vec2 pos, vec2 size, float radius) {
    radius = min(radius, min(size.x, size.y));
    vec2 d = abs(pos) - size + radius;
    return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - radius;
}

vec3 getNormal(vec2 fragcoord, float sdf, float R) {
    vec2 xy = fragcoord - floor(uHalfView);
    vec2 xy_a = abs(xy);
    sdf = smoothstep(-uInnerBlurRadius, 0.0, sdf);
    float z = sqrt(max(uInnerBlurRadius * uInnerBlurRadius - sdf * sdf, 0.0));
    vec3 coord = vec3(xy_a, -z);

    vec2 corner = uHalfView - R;
    corner.x = min(corner.x, xy_a.x);
    corner.y = min(corner.y, xy_a.y);

    vec2 diff = coord.xy - corner.xy;
    float len = length(diff);
    vec2 dir = len > 0.0 ? diff / len : vec2(0.0);
    corner += dir * (R - uInnerBlurRadius);

    if (xy_a.x < corner.x || xy_a.y < corner.y) {
        return vec3(0.0, 0.0, -1.0);
    }

    vec2 signal = vec2(xy.x < 0.0 ? -1.0 : 1.0, xy.y < 0.0 ? -1.0 : 1.0);
    vec3 n = normalize(coord - vec3(corner, 0.0));
    n.xy *= signal;
    return n;
}

void main() {
    vec2 fragcoord = FlutterFragCoord().xy;
    float R = max(uRadius, uInnerBlurRadius);
    vec2 xy = abs(fragcoord - uHalfView);
    vec2 centerRect = uHalfView - R * 1.6;
    if (xy.x < centerRect.x && xy.y < centerRect.y) {
        fragColor = vec4(0.0);
        return;
    }
    float glass = glassBoxSDF(xy, uHalfView, uRadius);
    float outMask = smoothstep(0.0, -1.0, glass);
    float strokeAlpha = smoothstep(-uStrokeWidth, -uStrokeWidth + 1.0, glass);
    // half4 stroke = uStrokeColor * strokeAlpha; blend() multiplies by alpha once more
    float stroke = strokeAlpha * strokeAlpha;
    if (uStrokeFade > 0.5) {
        // getStroke(): color_stops 1, 0, 0, 1 at stops 0, 0.35, 0.68, 1 along the 180 degree gradient
        float y = fragcoord.y / (2.0 * uHalfView.y);
        stroke *= y < 0.35 ? 1.0 - y / 0.35 : (y > 0.68 ? (y - 0.68) / 0.32 : 0.0);
    }
    vec3 c = uStrokeColor.rgb * uStrokeColor.a * stroke;

    vec3 n = getNormal(fragcoord, roundedBoxSDF(xy, uHalfView, uRadius), R);
    float light1 = clamp(dot(n, uLightDir1) * dot(vec3(0.0, -1.0, 0.0), n), 0.0, 1.0);
    c += uLightColor1.rgb * uLightColor1.a * light1 * light1;
    float light2 = clamp(dot(n, uLightDir2) * dot(vec3(0.0, 1.0, 0.0), n), 0.0, 1.0);
    c += uLightColor2.rgb * uLightColor2.a * light2 * light2;

    fragColor = vec4(clamp(c, 0.0, 1.0) * outMask * uOpacity, 0.0);
}
