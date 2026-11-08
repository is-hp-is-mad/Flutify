package com.hyperos.glass.shader

import android.annotation.TargetApi
import android.graphics.BitmapShader
import android.graphics.RenderEffect
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.os.Build
import com.hyperos.glass.token.BloomStrokeConfig
import com.hyperos.glass.token.ColorBlendConfig
import com.hyperos.glass.token.GlassToken
import com.hyperos.glass.util.LMGaussianKernel
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Decoupled Android 13+ (API 33) Standard AGSL (`android.graphics.RuntimeShader`) Shaders.
 *
 * Directly adapts Xiaomi's private `libhwui.so` SkSL shaders into standard Android AGSL:
 * - `mi_glass_sdf` (`040_5769.sksl`): G2 supercircle SDF + bevel normal map
 * - `mi_glass_tint` (`060_3119.sksl`): Dual-blur luminance Bézier + inner tint + burn
 * - `mi_glass_v13_f16` (`012_1417.sksl` + `013_8558.sksl`): Lens refraction, reflection, dual rim lighting, bottom glow
 * - `mi_blend_blur` (`072_15086.sksl` + `080_14850.sksl`): Multi-layer color blend + progressive gradient blur
 * - `mi_bloom_stroke` (`029_7597.sksl`): Superellipse rim stroke + dual normal diffuse bloom
 * - `mi_press_light` (`007_2414.sksl`): Interactive touch press light
 * - `mi_view_shadow` (`076_3204.sksl`): Dispersive soft shadow
 */
@TargetApi(Build.VERSION_CODES.TIRAMISU)
object HyperAgslShaders {

    /**
     * 1. `mi_glass_sdf` (`040_5769.sksl`):
     * Evaluates G2 supercircle (`1.5286649465560913`) or rounded-rect SDF and outputs:
     * - `.xy`: 2D surface normal encoded in `[0, 1]`
     * - `.z`: corner mask `[0, 1]`
     * - `.w`: normalized distance from edge `-d / rectEdge`
     */
    const val MI_GLASS_SDF_AGSL: String = """
        uniform vec2 uResolution;
        uniform float uRadius;
        uniform float uRectEdge;
        uniform int uUseSmoothCorner;

        const float SUPERCIRCLE_K = 1.5286649465560913;
        const float INV_K = 0.6541655897086058;

        float supercircleSdf(vec2 p, float r) {
            vec2 q = abs(p) / max(r, 1e-4);
            float d = pow(pow(max(q.x, 0.0), SUPERCIRCLE_K) + pow(max(q.y, 0.0), SUPERCIRCLE_K), INV_K);
            return (d - 1.0) * r;
        }

        float sdfRectOffset(vec2 uv, vec2 halfSize, float radius, out float cornerMask) {
            vec2 centerToUv = abs(uv - halfSize);
            vec2 q = centerToUv - (halfSize - vec2(radius));
            float rawD = min(max(q.x, q.y), 0.0) - radius;
            cornerMask = 1.0 - smoothstep(0.0, -1.0, rawD);
            if (q.x > 0.0 && q.y > 0.0) {
                if (uUseSmoothCorner == 1 && radius >= 1.0) {
                    return supercircleSdf(q, radius);
                } else {
                    return length(q) - radius;
                }
            }
            return max(q.x, q.y) - radius;
        }

        float smooth5Vertical(float x, float d) {
            float invD = 1.0 / max(d, 1e-4);
            float t = clamp(x * invD + 1.0, 0.0, 1.0);
            float t2 = t * t;
            return ((t * (t * 6.0 - 15.0) + 10.0) * t2 * t - 1.0) * d;
        }

        vec4 main(vec2 fragCoord) {
            vec2 halfSize = uResolution * 0.5;
            float maxRadius = min(halfSize.x, halfSize.y);
            float radius = min(uRadius, maxRadius);
            float cornerMask = 0.0;
            float d = sdfRectOffset(fragCoord, halfSize, radius, cornerMask);
            float rectEdge = max(min(uRectEdge, maxRadius), 1.0);
            float eps = 1.5;
            float dummy = 0.0;
            float dx = sdfRectOffset(fragCoord + vec2(eps, 0.0), halfSize, radius, dummy)
                     - sdfRectOffset(fragCoord - vec2(eps, 0.0), halfSize, radius, dummy);
            float dy = sdfRectOffset(fragCoord + vec2(0.0, eps), halfSize, radius, dummy)
                     - sdfRectOffset(fragCoord - vec2(0.0, eps), halfSize, radius, dummy);
            float curved = smooth5Vertical(d, rectEdge);
            float dz = sqrt(max(rectEdge * rectEdge - curved * curved, 0.0));
            vec3 n = normalize(vec3(dx, dy, dz) + vec3(0.0, 0.0, 1e-5));
            float normDist = clamp(-d / rectEdge, 0.0, 1.0);
            return vec4(n.xy * 0.5 + 0.5, cornerMask, normDist);
        }
    """

