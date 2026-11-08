package com.flutify.music.flutify_app

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.Point
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.SweepGradient
import android.os.Build
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import com.hyperos.glass.token.BloomStrokeConfig
import com.hyperos.glass.token.ColorBlendConfig
import com.hyperos.glass.token.GlassToken
import com.hyperos.glass.token.ShadowConfig
import com.hyperos.glass.util.HyperGlassCapabilities
import com.hyperos.glass.util.HyperGlassCapabilities.RenderBackend
import com.hyperos.glass.widget.HyperGlassView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Android Host supporting live manual switching between:
 * 1. **小米原生 (`xiaomi_native`)**: Invokes Xiaomi HyperOS ROM private `android.view.View.setMiGlass`
 *    / `setMiBackgroundBlendColors` / `setMiBloomStroke` / `setMiShadow` when present on Xiaomi devices,
 *    with safe crash-protection fallback on non-Xiaomi devices.
 * 2. **小米移植 (`xiaomi_port`)**: Invokes our decoupled universal `:hyperglass` SDK (`HyperGlassView`
 *    + Android 13+ AGSL `RuntimeShader` / Android 12 OpenGL ES 3.0 FBO `HyperGlES30Pipeline`) on ALL Android brands.
 * 3. **纯移植 (`flutter_port`)**: Handled directly in Flutter via `HyperGlassRenderer` `FragmentShader` passes.
 */
object HyperGlassPlugin {
    fun register(engine: FlutterEngine, context: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "hyper_glass/native_rom")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCapabilities" -> {
                        val portBackend = HyperGlassCapabilities.resolveBackend(context, null)
                        result.success(
                            mapOf(
                                "supported" to true,
                                "supportGlass" to true,
                                "xiaomiNativeSupported" to XiaomiRomReflector.isSupportGlass,
                                "hyperOsVersion" to XiaomiRomReflector.hyperOsVersion,
                                "portBackend" to portBackend.name,
                                "forcedPortBackend" to HyperGlassCapabilities.forcedBackend.name,
                                "agslSupported" to HyperGlassCapabilities.isAgslSupported(),
                                "gles30Supported" to HyperGlassCapabilities.isOpenGlEs30Supported(context),
                                "deviceModel" to "${Build.MANUFACTURER} ${Build.MODEL} (Android ${Build.VERSION.RELEASE}, API ${Build.VERSION.SDK_INT})"
                            )
                        )
                    }
                    "setPortBackend" -> {
                        val name = call.argument<String>("backend") ?: "AUTO"
                        val backend = runCatching { RenderBackend.valueOf(name) }.getOrDefault(RenderBackend.AUTO)
                        HyperGlassCapabilities.forcedBackend = backend
                        ActivePlatformViews.invalidateAll()
                        val resolved = HyperGlassCapabilities.resolveBackend(context, null)
                        result.success(
                            mapOf(
                                "forcedPortBackend" to backend.name,
                                "portBackend" to resolved.name
                            )
                        )
                    }
                    "updateSurface" -> {
                        @Suppress("UNCHECKED_CAST")
                        val args = (call.arguments as? Map<String, Any?>).orEmpty()
                        val surfaceKey = (args["surfaceKey"] as? Number)?.toInt()
                        if (surfaceKey != null) {
                            ActivePlatformViews.update(surfaceKey, args)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        engine.platformViewsController.registry.registerViewFactory(
            "hyper_glass/native_view",
            MultiBackendSurfaceFactory()
        )
    }
}

private object ActivePlatformViews {
    private val views = ConcurrentHashMap<Int, MultiBackendPlatformView>()

    fun register(key: Int, view: MultiBackendPlatformView) {
        views[key] = view
    }

    fun unregister(key: Int, view: MultiBackendPlatformView) {
        views.remove(key, view)
    }

    fun update(key: Int, params: Map<String, Any?>) {
        views[key]?.updateParams(params)
    }

    fun invalidateAll() {
        for (v in views.values) {
            v.refreshAll()
        }
    }
}

