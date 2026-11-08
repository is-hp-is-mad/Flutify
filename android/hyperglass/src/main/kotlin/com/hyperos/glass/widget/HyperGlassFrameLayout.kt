package com.hyperos.glass.widget

import android.content.Context
import android.graphics.Canvas
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import com.hyperos.glass.R
import com.hyperos.glass.pipeline.HyperGlassPipeline
import com.hyperos.glass.token.BloomStrokeConfig
import com.hyperos.glass.token.BloomStrokeToken
import com.hyperos.glass.token.ColorBlendConfig
import com.hyperos.glass.token.ColorBlendToken
import com.hyperos.glass.token.GlassToken
import com.hyperos.glass.token.MaterialToken
import com.hyperos.glass.token.ShadowConfig
import com.hyperos.glass.token.ShadowToken

/**
 * Standalone custom [FrameLayout] container that renders Xiaomi HyperOS soft-light glass
 * (`mi_glass_v13_f16`), color-blend blur (`mi_blend_blur`), diffuse bloom stroke (`mi_bloom_stroke`),
 * and dispersive shadow in [dispatchDraw] behind its child views.
 */
open class HyperGlassFrameLayout @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : FrameLayout(context, attrs, defStyleAttr) {

    val pipeline = HyperGlassPipeline(this)

    init {
        setWillNotDraw(false)
        if (attrs != null) {
            val a = context.obtainStyledAttributes(attrs, R.styleable.HyperGlassFrameLayout, defStyleAttr, 0)
            try {
                a.getString(R.styleable.HyperGlassFrameLayout_hg_glassToken)?.let { name ->
                    GlassToken.byName(name)?.let { pipeline.glassToken = it }
                }
                a.getString(R.styleable.HyperGlassFrameLayout_hg_blendToken)?.let { name ->
                    ColorBlendToken.byName(name)?.let {
                        pipeline.colorBlendConfig = it
                        if (a.getString(R.styleable.HyperGlassFrameLayout_hg_glassToken) == null) {
                            pipeline.glassToken = null
                        }
                    }
                }
                a.getString(R.styleable.HyperGlassFrameLayout_hg_bloomStrokeToken)?.let { name ->
                    BloomStrokeToken.byName(name)?.let { pipeline.bloomStrokeConfig = it }
                }
                a.getString(R.styleable.HyperGlassFrameLayout_hg_shadowToken)?.let { name ->
                    ShadowToken.byName(name)?.let { pipeline.shadowConfig = it }
                }
                if (a.hasValue(R.styleable.HyperGlassFrameLayout_hg_cornerRadius)) {
                    pipeline.cornerRadiusPx = a.getDimension(R.styleable.HyperGlassFrameLayout_hg_cornerRadius, 0f)
                }
                if (a.hasValue(R.styleable.HyperGlassFrameLayout_hg_blurRadius)) {
                    val px = a.getDimension(R.styleable.HyperGlassFrameLayout_hg_blurRadius, 60f)
                    pipeline.blurRadiusDp = px / resources.displayMetrics.density.coerceAtLeast(1f)
                }
                pipeline.useSuperellipse = a.getBoolean(R.styleable.HyperGlassFrameLayout_hg_useSuperellipse, true)
                pipeline.pressLightEnabled = a.getBoolean(R.styleable.HyperGlassFrameLayout_hg_pressLightEnabled, false)
                if (a.hasValue(R.styleable.HyperGlassFrameLayout_hg_fallbackColor)) {
                    pipeline.fallbackColorOverride = a.getColor(R.styleable.HyperGlassFrameLayout_hg_fallbackColor, 0)
                }
            } finally {
                a.recycle()
            }
        }
    }

    fun setGlassToken(token: GlassToken?) = apply {
        pipeline.glassToken = token
    }

    fun setBlendBlur(config: ColorBlendConfig?, blurRadiusDp: Float = config?.defaultBlurRadiusDp ?: 60f) = apply {
        pipeline.glassToken = null
        pipeline.colorBlendConfig = config
        pipeline.blurRadiusDp = blurRadiusDp
    }

    fun setMaterialToken(material: MaterialToken) = apply {
        pipeline.applyMaterialToken(material, resources.displayMetrics.density.coerceAtLeast(1f))
    }

    fun setBloomStroke(config: BloomStrokeConfig?) = apply {
        pipeline.bloomStrokeConfig = config
    }

    fun setShadow(config: ShadowConfig?) = apply {
        pipeline.shadowConfig = config
    }

    fun setCornerRadiusPx(radiusPx: Float) = apply {
        pipeline.cornerRadiusPx = radiusPx
    }

    fun setCornerRadiusDp(radiusDp: Float) = apply {
        pipeline.cornerRadiusPx = radiusDp * resources.displayMetrics.density
    }

    fun setUseSuperellipse(enabled: Boolean) = apply {
        pipeline.useSuperellipse = enabled
    }

    fun setPressLightEnabled(enabled: Boolean) = apply {
        pipeline.pressLightEnabled = enabled
    }

    fun setBackdropSourceView(source: View?) = apply {
        pipeline.backdropSourceView = source
        invalidate()
    }

    override fun draw(canvas: Canvas) {
        if (pipeline.isCurrentlyCapturing()) return
        super.draw(canvas)
    }

    override fun dispatchDraw(canvas: Canvas) {
        if (pipeline.isCurrentlyCapturing()) return
        pipeline.draw(canvas)
        super.dispatchDraw(canvas)
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        pipeline.onTouchEvent(ev)
        return super.dispatchTouchEvent(ev)
    }
}