    /**
     * 2. `mi_glass_tint` (`060_3119.sksl`):
     * Pre-processes small blur (`child`) and big blur (`uBigBlur`) with cubic Bézier luminance curve,
     * darker range, background saturation/brightness, burn, inner white highlight, and glass color mix.
     */
    const val MI_GLASS_TINT_AGSL: String = """
        uniform shader child;
        uniform shader uBigBlur;
        uniform vec4 uLuminanceCurve;
        uniform float uLuminanceAmount;
        uniform float uSaturation;
        uniform float uBrightness;
        uniform float uDarker;
        uniform vec2 uDarkerRange;
        uniform vec4 uGlassColor;
        uniform float uInnerColorWhite;
        uniform float uInnerColorMix;
        uniform float uBgColorSaturation;
        uniform float uBgColorBrightness;
        uniform float uBurn;

        const vec3 LUMA_WEIGHTS = vec3(0.299, 0.587, 0.114);

        vec3 adjustColor(vec3 color, float saturation, float brightness) {
            float luma = dot(color, LUMA_WEIGHTS);
            return clamp(mix(vec3(luma), color, saturation) + brightness, 0.0, 1.0);
        }

        vec3 applyLuminanceCurve(vec3 color, vec4 curve, float amount) {
            if (abs(amount) <= 0.001) return color;
            vec3 c = clamp(color, 0.0, 1.0);
            vec3 poly = ((curve.x * c + curve.y) * c + curve.z) * c + curve.w;
            return mix(color, poly, amount);
        }

        vec3 processGlassColor(vec3 smallColor, vec3 bigColor) {
            vec3 bgAdjusted = clamp(adjustColor(bigColor, uBgColorSaturation, uBgColorBrightness), 0.0, 1.0);
            vec3 burned = 1.0 - (1.0 - smallColor) / max(bgAdjusted, vec3(0.001));
            burned = mix(smallColor, burned, clamp(uBurn, 0.0, 1.0));
            vec3 lightened = min(vec3(1.0), bgAdjusted + uInnerColorWhite);
            vec3 mixed = mix(burned, lightened, uInnerColorMix);
            return mix(mixed, uGlassColor.rgb, uGlassColor.a);
        }

        vec4 main(vec2 fragCoord) {
            vec4 rawSmall = child.eval(fragCoord);
            vec4 rawBig = uBigBlur.eval(fragCoord);
            float invAS = rawSmall.a > 1e-4 ? 1.0 / rawSmall.a : 0.0;
            float invAB = rawBig.a > 1e-4 ? 1.0 / rawBig.a : 0.0;
            vec3 smallRgb = rawSmall.rgb * invAS;
            vec3 bigRgb = rawBig.rgb * invAB;

            float luma = dot(smallRgb, LUMA_WEIGHTS);
            float darkerFactor = smoothstep(uDarkerRange.x, uDarkerRange.y, luma) * uDarker;
            smallRgb -= smallRgb * darkerFactor;
            smallRgb = applyLuminanceCurve(smallRgb, uLuminanceCurve, uLuminanceAmount);
            smallRgb = adjustColor(smallRgb, uSaturation, uBrightness);

            vec3 outRgb = clamp(processGlassColor(smallRgb, bigRgb), 0.0, 1.0);
            return vec4(outRgb, 1.0);
        }
    """

