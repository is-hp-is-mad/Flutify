package com.hyperos.glass.gl

import android.graphics.Bitmap
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES30
import android.opengl.GLUtils
import com.hyperos.glass.token.ColorBlendConfig
import com.hyperos.glass.token.GlassToken
import com.hyperos.glass.util.LMGaussianKernel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.max
import kotlin.math.min

/**
 * Standard OpenGL ES 3.0 Offscreen FBO Rendering Pipeline for Android 12 and below (API <= 32).
 *
 * Uses pure Android SDK `android.opengl.EGL14` and `android.opengl.GLES30` with `#version 300 es`
 * shaders to render the exact Xiaomi HyperOS `mi_glass_v13_f16` and `mi_blend_blur` passes
 * without requiring Android 13+ `RuntimeShader` or any private native `.so` libraries.
 */
object HyperGlES30Pipeline {

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var initialized = false
    private var initFailed = false

    private var glassProgram = 0
    private var blendProgram = 0
    private var quadVbo = 0
    private var readbackBuffer: ByteBuffer? = null

    private const val VERTEX_SHADER_300_ES = """#version 300 es
        layout(location = 0) in vec2 aPosition;
        out vec2 vUv;
        void main() {
            vUv = aPosition * 0.5 + 0.5;
            gl_Position = vec4(aPosition, 0.0, 1.0);
        }
    """

    private const val GLASS_FRAG_300_ES = """#version 300 es
        precision highp float;
        in vec2 vUv;
        out vec4 fragColor;

        uniform sampler2D uSmallBlurTex;
        uniform sampler2D uBigBlurTex;

        uniform vec2 uResolution;
        uniform float uCornerRadius;
        uniform int uUseSmoothCorner;

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
            vec2 uv = clamp(localCoord / max(uResolution, vec2(1.0)), vec2(0.001), vec2(0.999));
            vec3 smallRgb = texture(uSmallBlurTex, uv).rgb;
            vec3 bigRgb = texture(uBigBlurTex, uv).rgb;

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

        void main() {
            vec2 fragCoord = vUv * uResolution;
            vec2 halfSize = uResolution * 0.5;
            float maxRadius = min(halfSize.x, halfSize.y);
            float radius = min(uCornerRadius, maxRadius);

            float cornerMask = 0.0;
            float d = evalShapeSdf(fragCoord, halfSize, radius, cornerMask);
            float shapeMask = clamp(0.5 - d, 0.0, 1.0);
            if (shapeMask <= 0.001) {
                fragColor = vec4(0.0);
                return;
            }

            float rectEdge = max(min(uEdgePx, maxRadius), 1.0);
            float normalizeSdf = clamp(-d / rectEdge, 0.0, 1.0);

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

            float ior = max(uRefractIOR, 1.01);
            vec3 refractVec = refract(vec3(0.0, 0.0, -1.0), normal, 1.0 / ior);
            float lensDepth = mix((uThicknessPx - uEdgePx) * 2.0, uThicknessPx * 2.0, abs(refractVec.z));
            vec3 refractColor = sampleTintedGlass(fragCoord + refractVec.xy * lensDepth);

            vec2 reflectVec = 2.0 * normal.z * normal.xy;
            vec2 reflectOffset = reflectVec * (uReflectOffsetPx * (1.0 - normalizeSdf));
            vec3 reflectSample = sampleTintedGlass(fragCoord + reflectOffset);
            vec3 reflectColor = clamp(reflectSample + vec3(uReflectionLighten * 0.1), 0.0, 1.0);
            float reflectAmount = clamp(length(reflectVec) * uReflectionStrength, 0.0, 1.0);
            vec3 color = hsvv(refractColor + reflectColor * reflectAmount);

            float bottomGlow = clamp((fragCoord.y / max(uResolution.y, 1.0)) * uInnerBottom, 0.0, 1.0);
            color += (1.0 - color) * bottomGlow;

            vec2 dir2d = normalize(uLightDirection.xy + vec2(1e-5, 0.0));
            vec2 n2d = normalize(normal.xy + vec2(1e-5, 0.0));
            float ndotl = dot(n2d, dir2d);
            float dirFactor = clamp(abs(ndotl), 0.0, 1.0);
            float angleFactor = mix(dirFactor, smoothstep(max(1.0 - uLightAngleRange, 0.001), 1.0, dirFactor), cornerMask);
            float edgeFactor = pow(max(1.0 - normalizeSdf, 0.0), max(uLightEdgePow, 0.01));
            float sideIntensity = ndotl < 0.0 ? uLightOpposite : uLightIntensity;
            vec3 lightColor = mix(color, vec3(1.0), clamp(abs(uLightDirection.z), 0.0, 1.0));
            color = hsvv(color + lightColor * (angleFactor * edgeFactor * sideIntensity));

            if (abs(uColorPow - 1.0) > 0.01) {
                color = pow(max(color, vec3(0.0)), vec3(uColorPow));
            }
            if (uUnshade > 0.001) {
                color = mix(color, uGlassColor.rgb, clamp(uUnshade, 0.0, 1.0));
            }

            float finalAlpha = clamp(uAlpha * shapeMask, 0.0, 1.0);
            fragColor = vec4(color * finalAlpha, finalAlpha);
        }
    """