/**
 * Safe reflection bridge exclusively used when the user manually selects the **"小米原生" (`xiaomi_native`)** mode.
 * Wrapped in `runCatching` so non-Xiaomi phones never throw `ClassNotFoundException` or `NoSuchMethodError`.
 */
private object XiaomiRomReflector {
    private val sysPropGet by lazy {
        runCatching {
            Class.forName("android.os.SystemProperties")
                .getMethod("get", String::class.java, String::class.java)
        }.getOrNull()
    }

    private fun getProp(key: String, def: String = ""): String =
        runCatching { sysPropGet?.invoke(null, key, def) as? String ?: def }.getOrDefault(def)

    val hyperOsVersion: Int by lazy {
        getProp("ro.mi.os.version.code", "0").toIntOrNull() ?: 0
    }

    val isBlurSupported: Boolean by lazy {
        getProp("persist.sys.background_blur_supported", "false").toBoolean()
    }

    val setMiViewMaterialType by lazy {
        runCatching { View::class.java.getMethod("setMiViewMaterialType", Int::class.javaPrimitiveType) }.getOrNull()
    }
    val setMiGlassBlurRadius by lazy {
        runCatching {
            View::class.java.getMethod(
                "setMiGlassBlurRadius",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType
            )
        }.getOrNull()
    }
    val setMiGlass by lazy {
        runCatching { View::class.java.getMethod("setMiGlass", FloatArray::class.java) }.getOrNull()
    }
    val setMiBackgroundBlurMode by lazy {
        runCatching { View::class.java.getMethod("setMiBackgroundBlurMode", Int::class.javaPrimitiveType) }.getOrNull()
    }
    val setMiBackgroundBlurRadius by lazy {
        runCatching { View::class.java.getMethod("setMiBackgroundBlurRadius", Int::class.javaPrimitiveType) }.getOrNull()
    }
    val setMiViewBlurMode by lazy {
        runCatching { View::class.java.getMethod("setMiViewBlurMode", Int::class.javaPrimitiveType) }.getOrNull()
    }
    val setMiBackgroundBlurType by lazy {
        runCatching { View::class.java.getMethod("setMiBackgroundBlurType", Int::class.javaPrimitiveType) }.getOrNull()
    }
    val setBackgroundGradientBlurParams by lazy {
        runCatching {
            View::class.java.getMethod(
                "setBackgroundGradientBlurParams",
                FloatArray::class.java,
                Int::class.javaPrimitiveType
            )
        }.getOrNull()
    }
    val setMiBackgroundBlendColors by lazy {
        runCatching { View::class.java.getMethod("setMiBackgroundBlendColors", ArrayList::class.java) }.getOrNull()
    }
    val setMiBloomStroke by lazy {
        runCatching { View::class.java.getMethod("setMiBloomStroke", FloatArray::class.java) }.getOrNull()
    }
    val setMiShadow by lazy {
        runCatching {
            View::class.java.getMethod(
                "setMiShadow",
                Int::class.javaPrimitiveType,
                Float::class.javaPrimitiveType,
                Float::class.javaPrimitiveType,
                Float::class.javaPrimitiveType,
                Float::class.javaPrimitiveType
            )
        }.getOrNull()
    }

    val isSupportGlass: Boolean by lazy {
        isBlurSupported && setMiGlass != null
    }
}

private class MultiBackendSurfaceFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = (args as? Map<String, Any?>).orEmpty()
        return MultiBackendPlatformView(context, params)
    }
}

/**
 * Draws the procedural scene wallpaper inside the Android View hierarchy so that both
 * **小米原生 (`View.setMiGlass`)** and **小米移植 (`HyperGlassView`)** have the exact
 * scene backdrop behind them in Android space.
 */
private class AndroidProceduralWallpaperView(context: Context) : View(context) {
    var wallpaperIndex: Int = 1
    var isDark: Boolean = false
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val arcPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val loc = IntArray(2)
    private val arcRect = RectF()