    /**
     * 3. `mi_glass_v13_f16` (`012_1417.sksl` + `013_8558.sksl` + `040_5769.sksl` + `060_3119.sksl`):
     * Complete Xiaomi HyperOS soft-light glass pipeline in a single AGSL `RuntimeShader`.
     *
     * Can be mounted directly as a `RenderEffect.createRuntimeShaderEffect(shader, "uSmallBlur")`
     * on a `View` / `RenderNode`, or drawn onto any `Canvas` using `BitmapShader` inputs!
     */
    const val MI_GLASS_V13_F16_FUSED_AGSL: String = """
        uniform shader uSmallBlur;
        uniform shader uBigBlur;

        uniform vec2 uResolution;
        uniform vec2 uBackdropOffset;
        uniform vec2 uBackdropSize;
        uniform vec2 uBackdropScale;

        uniform float uCornerRadius;
        uniform int uUseSmoothCorner;

        // Pre-tint & blend parameters (slots 0..18, 33..36)
        uniform vec4 uLuminanceCurve;
        uniform float uLuminanceAmount;
        uniform float uSaturation;
        uniform float uBrightness;
        uniform float uDarker;
        uniform vec2 uDarkerRange;
        uniform float uInnerBottom;
        uniform vec4 uGlassColor;
        uniform float uInnerColorWhite;
        uniform float uInnerColorMix;
        uniform float uColorPow;
        uniform float uAlpha;
        uniform float uBgColorSaturation;
        uniform float uBgColorBrightness;
        uniform float uBurn;
        uniform float uUnshade;

        // Shape, refraction, reflection, and directional light parameters (slots 19..32)
        uniform float uEdgePx;
        uniform float uEdgePow;
        uniform float uThicknessPx;
        uniform float uReflectOffsetPx;
        uniform float uReflectionLighten;
        uniform float uReflectionStrength;
        uniform vec3 uLightDirection;
        uniform float uLightIntensity;
        uniform float uLightOpposite;
        uniform float uLightAngleRange;
        uniform float uLightEdgePow;
        uniform float uRefractIOR;

        // Optional interactive touch press light & hit state
        uniform float uHit;
        uniform vec2 uTouchPos;
        uniform float uPressAlpha;

        const vec3 LUMA_WEIGHTS = vec3(0.299, 0.587, 0.114);
        const float SUPERCIRCLE_K = 1.5286649465560913;
        const float INV_K = 0.6541655897086058;

        float supercircleSdf(vec2 p, float r) {
            vec2 q = abs(p) / max(r, 1e-4);
            float d = pow(pow(max(q.x, 0.0), SUPERCIRCLE_K) + pow(max(q.y, 0.0), SUPERCIRCLE_K), INV_K);
            return (d - 1.0) * r;
        }

        float evalShapeSdf(vec2 uv, vec2 halfSize, float radius, out float cornerMask) {
            vec2 centerToUv = abs(uv - halfSize);
            vec2 q = centerToUv - (halfSize - vec2(radius));
            float rawD = min(max(q.x, q.y), 0.0) - radius;
            cornerMask = 1.0 - smoothstep(0.0, -1.0, rawD);
            if (q.x > 0.0 && q.y > 0.0) {
                if (uUseSmoothCorner == 1 && radius >= 1.0) {
                    return supercircleSdf(q, radius);
                } else {
                    return length(q) - radius;
                }
            }
            return max(q.x, q.y) - radius;
        }

        float smooth5Vertical(float x, float d) {
            float invD = 1.0 / max(d, 1e-4);
            float t = clamp(x * invD + 1.0, 0.0, 1.0);
            float t2 = t * t;
            return ((t * (t * 6.0 - 15.0) + 10.0) * t2 * t - 1.0) * d;
        }

        vec3 adjustColor(vec3 color, float saturation, float brightness) {
            float luma = dot(color, LUMA_WEIGHTS);
            return clamp(mix(vec3(luma), color, saturation) + brightness, 0.0, 1.0);
        }

        vec3 applyLuminanceCurve(vec3 color, vec4 curve, float amount) {
            if (abs(amount) <= 0.001) return color;
            vec3 c = clamp(color, 0.0, 1.0);
            vec3 poly = ((curve.x * c + curve.y) * c + curve.z) * c + curve.w;
            return mix(color, poly, amount);
        }

        vec3 sampleTintedGlass(vec2 localCoord) {
            vec2 backdropCoord = (localCoord + uBackdropOffset) * uBackdropScale;
            backdropCoord = clamp(backdropCoord, vec2(0.5), max(uBackdropSize - vec2(0.5), vec2(0.5)));

            vec4 rawSmall = uSmallBlur.eval(backdropCoord);
            vec4 rawBig = uBigBlur.eval(backdropCoord);
            float invAS = rawSmall.a > 1e-4 ? 1.0 / rawSmall.a : 0.0;
            float invAB = rawBig.a > 1e-4 ? 1.0 / rawBig.a : 0.0;
            vec3 smallRgb = rawSmall.rgb * invAS;
            vec3 bigRgb = rawBig.rgb * invAB;

            float luma = dot(smallRgb, LUMA_WEIGHTS);
            float darkerFactor = smoothstep(uDarkerRange.x, uDarkerRange.y, luma) * uDarker;
            smallRgb -= smallRgb * darkerFactor;
            smallRgb = applyLuminanceCurve(smallRgb, uLuminanceCurve, uLuminanceAmount);
            smallRgb = adjustColor(smallRgb, uSaturation, uBrightness);

            vec3 bgAdjusted = clamp(adjustColor(bigRgb, uBgColorSaturation, uBgColorBrightness), 0.0, 1.0);
            vec3 burned = 1.0 - (1.0 - smallRgb) / max(bgAdjusted, vec3(0.001));
            burned = mix(smallRgb, burned, clamp(uBurn, 0.0, 1.0));
            vec3 lightened = min(vec3(1.0), bgAdjusted + uInnerColorWhite);
            vec3 mixed = mix(burned, lightened, uInnerColorMix);
            return clamp(mix(mixed, uGlassColor.rgb, uGlassColor.a), 0.0, 1.0);
        }

        vec3 hsvv(vec3 y) {
            float maxc = max(max(y.r, y.g), y.b);
            if (maxc > 1.0) {
                float minc = min(min(y.r, y.g), y.b);
                if (minc >= 1.0) return vec3(1.0);
                float invSpan = 1.0 / max(maxc - minc, 1e-4);
                float excess = maxc - 1.0;
                y -= (maxc - y) * invSpan * excess;
                y -= vec3(maxc - 1.0);
            }
            return clamp(y, 0.0, 1.0);
        }

        vec3 addLight(vec3 base, vec3 blend, float intensity) {
            return hsvv(base + blend * intensity);
        }

        vec3 processLighting(
            vec3 color,
            vec3 normal,
            vec3 lightDirection,
            float lightIntensity,
            float oppositeIntensity,
            float lightAngleRange,
            float lightEdgePow,
            float cornerMask,
            float normalizeSdf
        ) {
            vec2 dir2d = normalize(lightDirection.xy + vec2(1e-5, 0.0));
            vec2 n2d = normalize(normal.xy + vec2(1e-5, 0.0));
            float ndotl = dot(n2d, dir2d);
            float dirFactor = clamp(abs(ndotl), 0.0, 1.0);
            float angleFactor = mix(
                dirFactor,
                smoothstep(max(1.0 - lightAngleRange, 0.001), 1.0, dirFactor),
                cornerMask
            );
            float edgeFactor = pow(max(1.0 - normalizeSdf, 0.0), max(lightEdgePow, 0.01));
            float lightMask = angleFactor * edgeFactor;
            float sideIntensity = ndotl < 0.0 ? oppositeIntensity : lightIntensity;

            vec3 lightColor = mix(color, vec3(1.0), clamp(abs(lightDirection.z), 0.0, 1.0));
            return hsvv(color + lightColor * (lightMask * sideIntensity));
        }

        vec4 main(vec2 fragCoord) {
            vec2 halfSize = uResolution * 0.5;
            float maxRadius = min(halfSize.x, halfSize.y);
            float radius = min(uCornerRadius, maxRadius);

            float cornerMask = 0.0;
            float d = evalShapeSdf(fragCoord, halfSize, radius, cornerMask);
            float shapeMask = clamp(0.5 - d, 0.0, 1.0);
            if (shapeMask <= 0.001) {
                return vec4(0.0);
            }

            float rectEdge = max(min(uEdgePx, maxRadius), 1.0);
            float normalizeSdf = clamp(-d / rectEdge, 0.0, 1.0);

            // Compute 2D SDF gradient & 3D bevel normal
            float eps = 1.5;
            float dummy = 0.0;
            float dx = evalShapeSdf(fragCoord + vec2(eps, 0.0), halfSize, radius, dummy)
                     - evalShapeSdf(fragCoord - vec2(eps, 0.0), halfSize, radius, dummy);
            float dy = evalShapeSdf(fragCoord + vec2(0.0, eps), halfSize, radius, dummy)
                     - evalShapeSdf(fragCoord - vec2(0.0, eps), halfSize, radius, dummy);
            float curved = smooth5Vertical(d, rectEdge);
            float dz = sqrt(max(rectEdge * rectEdge - curved * curved, 0.0));
            vec3 sdfNormal = normalize(vec3(dx, dy, dz) + vec3(0.0, 0.0, 1e-5));

            float zRaw = pow(max(1.0 - normalizeSdf, 0.0), max(uEdgePow, 0.01));
            float zComp = sqrt(max(1.0 - zRaw * zRaw, 0.0));
            vec3 normal = vec3(sdfNormal.xy * zRaw, zComp);

            // 1. Lens Refraction (`uvToRefractLens`)
            float ior = max(uRefractIOR - uHit * 0.2, 1.01);
            vec3 refractVec = refract(vec3(0.0, 0.0, -1.0), normal, 1.0 / ior);
            float lensDepth = mix(
                (uThicknessPx - uEdgePx) * 2.0,
                uThicknessPx * 2.0,
                abs(refractVec.z)
            );
            vec2 refractOffset = refractVec.xy * lensDepth;
            vec3 refractColor = sampleTintedGlass(fragCoord + refractOffset);

            // 2. Edge Reflection (`calculateReflection`)
            vec2 reflectVec = 2.0 * normal.z * normal.xy;
            vec2 reflectOffset = reflectVec * (uReflectOffsetPx * (1.0 - normalizeSdf));
            vec3 reflectSample = sampleTintedGlass(fragCoord + reflectOffset);
            vec3 reflectColor = clamp(reflectSample + vec3(uReflectionLighten * 0.1), 0.0, 1.0);
            float reflectAmount = clamp(length(reflectVec) * uReflectionStrength, 0.0, 1.0);
            vec3 color = addLight(refractColor, reflectColor, reflectAmount);

            // 3. Bottom Inner Glow (`calculateInnerEdgeEffects`)
            float bottomGlow = clamp((fragCoord.y / max(uResolution.y, 1.0)) * uInnerBottom, 0.0, 1.0);
            color += (1.0 - color) * bottomGlow;

            // 4. Dual Directional Rim Lighting (`processLighting`)
            color = processLighting(
                color,
                normal,
                uLightDirection,
                uLightIntensity,
                uLightOpposite,
                uLightAngleRange,
                uLightEdgePow,
                cornerMask,
                normalizeSdf
            );

            // 5. Interactive Press Light (`007_2414.sksl`)
            if (uPressAlpha > 0.001) {
                float distToTouch = length(fragCoord - uTouchPos);
                float maxDim = max(uResolution.x, uResolution.y) * 0.85;
                float radialFalloff = 1.0 - smoothstep(0.0, maxDim, distToTouch);
                float rimBoost = pow(max(1.0 - normalizeSdf, 0.0), 1.5) * 0.6 + 0.4;
                color = clamp(color + vec3(radialFalloff * rimBoost * uPressAlpha * 0.28), 0.0, 1.0);
            }

            // 6. Gamma power (`uColorPow`) & Unshade (`uUnshade`)
            if (abs(uColorPow - 1.0) > 0.01) {
                color = pow(max(color, vec3(0.0)), vec3(uColorPow));
            }
            if (uUnshade > 0.001) {
                color = mix(color, uGlassColor.rgb, clamp(uUnshade, 0.0, 1.0));
            }

            float finalAlpha = clamp(uAlpha * shapeMask, 0.0, 1.0);
            return vec4(color * finalAlpha, finalAlpha);
        }
    """

