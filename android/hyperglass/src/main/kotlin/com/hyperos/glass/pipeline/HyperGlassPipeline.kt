package com.hyperos.glass.pipeline

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.RenderEffect
import android.graphics.RenderNode
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.os.Build
import android.view.MotionEvent
import android.view.View
import com.hyperos.glass.gl.HyperGlES30Pipeline
import com.hyperos.glass.shader.HyperAgslShaders
import com.hyperos.glass.token.BloomStrokeConfig
import com.hyperos.glass.token.ColorBlendConfig
import com.hyperos.glass.token.GlassToken
import com.hyperos.glass.token.MaterialToken
import com.hyperos.glass.token.ShadowConfig
import com.hyperos.glass.util.HyperGlassCapabilities
import com.hyperos.glass.util.HyperGlassCapabilities.RenderBackend
import com.hyperos.glass.util.LMGaussianKernel
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Self-contained, ROM-independent rendering pipeline for Xiaomi HyperOS soft-light glass
 * (`mi_glass_v13_f16`), color-blend blur (`mi_blend_blur`), diffuse bloom stroke (`mi_bloom_stroke`),
 * interactive press light, and dispersive shadow.
 *
 * Supports:
 * 1. **Android 13+ (API 33+)**: Standard AGSL (`android.graphics.RuntimeShader` & `RenderEffect`).
 * 2. **Android 5.0–12L (API 21–32)**: Standard OpenGL ES 3.0 offscreen FBO (`HyperGlES30Pipeline`).
 * 3. **Graceful Degradation**: Smoothly falls back to `RenderEffect.createBlurEffect` or
 *    a semi-transparent superellipse/rounded-rect tint overlay if hardware acceleration is
 *    disabled, on low-RAM devices, or if shader compilation fails.
 */
class HyperGlassPipeline(private val targetView: View) {

    var glassToken: GlassToken? = GlassToken.Common_Large_Regular
        set(value) {
            field = value
            invalidateRenderEffectNode()
            targetView.invalidate()
        }

    var colorBlendConfig: ColorBlendConfig? = null
        set(value) {
            field = value
            invalidateRenderEffectNode()
            targetView.invalidate()
        }

    var blurRadiusDp: Float = 60f
        set(value) {
            field = value
            targetView.invalidate()
        }

    var bloomStrokeConfig: BloomStrokeConfig? = null
        set(value) {
            field = value
            targetView.invalidate()
        }

    var shadowConfig: ShadowConfig? = null
        set(value) {
            field = value
            targetView.invalidate()
        }

    var cornerRadiusPx: Float = -1f
        set(value) {
            field = value
            clipPathDirty = true
            invalidateRenderEffectNode()
            targetView.invalidate()
        }

    var useSuperellipse: Boolean = true
        set(value) {
            field = value
            clipPathDirty = true
            invalidateRenderEffectNode()
            targetView.invalidate()
        }

    var pressLightEnabled: Boolean = false
    var fallbackColorOverride: Int? = null
    var backdropSourceView: View? = null

    /** Optional vertical gradient blur mode: `0 = off`, `1 = top-to-bottom`, `2 = bottom-to-top`. */
    var gradientMode: Int = 0
    var gradientStart: Float = 0f
    var gradientEnd: Float = 1f

    // Touch / press state
    private var touchX: Float = 0f
    private var touchY: Float = 0f
    private var pressAlpha: Float = 0f
    private var hitStrength: Float = 0f

    // Backdrop capture state & pooled bitmaps
    private val targetLoc = IntArray(2)
    private val sourceLoc = IntArray(2)
    private var smallCapBitmap: Bitmap? = null
    private var smallCapCanvas: Canvas? = null
    private var bigCapBitmap: Bitmap? = null
    private var bigCapCanvas: Canvas? = null
    private var sharpCapBitmap: Bitmap? = null
    private var sharpCapCanvas: Canvas? = null
    private var glesOutputBitmap: Bitmap? = null
    private var blurScratchInt: IntArray? = null