    private val palettes = arrayOf(
        intArrayOf(0xFF2B64D8.toInt(), 0xFF72B6FF.toInt(), 0xFFFFB37E.toInt(), 0xFFFF6F91.toInt(), 0xFF8C6BFF.toInt()),
        intArrayOf(0xFF04213F.toInt(), 0xFF0A6EA8.toInt(), 0xFF19C4C4.toInt(), 0xFF2B3F9E.toInt(), 0xFF77FFD1.toInt()),
        intArrayOf(0xFF0F1D3A.toInt(), 0xFF1FBF8F.toInt(), 0xFF4F7CFF.toInt(), 0xFFA24BFF.toInt(), 0xFF9DFFB0.toInt()),
        intArrayOf(0xFF5A2410.toInt(), 0xFFFF9A3D.toInt(), 0xFFFFD76A.toInt(), 0xFFD8435A.toInt(), 0xFFFFF0C0.toInt()),
        intArrayOf(0xFF0F3F8C.toInt(), 0xFF2A78D6.toInt(), 0xFF6FB1EE.toInt(), 0xFF3A6FD8.toInt(), 0xFF5A8CF0.toInt())
    )

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val dm = resources.displayMetrics
        val screenW = dm.widthPixels.coerceAtLeast(width.coerceAtLeast(1)).toFloat()
        val screenH = dm.heightPixels.coerceAtLeast(height.coerceAtLeast(1)).toFloat()
        getLocationOnScreen(loc)
        val save = canvas.save()
        canvas.translate(-loc[0].toFloat(), -loc[1].toFloat())

        val idx = (wallpaperIndex % palettes.size + palettes.size) % palettes.size
        if (idx == 0) {
            drawCrescents(canvas, screenW, screenH)
        } else {
            val p = palettes[idx]
            paint.shader = LinearGradient(
                0f, 0f, 0f, screenH,
                intArrayOf(p[0], p[1], p[2]),
                floatArrayOf(0f, 0.5f, 1f),
                Shader.TileMode.CLAMP
            )
            canvas.drawRect(0f, 0f, screenW, screenH, paint)
            paint.shader = null

            val shortest = min(screenW, screenH)
            drawBlob(canvas, screenW * 0.2f, screenH * 0.30f, shortest * 0.95f, p[3])
            drawBlob(canvas, screenW * 0.85f, screenH * 0.50f, shortest * 0.90f, p[4])
            drawBlob(canvas, screenW * 0.40f, screenH * 0.88f, shortest * 1.05f, p[2])

            arcPaint.strokeWidth = screenW * 0.14f
            for (i in 0 until 3) {
                val cx = screenW * (0.75f - i * 0.28f)
                val cy = screenH * (0.32f + i * 0.24f)
                val r = screenW * (0.40f + i * 0.1f)
                arcRect.set(cx - r, cy - r, cx + r, cy + r)
                arcPaint.color = Color.argb(36 + i * 8, 255, 255, 255)
                canvas.drawArc(arcRect, (i * 110).toFloat(), 200f, false, arcPaint)
            }
            if (isDark) {
                paint.color = 0x8C000000.toInt()
                canvas.drawRect(0f, 0f, screenW, screenH, paint)
            }
        }
        canvas.restoreToCount(save)
    }

    private fun drawBlob(canvas: Canvas, cx: Float, cy: Float, r: Float, color: Int) {
        if (r <= 1f) return
        paint.shader = RadialGradient(
            cx, cy, r,
            intArrayOf(color, color and 0x00FFFFFF),
            floatArrayOf(0f, 1f),
            Shader.TileMode.CLAMP
        )
        canvas.drawCircle(cx, cy, r, paint)
        paint.shader = null
    }

    private fun drawCrescents(canvas: Canvas, w: Float, h: Float) {
        canvas.drawColor(0xFF040807.toInt())
        drawCrescent(
            canvas,
            w * 0.56f, h * 0.36f, w * 0.74f,
            w * 0.68f, h * 0.42f, w * 0.68f,
            intArrayOf(
                0xFF0FD27A.toInt(),
                0xFFE6F25A.toInt(),
                0xFF14B8FF.toInt(),
                0xFF5A3DFF.toInt(),
                0xFF0FD27A.toInt()
            )
        )
        drawCrescent(
            canvas,
            w * 0.20f, h * 0.86f, w * 0.62f,
            w * 0.08f, h * 0.92f, w * 0.56f,
            intArrayOf(
                0xFFFF4D8D.toInt(),
                0xFF7A3DFF.toInt(),
                0xFF14B8FF.toInt(),
                0xFFFF9D3D.toInt(),
                0xFFFF4D8D.toInt()
            )
        )
        if (isDark) {
            paint.color = 0x40000000
            canvas.drawRect(0f, 0f, w, h, paint)
        }
    }

    private fun drawCrescent(
        canvas: Canvas,
        litX: Float, litY: Float, r: Float,
        cutX: Float, cutY: Float, cutR: Float,
        colors: IntArray
    ) {
        paint.shader = SweepGradient(litX, litY, colors, null)
        canvas.drawCircle(litX, litY, r, paint)
        paint.shader = RadialGradient(
            cutX, cutY, cutR.coerceAtLeast(1f),
            intArrayOf(0xFF0B1411.toInt(), 0xFF040807.toInt()),
            floatArrayOf(0f, 1f),
            Shader.TileMode.CLAMP
        )
        canvas.drawCircle(cutX, cutY, cutR, paint)
        paint.shader = null
    }
}