    /**
     * 4. `mi_blend_blur` (`072_15086.sksl` + `080_14850.sksl`):
     * Multi-layer color blend over Gaussian-blurred backdrop with all Xiaomi HyperOS blend modes,
     * superellipse/rounded-rect AA clipping, and optional vertical gradient blur mask.
     */
    const val MI_BLEND_BLUR_AGSL: String = """
        uniform shader uBlurTex;
        uniform shader uSharpTex;

        uniform vec2 uResolution;
        uniform vec2 uBackdropOffset;
        uniform vec2 uBackdropSize;
        uniform vec2 uBackdropScale;
        uniform float uCornerRadius;
        uniform int uUseSmoothCorner;

        uniform int uLayerCount;
        uniform vec4 uLayerColor0;
        uniform vec4 uLayerColor1;
        uniform vec4 uLayerColor2;
        uniform vec4 uLayerColor3;
        uniform int uLayerMode0;
        uniform int uLayerMode1;
        uniform int uLayerMode2;
        uniform int uLayerMode3;

        // Progressive vertical gradient mask (`ActionBarContainer` / `mi_gradient_blur`)
        uniform int uGradientMode; // 0 = off, 1 = top-to-bottom fade, 2 = bottom-to-top fade
        uniform vec2 uGradientSpan;

        const vec3 LUMA_WEIGHTS = vec3(0.299, 0.587, 0.114);
        const float SUPERCIRCLE_K = 1.5286649465560913;
        const float INV_K = 0.6541655897086058;

        float supercircleSdf(vec2 p, float r) {
            vec2 q = abs(p) / max(r, 1e-4);
            float d = pow(pow(max(q.x, 0.0), SUPERCIRCLE_K) + pow(max(q.y, 0.0), SUPERCIRCLE_K), INV_K);
            return (d - 1.0) * r;
        }

        float evalShapeSdf(vec2 uv, vec2 halfSize, float radius) {
            vec2 centerToUv = abs(uv - halfSize);
            vec2 q = centerToUv - (halfSize - vec2(radius));
            if (q.x > 0.0 && q.y > 0.0) {
                if (uUseSmoothCorner == 1 && radius >= 1.0) {
                    return supercircleSdf(q, radius);
                } else {
                    return length(q) - radius;
                }
            }
            return max(q.x, q.y) - radius;
        }

        float blendOverlayChannel(float b, float s) {
            return b < 0.5 ? (2.0 * b * s) : (1.0 - 2.0 * (1.0 - b) * (1.0 - s));
        }

        vec3 blendOverlay(vec3 b, vec3 s) {
            return vec3(
                blendOverlayChannel(b.r, s.r),
                blendOverlayChannel(b.g, s.g),
                blendOverlayChannel(b.b, s.b)
            );
        }

        float blendSoftLightChannel(float b, float s) {
            if (s <= 0.5) {
                return b - (1.0 - 2.0 * s) * b * (1.0 - b);
            } else {
                float d = (b <= 0.25) ? (((16.0 * b - 12.0) * b + 4.0) * b) : sqrt(b);
                return b + (2.0 * s - 1.0) * (d - b);
            }
        }

        vec3 blendSoftLight(vec3 b, vec3 s) {
            return vec3(
                blendSoftLightChannel(b.r, s.r),
                blendSoftLightChannel(b.g, s.g),
                blendSoftLightChannel(b.b, s.b)
            );
        }

        vec3 clipColor(vec3 c) {
            float l = dot(c, LUMA_WEIGHTS);
            float n = min(min(c.r, c.g), c.b);
            float x = max(max(c.r, c.g), c.b);
            if (n < 0.0) {
                c = l + (c - l) * l / max(l - n, 1e-4);
            }
            if (x > 1.0) {
                c = l + (c - l) * (1.0 - l) / max(x - l, 1e-4);
            }
            return clamp(c, 0.0, 1.0);
        }

        vec3 setLum(vec3 c, float l) {
            return clipColor(c + (l - dot(c, LUMA_WEIGHTS)));
        }

        vec3 applyBlendLayer(vec3 dst, vec4 src, int mode) {
            float a = src.a;
            vec3 s = src.rgb;
            if (a <= 0.0001) return dst;

            // 120 = PLUS_DARKER, 111 = LINEAR_BURN
            if (mode == 120 || mode == 111) {
                return clamp(dst + (s - 1.0) * a, 0.0, 1.0);
            }
            // 121 = PLUS_LIGHTER, 12 = PLUS, 110 = LINEAR_DODGE
            if (mode == 121 || mode == 12 || mode == 110) {
                return clamp(dst + s * a, 0.0, 1.0);
            }
            // 100 = LINEAR_LIGHT, 101 = LINEAR_LIGHT_WITH_GREY
            if (mode == 100 || mode == 101) {
                vec3 res = clamp(dst + 2.0 * s - 1.0, 0.0, 1.0);
                return mix(dst, res, a);
            }

            vec3 blended = s;
            if (mode == 15) {
                // OVERLAY
                blended = blendOverlay(dst, s);
            } else if (mode == 20) {
                // HARD_LIGHT
                blended = blendOverlay(s, dst);
            } else if (mode == 21) {
                // SOFT_LIGHT
                blended = blendSoftLight(dst, s);
            } else if (mode == 19 || mode == 103) {
                // COLOR_BURN
                blended = 1.0 - min(vec3(1.0), (1.0 - dst) / max(s, vec3(1e-4)));
            } else if (mode == 18 || mode == 102) {
                // COLOR_DODGE
                blended = min(vec3(1.0), dst / max(1.0 - s, vec3(1e-4)));
            } else if (mode == 16 || mode == 107) {
                // DARKEN
                blended = min(dst, s);
            } else if (mode == 17 || mode == 108) {
                // LIGHTEN
                blended = max(dst, s);
            } else if (mode == 24 || mode == 13) {
                // MULTIPLY / MODULATE
                blended = dst * s;
            } else if (mode == 14) {
                // SCREEN
                blended = dst + s - dst * s;
            } else if (mode == 28 || mode == 106) {
                // LUMINOSITY / LAB
                blended = setLum(dst, dot(s, LUMA_WEIGHTS));
            } else if (mode == 27) {
                // COLOR
                blended = setLum(s, dot(dst, LUMA_WEIGHTS));
            }
            return clamp(mix(dst, blended, a), 0.0, 1.0);
        }

        vec4 main(vec2 fragCoord) {
            vec2 halfSize = uResolution * 0.5;
            float maxRadius = min(halfSize.x, halfSize.y);
            float radius = min(uCornerRadius, maxRadius);
            float d = evalShapeSdf(fragCoord, halfSize, radius);
            float shapeMask = clamp(0.5 - d, 0.0, 1.0);
            if (shapeMask <= 0.001) {
                return vec4(0.0);
            }

            vec2 backdropCoord = (fragCoord + uBackdropOffset) * uBackdropScale;
            backdropCoord = clamp(backdropCoord, vec2(0.5), max(uBackdropSize - vec2(0.5), vec2(0.5)));

            vec4 blurSample = uBlurTex.eval(backdropCoord);
            vec3 color = blurSample.a > 1e-4 ? (blurSample.rgb / blurSample.a) : blurSample.rgb;

            if (uLayerCount > 0) color = applyBlendLayer(color, uLayerColor0, uLayerMode0);
            if (uLayerCount > 1) color = applyBlendLayer(color, uLayerColor1, uLayerMode1);
            if (uLayerCount > 2) color = applyBlendLayer(color, uLayerColor2, uLayerMode2);
            if (uLayerCount > 3) color = applyBlendLayer(color, uLayerColor3, uLayerMode3);

            if (uGradientMode != 0) {
                float yNorm = clamp(fragCoord.y / max(uResolution.y, 1.0), 0.0, 1.0);
                float t = clamp((yNorm - uGradientSpan.x) / max(uGradientSpan.y - uGradientSpan.x, 1e-4), 0.0, 1.0);
                float w = (uGradientMode == 1) ? (1.0 - t) : t;
                w = w * w * (3.0 - 2.0 * w);
                vec4 sharpSample = uSharpTex.eval(backdropCoord);
                vec3 sharpRgb = sharpSample.a > 1e-4 ? (sharpSample.rgb / sharpSample.a) : sharpSample.rgb;
                color = mix(sharpRgb, color, w);
            }

            return vec4(color * shapeMask, shapeMask);
        }
    """