    private const val BLEND_FRAG_300_ES = """#version 300 es
        precision highp float;
        in vec2 vUv;
        out vec4 fragColor;

        uniform sampler2D uBlurTex;
        uniform vec2 uResolution;
        uniform float uCornerRadius;
        uniform int uUseSmoothCorner;
        uniform int uLayerCount;
        uniform vec4 uLayerColors[4];
        uniform int uLayerModes[4];

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
            return vec3(blendOverlayChannel(b.r, s.r), blendOverlayChannel(b.g, s.g), blendOverlayChannel(b.b, s.b));
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
            return vec3(blendSoftLightChannel(b.r, s.r), blendSoftLightChannel(b.g, s.g), blendSoftLightChannel(b.b, s.b));
        }

        vec3 applyBlendLayer(vec3 dst, vec4 src, int mode) {
            float a = src.a;
            vec3 s = src.rgb;
            if (a <= 0.0001) return dst;
            if (mode == 120 || mode == 111) return clamp(dst + (s - 1.0) * a, 0.0, 1.0);
            if (mode == 121 || mode == 12 || mode == 110) return clamp(dst + s * a, 0.0, 1.0);
            vec3 blended = s;
            if (mode == 15) blended = blendOverlay(dst, s);
            else if (mode == 20) blended = blendOverlay(s, dst);
            else if (mode == 21) blended = blendSoftLight(dst, s);
            else if (mode == 19 || mode == 103) blended = 1.0 - min(vec3(1.0), (1.0 - dst) / max(s, vec3(1e-4)));
            else if (mode == 18 || mode == 102) blended = min(vec3(1.0), dst / max(1.0 - s, vec3(1e-4)));
            else if (mode == 16 || mode == 107) blended = min(dst, s);
            else if (mode == 17 || mode == 108) blended = max(dst, s);
            else if (mode == 24 || mode == 13) blended = dst * s;
            else if (mode == 14) blended = dst + s - dst * s;
            return clamp(mix(dst, blended, a), 0.0, 1.0);
        }

        void main() {
            vec2 fragCoord = vUv * uResolution;
            vec2 halfSize = uResolution * 0.5;
            float maxRadius = min(halfSize.x, halfSize.y);
            float radius = min(uCornerRadius, maxRadius);
            float d = evalShapeSdf(fragCoord, halfSize, radius);
            float shapeMask = clamp(0.5 - d, 0.0, 1.0);
            if (shapeMask <= 0.001) {
                fragColor = vec4(0.0);
                return;
            }
            vec3 color = texture(uBlurTex, clamp(vUv, vec2(0.001), vec2(0.999))).rgb;
            for (int i = 0; i < 4; ++i) {
                if (i >= uLayerCount) break;
                color = applyBlendLayer(color, uLayerColors[i], uLayerModes[i]);
            }
            fragColor = vec4(color * shapeMask, shapeMask);
        }
    """

