package com.hyperos.glass.token

import kotlin.math.cos
import kotlin.math.sin

/**
 * Decoupled, standalone localization of Xiaomi HyperOS `miuix.theme.token.GlassToken`.
 *
 * Contains the complete 42-dimensional shader parameter specification, blur radii
 * (`smallBlurRadius` and `bigBlurRadius`), structured builder API, and all 35+ native
 * HyperOS material presets across the three official categories:
 * - **Common** (`Common_*` / `Glass_Common_*`)
 * - **Bionic** (`Bionic_*` / `Glass_Bionic_*`)
 * - **Tint** (`Tint_*` / `Glass_Tint_*`)
 * - **SystemUI** (`Notification_Default`)
 *
 * Zero runtime dependency on `miuix.*` or Xiaomi system framework classes.
 */
class GlassToken @JvmOverloads constructor(
    @JvmField val name: String = "Custom",
    @JvmField val blend: Blend = Blend(),
    @JvmField val inner: Inner = Inner(),
    @JvmField val shape: Shape = Shape(),
    @JvmField val reflect: Reflect = Reflect(),
    @JvmField val directionalLight: DirectionalLight = DirectionalLight(),
    @JvmField val refract: Refract = Refract(),
    @JvmField val blurBg: BlurBg = BlurBg(),
    @JvmField val mask: Mask = Mask(),
    @JvmField val blurRadius: BlurRadius = BlurRadius(40, 500),
    private val rawShaderParamsOverride: FloatArray? = null
) {

    class Blend @JvmOverloads constructor(
        @JvmField var luminanceValues: FloatArray = floatArrayOf(0.5f, 1.0f, 0.8f, 1.2f),
        @JvmField var luminanceFactor: Float = 0.24f,
        @JvmField var saturation: Float = 1.4f,
        @JvmField var brightness: Float = 0.14f,
        @JvmField var darker: Float = 0.2f,
        @JvmField var darkerRange: FloatArray = floatArrayOf(0.6f, 0.9f)
    )

    class Inner @JvmOverloads constructor(
        @JvmField var bottomGlow: Float = 0.01f,
        @JvmField var color: FloatArray = floatArrayOf(1.0f, 1.0f, 1.0f, 0.05f),
        @JvmField var highlight: Float = 0.3f,
        @JvmField var colorMix: Float = 0.5f,
        @JvmField var colorPow: Float = 1.5f,
        @JvmField var alpha: Float = 1.0f
    )

    class Shape @JvmOverloads constructor(
        @JvmField var edgeWidth: Float = 18.0f,
        @JvmField var edgeCurvature: Float = 1.6f,
        @JvmField var thickness: Float = 100.0f
    )

    class Reflect @JvmOverloads constructor(
        @JvmField var offset: Float = 110.0f,
        @JvmField var brightness: Float = 0.8f,
        @JvmField var intensity: Float = 1.0f
    )

    class DirectionalLight @JvmOverloads constructor(
        @JvmField var direction: FloatArray = floatArrayOf(-0.5f, 0.5f, 0.0f),
        @JvmField var intensity: Float = 1.1f,
        @JvmField var oppositeIntensity: Float = 0.5f,
        @JvmField var angle: Float = 0.3f,
        @JvmField var edgePow: Float = 1.0f
    )

    class Refract @JvmOverloads constructor(
        @JvmField var index: Float = 1.4f
    )

    class BlurBg @JvmOverloads constructor(
        @JvmField var saturation: Float = 1.0f,
        @JvmField var brightness: Float = 0.08f
    )

    class Mask @JvmOverloads constructor(
        @JvmField var burn: Float = 0.0f,
        @JvmField var mix: Float = 0.0f
    )

    class BlurRadius @JvmOverloads constructor(
        @JvmField var smallBlurRadius: Int = 40,
        @JvmField var bigBlurRadius: Int = 500
    )

    /**
     * Converts this token into the canonical 42-float array expected by the HyperOS
     * `mi_glass_v13_f16` shader pipeline.
     *
     * Slot layout:
     * - `[0..3]`: `luminanceBezier` (`b0, b1, b2, b3`)
     * - `[4]`: `luminanceFactor` (`uLuminanceAmount`)
     * - `[5]`: `saturation` (`uSaturation`)
     * - `[6]`: `brightness` (`uBrightness`)
     * - `[7]`: `darker` (`uDarker`)
     * - `[8..9]`: `darkerRange` (`uDarkerRange.xy`)
     * - `[10]`: `inner.bottomGlow` (`uInnerBottom`)
     * - `[11..14]`: `inner.color` (`uGlassColor.rgba`)
     * - `[15]`: `inner.highlight` (`uInnerColorWhite`)
     * - `[16]`: `inner.colorMix` (`uInnerColorMix`)
     * - `[17]`: `inner.colorPow` (`uColorPow`)
     * - `[18]`: `inner.alpha` (`uAlpha`)
     * - `[19]`: `shape.edgeWidth` (`uEdgePx`)
     * - `[20]`: `shape.edgeCurvature` (`uEdgePow`)
     * - `[21]`: `shape.thickness` (`uThicknessPx`)
     * - `[22]`: `reflect.offset` (`uReflectOffsetPx`)
     * - `[23]`: `reflect.brightness` (`uReflectionLighten`)
     * - `[24]`: `reflect.intensity` (`uReflectionStrength`)
     * - `[25..27]`: `directionalLight.direction` (`uLightDirection.xyz`)
     * - `[28]`: `directionalLight.intensity` (`uLightIntensity`)
     * - `[29]`: `directionalLight.oppositeIntensity` (`uLightOpposite`)
     * - `[30]`: `directionalLight.angle` (`uLightAngleRange`)
     * - `[31]`: `directionalLight.edgePow` (`uLightEdgePow`)
     * - `[32]`: `refract.index` (`uRefractIOR`)
     * - `[33]`: `blurBg.saturation` (`uBgColorSaturation`)
     * - `[34]`: `blurBg.brightness` (`uBgColorBrightness`)
     * - `[35]`: `mask.burn` (`uBurn`)
     * - `[36]`: `mask.mix` (`uUnshade`)
     * - `[37..41]`: reserved (`0f`)
     */
    fun toShaderParams(): FloatArray {
        rawShaderParamsOverride?.let { return it.copyOf(42) }
        return floatArrayOf(
            blend.luminanceValues[0],
            blend.luminanceValues[1],
            blend.luminanceValues[2],
            blend.luminanceValues[3],
            blend.luminanceFactor,
            blend.saturation,
            blend.brightness,
            blend.darker,
            blend.darkerRange[0],
            blend.darkerRange[1],
            inner.bottomGlow,
            inner.color[0],
            inner.color[1],
            inner.color[2],
            inner.color[3],
            inner.highlight,
            inner.colorMix,
            inner.colorPow,
            inner.alpha,
            shape.edgeWidth,
            shape.edgeCurvature,
            shape.thickness,
            reflect.offset,
            reflect.brightness,
            reflect.intensity,
            directionalLight.direction[0],
            directionalLight.direction[1],
            directionalLight.direction[2],
            directionalLight.intensity,
            directionalLight.oppositeIntensity,
            directionalLight.angle,
            directionalLight.edgePow,
            refract.index,
            blurBg.saturation,
            blurBg.brightness,
            mask.burn,
            mask.mix,
            0.0f,
            0.0f,
            0.0f,
            0.0f,
            0.0f
        )
    }

    /**
     * Computes a graceful degradation ARGB fallback color representing this glass material's
     * inner tint and brightness when hardware shaders are unavailable.
     */
    fun toFallbackArgb(): Int {
        val p = toShaderParams()
        val r = p[11].coerceIn(0f, 1f)
        val g = p[12].coerceIn(0f, 1f)
        val b = p[13].coerceIn(0f, 1f)
        val rawAlpha = (p[14] * p[18]).coerceIn(0.18f, 0.78f)
        val aInt = (rawAlpha * 255f + 0.5f).toInt().coerceIn(0, 255)
        val rInt = (r * 255f + 0.5f).toInt().coerceIn(0, 255)
        val gInt = (g * 255f + 0.5f).toInt().coerceIn(0, 255)
        val bInt = (b * 255f + 0.5f).toInt().coerceIn(0, 255)
        return (aInt shl 24) or (rInt shl 16) or (gInt shl 8) or bInt
    }

    class Builder(private val name: String = "Custom") {
        private val blend = Blend()
        private val inner = Inner()
        private val shape = Shape()
        private val reflect = Reflect()
        private val directionalLight = DirectionalLight()
        private val refract = Refract()
        private val blurBg = BlurBg()
        private val mask = Mask()
        private val blurRadius = BlurRadius()

        fun blend(
            luminanceValues: FloatArray,
            luminanceFactor: Float,
            saturation: Float,
            brightness: Float,
            darker: Float,
            darkerRange: FloatArray
        ) = apply {
            blend.luminanceValues = luminanceValues
            blend.luminanceFactor = luminanceFactor
            blend.saturation = saturation
            blend.brightness = brightness
            blend.darker = darker
            blend.darkerRange = darkerRange
        }

        fun inner(
            bottomGlow: Float,
            color: FloatArray,
            highlight: Float,
            colorMix: Float,
            colorPow: Float,
            alpha: Float
        ) = apply {
            inner.bottomGlow = bottomGlow
            inner.color = color
            inner.highlight = highlight
            inner.colorMix = colorMix
            inner.colorPow = colorPow
            inner.alpha = alpha
        }

        fun innerColor(color: Int) = apply {
            inner.color = intToRgbaFloat(color)
        }

        fun shape(edgeWidth: Float, edgeCurvature: Float, thickness: Float) = apply {
            shape.edgeWidth = edgeWidth
            shape.edgeCurvature = edgeCurvature
            shape.thickness = thickness
        }

        fun reflect(offset: Float, brightness: Float, intensity: Float) = apply {
            reflect.offset = offset
            reflect.brightness = brightness
            reflect.intensity = intensity
        }

        fun directionalLight(
            direction: FloatArray,
            intensity: Float,
            oppositeIntensity: Float,
            angle: Float,
            edgePow: Float
        ) = apply {
            directionalLight.direction = direction
            directionalLight.intensity = intensity
            directionalLight.oppositeIntensity = oppositeIntensity
            directionalLight.angle = angle
            directionalLight.edgePow = edgePow
        }

        fun lightDirectionByAngle(angleDeg: Float) = apply {
            val rad = Math.toRadians(angleDeg.toDouble())
            directionalLight.direction = floatArrayOf(
                cos(rad).toFloat(),
                sin(rad).toFloat(),
                directionalLight.direction[2]
            )
        }

        fun refract(index: Float) = apply {
            refract.index = index
        }

        fun blurBg(saturation: Float, brightness: Float) = apply {
            blurBg.saturation = saturation
            blurBg.brightness = brightness
        }

        fun mask(burn: Float, mix: Float) = apply {
            mask.burn = burn
            mask.mix = mix
        }

        fun blurRadius(smallBlurRadius: Int, bigBlurRadius: Int) = apply {
            blurRadius.smallBlurRadius = smallBlurRadius
            blurRadius.bigBlurRadius = bigBlurRadius
        }

        fun build(): GlassToken = GlassToken(
            name = name,
            blend = blend,
            inner = inner,
            shape = shape,
            reflect = reflect,
            directionalLight = directionalLight,
            refract = refract,
            blurBg = blurBg,
            mask = mask,
            blurRadius = blurRadius
        )
    }

    companion object {
        @JvmStatic
        fun intToRgbaFloat(color: Int): FloatArray = floatArrayOf(
            ((color shr 16) and 0xFF) / 255.0f,
            ((color shr 8) and 0xFF) / 255.0f,
            (color and 0xFF) / 255.0f,
            ((color ushr 24) and 0xFF) / 255.0f
        )

        /**
         * Creates a [GlassToken] directly from a 42-float shader parameter array and blur radii.
         */
        @JvmStatic
        @JvmOverloads
        fun fromShaderParams(
            name: String,
            params: FloatArray,
            smallBlurRadius: Int = 40,
            bigBlurRadius: Int = 500
        ): GlassToken {
            val a = FloatArray(42) { idx -> if (idx < params.size) params[idx] else 0f }
            return GlassToken(
                name = name,
                blend = Blend(
                    luminanceValues = floatArrayOf(a[0], a[1], a[2], a[3]),
                    luminanceFactor = a[4],
                    saturation = a[5],
                    brightness = a[6],
                    darker = a[7],
                    darkerRange = floatArrayOf(a[8], a[9])
                ),
                inner = Inner(
                    bottomGlow = a[10],
                    color = floatArrayOf(a[11], a[12], a[13], a[14]),
                    highlight = a[15],
                    colorMix = a[16],
                    colorPow = a[17],
                    alpha = a[18]
                ),
                shape = Shape(
                    edgeWidth = a[19],
                    edgeCurvature = a[20],
                    thickness = a[21]
                ),
                reflect = Reflect(
                    offset = a[22],
                    brightness = a[23],
                    intensity = a[24]
                ),
                directionalLight = DirectionalLight(
                    direction = floatArrayOf(a[25], a[26], a[27]),
                    intensity = a[28],
                    oppositeIntensity = a[29],
                    angle = a[30],
                    edgePow = a[31]
                ),
                refract = Refract(index = a[32]),
                blurBg = BlurBg(saturation = a[33], brightness = a[34]),
                mask = Mask(burn = a[35], mix = a[36]),
                blurRadius = BlurRadius(smallBlurRadius, bigBlurRadius),
                rawShaderParamsOverride = a
            )
        }

        // =========================================================================================
        // 1. COMMON GLASS TOKENS (15 Native Presets — OS4.0.4.0 & miuix.theme.token.GlassToken)
        // =========================================================================================

        @JvmField
        val Common_Small_Thin: GlassToken = fromShaderParams(
            "Common_Small_Thin",
            floatArrayOf(0.5f, 1f, 0f, 1f, 0.2f, 2f, 0.24f, 0.26f, 0.6f, 0.8f, 0.05f, 1f, 1f, 1f, 0.15f, 0f, 0.4f, 1.5f, 1f, 50f, 4f, 60f, 600f, 2f, 0.6f, -0.4f, 0.6f, -0.8f, 1.4f, 0.8f, 1.4f, 1f, 1.5f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 30,
            bigBlurRadius = 500
        )

        @JvmField
        val Common_Small_Normal: GlassToken = fromShaderParams(
            "Common_Small_Normal",
            floatArrayOf(0f, 2f, 0.5f, 0.8f, 0.15f, 2f, 0.26f, 0.26f, 0.6f, 1f, 0f, 0f, 0f, 0f, 0.42f, 0.15f, 0.4f, 1.2f, 1f, 16f, 1.4f, 100f, 1000f, 0.75f, 1.5f, 0.6f, -1f, 0f, 1f, 1.4f, 0.8f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 150,
            bigBlurRadius = 500
        )

        @JvmField
        val Common_Small_Regular: GlassToken = fromShaderParams(
            "Common_Small_Regular",
            floatArrayOf(0.5f, 1f, 0.8f, 1.2f, 0.24f, 1.4f, 0.14f, 0.2f, 0.6f, 0.9f, 0.01f, 1f, 1f, 1f, 0.05f, 0.3f, 0.5f, 1.5f, 1f, 18f, 1.6f, 100f, 110f, 0.8f, 1f, -0.5f, 0.5f, 0f, 1.1f, 0.5f, 0.3f, 1f, 1.4f, 1f, 0.08f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 8,
            bigBlurRadius = 500
        )

        @JvmField
        val Common_Small_Semibold: GlassToken = fromShaderParams(
            "Common_Small_Semibold",
            floatArrayOf(0.5f, 1f, 0f, 1f, 0.2f, 2.6f, 0.22f, 0.26f, 0.6f, 0.8f, 0.05f, 1f, 1f, 1f, 0f, 0f, 0.4f, 0.97f, 1f, 60f, 4f, 60f, 600f, 2f, 0.8f, -0.5f, 0.5f, -0.8f, 1.2f, 0.8f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 36,
            bigBlurRadius = 500
        )

        @JvmField
        val Common_Small_Bold: GlassToken = fromShaderParams(
            "Common_Small_Bold",
            floatArrayOf(0.42f, 0.22f, 0.24f, 0f, 0.24f, 1.4f, 0.28f, 0.4f, 0.6f, 1f, 0.05f, 1f, 1f, 1f, 0.1f, 0.2f, 0.3f, 1f, 1f, 60f, 4f, 80f, 1200f, 1.2f, 1f, -0.4f, 0.6f, -0.8f, 1.6f, 0.8f, 1.4f, 1f, 4f, 2.6f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 120,
            bigBlurRadius = 120
        )

        @JvmField
        val Common_Medium_Thin_Low: GlassToken = fromShaderParams(
            "Common_Medium_Thin_Low",
            floatArrayOf(0.5f, 1f, 0f, 1f, 0.2f, 1.5f, 0.2f, 0.1f, 0.6f, 0.8f, 0.05f, 1f, 1f, 1f, 0.05f, 0f, 0.3f, 1.2f, 1f, 60f, 4f, 60f, 600f, 1f, 0.6f, -0.4f, 0.6f, -0.8f, 1.2f, 0.8f, 1.4f, 1f, 2f, 1f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 36,
            bigBlurRadius = 500
        )

        @JvmField
        val Common_Medium_Thin_High: GlassToken = fromShaderParams(
            "Common_Medium_Thin_High",
            floatArrayOf(0.5f, 1.6f, 0f, 0.3f, 0.2f, 1.5f, 0.24f, 0.1f, 0.6f, 0.8f, 0.05f, 1f, 1f, 1f, 0.1f, 0f, 0.3f, 1.2f, 1f, 60f, 4f, 60f, 600f, 1f, 0.6f, -0.4f, 0.6f, -0.8f, 0.9f, 0.3f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 36,
            bigBlurRadius = 500
        )

        @JvmField
        val Common_Medium_Regular_Low_Light: GlassToken = fromShaderParams(
            "Common_Medium_Regular_Low_Light",
            floatArrayOf(0.5f, 1f, 0f, 1f, 0.2f, 2f, 0.2f, 0f, 0.6f, 0.8f, 0.04f, 0.9f, 0.9f, 0.9f, 1f, 0f, 1f, 1f, 1f, 60f, 4f, 80f, 600f, 1f, 0.8f, -0.4f, 0.6f, -0.8f, 1.4f, 0.8f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 36,
            bigBlurRadius = 500
        )

        @JvmField
        val Common_Medium_Regular_High_Light: GlassToken = fromShaderParams(
            "Common_Medium_Regular_High_Light",
            floatArrayOf(0.5f, 1f, 0f, 1f, 0.2f, 2f, 0.1f, 0f, 0.6f, 0.8f, 0.02f, 0.9f, 0.9f, 0.9f, 1f, 0f, 1f, 1f, 1f, 60f, 4f, 80f, 600f, 1f, 0.8f, -0.4f, 0.6f, -0.8f, 1.4f, 0.8f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 36,
            bigBlurRadius = 500
        )

        @JvmField
        val Common_Medium_Regular_Dark: GlassToken = fromShaderParams(
            "Common_Medium_Regular_Dark",
            floatArrayOf(0.5f, 1f, 0f, 1f, 0.2f, 3f, 0.2f, 0f, 0.6f, 0.8f, 0.04f, 0.06f, 0.06f, 0.06f, 0.4f, 0f, 0.8f, 1.5f, 1f, 60f, 4f, 80f, 600f, 1f, 0.8f, -0.4f, 0.6f, -0.8f, 2.4f, 1.6f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 36,
            bigBlurRadius = 500
        )

        @JvmField
        val Common_Medium_Bold_Light: GlassToken = fromShaderParams(
            "Common_Medium_Bold_Light",
            floatArrayOf(0.5f, 1f, 0f, 1f, 0.5f, 1.2f, 0.06f, 0.1f, 0.6f, 0.8f, 0.05f, 1f, 1f, 1f, 2f, 0f, 0.3f, 1.2f, 1f, 72f, 4f, 80f, 600f, 1f, 0.8f, -0.4f, 0.6f, -0.8f, 1f, 0.6f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 40,
            bigBlurRadius = 500
        )

        @JvmField
        val Common_Medium_Bold_Dark: GlassToken = fromShaderParams(
            "Common_Medium_Bold_Dark",
            floatArrayOf(0.5f, 1f, 0f, 1f, 0.2f, 2f, 0.14f, 0.1f, 0.6f, 0.8f, 0.02f, 0.27f, 0.27f, 0.27f, 0.6f, 0f, 0.2f, 1.2f, 1f, 72f, 4f, 80f, 600f, 1f, 0.8f, -0.4f, 0.6f, -0.8f, 3f, 2f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 40,
            bigBlurRadius = 500
        )

        @JvmField
        val Common_Medium_Bold_Low: GlassToken = fromShaderParams(
            "Common_Medium_Bold_Low",
            floatArrayOf(2f, 2f, 0.5f, 0.8f, 0.2f, 1.2f, 0f, 0.4f, 0.6f, 1f, 0.02f, 1f, 1f, 1f, 0.1f, 0.26f, 0.3f, 1.8f, 1f, 50f, 4f, 80f, 1000f, 1f, 0.8f, -0.4f, 0.6f, -0.8f, 0.8f, 0.6f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 40,
            bigBlurRadius = 500
        )

        @JvmField
        val Common_Large_Regular: GlassToken = fromShaderParams(
            "Common_Large_Regular",
            floatArrayOf(0f, 2f, 0.5f, 0.8f, 0.15f, 2.2f, 0.08f, 0.2f, 0.6f, 1f, 0.05f, 1f, 1f, 1f, 0.1f, 0.15f, 0.4f, 1.2f, 1f, 50f, 4f, 80f, 600f, 1f, 0.8f, -0.6f, 0.6f, -0.8f, 1.6f, 0.8f, 1f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 80,
            bigBlurRadius = 500
        )

        @JvmField
        val Common_Large_Demibold: GlassToken = fromShaderParams(
            "Common_Large_Demibold",
            floatArrayOf(1.55f, 2f, 0.5f, 0.8f, 0.56f, 2f, 0.18f, 0.26f, 0.6f, 1f, 0.05f, 1f, 1f, 1f, 1f, 0.6f, 0.9f, 1.2f, 1f, 50f, 4f, 80f, 600f, 1f, 0.8f, -0.6f, 0.6f, -0.8f, 2f, 1f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 50,
            bigBlurRadius = 500
        )

        // =========================================================================================
        // 2. BIONIC GLASS TOKENS (6 Native Presets)
        // =========================================================================================

        @JvmField
        val Bionic_Medium_Thin: GlassToken = fromShaderParams(
            "Bionic_Medium_Thin",
            floatArrayOf(0f, 2f, 0.5f, 0.8f, 0.15f, 1.4f, 0.08f, 0.2f, 0.6f, 1f, 0.05f, 1f, 1f, 1f, 0.15f, 0.15f, 0.4f, 1.2f, 1f, 60f, 4f, 60f, 1000f, 1f, 0.8f, -0.4f, 0.6f, -0.8f, 1.2f, 0.8f, 1.4f, 1f, 3f, 2.4f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 40,
            bigBlurRadius = 500
        )

        @JvmField
        val Bionic_Medium_Normal: GlassToken = fromShaderParams(
            "Bionic_Medium_Normal",
            floatArrayOf(0.42f, 0.22f, 0.24f, 0f, 0.24f, 1.4f, -0.02f, 0.3f, 0.6f, 1f, 0.05f, 1f, 1f, 1f, 0.1f, 0.2f, 0.3f, 1f, 1f, 60f, 4f, 80f, 1200f, 1.2f, 1f, -0.4f, 0.6f, -0.8f, 1.6f, 0.8f, 1.4f, 1f, 4f, 2.6f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 120,
            bigBlurRadius = 120
        )

        @JvmField
        val Bionic_Medium_Normal_Motion: GlassToken = fromShaderParams(
            "Bionic_Medium_Normal_Motion",
            floatArrayOf(0.42f, 0.22f, 0.24f, 0f, 0.24f, 1.4f, -0.02f, 0.3f, 0.6f, 1f, 0.05f, 1f, 1f, 1f, 0.1f, 0.2f, 0.3f, 1f, 1f, 60f, 4f, 80f, 1200f, 1.2f, 1f, -0.4f, 0.6f, -0.8f, 1.6f, 0.8f, 1.4f, 1f, 4f, 2.6f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 120,
            bigBlurRadius = 120
        )

        @JvmField
        val Bionic_Medium_Regular: GlassToken = fromShaderParams(
            "Bionic_Medium_Regular",
            floatArrayOf(0.78f, 0.36f, 0f, 1f, 0.3f, 1.8f, -0.18f, 0.1f, 0.6f, 0.8f, 0.1f, 1f, 1f, 1f, 0.15f, 0.16f, 0.3f, 1.1f, 1f, 60f, 4f, 80f, 600f, 1f, 0.8f, -0.4f, 0.6f, -0.8f, 2.6f, 1.2f, 1.4f, 1f, 3f, 2f, -0.2f, 1f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 36,
            bigBlurRadius = 500
        )

        @JvmField
        val Bionic_Medium_Demibold_Motion: GlassToken = fromShaderParams(
            "Bionic_Medium_Demibold_Motion",
            floatArrayOf(0.42f, 0.22f, 0.24f, 0f, 0.2f, 2f, -0.02f, 0.3f, 0.6f, 1f, 0.05f, 1f, 1f, 1f, 0.2f, 0f, 0.2f, 0.4f, 1f, 60f, 4f, 80f, 1200f, 1.2f, 1f, -0.4f, 0.6f, -0.8f, 3f, 2f, 1.4f, 1f, 4f, 2.6f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 120,
            bigBlurRadius = 120
        )

        @JvmField
        val Bionic_Medium_Semibold_Motion: GlassToken = fromShaderParams(
            "Bionic_Medium_Semibold_Motion",
            floatArrayOf(1.3f, 0.64f, 0.24f, 0f, 0.52f, 2f, -0.02f, 0.3f, 0.6f, 1f, 0.05f, 1f, 1f, 1f, 1.4f, 0.15f, 0.9f, 0.4f, 1f, 60f, 4f, 80f, 1200f, 1.2f, 1f, -0.4f, 0.6f, -0.8f, 3f, 2f, 1.4f, 1f, 4f, 2.6f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 120,
            bigBlurRadius = 120
        )

        // =========================================================================================
        // 3. TINT GLASS TOKENS (14 Native Presets)
        // =========================================================================================

        @JvmField
        val Tint_Purple: GlassToken = fromShaderParams(
            "Tint_Purple",
            floatArrayOf(0.5f, 1.2f, 0.06f, 1f, 0.3f, 1f, 0.6f, 0.2f, 0.6f, 0.8f, 0f, 0.44f, 0.37f, 1f, 0.6f, 0.5f, 0.8f, 1.6f, 1f, 60f, 4f, 80f, 600f, 1f, 0.6f, -0.4f, 0.6f, -0.8f, 1.4f, 1f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 36,
            bigBlurRadius = 500
        )

        @JvmField
        val Tint_Orange: GlassToken = fromShaderParams(
            "Tint_Orange",
            floatArrayOf(0.5f, 1.2f, 0.06f, 1f, 0.3f, 1f, 0.6f, 0.2f, 0.6f, 0.8f, 0f, 0.99f, 0.41f, 0.15f, 0.6f, 0.5f, 0.8f, 1.6f, 1f, 60f, 4f, 80f, 600f, 1f, 0.6f, -0.4f, 0.6f, -0.8f, 1f, 0.8f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 36,
            bigBlurRadius = 500
        )

        @JvmField
        val Tint_Blue: GlassToken = fromShaderParams(
            "Tint_Blue",
            floatArrayOf(0.5f, 1.2f, 0.06f, 1f, 0.3f, 1f, 0.6f, 0.2f, 0.6f, 0.8f, 0.05f, 0.35f, 0.45f, 0.65f, 0.8f, 0.5f, 0.6f, 1.45f, 1f, 60f, 4f, 80f, 600f, 0.75f, 0.8f, -0.4f, 0.6f, -0.8f, 1.4f, 1f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 36,
            bigBlurRadius = 500
        )

        @JvmField
        val Tint_Yellow: GlassToken = fromShaderParams(
            "Tint_Yellow",
            floatArrayOf(0.5f, 1.2f, 0.06f, 1f, 0.3f, 1f, 0.6f, 0.2f, 0.6f, 0.8f, 0.05f, 0.99f, 0.78f, 0.15f, 0.6f, 0.5f, 0.6f, 1.45f, 1f, 60f, 4f, 80f, 600f, 0.75f, 0.8f, -0.4f, 0.6f, -0.8f, 1f, 0.6f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 36,
            bigBlurRadius = 500
        )

        @JvmField
        val Tint_Brown: GlassToken = fromShaderParams(
            "Tint_Brown",
            floatArrayOf(0.5f, 1.2f, 0.06f, 1f, 0.3f, 2f, 0.6f, 0.2f, 0.6f, 0.8f, 0.05f, 0.38f, 0.26f, 0.22f, 0.8f, 0.5f, 0.6f, 1.45f, 1f, 60f, 4f, 80f, 600f, 0.75f, 0.8f, -0.4f, 0.6f, -0.8f, 1.8f, 1.2f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 36,
            bigBlurRadius = 500
        )

        @JvmField
        val Tint_Black_Thin: GlassToken = fromShaderParams(
            "Tint_Black_Thin",
            floatArrayOf(0f, 2f, 0.5f, 0.8f, 0.15f, 2f, 0.18f, 0.26f, 0.6f, 1f, 0.05f, 0f, 0f, 0f, 0.3f, 0.15f, 0.4f, 1.2f, 1f, 50f, 4f, 80f, 600f, 1f, 0.8f, -0.6f, 0.6f, -0.8f, 2f, 1.6f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 50,
            bigBlurRadius = 500
        )

        @JvmField
        val Tint_Black_Normal: GlassToken = fromShaderParams(
            "Tint_Black_Normal",
            floatArrayOf(0f, 2f, 0.5f, 0.8f, 0.15f, 2f, 0.3f, 0.2f, 0.6f, 1f, 0.02f, 0.06f, 0.06f, 0.06f, 0.5f, 0.15f, 0.4f, 1.36f, 1f, 72f, 4f, 80f, 1000f, 1.4f, 0.8f, -0.4f, 0.6f, -0.8f, 2.6f, 1.6f, 1.4f, 1f, 3f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 40,
            bigBlurRadius = 500
        )

        @JvmField
        val Tint_Black_Regular: GlassToken = fromShaderParams(
            "Tint_Black_Regular",
            floatArrayOf(0.42f, 0.22f, 0.24f, 0f, 0.2f, 1.4f, 0.1f, 0.3f, 0.6f, 1f, 0.02f, 0.06f, 0.06f, 0.06f, 0.7f, 0.2f, 0.3f, 1f, 1f, 60f, 4f, 80f, 1200f, 1.2f, 1f, -0.4f, 0.6f, -0.8f, 3.4f, 2.6f, 1.4f, 1f, 3f, 4f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 120,
            bigBlurRadius = 120
        )

        @JvmField
        val Tint_Black_Demibold: GlassToken = fromShaderParams(
            "Tint_Black_Demibold",
            floatArrayOf(0f, 2f, 0.5f, 0.8f, 0.15f, 3f, 0.3f, 0.2f, 0.6f, 1f, 0f, 0.06f, 0.06f, 0.06f, 0.6f, 0.15f, 0.4f, 1.36f, 1f, 60f, 4f, 80f, 1000f, 1.2f, 0.6f, -0.4f, 0.6f, -0.8f, 3f, 2f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 40,
            bigBlurRadius = 500
        )

        @JvmField
        val Tint_Black_Heavy: GlassToken = fromShaderParams(
            "Tint_Black_Heavy",
            floatArrayOf(2f, 2f, 0.5f, 0.8f, 0.2f, 1.2f, 0f, 0.4f, 0.6f, 1f, 0.02f, 0.06f, 0.06f, 0.06f, 0.4f, 0.26f, 0.3f, 1.8f, 1f, 72f, 4f, 80f, 1000f, 1f, 0.8f, -0.4f, 0.6f, -0.8f, 1.6f, 1f, 1.4f, 1f, 3f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 40,
            bigBlurRadius = 500
        )

        @JvmField
        val Tint_Red_Motion: GlassToken = fromShaderParams(
            "Tint_Red_Motion",
            floatArrayOf(0.42f, 0.22f, 0.24f, 0f, 0.8f, 2f, 0.2f, 0.6f, 0.6f, 1f, 0.06f, 1f, 0.31f, 0.27f, 1f, 0.3f, 1f, 1.2f, 1f, 60f, 4f, 80f, 1200f, 1.2f, 1f, -0.4f, 0.6f, -0.8f, 3f, 1f, 1.4f, 1f, 4f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 120,
            bigBlurRadius = 120
        )

        @JvmField
        val Tint_Green_Motion: GlassToken = fromShaderParams(
            "Tint_Green_Motion",
            floatArrayOf(0.42f, 0.22f, 0.24f, 0f, 0.8f, 2f, 0.2f, 0.6f, 0.6f, 1f, 0.06f, 0.25f, 0.84f, 0.35f, 1f, 0.3f, 1f, 1.2f, 1f, 60f, 4f, 80f, 1200f, 1.2f, 1f, -0.4f, 0.6f, -0.8f, 3f, 1f, 1.4f, 1f, 4f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 120,
            bigBlurRadius = 120
        )

        @JvmField
        val Tint_Blue_Motion: GlassToken = fromShaderParams(
            "Tint_Blue_Motion",
            floatArrayOf(0.42f, 0.22f, 0.24f, 0f, 0.8f, 2f, 0.2f, 0.6f, 0.6f, 1f, 0.06f, 0.2f, 0.51f, 1f, 1f, 0.3f, 1f, 1.2f, 1f, 60f, 4f, 80f, 1200f, 1.2f, 1f, -0.4f, 0.6f, -0.8f, 3f, 1f, 1.4f, 1f, 4f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 120,
            bigBlurRadius = 120
        )

        @JvmField
        val Tint_Blue_Normal: GlassToken = fromShaderParams(
            "Tint_Blue_Normal",
            floatArrayOf(0.5f, 1f, 0f, 1f, 0.2f, 2f, 1f, 0f, 0.6f, 0.8f, 0f, 0.2f, 0.51f, 1f, 1.5f, 0f, 0.4f, 0.92f, 1f, 60f, 4f, 60f, 600f, 2f, 0.6f, -0.4f, 0.6f, -0.8f, 1f, 0.6f, 1.4f, 1f, 1.5f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
            smallBlurRadius = 30,
            bigBlurRadius = 500
        )

        // =========================================================================================
        // 4. SYSTEMUI & WEATHER PRESETS (Extracted from SystemUI / MIUIWeather)
        // =========================================================================================

        @JvmField
        val Notification_Default: GlassToken = fromShaderParams(
            "Notification_Default",
            floatArrayOf(0.67f, 0.16f, 0.09f, 0.0f, 0.24f, 1.4f, -0.02f, 0.3f, 0.6f, 1.0f, 0.03f, 1.0f, 1.0f, 1.0f, 0.1f, 0.2f, 0.3f, 1.0f, 1.0f, 72.0f, 3.8f, 80.0f, 800.0f, 1.2f, 1.0f, -0.4f, 0.6f, -0.8f, 1.4f, 0.7f, 0.8f, 1.15f, 4.0f, 2.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f),
            smallBlurRadius = 80,
            bigBlurRadius = 500
        )

        @JvmField
        val Weather_Card_Default: GlassToken = fromShaderParams(
            "Weather_Card_Default",
            floatArrayOf(0.5f, 1.0f, 0.8f, 1.2f, 0.24f, 1.6f, 0.14f, 0.2f, 0.6f, 0.9f, 0.01f, 1.0f, 1.0f, 1.0f, 0.05f, 0.3f, 0.5f, 1.5f, 1.0f, 20.0f, 1.6f, 98.22091f, 110.0f, 1.0f, 1.4f, -0.5f, 0.5f, -0.1f, 1.2f, 0.8f, 0.3f, 1.0f, 1.4f, 1.5f, 0.08f, 11.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f),
            smallBlurRadius = 4,
            bigBlurRadius = 1
        )

        // =========================================================================================
        // 5. MIUIX `Glass_*` ALIASES (100% compatibility with miuix.theme.token.GlassToken)
        // =========================================================================================
        @JvmField val Glass_Common_ExtraLarge_Regular: GlassToken = Common_Small_Thin
        @JvmField val Glass_Common_ExtraLarge_Regular_Dark: GlassToken = Common_Small_Normal
        @JvmField val Glass_Common_Large_Regular: GlassToken = Common_Small_Regular
        @JvmField val Glass_Common_Large_Regular_Dark: GlassToken = Common_Small_Semibold
        @JvmField val Glass_Common_Regular: GlassToken = Common_Small_Bold
        @JvmField val Glass_Common_Regular_Dark: GlassToken = Common_Medium_Thin_Low
        @JvmField val Glass_Common_Regular_Thin: GlassToken = Common_Medium_Thin_High
        @JvmField val Glass_Common_Regular_Thin_Dark: GlassToken = Common_Medium_Regular_Low_Light
        @JvmField val Glass_Common_Medium_Regular: GlassToken = Common_Medium_Regular_High_Light
        @JvmField val Glass_Common_Medium_Regular_Dark: GlassToken = Common_Medium_Regular_Dark
        @JvmField val Glass_Common_Small_Regular: GlassToken = Common_Medium_Bold_Light
        @JvmField val Glass_Common_Small_Regular_Dark: GlassToken = Common_Medium_Bold_Dark
        @JvmField val Glass_Common_Small_Thin: GlassToken = Common_Medium_Bold_Low
        @JvmField val Glass_Common_Small_Thin_Dark: GlassToken = Common_Large_Regular
        @JvmField val Glass_Common_Overlay_Dark: GlassToken = Common_Large_Demibold

        @JvmField val Glass_Bionic_Medium_Regular: GlassToken = Bionic_Medium_Thin
        @JvmField val Glass_Bionic_Medium_Regular_Dark: GlassToken = Bionic_Medium_Normal
        @JvmField val Glass_Bionic_Small_Regular: GlassToken = Bionic_Medium_Normal_Motion
        @JvmField val Glass_Bionic_Small_Regular_Dark: GlassToken = Bionic_Medium_Regular
        @JvmField val Glass_Bionic_Small_Thin: GlassToken = Bionic_Medium_Demibold_Motion
        @JvmField val Glass_Bionic_Small_Thin_Dark: GlassToken = Bionic_Medium_Semibold_Motion

        @JvmField val Glass_Tint_Carmine: GlassToken = Tint_Purple
        @JvmField val Glass_Tint_Red: GlassToken = Tint_Orange
        @JvmField val Glass_Tint_Orange: GlassToken = Tint_Blue
        @JvmField val Glass_Tint_Amber: GlassToken = Tint_Yellow
        @JvmField val Glass_Tint_Yellow: GlassToken = Tint_Brown
        @JvmField val Glass_Tint_Lime: GlassToken = Tint_Black_Thin
        @JvmField val Glass_Tint_Green: GlassToken = Tint_Black_Normal
        @JvmField val Glass_Tint_Turquoise: GlassToken = Tint_Black_Regular
        @JvmField val Glass_Tint_Cyan: GlassToken = Tint_Black_Demibold
        @JvmField val Glass_Tint_Blue: GlassToken = Tint_Black_Heavy
        @JvmField val Glass_Tint_Indigo: GlassToken = Tint_Red_Motion
        @JvmField val Glass_Tint_Ultramarine: GlassToken = Tint_Green_Motion
        @JvmField val Glass_Tint_Purple: GlassToken = Tint_Blue_Motion
        @JvmField val Glass_Tint_Magenta: GlassToken = Tint_Blue_Normal

        /**
         * All 35 official named HyperOS glass tokens indexed by name.
         */
        @JvmField
        val ALL_TOKENS: Map<String, GlassToken> = linkedMapOf(
            "Common_Small_Thin" to Common_Small_Thin,
            "Common_Small_Normal" to Common_Small_Normal,
            "Common_Small_Regular" to Common_Small_Regular,
            "Common_Small_Semibold" to Common_Small_Semibold,
            "Common_Small_Bold" to Common_Small_Bold,
            "Common_Medium_Thin_Low" to Common_Medium_Thin_Low,
            "Common_Medium_Thin_High" to Common_Medium_Thin_High,
            "Common_Medium_Regular_Low_Light" to Common_Medium_Regular_Low_Light,
            "Common_Medium_Regular_High_Light" to Common_Medium_Regular_High_Light,
            "Common_Medium_Regular_Dark" to Common_Medium_Regular_Dark,
            "Common_Medium_Bold_Light" to Common_Medium_Bold_Light,
            "Common_Medium_Bold_Dark" to Common_Medium_Bold_Dark,
            "Common_Medium_Bold_Low" to Common_Medium_Bold_Low,
            "Common_Large_Regular" to Common_Large_Regular,
            "Common_Large_Demibold" to Common_Large_Demibold,
            "Bionic_Medium_Thin" to Bionic_Medium_Thin,
            "Bionic_Medium_Normal" to Bionic_Medium_Normal,
            "Bionic_Medium_Normal_Motion" to Bionic_Medium_Normal_Motion,
            "Bionic_Medium_Regular" to Bionic_Medium_Regular,
            "Bionic_Medium_Demibold_Motion" to Bionic_Medium_Demibold_Motion,
            "Bionic_Medium_Semibold_Motion" to Bionic_Medium_Semibold_Motion,
            "Tint_Purple" to Tint_Purple,
            "Tint_Orange" to Tint_Orange,
            "Tint_Blue" to Tint_Blue,
            "Tint_Yellow" to Tint_Yellow,
            "Tint_Brown" to Tint_Brown,
            "Tint_Black_Thin" to Tint_Black_Thin,
            "Tint_Black_Normal" to Tint_Black_Normal,
            "Tint_Black_Regular" to Tint_Black_Regular,
            "Tint_Black_Demibold" to Tint_Black_Demibold,
            "Tint_Black_Heavy" to Tint_Black_Heavy,
            "Tint_Red_Motion" to Tint_Red_Motion,
            "Tint_Green_Motion" to Tint_Green_Motion,
            "Tint_Blue_Motion" to Tint_Blue_Motion,
            "Tint_Blue_Normal" to Tint_Blue_Normal,
            "Notification_Default" to Notification_Default,
            "Weather_Card_Default" to Weather_Card_Default
        )

        @JvmStatic
        fun byName(name: String?): GlassToken? {
            if (name.isNullOrBlank()) return null
            ALL_TOKENS[name]?.let { return it }
            val stripped = name.removePrefix("Glass_")
            return ALL_TOKENS[stripped]
        }
    }
}