    /**
     * 5. `mi_bloom_stroke` (`029_7597.sksl`):
     * Superellipse/rounded-rect rim outline + 2 directional normal diffuse bloom lights.
     */
    const val MI_BLOOM_STROKE_AGSL: String = """
        uniform vec2 uResolution;
        uniform float uCornerRadius;
        uniform int uUseSmoothCorner;

        uniform float uStrokeWidth;
        uniform float uNormalWidth;
        uniform vec4 uSourceColor;
        uniform vec2 uTexelOffset;
        uniform vec2 uLightDir1;
        uniform vec4 uLightColor1;
        uniform vec3 uLightDir2;
        uniform vec4 uLightColor2;
        uniform int uGradientBorder;

        const float SUPERCIRCLE_K = 1.5286649465560913;
        const float INV_K = 0.6541655897086058;

        float supercircleSdf(vec2 p, float r) {
            vec2 q = abs(p) / max(r, 1e-4);
            float d = pow(pow(max(q.x, 0.0), SUPERCIRCLE_K) + pow(max(q.y, 0.0), SUPERCIRCLE_K), INV_K);
            return (d - 1.0) * r;
        }

        float evalShapeSdf(vec2 uv, vec2 halfSize, float radius) {
            vec2 centerToUv = abs(uv - halfSize);
            vec2 q = centerToUv - (halfSize - vec2(radius));
            if (q.x > 0.0 && q.y > 0.0) {
                if (uUseSmoothCorner == 1 && radius >= 1.0) {
                    return supercircleSdf(q, radius);
                } else {
                    return length(q) - radius;
                }
            }
            return max(q.x, q.y) - radius;
        }

        vec4 main(vec2 fragCoord) {
            vec2 halfSize = uResolution * 0.5;
            float maxRadius = min(halfSize.x, halfSize.y);
            float radius = min(uCornerRadius, maxRadius);
            float d = evalShapeSdf(fragCoord, halfSize, radius);

            float outerClip = clamp(0.5 - d, 0.0, 1.0);
            if (outerClip <= 0.001) return vec4(0.0);

            float innerLimit = max(uNormalWidth, uStrokeWidth) + 2.0;
            if (-d > innerLimit) return vec4(0.0);

            float eps = max(uTexelOffset.x, 1.0);
            float dx = evalShapeSdf(fragCoord + vec2(eps, 0.0), halfSize, radius)
                     - evalShapeSdf(fragCoord - vec2(eps, 0.0), halfSize, radius);
            float dy = evalShapeSdf(fragCoord + vec2(0.0, eps), halfSize, radius)
                     - evalShapeSdf(fragCoord - vec2(0.0, eps), halfSize, radius);
            vec2 n2d = normalize(vec2(dx, dy) + vec2(1e-5, 0.0));

            // Stroke rim mask (`uStrokeWidth`)
            float strokeAlpha = clamp(1.0 - max(-d - uStrokeWidth + 0.5, 0.0), 0.0, 1.0) * outerClip;

            // Inner bevel diffuse normal mask (`uNormalWidth`)
            float normalFalloff = clamp(1.0 - (-d / max(uNormalWidth, 1.0)), 0.0, 1.0);
            normalFalloff = normalFalloff * normalFalloff;

            // Light 1 directional lobe
            vec2 dir1 = normalize(vec2(-cos(uLightDir1.x), -sin(uLightDir1.x)));
            float l1 = max(dot(n2d, dir1), 0.0) * uLightColor1.a;

            // Light 2 directional lobe (with opposite intensity in uLightDir2.z)
            vec2 dir2 = normalize(vec2(-cos(uLightDir2.x), -sin(uLightDir2.x)));
            float ndotl2 = dot(n2d, dir2);
            float l2 = (ndotl2 >= 0.0 ? ndotl2 : (-ndotl2 * abs(uLightDir2.z))) * uLightColor2.a;

            vec3 baseStroke = uSourceColor.rgb * (uSourceColor.a * strokeAlpha);
            vec3 bloom1 = uLightColor1.rgb * (l1 * mix(strokeAlpha, normalFalloff, 0.35));
            vec3 bloom2 = uLightColor2.rgb * (l2 * mix(strokeAlpha, normalFalloff, 0.5));

            vec3 totalRgb = clamp(baseStroke + bloom1 + bloom2, 0.0, 1.0);
            float totalAlpha = clamp(
                max(uSourceColor.a * strokeAlpha, max(l1, l2) * max(strokeAlpha, normalFalloff * 0.5)),
                0.0,
                1.0
            ) * outerClip;

            if (uGradientBorder == 1) {
                float vFade = 1.0 - clamp(fragCoord.y / max(uResolution.y, 1.0), 0.0, 1.0);
                totalRgb *= vFade;
                totalAlpha *= vFade;
            }

            return vec4(totalRgb * totalAlpha, totalAlpha);
        }
    """

