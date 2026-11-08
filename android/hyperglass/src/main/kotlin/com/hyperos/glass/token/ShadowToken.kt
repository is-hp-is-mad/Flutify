package com.hyperos.glass.token

/**
 * Decoupled, standalone localization of Xiaomi HyperOS `miuix.theme.token.ShadowToken`.
 */
class ShadowConfig @JvmOverloads constructor(
    @JvmField val color: Int = 0x1F000000,
    @JvmField val offsetXDp: Float = 0f,
    @JvmField val offsetYDp: Float = 8f,
    @JvmField val blurRadiusDp: Float = 24f,
    @JvmField val dispersion: Float = 1f,
    @JvmField val clipShadow: Boolean = true
)

object ShadowToken {
    @JvmField val Low_Light = ShadowConfig(0x14000000, 0.0f, 3.0f, 15.0f, 1.0f)
    @JvmField val Low_Dark = ShadowConfig(0x66000000, 0.0f, 3.0f, 15.0f, 1.0f)
    @JvmField val Regular_Light = ShadowConfig(0x1F000000, 0.0f, 8.0f, 30.0f, 1.0f)
    @JvmField val Regular_Dark = ShadowConfig(0x66000000, 0.0f, 8.0f, 30.0f, 1.0f)
    @JvmField val High_Light = ShadowConfig(0x2E000000, 0.0f, 20.0f, 50.0f, 0.9f)
    @JvmField val High_Dark = ShadowConfig(0x99000000.toInt(), 0.0f, 20.0f, 50.0f, 0.9f)
    @JvmField val ExtraHigh_Light = ShadowConfig(0x47000000, 0.0f, 40.0f, 100.0f, 0.8f)
    @JvmField val ExtraHigh_Dark = ShadowConfig(0x99000000.toInt(), 0.0f, 40.0f, 100.0f, 0.8f)
    @JvmField val Float_Light = ShadowConfig(0x1F000000, 0.0f, 4.0f, 20.0f, 1.0f)
    @JvmField val Float_Dark = ShadowConfig(0x3D000000, 0.0f, 4.0f, 20.0f, 1.0f)

    @JvmField
    val ALL_TOKENS: Map<String, ShadowConfig> = linkedMapOf(
        "Low_Light" to Low_Light,
        "Low_Dark" to Low_Dark,
        "Regular_Light" to Regular_Light,
        "Regular_Dark" to Regular_Dark,
        "High_Light" to High_Light,
        "High_Dark" to High_Dark,
        "ExtraHigh_Light" to ExtraHigh_Light,
        "ExtraHigh_Dark" to ExtraHigh_Dark,
        "Float_Light" to Float_Light,
        "Float_Dark" to Float_Dark
    )

    @JvmStatic
    fun byName(name: String?): ShadowConfig? =
        if (name.isNullOrBlank()) null else ALL_TOKENS[name]
}
