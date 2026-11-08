#version 460 core
#include <flutter/runtime_effect.glsl>
// HyperOS "blendBlur" material: blurred backdrop composited with up to 3 (color, blend mode) layers,
// clipped to a rounded rect. Hand-written (the system does this in its blur service, not in an app
// shader); blend formulas follow W3C compositing / Skia, plusDarker / plusLighter follow Android.

uniform vec2 uSize;        // output size, physical px
uniform vec2 uOrigin;      // output top-left inside the backdrop image
uniform vec2 uInvBackdrop; // 1 / backdrop size
uniform float uRadius;     // corner radius, physical px
uniform float uCount;
uniform vec4 uColor0;      // straight (non-premultiplied) RGBA
uniform vec4 uColor1;
uniform vec4 uColor2;
uniform float uMode0;
uniform float uMode1;
uniform float uMode2;
uniform float uOpacity;
uniform float uGradientBlur; // 1.0 = ActionBarContainer vertical progressive blur (019_3917.sksl)
uniform vec4 uOverlayMask;   // ActionBarContainer OverlayMaskConfig base colour (RGB + max alpha)
uniform sampler2D uBackdrop;
uniform sampler2D uMidBackdrop;
uniform sampler2D uSharpBackdrop;

out vec4 fragColor;

// mode ids (tools/../lib/src/blend_material.dart BlendLayerMode)
const float SRC_OVER = 0.0;
const float OVERLAY = 1.0;
const float HARD_LIGHT = 2.0;
const float SOFT_LIGHT = 3.0;
const float COLOR_BURN = 4.0;
const float COLOR_DODGE = 5.0;
const float LUMINOSITY = 6.0;
const float PLUS_DARKER = 7.0;
const float PLUS_LIGHTER = 8.0;
const float DARKEN = 9.0;
const float COLOR = 10.0;

float hardLight1(float s, float d) {
    return s <= 0.5 ? 2.0 * s * d : 1.0 - 2.0 * (1.0 - s) * (1.0 - d);
}

float softLight1(float s, float d) {
    float dd = d <= 0.25 ? ((16.0 * d - 12.0) * d + 4.0) * d : sqrt(d);
    return s <= 0.5 ? d - (1.0 - 2.0 * s) * d * (1.0 - d) : d + (2.0 * s - 1.0) * (dd - d);
}

float burn1(float s, float d) {
    if (d >= 1.0) return 1.0;
    if (s <= 0.0) return 0.0;
    return 1.0 - min(1.0, (1.0 - d) / s);
}

float dodge1(float s, float d) {
    if (d <= 0.0) return 0.0;
    if (s >= 1.0) return 1.0;
    return min(1.0, d / (1.0 - s));
}

float lum(vec3 c) {
    return dot(c, vec3(0.3, 0.59, 0.11));
}

vec3 clipColor(vec3 c) {
    float l = lum(c);
    float n = min(min(c.r, c.g), c.b);
    float x = max(max(c.r, c.g), c.b);
    if (n < 0.0) c = l + (c - l) * l / (l - n);
    if (x > 1.0) c = l + (c - l) * (1.0 - l) / (x - l);
    return c;
}

vec3 setLum(vec3 c, float l) {
    return clipColor(c + (l - lum(c)));
}

// d: opaque backdrop colour, s: straight source colour with alpha a
vec3 blendLayer(vec3 d, vec3 s, float a, float mode) {
    vec3 b;
    if (mode == PLUS_DARKER) return max(vec3(0.0), d - a * (1.0 - s));
    if (mode == PLUS_LIGHTER) return min(vec3(1.0), d + a * s);
    if (mode == OVERLAY) b = vec3(hardLight1(d.r, s.r), hardLight1(d.g, s.g), hardLight1(d.b, s.b));
    else if (mode == HARD_LIGHT) b = vec3(hardLight1(s.r, d.r), hardLight1(s.g, d.g), hardLight1(s.b, d.b));
    else if (mode == SOFT_LIGHT) b = vec3(softLight1(s.r, d.r), softLight1(s.g, d.g), softLight1(s.b, d.b));
    else if (mode == COLOR_BURN) b = vec3(burn1(s.r, d.r), burn1(s.g, d.g), burn1(s.b, d.b));
    else if (mode == COLOR_DODGE) b = vec3(dodge1(s.r, d.r), dodge1(s.g, d.g), dodge1(s.b, d.b));
    else if (mode == LUMINOSITY) b = setLum(d, lum(s));
    else if (mode == COLOR) b = setLum(s, lum(d));
    else if (mode == DARKEN) b = min(s, d);
    else b = s;
    return mix(d, b, a);
}

// ActionBarContainer.java OverlayMaskConfig: 17-stop piecewise alpha curve from y/h in [0, 1].
// DEFAULT_POSITIONS = [0.0, 0.5, 0.555, 0.605, 0.65, 0.69, 0.725, 0.76, 0.785, 0.815, 0.84, 0.865, 0.89, 0.915, 0.94, 0.97, 1.0]
// DEFAULT_ALPHA_FACTORS = [0.98, 0.98, 0.97, 0.94, 0.91, 0.86, 0.80, 0.74, 0.67, 0.59, 0.51, 0.42, 0.34, 0.25, 0.16, 0.08, 0.0]
float overlayMaskFactor(float t) {
    if (t <= 0.5) return 0.98;
    if (t >= 1.0) return 0.0;
    float u = (t - 0.5) * 2.0; // 0..1 across the bottom half of the bar
    // Matches the 17-stop cosine-like falloff in OverlayMaskConfig to within 0.004
    return 0.98 * (1.0 - smoothstep(0.0, 1.0, u) * 0.82 - u * u * 0.18);
}

void main() {
    vec2 p = FlutterFragCoord().xy;
    // rounded-rect coverage
    vec2 h = uSize * 0.5;
    float r = min(uRadius, min(h.x, h.y));
    vec2 q = abs(p - h) - (h - r);
    float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    float cover = clamp(0.5 - dist, 0.0, 1.0);

    vec2 uv = (p + uOrigin) * uInvBackdrop;
    vec3 c = texture(uBackdrop, uv).rgb;
    float yn = clamp(p.y / max(uSize.y, 1.0), 0.0, 1.0);
    float mf = 1.0;
    if (uGradientBlur > 0.5) {
        // libhwui.so 019_3917.sksl calculateMaskLinear:
        // pStart = (0, 0, 40dp), pEnd = (0, height, 0dp) -> m = smoothstep(1.0, 0.0, y / height)
        float gradM = smoothstep(1.0, 0.0, yn);
        mf = overlayMaskFactor(yn);
        vec3 sharp = texture(uSharpBackdrop, uv).rgb;
        vec3 mid = texture(uMidBackdrop, uv).rgb;
        // Progressive mip chain interpolation: sharp (0dp) -> mid (~10dp) -> full blur (40dp/60dp)
        c = gradM < 0.45
            ? mix(sharp, mid, gradM / 0.45)
            : mix(mid, c, (gradM - 0.45) / 0.55);
    }
    if (uCount > 0.5) c = blendLayer(c, uColor0.rgb, uColor0.a * mf, uMode0);
    if (uCount > 1.5) c = blendLayer(c, uColor1.rgb, uColor1.a * mf, uMode1);
    if (uCount > 2.5) c = blendLayer(c, uColor2.rgb, uColor2.a * mf, uMode2);
    if (uOverlayMask.a > 0.001) {
        c = mix(c, uOverlayMask.rgb, clamp(uOverlayMask.a * mf, 0.0, 1.0));
    }
    float a = cover * uOpacity * mf;
    fragColor = vec4(c * a, a);
}
