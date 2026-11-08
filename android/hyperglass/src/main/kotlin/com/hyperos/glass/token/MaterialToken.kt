package com.hyperos.glass.token

/**
 * Decoupled, standalone localization of Xiaomi HyperOS `miuix.theme.token.MaterialToken`,
 * `MaterialDayNightToken`, and `miuix.theme.token.hypermaterial.*` (`Frosted`, `Mask`, `Overlay`, `Info`).
 *
 * Combines a glass or blend-blur effect with optional bloom stroke and shadow.
 */
class MaterialToken @JvmOverloads constructor(
    @JvmField val name: String = "Custom",
    @JvmField val glassToken: GlassToken? = null,
    @JvmField val colorBlendConfig: ColorBlendConfig? = null,
    @JvmField val blurRadiusDp: Float = 60f,
    @JvmField val bloomStrokeConfig: BloomStrokeConfig? = null,
    @JvmField val shadowConfig: ShadowConfig? = null,
    @JvmField val cornerRadiusDp: Float = 24f,
    @JvmField val useSuperellipse: Boolean = true,
    @JvmField val pressLightEnabled: Boolean = false
) {
    class DayNight(
        @JvmField val light: MaterialToken,
        @JvmField val dark: MaterialToken
    ) {
        fun get(isLight: Boolean): MaterialToken = if (isLight) light else dark
    }

    companion object {
        // HyperMaterial Overlay presets (Pill, Dialog, Menu)
        @JvmField
        val Overlay_Pill_Light = MaterialToken(
            name = "Overlay_Pill_Light",
            glassToken = GlassToken.Glass_Bionic_Small_Thin,
            colorBlendConfig = ColorBlendToken.Overlay_Pill_Light,
            blurRadiusDp = 60f,
            bloomStrokeConfig = BloomStrokeToken.Glass_Stroke_Small_Light,
            shadowConfig = ShadowToken.Float_Light
        )

        @JvmField
        val Overlay_Pill_Dark = MaterialToken(
            name = "Overlay_Pill_Dark",
            glassToken = GlassToken.Glass_Bionic_Small_Thin_Dark,
            colorBlendConfig = ColorBlendToken.Overlay_Pill_Dark,
            blurRadiusDp = 60f,
            bloomStrokeConfig = BloomStrokeToken.Glass_Stroke_Small_Dark,
            shadowConfig = ShadowToken.Float_Dark
        )

        @JvmField
        val Overlay_Dialog_Light = MaterialToken(
            name = "Overlay_Dialog_Light",
            colorBlendConfig = ColorBlendToken.Overlay_Dialog_Light,
            blurRadiusDp = 80f,
            bloomStrokeConfig = BloomStrokeToken.Glass_Stroke_Big_Light
        )

        @JvmField
        val Overlay_Dialog_Dark = MaterialToken(
            name = "Overlay_Dialog_Dark",
            colorBlendConfig = ColorBlendToken.Overlay_Dialog_Dark,
            blurRadiusDp = 80f,
            bloomStrokeConfig = BloomStrokeToken.Glass_Stroke_Big_Dark
        )

        @JvmField
        val Overlay_Menu_Light = MaterialToken(
            name = "Overlay_Menu_Light",
            colorBlendConfig = ColorBlendToken.Overlay_Menu_Light,
            blurRadiusDp = 66f,
            bloomStrokeConfig = BloomStrokeToken.Glass_Stroke_Middle_Light,
            shadowConfig = ShadowToken.High_Light
        )

        @JvmField
        val Overlay_Menu_Dark = MaterialToken(
            name = "Overlay_Menu_Dark",
            colorBlendConfig = ColorBlendToken.Overlay_Menu_Dark,
            blurRadiusDp = 66f,
            bloomStrokeConfig = BloomStrokeToken.Glass_Stroke_Middle_Dark,
            shadowConfig = ShadowToken.High_Dark
        )
    }
}