    /**
     * Binds all 42 uniforms of a [GlassToken] onto a compiled [MI_GLASS_V13_F16_FUSED_AGSL] [RuntimeShader].
     */
    @JvmStatic
    fun bindGlassUniforms(
        shader: RuntimeShader,
        token: GlassToken,
        widthPx: Float,
        heightPx: Float,
        cornerRadiusPx: Float,
        density: Float,
        useSuperellipse: Boolean,
        backdropOffsetX: Float,
        backdropOffsetY: Float,
        backdropWidth: Float,
        backdropHeight: Float,
        backdropScaleX: Float,
        backdropScaleY: Float,
        hit: Float = 0f,
        touchX: Float = widthPx * 0.5f,
        touchY: Float = heightPx * 0.5f,
        pressAlpha: Float = 0f
    ) {
        val p = token.toShaderParams()
        val poly = LMGaussianKernel.bezierToPolynomial(p[0], p[1], p[2], p[3])

        shader.setFloatUniform("uResolution", max(widthPx, 1f), max(heightPx, 1f))
        shader.setFloatUniform("uBackdropOffset", backdropOffsetX, backdropOffsetY)
        shader.setFloatUniform("uBackdropSize", max(backdropWidth, 1f), max(backdropHeight, 1f))
        shader.setFloatUniform("uBackdropScale", backdropScaleX, backdropScaleY)
        shader.setFloatUniform("uCornerRadius", max(cornerRadiusPx, 0f))
        shader.setIntUniform("uUseSmoothCorner", if (useSuperellipse) 1 else 0)

        shader.setFloatUniform("uLuminanceCurve", poly[0], poly[1], poly[2], poly[3])
        shader.setFloatUniform("uLuminanceAmount", p[4])
        shader.setFloatUniform("uSaturation", p[5])
        shader.setFloatUniform("uBrightness", p[6])
        shader.setFloatUniform("uDarker", p[7])
        shader.setFloatUniform("uDarkerRange", p[8], p[9])
        shader.setFloatUniform("uInnerBottom", p[10])
        shader.setFloatUniform("uGlassColor", p[11], p[12], p[13], p[14])
        shader.setFloatUniform("uInnerColorWhite", p[15])
        shader.setFloatUniform("uInnerColorMix", p[16])
        shader.setFloatUniform("uColorPow", p[17])
        shader.setFloatUniform("uAlpha", p[18])

        // Scale spatial pixel metrics relative to reference 3.0x density (1080p HyperOS baseline)
        val metricScale = (density / 3.0f).coerceIn(0.4f, 2.0f)
        shader.setFloatUniform("uEdgePx", max(p[19] * metricScale, 1f))
        shader.setFloatUniform("uEdgePow", p[20])
        shader.setFloatUniform("uThicknessPx", p[21] * metricScale)
        shader.setFloatUniform("uReflectOffsetPx", p[22] * metricScale)
        shader.setFloatUniform("uReflectionLighten", p[23])
        shader.setFloatUniform("uReflectionStrength", p[24])
        shader.setFloatUniform("uLightDirection", p[25], p[26], p[27])
        shader.setFloatUniform("uLightIntensity", p[28])
        shader.setFloatUniform("uLightOpposite", p[29])
        shader.setFloatUniform("uLightAngleRange", p[30])
        shader.setFloatUniform("uLightEdgePow", p[31])
        shader.setFloatUniform("uRefractIOR", p[32])
        shader.setFloatUniform("uBgColorSaturation", p[33])
        shader.setFloatUniform("uBgColorBrightness", p[34])
        shader.setFloatUniform("uBurn", p[35])
        shader.setFloatUniform("uUnshade", p[36])

        shader.setFloatUniform("uHit", hit)
        shader.setFloatUniform("uTouchPos", touchX, touchY)
        shader.setFloatUniform("uPressAlpha", pressAlpha)
    }