/**
 * PlatformView container that switches between:
 * - `xiaomi_native` (Xiaomi ROM `View.setMiGlass` reflection + non-Xiaomi safe fallback)
 * - `xiaomi_port` (Decoupled Universal `HyperGlassView` from `:hyperglass`)
 */
private class MultiBackendPlatformView(
    context: Context,
    initialParams: Map<String, Any?>
) : FrameLayout(context), PlatformView {

    private val density = context.resources.displayMetrics.density.coerceAtLeast(1f)
    private val wallpaperView = AndroidProceduralWallpaperView(context)
    private val hyperPortView = HyperGlassView(context)
    private val xiaomiNativeView = XiaomiNativeSurfaceView(context)
    private var surfaceKey: Int? = null

    init {
        clipChildren = true
        clipToPadding = true
        addView(wallpaperView, LayoutParams(MATCH_PARENT, MATCH_PARENT))
        hyperPortView.setBackdropSourceView(wallpaperView)
        addView(hyperPortView, LayoutParams(MATCH_PARENT, MATCH_PARENT))
        addView(xiaomiNativeView, LayoutParams(MATCH_PARENT, MATCH_PARENT))
        updateParams(initialParams)
    }

    fun updateParams(params: Map<String, Any?>) {
        (params["surfaceKey"] as? Number)?.toInt()?.let { key ->
            if (surfaceKey != key) {
                surfaceKey?.let { ActivePlatformViews.unregister(it, this) }
                surfaceKey = key
                ActivePlatformViews.register(key, this)
            }
        }

        val radiusDp = (params["borderRadius"] as? Number)?.toFloat() ?: 0f
        val radiusPx = radiusDp * density
        if (radiusPx > 0f) {
            clipToOutline = true
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) {
                    outline.setRoundRect(0, 0, view.width, view.height, radiusPx)
                }
            }
        } else {
            clipToOutline = false
        }

        wallpaperView.wallpaperIndex = (params["wallpaperIndex"] as? Number)?.toInt() ?: 1
        wallpaperView.isDark = (params["dark"] as? Boolean) ?: false
        wallpaperView.invalidate()

        val renderBackend = params["renderBackend"] as? String ?: "xiaomi_port"
        if (renderBackend == "xiaomi_native") {
            hyperPortView.visibility = View.GONE
            xiaomiNativeView.visibility = View.VISIBLE
            xiaomiNativeView.applyRomParams(params, radiusDp)
        } else {
            xiaomiNativeView.visibility = View.GONE
            hyperPortView.visibility = View.VISIBLE
            applyPortParams(params, radiusDp)
        }
    }

    private fun applyPortParams(params: Map<String, Any?>, radiusDp: Float) {
        val mode = params["mode"] as? String ?: "glass"
        hyperPortView.setCornerRadiusDp(radiusDp)
        when (mode) {
            "glass" -> {
                val glassParams = params["glassParams"] as? FloatArray
                val smallBlur = ((params["smallBlur"] as? Number)?.toFloat() ?: 36f).roundToInt()
                val bigBlur = ((params["bigBlur"] as? Number)?.toFloat() ?: 500f).roundToInt()
                val token = if (glassParams != null) {
                    GlassToken.fromShaderParams("PlatformViewGlass", glassParams, smallBlur, bigBlur)
                } else {
                    GlassToken.Common_Large_Regular
                }
                hyperPortView.setGlassToken(token)
            }
            "blend", "gradientBlur" -> {
                val radiusBlurDp = (params["blurRadius"] as? Number)?.toFloat() ?: 40f
                val colors = params["blendColors"] as? IntArray ?: intArrayOf()
                val modes = params["blendModes"] as? IntArray ?: intArrayOf()
                val count = minOf(colors.size, modes.size)
                val config = ColorBlendConfig(
                    name = "PlatformViewBlend",
                    colors = colors.copyOf(count),
                    modes = modes.copyOf(count),
                    defaultBlurRadiusDp = radiusBlurDp
                )
                hyperPortView.setBlendBlur(config, radiusBlurDp)
                hyperPortView.pipeline.gradientMode = if (mode == "gradientBlur") 1 else 0
            }
        }

        val bloomParams = params["bloomParams"] as? FloatArray
        if (bloomParams != null && bloomParams.size >= 21) {
            hyperPortView.setBloomStroke(BloomStrokeConfig.fromFloatArray(bloomParams, gradientBorder = bloomParams[1] >= 90f))
        } else {
            hyperPortView.setBloomStroke(null)
        }

        val shadowColor = (params["shadowColor"] as? Number)?.toInt()
        if (shadowColor != null) {
            val offsetY = (params["shadowOffsetY"] as? Number)?.toFloat() ?: 0f
            val radius = (params["shadowRadius"] as? Number)?.toFloat() ?: 64f
            val dispersion = (params["shadowDispersion"] as? Number)?.toFloat() ?: 0.5f
            hyperPortView.setShadow(
                ShadowConfig(
                    color = shadowColor,
                    offsetXDp = 0f,
                    offsetYDp = offsetY / density,
                    blurRadiusDp = radius / density,
                    dispersion = dispersion
                )
            )
        } else {
            hyperPortView.setShadow(null)
        }
        hyperPortView.invalidate()
    }

    fun refreshAll() {
        wallpaperView.invalidate()
        hyperPortView.invalidate()
        xiaomiNativeView.invalidate()
    }

    override fun getView(): View = this

    override fun dispose() {
        surfaceKey?.let { ActivePlatformViews.unregister(it, this) }
    }
}

