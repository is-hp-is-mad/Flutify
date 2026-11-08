package com.hyperos.glass

import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.PixelFormat
import android.graphics.drawable.Drawable
import android.view.View
import android.view.ViewTreeObserver
import com.hyperos.glass.pipeline.HyperGlassPipeline
import com.hyperos.glass.token.BloomStrokeConfig
import com.hyperos.glass.token.ColorBlendConfig
import com.hyperos.glass.token.GlassToken
import com.hyperos.glass.token.MaterialToken
import com.hyperos.glass.token.ShadowConfig
import java.util.WeakHashMap

/**
 * Universal static helper to attach Xiaomi HyperOS soft-light glass (`mi_glass_v13_f16`),
 * color-blend blur (`mi_blend_blur`), diffuse bloom stroke (`mi_bloom_stroke`), and dispersive
 * shadow to **any standard Android [View]** (`LinearLayout`, `FrameLayout`, `CardView`,
 * `Button`, `TextView`, etc.) without modifying the View's class hierarchy or relying on
 * Xiaomi ROM framework hooks.
 *
 * ### Quick Example
 * ```kotlin
 * // 1. Attach soft-light glass to any View:
 * HyperGlassHelper.attach(myCardView, GlassToken.Common_Large_Regular)
 *
 * // 2. Attach tinted glass with Bloom diffuse rim stroke:
 * HyperGlassHelper.attach(
 *     target = myFloatingButton,
 *     token = GlassToken.Tint_Purple,
 *     cornerRadiusDp = 28f,
 *     bloomStroke = BloomStrokeToken.Glass_Stroke_Middle_Light,
 *     shadow = ShadowToken.Float_Light
 * )
 * ```
 */
object HyperGlassHelper {

    private val controllers = WeakHashMap<View, Controller>()

    /**
     * Controller handle returned by [attach], allowing dynamic runtime updates to the
     * attached [View]'s material parameters.
     */
    class Controller internal constructor(
        val targetView: View,
        val pipeline: HyperGlassPipeline,
        internal val drawable: HyperGlassBackgroundDrawable
    ) {
        private var preDrawListener: ViewTreeObserver.OnPreDrawListener? = null

        fun setGlassToken(token: GlassToken?) = apply {
            pipeline.glassToken = token
        }

        fun setBlendBlur(config: ColorBlendConfig?, blurRadiusDp: Float = config?.defaultBlurRadiusDp ?: 60f) = apply {
            pipeline.glassToken = null
            pipeline.colorBlendConfig = config
            pipeline.blurRadiusDp = blurRadiusDp
        }

        fun setBloomStroke(config: BloomStrokeConfig?) = apply {
            pipeline.bloomStrokeConfig = config
        }

        fun setShadow(config: ShadowConfig?) = apply {
            pipeline.shadowConfig = config
        }

        fun setCornerRadiusDp(radiusDp: Float) = apply {
            val density = targetView.resources.displayMetrics.density.coerceAtLeast(1f)
            pipeline.cornerRadiusPx = radiusDp * density
        }

        fun setCornerRadiusPx(radiusPx: Float) = apply {
            pipeline.cornerRadiusPx = radiusPx
        }

        fun setUseSuperellipse(enabled: Boolean) = apply {
            pipeline.useSuperellipse = enabled
        }

        fun setPressLightEnabled(enabled: Boolean) = apply {
            pipeline.pressLightEnabled = enabled
            if (enabled) {
                targetView.setOnTouchListener { _, event ->
                    pipeline.onTouchEvent(event)
                    false
                }
            }
        }

        fun setBackdropSourceView(source: View?) = apply {
            pipeline.backdropSourceView = source
            targetView.invalidate()
        }

        /**
         * Enables or disables automatic per-frame backdrop invalidation when background
         * content scrolls or animates beneath [targetView].
         */
        fun setLiveBackdropUpdates(enabled: Boolean) = apply {
            if (enabled && preDrawListener == null) {
                val listener = ViewTreeObserver.OnPreDrawListener {
                    if (targetView.isShown && !pipeline.isCurrentlyCapturing()) {
                        targetView.invalidate()
                    }
                    true
                }
                preDrawListener = listener
                targetView.viewTreeObserver.addOnPreDrawListener(listener)
            } else if (!enabled && preDrawListener != null) {
                targetView.viewTreeObserver.removeOnPreDrawListener(preDrawListener)
                preDrawListener = null
            }
        }
    }