    /**
     * Binds a [ColorBlendConfig] onto a compiled [MI_BLEND_BLUR_AGSL] [RuntimeShader].
     */
    @JvmStatic
    fun bindBlendBlurUniforms(
        shader: RuntimeShader,
        config: ColorBlendConfig,
        widthPx: Float,
        heightPx: Float,
        cornerRadiusPx: Float,
        useSuperellipse: Boolean,
        backdropOffsetX: Float,
        backdropOffsetY: Float,
        backdropWidth: Float,
        backdropHeight: Float,
        backdropScaleX: Float,
        backdropScaleY: Float,
        gradientMode: Int = 0,
        gradientStart: Float = 0f,
        gradientEnd: Float = 1f
    ) {
        shader.setFloatUniform("uResolution", max(widthPx, 1f), max(heightPx, 1f))
        shader.setFloatUniform("uBackdropOffset", backdropOffsetX, backdropOffsetY)
        shader.setFloatUniform("uBackdropSize", max(backdropWidth, 1f), max(backdropHeight, 1f))
        shader.setFloatUniform("uBackdropScale", backdropScaleX, backdropScaleY)
        shader.setFloatUniform("uCornerRadius", max(cornerRadiusPx, 0f))
        shader.setIntUniform("uUseSmoothCorner", if (useSuperellipse) 1 else 0)

        val count = min(config.colors.size, 4)
        shader.setIntUniform("uLayerCount", count)

        val layerColorNames = arrayOf("uLayerColor0", "uLayerColor1", "uLayerColor2", "uLayerColor3")
        val layerModeNames = arrayOf("uLayerMode0", "uLayerMode1", "uLayerMode2", "uLayerMode3")
        for (i in 0 until 4) {
            if (i < count) {
                val c = config.colors[i]
                val a = ((c ushr 24) and 0xFF) / 255f
                val r = ((c shr 16) and 0xFF) / 255f
                val g = ((c shr 8) and 0xFF) / 255f
                val b = (c and 0xFF) / 255f
                shader.setFloatUniform(layerColorNames[i], r, g, b, a)
                shader.setIntUniform(layerModeNames[i], config.modes[i])
            } else {
                shader.setFloatUniform(layerColorNames[i], 0f, 0f, 0f, 0f)
                shader.setIntUniform(layerModeNames[i], 3)
            }
        }

        shader.setIntUniform("uGradientMode", gradientMode)
        shader.setFloatUniform("uGradientSpan", gradientStart, gradientEnd)
    }

