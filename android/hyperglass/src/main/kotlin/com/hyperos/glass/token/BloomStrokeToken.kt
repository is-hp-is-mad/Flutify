package com.hyperos.glass.token

/**
 * Decoupled, standalone localization of Xiaomi HyperOS `miuix.theme.token.BloomStrokeToken`.
 *
 * Defines the 21-dimensional float configuration for `MiBloomStrokeFilter` (directional edge
 * diffuse rim lighting + stroke outline).
 */
class BloomStrokeConfig @JvmOverloads constructor(
    @JvmField val strokeWidth: Float,
    @JvmField val normalWidth: Float,
    @JvmField val sourceColorR: Float,
    @JvmField val sourceColorG: Float,
    @JvmField val sourceColorB: Float,
    @JvmField val sourceColorA: Float,
    @JvmField val texelOffsetX: Float,
    @JvmField val texelOffsetY: Float,
    @JvmField val light1X: Float,
    @JvmField val light1Y: Float,
    @JvmField val light1R: Float,
    @JvmField val light1G: Float,
    @JvmField val light1B: Float,
    @JvmField val light1A: Float,
    @JvmField val light2X: Float,
    @JvmField val light2Y: Float,
    @JvmField val light2Z: Float,
    @JvmField val light2R: Float,
    @JvmField val light2G: Float,
    @JvmField val light2B: Float,
    @JvmField val light2A: Float,
    @JvmField val gradientBorder: Boolean = false
) {
    /**
     * Converts this configuration to the canonical 21-float array originally passed to
     * `View.setMiBloomStroke(float[21])`.
     */
    fun toFloatArray(): FloatArray = floatArrayOf(
        strokeWidth,
        normalWidth,
        sourceColorR,
        sourceColorG,
        sourceColorB,
        sourceColorA,
        texelOffsetX,
        texelOffsetY,
        light1X,
        light1Y,
        light1R,
        light1G,
        light1B,
        light1A,
        light2X,
        light2Y,
        light2Z,
        light2R,
        light2G,
        light2B,
        light2A
    )

    companion object {
        @JvmStatic
        @JvmOverloads
        fun fromFloatArray(a: FloatArray, gradientBorder: Boolean = false): BloomStrokeConfig {
            require(a.size >= 21) { "BloomStrokeConfig requires at least 21 floats, got ${a.size}" }
            return BloomStrokeConfig(
                strokeWidth = a[0],
                normalWidth = a[1],
                sourceColorR = a[2],
                sourceColorG = a[3],
                sourceColorB = a[4],
                sourceColorA = a[5],
                texelOffsetX = a[6],
                texelOffsetY = a[7],
                light1X = a[8],
                light1Y = a[9],
                light1R = a[10],
                light1G = a[11],
                light1B = a[12],
                light1A = a[13],
                light2X = a[14],
                light2Y = a[15],
                light2Z = a[16],
                light2R = a[17],
                light2G = a[18],
                light2B = a[19],
                light2A = a[20],
                gradientBorder = gradientBorder
            )
        }
    }
}

object BloomStrokeToken {
    @JvmField
    val Glass_Stroke_Big_Light = BloomStrokeConfig(
        0.8f, 24.0f, 1.0f, 1.0f, 1.0f, 0.1f, 1.2f, 0.2f,
        0.5f, 0.0f, 1.0f, 1.0f, 1.0f, 0.6f,
        0.5f, 0.9f, -0.5f, 1.0f, 1.0f, 1.0f, 0.05f
    )

    @JvmField
    val Glass_Stroke_Middle_Light = BloomStrokeConfig(
        0.8f, 24.0f, 1.0f, 1.0f, 1.0f, 0.1f, 1.2f, 0.2f,
        0.5f, 0.0f, 1.0f, 1.0f, 1.0f, 0.5f,
        0.7f, 0.8f, 0.0f, 1.0f, 1.0f, 1.0f, 0.3f
    )

    @JvmField
    val Glass_Stroke_Small_Light = BloomStrokeConfig(
        0.8f, 24.0f, 1.0f, 1.0f, 1.0f, 0.05f, 1.2f, 0.2f,
        0.5f, 0.0f, 1.0f, 1.0f, 1.0f, 0.6f,
        0.5f, 0.95f, -0.5f, 1.0f, 1.0f, 1.0f, 0.35f
    )

    @JvmField
    val Glass_Stroke_Big_Dark = BloomStrokeConfig(
        0.8f, 24.0f, 1.0f, 1.0f, 1.0f, 0.1f, 1.2f, 0.2f,
        0.5f, 0.0f, 1.0f, 1.0f, 1.0f, 0.4f,
        0.5f, 0.9f, -0.5f, 1.0f, 1.0f, 1.0f, 0.01f
    )

    @JvmField
    val Glass_Stroke_Middle_Dark = BloomStrokeConfig(
        0.8f, 24.0f, 1.0f, 1.0f, 1.0f, 0.1f, 1.2f, 0.2f,
        0.5f, 0.0f, 1.0f, 1.0f, 1.0f, 0.4f,
        0.7f, 0.8f, 0.0f, 1.0f, 1.0f, 1.0f, 0.2f
    )

    @JvmField
    val Glass_Stroke_Small_Dark = BloomStrokeConfig(
        0.8f, 24.0f, 1.0f, 1.0f, 1.0f, 0.05f, 1.2f, 0.2f,
        0.5f, 0.0f, 1.0f, 1.0f, 1.0f, 0.6f,
        0.5f, 0.95f, -0.36f, 1.0f, 1.0f, 1.0f, 0.25f
    )

    /**
     * Gallery floating bar / MIUIWeather card bloom stroke preset (`BloomStroke.flutter()`).
     */
    @JvmField
    val Flutter_Card_Light = BloomStrokeConfig(
        1.0f, 15.0f, 1.0f, 1.0f, 1.0f, 0.02f, 1.2f, 0.2f,
        0.5f, 0.0f, 1.0f, 1.0f, 1.0f, 0.9f,
        0.5f, 0.9f, -0.36f, 1.0f, 1.0f, 1.0f, 0.3f
    )

    @JvmField
    val ALL_TOKENS: Map<String, BloomStrokeConfig> = linkedMapOf(
        "Glass_Stroke_Big_Light" to Glass_Stroke_Big_Light,
        "Glass_Stroke_Middle_Light" to Glass_Stroke_Middle_Light,
        "Glass_Stroke_Small_Light" to Glass_Stroke_Small_Light,
        "Glass_Stroke_Big_Dark" to Glass_Stroke_Big_Dark,
        "Glass_Stroke_Middle_Dark" to Glass_Stroke_Middle_Dark,
        "Glass_Stroke_Small_Dark" to Glass_Stroke_Small_Dark,
        "Flutter_Card_Light" to Flutter_Card_Light
    )

    @JvmStatic
    fun byName(name: String?): BloomStrokeConfig? =
        if (name.isNullOrBlank()) null else ALL_TOKENS[name]
}