    internal class HyperGlassBackgroundDrawable(
        private val pipeline: HyperGlassPipeline
    ) : Drawable() {
        override fun draw(canvas: Canvas) {
            if (pipeline.isCurrentlyCapturing()) return
            pipeline.draw(canvas)
        }

        override fun setAlpha(alpha: Int) {}
        override fun setColorFilter(colorFilter: ColorFilter?) {}
        @Deprecated("Deprecated in Java")
        override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
    }

    /**
     * Attaches Xiaomi HyperOS soft-light glass ([GlassToken]) to [target].
     */
    @JvmStatic
    @JvmOverloads
    fun attach(
        target: View,
        token: GlassToken = GlassToken.Common_Large_Regular,
        cornerRadiusDp: Float = 24f,
        bloomStroke: BloomStrokeConfig? = null,
        shadow: ShadowConfig? = null,
        useSuperellipse: Boolean = true
    ): Controller {
        val controller = getOrCreateController(target)
        val density = target.resources.displayMetrics.density.coerceAtLeast(1f)
        controller.pipeline.glassToken = token
        controller.pipeline.colorBlendConfig = null
        controller.pipeline.cornerRadiusPx = cornerRadiusDp * density
        controller.pipeline.bloomStrokeConfig = bloomStroke
        controller.pipeline.shadowConfig = shadow
        controller.pipeline.useSuperellipse = useSuperellipse
        target.invalidate()
        return controller
    }

    /**
     * Attaches Xiaomi HyperOS multi-layer color-blend blur ([ColorBlendConfig]) to [target].
     */
    @JvmStatic
    @JvmOverloads
    fun attachBlendBlur(
        target: View,
        blendConfig: ColorBlendConfig,
        blurRadiusDp: Float = blendConfig.defaultBlurRadiusDp,
        cornerRadiusDp: Float = 24f,
        bloomStroke: BloomStrokeConfig? = null,
        shadow: ShadowConfig? = null,
        useSuperellipse: Boolean = true
    ): Controller {
        val controller = getOrCreateController(target)
        val density = target.resources.displayMetrics.density.coerceAtLeast(1f)
        controller.pipeline.glassToken = null
        controller.pipeline.colorBlendConfig = blendConfig
        controller.pipeline.blurRadiusDp = blurRadiusDp
        controller.pipeline.cornerRadiusPx = cornerRadiusDp * density
        controller.pipeline.bloomStrokeConfig = bloomStroke
        controller.pipeline.shadowConfig = shadow
        controller.pipeline.useSuperellipse = useSuperellipse
        target.invalidate()
        return controller
    }

    /**
     * Attaches a composite [MaterialToken] (Glass or BlendBlur + BloomStroke + Shadow) to [target].
     */
    @JvmStatic
    fun attachMaterial(
        target: View,
        material: MaterialToken
    ): Controller {
        val controller = getOrCreateController(target)
        val density = target.resources.displayMetrics.density.coerceAtLeast(1f)
        controller.pipeline.applyMaterialToken(material, density)
        target.invalidate()
        return controller
    }

    /**
     * Detaches the HyperGlass rendering pipeline from [target].
     */
    @JvmStatic
    fun detach(target: View) {
        val existing = controllers.remove(target) ?: return
        existing.setLiveBackdropUpdates(false)
        if (target.background === existing.drawable) {
            target.background = null
        }
        target.invalidate()
    }

    private fun getOrCreateController(target: View): Controller {
        controllers[target]?.let { return it }
        val pipeline = HyperGlassPipeline(target)
        val drawable = HyperGlassBackgroundDrawable(pipeline)
        target.background = drawable
        val controller = Controller(target, pipeline, drawable)
        controllers[target] = controller
        return controller
    }
}