/**
 * View used when the user selects **"小米原生" (`xiaomi_native`)**.
 * Invokes Xiaomi's ROM `View.setMiGlass` / `setMiBackgroundBlendColors` / `setMiBloomStroke` via reflection.
 * When running on a non-Xiaomi device where those ROM methods do not exist, safely prevents crashes
 * and draws a fallback glass tint so the user can compare Xiaomi Native vs Universal Port.
 */
private class XiaomiNativeSurfaceView(context: Context) : View(context) {
    private val density = context.resources.displayMetrics.density.coerceAtLeast(1f)
    private val fallbackPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val rectF = RectF()
    private var cornerRadiusPx = 0f
    private var fallbackArgb = 0x4DFFFFFF

    fun applyRomParams(params: Map<String, Any?>, radiusDp: Float) {
        cornerRadiusPx = radiusDp * density
        val mode = params["mode"] as? String ?: "glass"

        if (!XiaomiRomReflector.isSupportGlass) {
            // Non-Xiaomi ROM: compute fallback color from GlassToken or BlendColors without crashing
            val glassParams = params["glassParams"] as? FloatArray
            if (glassParams != null && glassParams.size >= 19) {
                val token = GlassToken.fromShaderParams("Fallback", glassParams)
                fallbackArgb = token.toFallbackArgb()
            } else {
                val colors = params["blendColors"] as? IntArray
                fallbackArgb = if (colors != null && colors.isNotEmpty()) colors.last() else 0x59FFFFFF
            }
            invalidate()
            return
        }

        when (mode) {
            "glass" -> {
                val glassParams = params["glassParams"] as? FloatArray ?: return
                val smallPx = (((params["smallBlur"] as? Number)?.toFloat() ?: 36f) * density).roundToInt()
                val bigPx = (((params["bigBlur"] as? Number)?.toFloat() ?: 500f) * density).roundToInt()
                runCatching {
                    XiaomiRomReflector.setMiViewMaterialType?.invoke(this, 1)
                    XiaomiRomReflector.setMiGlassBlurRadius?.invoke(this, smallPx, bigPx)
                    XiaomiRomReflector.setMiGlass?.invoke(this, glassParams)
                }
            }
            "blend", "gradientBlur" -> {
                val radiusPx = (((params["blurRadius"] as? Number)?.toFloat() ?: 40f) * density).roundToInt()
                val colors = params["blendColors"] as? IntArray
                val modes = params["blendModes"] as? IntArray
                runCatching {
                    XiaomiRomReflector.setMiViewMaterialType?.invoke(this, 0)
                    XiaomiRomReflector.setMiBackgroundBlurMode?.invoke(this, 1)
                    XiaomiRomReflector.setMiViewBlurMode?.invoke(this, 1)
                    if (mode == "gradientBlur") {
                        post {
                            val round = (40f * density).roundToInt().toFloat()
                            val h = height.toFloat()
                            XiaomiRomReflector.setMiBackgroundBlurType?.invoke(this, 2)
                            XiaomiRomReflector.setBackgroundGradientBlurParams?.invoke(
                                this,
                                floatArrayOf(0f, 0f, round, 0f, h, 0f),
                                1
                            )
                        }
                    } else {
                        XiaomiRomReflector.setMiBackgroundBlurType?.invoke(this, 0)
                        XiaomiRomReflector.setMiBackgroundBlurRadius?.invoke(this, radiusPx)
                    }
                    if (colors != null && modes != null) {
                        val list = ArrayList<Point>(colors.size)
                        for (i in 0 until minOf(colors.size, modes.size)) {
                            list.add(Point(colors[i], modes[i]))
                        }
                        XiaomiRomReflector.setMiBackgroundBlendColors?.invoke(this, list)
                    }
                }
            }
        }

        (params["bloomParams"] as? FloatArray)?.let { raw ->
            val scaled = raw.copyOf()
            scaled[0] = (raw[0] * density + 0.5f).toInt().toFloat()
            scaled[6] = (raw[6] * density + 0.5f).toInt().toFloat()
            runCatching { XiaomiRomReflector.setMiBloomStroke?.invoke(this, scaled) }
        }

        (params["shadowColor"] as? Number)?.toInt()?.let { color ->
            val offsetY = (params["shadowOffsetY"] as? Number)?.toFloat() ?: 0f
            val radius = (params["shadowRadius"] as? Number)?.toFloat() ?: 64f
            val dispersion = (params["shadowDispersion"] as? Number)?.toFloat() ?: 0.5f
            runCatching { XiaomiRomReflector.setMiShadow?.invoke(this, color, 0f, offsetY, radius, dispersion) }
        }
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (!XiaomiRomReflector.isSupportGlass) {
            rectF.set(0f, 0f, width.toFloat(), height.toFloat())
            fallbackPaint.color = fallbackArgb
            canvas.drawRoundRect(rectF, cornerRadiusPx, cornerRadiusPx, fallbackPaint)
            strokePaint.strokeWidth = 1f * density
            strokePaint.color = 0x44FFFFFF
            canvas.drawRoundRect(rectF, cornerRadiusPx, cornerRadiusPx, strokePaint)
        }
    }
}