    @Synchronized
    private fun ensureInitialized(): Boolean {
        if (initialized) return true
        if (initFailed) return false
        return try {
            eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (eglDisplay == EGL14.EGL_NO_DISPLAY) {
                initFailed = true
                return false
            }
            val version = IntArray(2)
            if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
                initFailed = true
                return false
            }
            val configAttribs = intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, 0x0040, // EGL_OPENGL_ES3_BIT_KHR
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_NONE
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfigs = IntArray(1)
            if (!EGL14.eglChooseConfig(eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0) || numConfigs[0] == 0) {
                initFailed = true
                return false
            }
            val cfg = configs[0]!!
            val ctxAttribs = intArrayOf(
                EGL14.EGL_CONTEXT_CLIENT_VERSION, 3,
                EGL14.EGL_NONE
            )
            eglContext = EGL14.eglCreateContext(eglDisplay, cfg, EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)
            if (eglContext == EGL14.EGL_NO_CONTEXT) {
                initFailed = true
                return false
            }
            val pbufferAttribs = intArrayOf(
                EGL14.EGL_WIDTH, 16,
                EGL14.EGL_HEIGHT, 16,
                EGL14.EGL_NONE
            )
            eglSurface = EGL14.eglCreatePbufferSurface(eglDisplay, cfg, pbufferAttribs, 0)
            if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
                initFailed = true
                return false
            }

            glassProgram = linkProgram(VERTEX_SHADER_300_ES, GLASS_FRAG_300_ES)
            blendProgram = linkProgram(VERTEX_SHADER_300_ES, BLEND_FRAG_300_ES)
            if (glassProgram == 0 || blendProgram == 0) {
                initFailed = true
                return false
            }