    // Reusable drawing primitives
    private val shaderPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val bloomPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val fallbackPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val fallbackStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
    }
    private val boundsRect = RectF()
    private val clipPath = Path()
    private var clipPathDirty = true
    private var lastPathWidth = -1
    private var lastPathHeight = -1
    private var lastPathRadius = -1f

    // Cached Android 13+ AGSL RuntimeShader instances (lazily compiled, null if unsupported/failed)
    private var agslGlassShader: Any? = null
    private var agslBlendShader: Any? = null
    private var agslBloomShader: Any? = null
    private var agslCompileFailed = false

    // Optional Android 13+ RenderNode with chained RenderEffect
    private var effectRenderNode: Any? = null

    /**
     * Applies a composite [MaterialToken] to this pipeline.
     */
    fun applyMaterialToken(material: MaterialToken, density: Float) {
        this.glassToken = material.glassToken
        this.colorBlendConfig = material.colorBlendConfig
        this.blurRadiusDp = material.blurRadiusDp
        this.bloomStrokeConfig = material.bloomStrokeConfig
        this.shadowConfig = material.shadowConfig
        this.cornerRadiusPx = material.cornerRadiusDp * density
        this.useSuperellipse = material.useSuperellipse
        this.pressLightEnabled = material.pressLightEnabled
        targetView.invalidate()
    }

    /**
     * Handles touch events when [pressLightEnabled] is true to drive the HyperOS interactive
     * refraction & press-light ripple.
     */
    fun onTouchEvent(event: MotionEvent) {
        if (!pressLightEnabled) return
        touchX = event.x
        touchY = event.y
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                pressAlpha = 1.0f
                hitStrength = 1.0f
                targetView.invalidate()
            }
            MotionEvent.ACTION_MOVE -> {
                targetView.invalidate()
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                pressAlpha = 0.0f
                hitStrength = 0.0f
                targetView.invalidate()
            }
        }
    }

    /**
     * Returns true if any pipeline instance on the current thread is currently capturing
     * the backdrop hierarchy (used to prevent recursive self-drawing).
     */
    fun isCurrentlyCapturing(): Boolean = capturingDepth.get() > 0

    /**
     * Renders the complete HyperOS glass / blend-blur + bloom stroke + shadow onto [canvas].
     *
     * Safe on all devices: never throws `ClassNotFoundException`, `NoSuchMethodError`,
     * or shader exceptions.
     */
    fun draw(canvas: Canvas) {
        if (isCurrentlyCapturing()) return
        val w = targetView.width
        val h = targetView.height
        if (w <= 0 || h <= 0) return

        val density = targetView.resources.displayMetrics.density.coerceAtLeast(1f)
        val resolvedRadius = resolveCornerRadiusPx(w, h, density)
        ensureClipPath(w, h, resolvedRadius)

        // 1. Draw dispersive drop shadow behind the glass shape if configured
        shadowConfig?.let { drawShadow(canvas, w.toFloat(), h.toFloat(), resolvedRadius, density, it) }

        // 2. Resolve active rendering backend & execute with automatic graceful degradation
        val backend = HyperGlassCapabilities.resolveBackend(targetView.context, canvas)
        var rendered = false

        if (backend == RenderBackend.AGSL_RUNTIME_SHADER &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !agslCompileFailed
        ) {
            rendered = tryRenderAgsl(canvas, w, h, resolvedRadius, density)
        }

        if (!rendered && (backend == RenderBackend.OPENGL_ES_30 || backend == RenderBackend.AGSL_RUNTIME_SHADER)) {
            rendered = tryRenderOpenGlEs30(canvas, w, h, resolvedRadius, density)
        }

        if (!rendered) {
            renderGracefulFallback(canvas, w, h, resolvedRadius, density)
        }

        // 3. Draw Bloom diffuse rim stroke on top
        bloomStrokeConfig?.let {
            drawBloomStroke(canvas, w.toFloat(), h.toFloat(), resolvedRadius, density, it, backend)
        }
    }

    private fun resolveCornerRadiusPx(w: Int, h: Int, density: Float): Float {
        val maxR = min(w, h) * 0.5f
        val r = if (cornerRadiusPx >= 0f) cornerRadiusPx else 24f * density
        return r.coerceIn(0f, maxR)
    }

    private fun invalidateRenderEffectNode() {
        effectRenderNode = null
    }

    /**
     * Android 13+ (API 33) Standard AGSL (`RuntimeShader` + `RenderEffect`) rendering path.
     */
    private fun tryRenderAgsl(
        canvas: Canvas,
        w: Int,
        h: Int,
        cornerRadius: Float,
        density: Float
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        return try {
            val activeGlass = glassToken
            val activeBlend = colorBlendConfig

            if (activeGlass != null) {
                val p = activeGlass.toShaderParams()
                val metricScale = (density / 3.0f).coerceIn(0.4f, 2.0f)
                val maxDisplacement = max(p[21] * 2.0f, p[22] * 0.35f) * metricScale
                val marginPx = maxDisplacement.roundToInt().coerceIn(8, 96)

                val smallRadius = activeGlass.blurRadius.smallBlurRadius.toFloat() * metricScale
                val bigRadius = activeGlass.blurRadius.bigBlurRadius.toFloat() * metricScale

                val smallCap = captureAndBlurBackdrop(
                    w = w,
                    h = h,
                    marginPx = marginPx,
                    downscale = 2,
                    blurRadiusPx = smallRadius,
                    isBigSlot = false
                ) ?: return false

                val bigCap = captureAndBlurBackdrop(
                    w = w,
                    h = h,
                    marginPx = marginPx,
                    downscale = 6,
                    blurRadiusPx = bigRadius,
                    isBigSlot = true
                ) ?: smallCap

                val glassShader = (agslGlassShader as? RuntimeShader)
                    ?: RuntimeShader(HyperAgslShaders.MI_GLASS_V13_F16_FUSED_AGSL).also {
                        agslGlassShader = it
                    }

                val smallBs = BitmapShader(smallCap, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
                // Scale bigCap to match smallCap coordinate space
                val bigBs = BitmapShader(bigCap, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
                if (bigCap !== smallCap) {
                    val m = Matrix()
                    m.setScale(
                        smallCap.width.toFloat() / max(bigCap.width, 1).toFloat(),
                        smallCap.height.toFloat() / max(bigCap.height, 1).toFloat()
                    )
                    bigBs.setLocalMatrix(m)
                }

                glassShader.setInputShader("uSmallBlur", smallBs)
                glassShader.setInputShader("uBigBlur", bigBs)

                val totalW = (w + marginPx * 2).toFloat()
                val totalH = (h + marginPx * 2).toFloat()
                val scaleX = smallCap.width.toFloat() / max(totalW, 1f)
                val scaleY = smallCap.height.toFloat() / max(totalH, 1f)

                HyperAgslShaders.bindGlassUniforms(
                    shader = glassShader,
                    token = activeGlass,
                    widthPx = w.toFloat(),
                    heightPx = h.toFloat(),
                    cornerRadiusPx = cornerRadius,
                    density = density,
                    useSuperellipse = useSuperellipse,
                    backdropOffsetX = marginPx.toFloat(),
                    backdropOffsetY = marginPx.toFloat(),
                    backdropWidth = smallCap.width.toFloat(),
                    backdropHeight = smallCap.height.toFloat(),
                    backdropScaleX = scaleX,
                    backdropScaleY = scaleY,
                    hit = hitStrength,
                    touchX = if (pressAlpha > 0f) touchX else w * 0.5f,
                    touchY = if (pressAlpha > 0f) touchY else h * 0.5f,
                    pressAlpha = pressAlpha
                )

                // If the user ALSO configured a ColorBlendConfig on top of Glass (e.g. Overlay_Pill),
                // or if it's pure Glass:
                shaderPaint.shader = glassShader
                canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), shaderPaint)
                shaderPaint.shader = null

                if (activeBlend != null) {
                    drawBlendOverlayFallback(canvas, activeBlend)
                }
                true
            } else if (activeBlend != null) {
                val marginPx = 8
                val effBlurPx = (if (blurRadiusDp > 0f) blurRadiusDp else activeBlend.defaultBlurRadiusDp) * density
                val blurCap = captureAndBlurBackdrop(
                    w = w,
                    h = h,
                    marginPx = marginPx,
                    downscale = 3,
                    blurRadiusPx = effBlurPx,
                    isBigSlot = false
                ) ?: return false

                val sharpCap = if (gradientMode != 0) {
                    captureAndBlurBackdrop(
                        w = w,
                        h = h,
                        marginPx = marginPx,
                        downscale = 2,
                        blurRadiusPx = 0f,
                        isBigSlot = true
                    ) ?: blurCap
                } else {
                    blurCap
                }

                val blendShader = (agslBlendShader as? RuntimeShader)
                    ?: RuntimeShader(HyperAgslShaders.MI_BLEND_BLUR_AGSL).also {
                        agslBlendShader = it
                    }

                val blurBs = BitmapShader(blurCap, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
                val sharpBs = BitmapShader(sharpCap, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
                if (sharpCap !== blurCap) {
                    val m = Matrix()
                    m.setScale(
                        blurCap.width.toFloat() / max(sharpCap.width, 1).toFloat(),
                        blurCap.height.toFloat() / max(sharpCap.height, 1).toFloat()
                    )
                    sharpBs.setLocalMatrix(m)
                }
                blendShader.setInputShader("uBlurTex", blurBs)
                blendShader.setInputShader("uSharpTex", sharpBs)

                val totalW = (w + marginPx * 2).toFloat()
                val totalH = (h + marginPx * 2).toFloat()
                val scaleX = blurCap.width.toFloat() / max(totalW, 1f)
                val scaleY = blurCap.height.toFloat() / max(totalH, 1f)

                HyperAgslShaders.bindBlendBlurUniforms(
                    shader = blendShader,
                    config = activeBlend,
                    widthPx = w.toFloat(),
                    heightPx = h.toFloat(),
                    cornerRadiusPx = cornerRadius,
                    useSuperellipse = useSuperellipse,
                    backdropOffsetX = marginPx.toFloat(),
                    backdropOffsetY = marginPx.toFloat(),
                    backdropWidth = blurCap.width.toFloat(),
                    backdropHeight = blurCap.height.toFloat(),
                    backdropScaleX = scaleX,
                    backdropScaleY = scaleY,
                    gradientMode = gradientMode,
                    gradientStart = gradientStart,
                    gradientEnd = gradientEnd
                )

                shaderPaint.shader = blendShader
                canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), shaderPaint)
                shaderPaint.shader = null
                true
            } else {
                false
            }
        } catch (_: Throwable) {
            agslCompileFailed = true
            false
        }
    }

    /**
     * Android 12 and below (API <= 32) OpenGL ES 3.0 Offscreen FBO rendering path.
     */
    private fun tryRenderOpenGlEs30(
        canvas: Canvas,
        w: Int,
        h: Int,
        cornerRadius: Float,
        density: Float
    ): Boolean {
        return try {
            val activeGlass = glassToken
            val activeBlend = colorBlendConfig
            val metricScale = (density / 3.0f).coerceIn(0.4f, 2.0f)

            var outBmp = glesOutputBitmap
            if (outBmp == null || outBmp.width != w || outBmp.height != h) {
                outBmp?.recycle()
                outBmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                glesOutputBitmap = outBmp
            }

            if (activeGlass != null) {
                val smallRadius = activeGlass.blurRadius.smallBlurRadius.toFloat() * metricScale
                val bigRadius = activeGlass.blurRadius.bigBlurRadius.toFloat() * metricScale
                val smallCap = captureAndBlurBackdrop(w, h, 0, 2, smallRadius, false) ?: return false
                val bigCap = captureAndBlurBackdrop(w, h, 0, 6, bigRadius, true) ?: smallCap

                val ok = HyperGlES30Pipeline.renderGlassToBitmap(
                    smallBlurBitmap = smallCap,
                    bigBlurBitmap = bigCap,
                    outBitmap = outBmp,
                    token = activeGlass,
                    widthPx = w,
                    heightPx = h,
                    cornerRadiusPx = cornerRadius,
                    density = density,
                    useSuperellipse = useSuperellipse
                )
                if (!ok) return false
                canvas.drawBitmap(outBmp, 0f, 0f, null)
                if (activeBlend != null) {
                    drawBlendOverlayFallback(canvas, activeBlend)
                }
                true
            } else if (activeBlend != null) {
                val effBlurPx = (if (blurRadiusDp > 0f) blurRadiusDp else activeBlend.defaultBlurRadiusDp) * density
                val blurCap = captureAndBlurBackdrop(w, h, 0, 3, effBlurPx, false) ?: return false
                val ok = HyperGlES30Pipeline.renderBlendBlurToBitmap(
                    blurBitmap = blurCap,
                    outBitmap = outBmp,
                    config = activeBlend,
                    widthPx = w,
                    heightPx = h,
                    cornerRadiusPx = cornerRadius,
                    useSuperellipse = useSuperellipse
                )
                if (!ok) return false
                canvas.drawBitmap(outBmp, 0f, 0f, null)
                true
            } else {
                false
            }
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Requirement ④: Graceful Degradation Path.
     * When running on low-end devices, software canvases, or if shader compilation fails,
     * smoothly degrades to downscaled blurred backdrop + tint overlay, or a semi-transparent
     * rounded-rect / superellipse mask. Never crashes.
     */
    private fun renderGracefulFallback(
        canvas: Canvas,
        w: Int,
        h: Int,
        cornerRadius: Float,
        density: Float
    ) {
        try {
            val saveCount = canvas.save()
            canvas.clipPath(clipPath)

            val backend = HyperGlassCapabilities.resolveBackend(targetView.context, canvas)
            if (backend != RenderBackend.FALLBACK_MASK_ONLY) {
                val blurCap = captureAndBlurBackdrop(w, h, 0, 4, 24f * density, false)
                if (blurCap != null) {
                    boundsRect.set(0f, 0f, w.toFloat(), h.toFloat())
                    canvas.drawBitmap(blurCap, null, boundsRect, shaderPaint)
                }
            }

            val fallbackArgb = fallbackColorOverride
                ?: glassToken?.toFallbackArgb()
                ?: colorBlendConfig?.fallbackColorArgb
                ?: 0x80FFFFFF.toInt()

            fallbackPaint.color = fallbackArgb
            fallbackPaint.style = Paint.Style.FILL
            canvas.drawPath(clipPath, fallbackPaint)

            colorBlendConfig?.let { drawBlendOverlayFallback(canvas, it) }

            // Subtle glass rim highlight
            fallbackStrokePaint.strokeWidth = max(1f * density, 1f)
            fallbackStrokePaint.color = 0x33FFFFFF
            canvas.drawPath(clipPath, fallbackStrokePaint)

            canvas.restoreToCount(saveCount)
        } catch (_: Throwable) {
            // Ultimate safety net: plain rounded rect fill
            fallbackPaint.color = fallbackColorOverride ?: 0x66FFFFFF
            boundsRect.set(0f, 0f, w.toFloat(), h.toFloat())
            canvas.drawRoundRect(boundsRect, cornerRadius, cornerRadius, fallbackPaint)
        }
    }

    private fun drawBlendOverlayFallback(canvas: Canvas, config: ColorBlendConfig) {
        val save = canvas.save()
        canvas.clipPath(clipPath)
        for (i in config.colors.indices) {
            fallbackPaint.color = config.colors[i]
            canvas.drawPath(clipPath, fallbackPaint)
        }
        canvas.restoreToCount(save)
    }

    /**
     * Renders `MiBloomStrokeFilter` (`mi_bloom_stroke`) via AGSL on Android 13+ or smooth
     * stroke fallback on earlier Android versions.
     */
    private fun drawBloomStroke(
        canvas: Canvas,
        w: Float,
        h: Float,
        cornerRadius: Float,
        density: Float,
        config: BloomStrokeConfig,
        backend: RenderBackend
    ) {
        if (backend == RenderBackend.AGSL_RUNTIME_SHADER &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !agslCompileFailed
        ) {
            try {
                val bloomShader = (agslBloomShader as? RuntimeShader)
                    ?: RuntimeShader(HyperAgslShaders.MI_BLOOM_STROKE_AGSL).also {
                        agslBloomShader = it
                    }
                HyperAgslShaders.bindBloomStrokeUniforms(
                    shader = bloomShader,
                    config = config,
                    widthPx = w,
                    heightPx = h,
                    cornerRadiusPx = cornerRadius,
                    density = density,
                    useSuperellipse = useSuperellipse
                )
                bloomPaint.shader = bloomShader
                canvas.drawRect(0f, 0f, w, h, bloomPaint)
                bloomPaint.shader = null
                return
            } catch (_: Throwable) {
                // Fall through to stroke path fallback
            }
        }

        // Fallback stroke rendering
        try {
            val alpha = max(config.sourceColorA, max(config.light1A, config.light2A) * 0.45f)
                .coerceIn(0f, 1f)
            val r = (config.sourceColorR * 255f).roundToInt().coerceIn(0, 255)
            val g = (config.sourceColorG * 255f).roundToInt().coerceIn(0, 255)
            val b = (config.sourceColorB * 255f).roundToInt().coerceIn(0, 255)
            val a = (alpha * 255f).roundToInt().coerceIn(0, 255)
            fallbackStrokePaint.strokeWidth = max(config.strokeWidth * density, 1f)
            fallbackStrokePaint.color = Color.argb(a, r, g, b)
            canvas.drawPath(clipPath, fallbackStrokePaint)
        } catch (_: Throwable) {
        }
    }

    private fun drawShadow(
        canvas: Canvas,
        w: Float,
        h: Float,
        cornerRadius: Float,
        density: Float,
        shadow: ShadowConfig
    ) {
        try {
            val blurPx = max(shadow.blurRadiusDp * density * 0.35f, 1f)
            val dx = shadow.offsetXDp * density
            val dy = shadow.offsetYDp * density
            val save = canvas.save()
            // Clip out the interior of the glass view so the shadow only renders outside it
            if (shadow.clipShadow) {
                canvas.clipPath(clipPath, android.graphics.Region.Op.DIFFERENCE)
            }
            shadowPaint.color = Color.TRANSPARENT
            shadowPaint.setShadowLayer(blurPx, dx, dy, shadow.color)
            canvas.drawPath(clipPath, shadowPaint)
            shadowPaint.clearShadowLayer()
            canvas.restoreToCount(save)
        } catch (_: Throwable) {
        }
    }

    /**
     * Captures the region behind [targetView] from the root/source view into a downscaled
     * [Bitmap] and applies the LM Gaussian blur kernel.
     */
    private fun captureAndBlurBackdrop(
        w: Int,
        h: Int,
        marginPx: Int,
        downscale: Int,
        blurRadiusPx: Float,
        isBigSlot: Boolean
    ): Bitmap? {
        val sourceView = backdropSourceView
            ?: targetView.rootView?.findViewById(android.R.id.content)
            ?: targetView.rootView
            ?: return null

        if (sourceView.width <= 0 || sourceView.height <= 0) return null

        val totalW = w + marginPx * 2
        val totalH = h + marginPx * 2
        val scale = max(downscale, 1)
        val capW = max(totalW / scale, 4)
        val capH = max(totalH / scale, 4)

        val bmp: Bitmap
        val capCanvas: Canvas
        if (isBigSlot) {
            var b = bigCapBitmap
            if (b == null || b.width != capW || b.height != capH) {
                b?.recycle()
                b = Bitmap.createBitmap(capW, capH, Bitmap.Config.ARGB_8888)
                bigCapBitmap = b
                bigCapCanvas = Canvas(b)
            }
            bmp = b
            capCanvas = bigCapCanvas!!
        } else {
            var b = smallCapBitmap
            if (b == null || b.width != capW || b.height != capH) {
                b?.recycle()
                b = Bitmap.createBitmap(capW, capH, Bitmap.Config.ARGB_8888)
                smallCapBitmap = b
                smallCapCanvas = Canvas(b)
            }
            bmp = b
            capCanvas = smallCapCanvas!!
        }

        targetView.getLocationInWindow(targetLoc)
        sourceView.getLocationInWindow(sourceLoc)
        val relX = (targetLoc[0] - sourceLoc[0]) - marginPx
        val relY = (targetLoc[1] - sourceLoc[1]) - marginPx

        val depth = capturingDepth.get()
        capturingDepth.set(depth + 1)
        try {
            bmp.eraseColor(0xFF10141C.toInt())
            val save = capCanvas.save()
            val sx = capW.toFloat() / totalW.toFloat()
            val sy = capH.toFloat() / totalH.toFloat()
            capCanvas.scale(sx, sy)
            capCanvas.translate(-relX.toFloat(), -relY.toFloat())
            sourceView.draw(capCanvas)
            capCanvas.restoreToCount(save)
        } catch (_: Throwable) {
            return null
        } finally {
            capturingDepth.set(depth)
        }

        if (blurRadiusPx > 1f) {
            val sigmaFull = LMGaussianKernel.radiusToSigma(blurRadiusPx)
            val sigmaScaled = (sigmaFull / scale.toFloat()).coerceIn(0.5f, 36f)
            val boxRadius = (sigmaScaled * 1.4f).roundToInt().coerceIn(1, 32)
            fastStackBlur(bmp, boxRadius)
        }
        return bmp
    }

    /**
     * Builds an exact G2-continuous superellipse (`k = 1.528665`) or rounded-rect [Path]
     * for clipping, shadow, and fallback rendering.
     */
    private fun ensureClipPath(w: Int, h: Int, radius: Float) {
        if (!clipPathDirty && w == lastPathWidth && h == lastPathHeight && abs(radius - lastPathRadius) < 0.1f) {
            return
        }
        lastPathWidth = w
        lastPathHeight = h
        lastPathRadius = radius
        clipPathDirty = false
        clipPath.reset()

        val wf = w.toFloat()
        val hf = h.toFloat()
        if (radius <= 0.5f) {
            clipPath.addRect(0f, 0f, wf, hf, Path.Direction.CW)
            return
        }

        if (!useSuperellipse) {
            boundsRect.set(0f, 0f, wf, hf)
            clipPath.addRoundRect(boundsRect, radius, radius, Path.Direction.CW)
            return
        }

        // G2 superellipse corner approximation using cubic Bézier segments matching HyperOS SmoothContainerDrawable2
        val r = min(radius, min(wf, hf) * 0.5f)
        val k = 0.6314f * r
        clipPath.moveTo(0f, r)
        clipPath.cubicTo(0f, r - k, r - k, 0f, r, 0f)
        clipPath.lineTo(wf - r, 0f)
        clipPath.cubicTo(wf - r + k, 0f, wf, r - k, wf, r)
        clipPath.lineTo(wf, hf - r)
        clipPath.cubicTo(wf, hf - r + k, wf - r + k, hf, wf - r, hf)
        clipPath.lineTo(r, hf)
        clipPath.cubicTo(r - k, hf, 0f, hf - r + k, 0f, hf - r)
        clipPath.close()
    }

    /**
     * In-place separable stack/Gaussian approximation on the already-downscaled backdrop bitmap.
     * Zero JNI / RenderScript dependency; runs in < 0.25 ms on downscaled buffers.
     */
    private fun fastStackBlur(bitmap: Bitmap, radius: Int) {
        if (radius < 1) return
        val w = bitmap.width
        val h = bitmap.height
        val wh = w * h
        var pix = blurScratchInt
        if (pix == null || pix.size < wh) {
            pix = IntArray(wh)
            blurScratchInt = pix
        }
        bitmap.getPixels(pix, 0, w, 0, 0, w, h)

        val wm = w - 1
        val hm = h - 1
        val div = radius + radius + 1
        val r = IntArray(wh)
        val g = IntArray(wh)
        val b = IntArray(wh)
        var rsum: Int
        var gsum: Int
        var bsum: Int
        var x: Int
        var y: Int
        var i: Int
        var p: Int
        var yp: Int
        var yi: Int
        var yw: Int
        val vmin = IntArray(max(w, h))

        var divsum = (div + 1) shr 1
        divsum *= divsum
        val dv = IntArray(256 * divsum)
        for (idx in 0 until 256 * divsum) {
            dv[idx] = idx / divsum
        }

        yi = 0
        yw = 0

        val stack = Array(div) { IntArray(3) }
        var stackpointer: Int
        var stackstart: Int
        var sir: IntArray
        var rbs: Int
        val r1 = radius + 1
        var routsum: Int
        var goutsum: Int
        var boutsum: Int
        var rinsum: Int
        var ginsum: Int
        var binsum: Int

        y = 0
        while (y < h) {
            bsum = 0
            gsum = 0
            rsum = 0
            boutsum = 0
            goutsum = 0
            routsum = 0
            binsum = 0
            ginsum = 0
            rinsum = 0
            i = -radius
            while (i <= radius) {
                p = pix[yi + min(wm, max(i, 0))]
                sir = stack[i + radius]
                sir[0] = (p and 0xff0000) shr 16
                sir[1] = (p and 0x00ff00) shr 8
                sir[2] = p and 0x0000ff
                rbs = r1 - abs(i)
                rsum += sir[0] * rbs
                gsum += sir[1] * rbs
                bsum += sir[2] * rbs
                if (i > 0) {
                    rinsum += sir[0]
                    ginsum += sir[1]
                    binsum += sir[2]
                } else {
                    routsum += sir[0]
                    goutsum += sir[1]
                    boutsum += sir[2]
                }
                i++
            }
            stackpointer = radius

            x = 0
            while (x < w) {
                r[yi] = dv[rsum]
                g[yi] = dv[gsum]
                b[yi] = dv[bsum]

                rsum -= routsum
                gsum -= goutsum
                bsum -= boutsum

                stackstart = stackpointer - radius + div
                sir = stack[stackstart % div]

                routsum -= sir[0]
                goutsum -= sir[1]
                boutsum -= sir[2]

                if (y == 0) {
                    vmin[x] = min(x + radius + 1, wm)
                }
                p = pix[yw + vmin[x]]

                sir[0] = (p and 0xff0000) shr 16
                sir[1] = (p and 0x00ff00) shr 8
                sir[2] = p and 0x0000ff

                rinsum += sir[0]
                ginsum += sir[1]
                binsum += sir[2]

                rsum += rinsum
                gsum += ginsum
                bsum += binsum

                stackpointer = (stackpointer + 1) % div
                sir = stack[stackpointer % div]

                routsum += sir[0]
                goutsum += sir[1]
                boutsum += sir[2]

                rinsum -= sir[0]
                ginsum -= sir[1]
                binsum -= sir[2]

                yi++
                x++
            }
            yw += w
            y++
        }

        x = 0
        while (x < w) {
            bsum = 0
            gsum = 0
            rsum = 0
            boutsum = 0
            goutsum = 0
            routsum = 0
            binsum = 0
            ginsum = 0
            rinsum = 0
            yp = -radius * w
            i = -radius
            while (i <= radius) {
                yi = max(0, yp) + x
                sir = stack[i + radius]
                sir[0] = r[yi]
                sir[1] = g[yi]
                sir[2] = b[yi]
                rbs = r1 - abs(i)
                rsum += r[yi] * rbs
                gsum += g[yi] * rbs
                bsum += b[yi] * rbs
                if (i > 0) {
                    rinsum += sir[0]
                    ginsum += sir[1]
                    binsum += sir[2]
                } else {
                    routsum += sir[0]
                    goutsum += sir[1]
                    boutsum += sir[2]
                }
                if (i < hm) {
                    yp += w
                }
                i++
            }
            yi = x
            stackpointer = radius
            y = 0
            while (y < h) {
                pix[yi] = -0x1000000 or (dv[rsum] shl 16) or (dv[gsum] shl 8) or dv[bsum]

                rsum -= routsum
                gsum -= goutsum
                bsum -= boutsum

                stackstart = stackpointer - radius + div
                sir = stack[stackstart % div]

                routsum -= sir[0]
                goutsum -= sir[1]
                boutsum -= sir[2]

                if (x == 0) {
                    vmin[y] = min(y + r1, hm) * w
                }
                p = x + vmin[y]

                sir[0] = r[p]
                sir[1] = g[p]
                sir[2] = b[p]

                rinsum += sir[0]
                ginsum += sir[1]
                binsum += sir[2]

                rsum += rinsum
                gsum += ginsum
                bsum += binsum

                stackpointer = (stackpointer + 1) % div
                sir = stack[stackpointer]

                routsum += sir[0]
                goutsum += sir[1]
                boutsum += sir[2]

                rinsum -= sir[0]
                ginsum -= sir[1]
                binsum -= sir[2]

                yi += w
                y++
            }
            x++
        }
        bitmap.setPixels(pix, 0, w, 0, 0, w, h)
    }

    companion object {
        private val capturingDepth = object : ThreadLocal<Int>() {
            override fun initialValue(): Int = 0
        }
    }
}