    /**
     * Binds a [BloomStrokeConfig] onto a compiled [MI_BLOOM_STROKE_AGSL] [RuntimeShader].
     */
    @JvmStatic
    fun bindBloomStrokeUniforms(
        shader: RuntimeShader,
        config: BloomStrokeConfig,
        widthPx: Float,
        heightPx: Float,
        cornerRadiusPx: Float,
        density: Float,
        useSuperellipse: Boolean
    ) {
        shader.setFloatUniform("uResolution", max(widthPx, 1f), max(heightPx, 1f))
        shader.setFloatUniform("uCornerRadius", max(cornerRadiusPx, 0f))
        shader.setIntUniform("uUseSmoothCorner", if (useSuperellipse) 1 else 0)
        shader.setFloatUniform("uStrokeWidth", max(config.strokeWidth * density, 1f))
        shader.setFloatUniform("uNormalWidth", max(config.normalWidth * density, 1f))
        shader.setFloatUniform(
            "uSourceColor",
            config.sourceColorR,
            config.sourceColorG,
            config.sourceColorB,
            config.sourceColorA
        )
        shader.setFloatUniform("uTexelOffset", config.texelOffsetX, config.texelOffsetY)
        shader.setFloatUniform("uLightDir1", config.light1X, config.light1Y)
        shader.setFloatUniform("uLightColor1", config.light1R, config.light1G, config.light1B, config.light1A)
        shader.setFloatUniform("uLightDir2", config.light2X, config.light2Y, config.light2Z)
        shader.setFloatUniform("uLightColor2", config.light2R, config.light2G, config.light2B, config.light2A)
        shader.setIntUniform("uGradientBorder", if (config.gradientBorder) 1 else 0)
    }

    /**
     * Creates a chained Android 13+ [RenderEffect] combining [RenderEffect.createBlurEffect] and
     * [RenderEffect.createRuntimeShaderEffect] for direct attachment to a `View` or `RenderNode`.
     */
    @JvmStatic
    fun createGlassRenderEffect(
        token: GlassToken,
        widthPx: Float,
        heightPx: Float,
        cornerRadiusPx: Float,
        density: Float,
        useSuperellipse: Boolean = true,
        bigBlurBitmapShader: BitmapShader? = null
    ): RenderEffect? {
        return try {
            val runtimeShader = RuntimeShader(MI_GLASS_V13_F16_FUSED_AGSL)
            bindGlassUniforms(
                shader = runtimeShader,
                token = token,
                widthPx = widthPx,
                heightPx = heightPx,
                cornerRadiusPx = cornerRadiusPx,
                density = density,
                useSuperellipse = useSuperellipse,
                backdropOffsetX = 0f,
                backdropOffsetY = 0f,
                backdropWidth = widthPx,
                backdropHeight = heightPx,
                backdropScaleX = 1f,
                backdropScaleY = 1f
            )
            if (bigBlurBitmapShader != null) {
                runtimeShader.setInputShader("uBigBlur", bigBlurBitmapShader)
            }
            val smallSigma = max(
                LMGaussianKernel.radiusToSigma(token.blurRadius.smallBlurRadius.toFloat()),
                0.5f
            )
            val blurEffect = RenderEffect.createBlurEffect(
                smallSigma,
                smallSigma,
                Shader.TileMode.CLAMP
            )
            val glassEffect = RenderEffect.createRuntimeShaderEffect(runtimeShader, "uSmallBlur")
            RenderEffect.createChainEffect(glassEffect, blurEffect)
        } catch (_: Throwable) {
            null
        }
    }
}