            val quadCoords = floatArrayOf(
                -1f, -1f,
                1f, -1f,
                -1f, 1f,
                1f, 1f
            )
            val vboIds = IntArray(1)
            GLES30.glGenBuffers(1, vboIds, 0)
            quadVbo = vboIds[0]
            val fb: FloatBuffer = ByteBuffer.allocateDirect(quadCoords.size * 4)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()
                .put(quadCoords)
            fb.position(0)
            GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, quadVbo)
            GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, quadCoords.size * 4, fb, GLES30.GL_STATIC_DRAW)

            initialized = true
            true
        } catch (_: Throwable) {
            initFailed = true
            false
        }
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES30.glCreateShader(type)
        if (shader == 0) return 0
        GLES30.glShaderSource(shader, src)
        GLES30.glCompileShader(shader)
        val status = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            GLES30.glDeleteShader(shader)
            return 0
        }
        return shader
    }

    private fun linkProgram(vertSrc: String, fragSrc: String): Int {
        val vs = compileShader(GLES30.GL_VERTEX_SHADER, vertSrc)
        val fs = compileShader(GLES30.GL_FRAGMENT_SHADER, fragSrc)
        if (vs == 0 || fs == 0) return 0
        val prog = GLES30.glCreateProgram()
        GLES30.glAttachShader(prog, vs)
        GLES30.glAttachShader(prog, fs)
        GLES30.glLinkProgram(prog)
        GLES30.glDeleteShader(vs)
        GLES30.glDeleteShader(fs)
        val status = IntArray(1)
        GLES30.glGetProgramiv(prog, GLES30.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            GLES30.glDeleteProgram(prog)
            return 0
        }
        return prog
    }

    /**
     * Renders `mi_glass_v13_f16` offscreen via OpenGL ES 3.0 FBO for Android 12 and below.
     * Returns `true` if `outBitmap` was populated, or `false` on any error.
     */
    @Synchronized
    fun renderGlassToBitmap(
        smallBlurBitmap: Bitmap,
        bigBlurBitmap: Bitmap,
        outBitmap: Bitmap,
        token: GlassToken,
        widthPx: Int,
        heightPx: Int,
        cornerRadiusPx: Float,
        density: Float,
        useSuperellipse: Boolean
    ): Boolean {
        if (widthPx <= 0 || heightPx <= 0) return false
        if (!ensureInitialized()) return false
        return try {
            if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) return false

            val texIds = IntArray(3)
            GLES30.glGenTextures(3, texIds, 0)
            val smallTex = texIds[0]
            val bigTex = texIds[1]
            val fboTex = texIds[2]

            uploadBitmapToTexture(smallTex, smallBlurBitmap)
            uploadBitmapToTexture(bigTex, bigBlurBitmap)

            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, fboTex)
            GLES30.glTexImage2D(
                GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8,
                widthPx, heightPx, 0, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null
            )
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)

            val fboIds = IntArray(1)
            GLES30.glGenFramebuffers(1, fboIds, 0)
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fboIds[0])
            GLES30.glFramebufferTexture2D(
                GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
                GLES30.GL_TEXTURE_2D, fboTex, 0
            )

            GLES30.glViewport(0, 0, widthPx, heightPx)
            GLES30.glUseProgram(glassProgram)

            val p = token.toShaderParams()
            val poly = LMGaussianKernel.bezierToPolynomial(p[0], p[1], p[2], p[3])
            val metricScale = (density / 3.0f).coerceIn(0.4f, 2.0f)

            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, smallTex)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(glassProgram, "uSmallBlurTex"), 0)

            GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, bigTex)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(glassProgram, "uBigBlurTex"), 1)

            GLES30.glUniform2f(GLES30.glGetUniformLocation(glassProgram, "uResolution"), widthPx.toFloat(), heightPx.toFloat())
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uCornerRadius"), cornerRadiusPx)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(glassProgram, "uUseSmoothCorner"), if (useSuperellipse) 1 else 0)
            GLES30.glUniform4f(GLES30.glGetUniformLocation(glassProgram, "uLuminanceCurve"), poly[0], poly[1], poly[2], poly[3])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uLuminanceAmount"), p[4])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uSaturation"), p[5])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uBrightness"), p[6])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uDarker"), p[7])
            GLES30.glUniform2f(GLES30.glGetUniformLocation(glassProgram, "uDarkerRange"), p[8], p[9])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uInnerBottom"), p[10])
            GLES30.glUniform4f(GLES30.glGetUniformLocation(glassProgram, "uGlassColor"), p[11], p[12], p[13], p[14])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uInnerColorWhite"), p[15])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uInnerColorMix"), p[16])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uColorPow"), p[17])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uAlpha"), p[18])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uEdgePx"), max(p[19] * metricScale, 1f))
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uEdgePow"), p[20])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uThicknessPx"), p[21] * metricScale)
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uReflectOffsetPx"), p[22] * metricScale)
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uReflectionLighten"), p[23])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uReflectionStrength"), p[24])
            GLES30.glUniform3f(GLES30.glGetUniformLocation(glassProgram, "uLightDirection"), p[25], p[26], p[27])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uLightIntensity"), p[28])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uLightOpposite"), p[29])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uLightAngleRange"), p[30])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uLightEdgePow"), p[31])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uRefractIOR"), p[32])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uBgColorSaturation"), p[33])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uBgColorBrightness"), p[34])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uBurn"), p[35])
            GLES30.glUniform1f(GLES30.glGetUniformLocation(glassProgram, "uUnshade"), p[36])

            drawQuadAndReadback(widthPx, heightPx, outBitmap)

            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
            GLES30.glDeleteFramebuffers(1, fboIds, 0)
            GLES30.glDeleteTextures(3, texIds, 0)
            true
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Renders `mi_blend_blur` offscreen via OpenGL ES 3.0 FBO for Android 12 and below.
     */
    @Synchronized
    fun renderBlendBlurToBitmap(
        blurBitmap: Bitmap,
        outBitmap: Bitmap,
        config: ColorBlendConfig,
        widthPx: Int,
        heightPx: Int,
        cornerRadiusPx: Float,
        useSuperellipse: Boolean
    ): Boolean {
        if (widthPx <= 0 || heightPx <= 0) return false
        if (!ensureInitialized()) return false
        return try {
            if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) return false

            val texIds = IntArray(2)
            GLES30.glGenTextures(2, texIds, 0)
            val blurTex = texIds[0]
            val fboTex = texIds[1]

            uploadBitmapToTexture(blurTex, blurBitmap)

            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, fboTex)
            GLES30.glTexImage2D(
                GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8,
                widthPx, heightPx, 0, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null
            )
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)

            val fboIds = IntArray(1)
            GLES30.glGenFramebuffers(1, fboIds, 0)
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fboIds[0])
            GLES30.glFramebufferTexture2D(
                GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
                GLES30.GL_TEXTURE_2D, fboTex, 0
            )

            GLES30.glViewport(0, 0, widthPx, heightPx)
            GLES30.glUseProgram(blendProgram)

            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, blurTex)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(blendProgram, "uBlurTex"), 0)

            GLES30.glUniform2f(GLES30.glGetUniformLocation(blendProgram, "uResolution"), widthPx.toFloat(), heightPx.toFloat())
            GLES30.glUniform1f(GLES30.glGetUniformLocation(blendProgram, "uCornerRadius"), cornerRadiusPx)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(blendProgram, "uUseSmoothCorner"), if (useSuperellipse) 1 else 0)

            val count = min(config.colors.size, 4)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(blendProgram, "uLayerCount"), count)

            val colorFloats = FloatArray(16)
            val modeInts = IntArray(4)
            for (i in 0 until count) {
                val c = config.colors[i]
                colorFloats[i * 4] = ((c shr 16) and 0xFF) / 255f
                colorFloats[i * 4 + 1] = ((c shr 8) and 0xFF) / 255f
                colorFloats[i * 4 + 2] = (c and 0xFF) / 255f
                colorFloats[i * 4 + 3] = ((c ushr 24) and 0xFF) / 255f
                modeInts[i] = config.modes[i]
            }
            GLES30.glUniform4fv(GLES30.glGetUniformLocation(blendProgram, "uLayerColors"), 4, colorFloats, 0)
            GLES30.glUniform1iv(GLES30.glGetUniformLocation(blendProgram, "uLayerModes"), 4, modeInts, 0)

            drawQuadAndReadback(widthPx, heightPx, outBitmap)

            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
            GLES30.glDeleteFramebuffers(1, fboIds, 0)
            GLES30.glDeleteTextures(2, texIds, 0)
            true
        } catch (_: Throwable) {
            false
        }
    }

    private fun uploadBitmapToTexture(texId: Int, bitmap: Bitmap) {
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texId)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLUtils.texImage2D(GLES30.GL_TEXTURE_2D, 0, bitmap, 0)
    }

    private fun drawQuadAndReadback(widthPx: Int, heightPx: Int, outBitmap: Bitmap) {
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, quadVbo)
        GLES30.glEnableVertexAttribArray(0)
        GLES30.glVertexAttribPointer(0, 2, GLES30.GL_FLOAT, false, 0, 0)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)

        val neededBytes = widthPx * heightPx * 4
        var buf = readbackBuffer
        if (buf == null || buf.capacity() < neededBytes) {
            buf = ByteBuffer.allocateDirect(neededBytes).order(ByteOrder.nativeOrder())
            readbackBuffer = buf
        }
        buf.position(0)
        buf.limit(neededBytes)
        GLES30.glReadPixels(0, 0, widthPx, heightPx, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, buf)
        buf.position(0)
        outBitmap.copyPixelsFromBuffer(buf)
    }
}
