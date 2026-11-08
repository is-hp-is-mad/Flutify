package com.hyperos.glass.token

/**
 * Decoupled, standalone localization of Xiaomi HyperOS `miuix.theme.token.ColorBlendToken`.
 *
 * Defines multi-layer color blend configurations (`colors: IntArray`, `modes: IntArray`)
 * applied over Gaussian-blurred backdrops (`mi_blend_blur`).
 */
class ColorBlendConfig @JvmOverloads constructor(
    @JvmField val name: String = "Custom",
    @JvmField val colors: IntArray,
    @JvmField val modes: IntArray,
    @JvmField val defaultBlurRadiusDp: Float = 60f,
    @JvmField val fallbackColorArgb: Int = if (colors.isNotEmpty()) colors.last() else 0xCCFFFFFF.toInt()
) {
    init {
        require(colors.size == modes.size) {
            "colors (${colors.size}) and modes (${modes.size}) must have equal length"
        }
    }

    /**
     * Interleaved `[color0, mode0, color1, mode1, ...]` array matching the format originally
     * passed to `MiuiBlurUtils.setBackgroundBlendColors(view, int[], scale)`.
     */
    fun toInterleavedIntArray(): IntArray {
        val out = IntArray(colors.size * 2)
        for (i in colors.indices) {
            out[i * 2] = colors[i]
            out[i * 2 + 1] = modes[i]
        }
        return out
    }
}

object ColorBlendToken {
    @JvmField
    val Info_Highlight_Light = ColorBlendConfig(
        "Info_Highlight_Light",
        intArrayOf(0x3DB9B9B9, 0xCCFFFFFF.toInt()),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.PLUS_LIGHTER.value)
    )

    @JvmField
    val Info_Normal_Light = ColorBlendConfig(
        "Info_Normal_Light",
        intArrayOf(0xB8919191.toInt(), 0x5CE8E8E8),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.PLUS_LIGHTER.value)
    )

    @JvmField
    val Info_Thin_Light = ColorBlendConfig(
        "Info_Thin_Light",
        intArrayOf(0xD6C2C2C2.toInt(), 0x29E8E8E8),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.PLUS_LIGHTER.value)
    )

    @JvmField
    val Info_Highlight_Dark = ColorBlendConfig(
        "Info_Highlight_Dark",
        intArrayOf(0xADADADAD.toInt(), 0x42383838),
        intArrayOf(BlendModeToken.PLUS_LIGHTER.value, BlendModeToken.PLUS_DARKER.value)
    )

    @JvmField
    val Info_Normal_Dark = ColorBlendConfig(
        "Info_Normal_Dark",
        intArrayOf(0x8F8A8A8A.toInt(), 0x8F1C1C1C.toInt()),
        intArrayOf(BlendModeToken.PLUS_LIGHTER.value, BlendModeToken.PLUS_DARKER.value)
    )

    @JvmField
    val Info_Thin_Dark = ColorBlendConfig(
        "Info_Thin_Dark",
        intArrayOf(0x3D6E6E6E, 0xD61C1C1C.toInt()),
        intArrayOf(BlendModeToken.PLUS_LIGHTER.value, BlendModeToken.PLUS_DARKER.value)
    )

    @JvmField
    val Colored_Thin_Light = ColorBlendConfig(
        "Colored_Thin_Light",
        intArrayOf(0xB8DEDEDE.toInt(), 0x8FFFFFFF.toInt()),
        intArrayOf(BlendModeToken.LINEAR_BURN.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 30f
    )

    @JvmField
    val Colored_Thin_Dark = ColorBlendConfig(
        "Colored_Thin_Dark",
        intArrayOf(0x805C5C5C.toInt(), 0xB21F1F1F.toInt()),
        intArrayOf(BlendModeToken.LINEAR_DODGE.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 30f
    )

    @JvmField
    val Colored_Regular_Light = ColorBlendConfig(
        "Colored_Regular_Light",
        intArrayOf(0x9EE0E0E0.toInt(), 0xB8F5F5F5.toInt()),
        intArrayOf(BlendModeToken.LINEAR_BURN.value, BlendModeToken.SRC_OVER.value)
    )

    @JvmField
    val Colored_Regular_Dark = ColorBlendConfig(
        "Colored_Regular_Dark",
        intArrayOf(0xA6525252.toInt(), 0xAD242424.toInt()),
        intArrayOf(BlendModeToken.LINEAR_DODGE.value, BlendModeToken.SRC_OVER.value)
    )

    @JvmField
    val Colored_Thick_Light = ColorBlendConfig(
        "Colored_Thick_Light",
        intArrayOf(0x7FA8A8A8, 0xD1FFFFFF.toInt()),
        intArrayOf(BlendModeToken.LINEAR_BURN.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 100f
    )

    @JvmField
    val Colored_Thick_Dark = ColorBlendConfig(
        "Colored_Thick_Dark",
        intArrayOf(0xBF616161.toInt(), 0xC2202020.toInt()),
        intArrayOf(BlendModeToken.LINEAR_DODGE.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 100f
    )

    @JvmField
    val Pured_ExtraThin_Light = ColorBlendConfig(
        "Pured_ExtraThin_Light",
        intArrayOf(0x285E5E5E, 0x4CFFFFFF),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 10f
    )

    @JvmField
    val Pured_ExtraThin_Dark = ColorBlendConfig(
        "Pured_ExtraThin_Dark",
        intArrayOf(0x21949494, 0x59000000),
        intArrayOf(BlendModeToken.PLUS_LIGHTER.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 10f
    )

    @JvmField
    val Pured_Thin_Light = ColorBlendConfig(
        "Pured_Thin_Light",
        intArrayOf(0x33757575, 0x80F2F2F2.toInt()),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 30f
    )

    @JvmField
    val Pured_Thin_Dark = ColorBlendConfig(
        "Pured_Thin_Dark",
        intArrayOf(0x3D808080, 0x802E2E2E.toInt()),
        intArrayOf(BlendModeToken.PLUS_LIGHTER.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 30f
    )

    @JvmField
    val Pured_Thin_Glass_Light = ColorBlendConfig(
        "Pured_Thin_Glass_Light",
        intArrayOf(0x1F525252, 0xB8FFFFFF.toInt(), 0x05000000),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.HARD_LIGHT.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 60f
    )

    @JvmField
    val Pured_Thin_Glass_Dark = ColorBlendConfig(
        "Pured_Thin_Glass_Dark",
        intArrayOf(0x2E808080, 0x8F2B2B2B.toInt(), 0x1F000000),
        intArrayOf(BlendModeToken.PLUS_LIGHTER.value, BlendModeToken.HARD_LIGHT.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 60f
    )

    @JvmField
    val Pured_Regular_Light = ColorBlendConfig(
        "Pured_Regular_Light",
        intArrayOf(0x618A8A8A, 0xB2FFFFFF.toInt()),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.SRC_OVER.value)
    )

    @JvmField
    val Pured_Regular_Dark = ColorBlendConfig(
        "Pured_Regular_Dark",
        intArrayOf(0x6B8A8A8A, 0xAB242424.toInt()),
        intArrayOf(BlendModeToken.PLUS_LIGHTER.value, BlendModeToken.SRC_OVER.value)
    )

    @JvmField
    val Pured_Regular_Glass_Light = ColorBlendConfig(
        "Pured_Regular_Glass_Light",
        intArrayOf(0x478A8A8A, 0xADFFFFFF.toInt(), 0x1AFFFFFF),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.HARD_LIGHT.value, BlendModeToken.SRC_OVER.value)
    )

    @JvmField
    val Pured_Regular_Glass_Dark = ColorBlendConfig(
        "Pured_Regular_Glass_Dark",
        intArrayOf(0x6B8A8A8A, 0xAD242424.toInt(), 0x0D000000),
        intArrayOf(BlendModeToken.PLUS_LIGHTER.value, BlendModeToken.HARD_LIGHT.value, BlendModeToken.SRC_OVER.value)
    )

    @JvmField
    val Pured_Thick_Light = ColorBlendConfig(
        "Pured_Thick_Light",
        intArrayOf(0x5CA3A3A3, 0xD8FFFFFF.toInt()),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 100f
    )

    @JvmField
    val Pured_Thick_Dark = ColorBlendConfig(
        "Pured_Thick_Dark",
        intArrayOf(0x61757575, 0xD11F1F1F.toInt()),
        intArrayOf(BlendModeToken.PLUS_LIGHTER.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 100f
    )

    @JvmField
    val Pured_Thick_Glass_Light = ColorBlendConfig(
        "Pured_Thick_Glass_Light",
        intArrayOf(0x3D636363, 0xD9FFFFFF.toInt(), 0x0DFFFFFF),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.HARD_LIGHT.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 100f
    )

    @JvmField
    val Pured_Thick_Glass_Dark = ColorBlendConfig(
        "Pured_Thick_Glass_Dark",
        intArrayOf(0x61757575, 0xBF1F1F1F.toInt(), 0x331F1F1F),
        intArrayOf(BlendModeToken.PLUS_LIGHTER.value, BlendModeToken.HARD_LIGHT.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 100f
    )

    @JvmField
    val Overlay_Pill_Light = ColorBlendConfig(
        "Overlay_Pill_Light",
        intArrayOf(0x33757575, 0xBFEDEDED.toInt()),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.SRC_OVER.value)
    )

    @JvmField
    val Overlay_Pill_Dark = ColorBlendConfig(
        "Overlay_Pill_Dark",
        intArrayOf(0x406E6E6E, 0xD1292929.toInt()),
        intArrayOf(BlendModeToken.PLUS_LIGHTER.value, BlendModeToken.SRC_OVER.value)
    )

    @JvmField
    val Overlay_Dialog_Light = ColorBlendConfig(
        "Overlay_Dialog_Light",
        intArrayOf(0x52ADADAD, 0xEBFFFFFF.toInt()),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 80f,
        fallbackColorArgb = 0xFFF7F7F7.toInt()
    )

    @JvmField
    val Overlay_Dialog_Dark = ColorBlendConfig(
        "Overlay_Dialog_Dark",
        intArrayOf(0x59575757, 0xEB242424.toInt()),
        intArrayOf(BlendModeToken.PLUS_LIGHTER.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 80f,
        fallbackColorArgb = 0xFF1F1F1F.toInt()
    )

    @JvmField
    val Overlay_Menu_Light = ColorBlendConfig(
        "Overlay_Menu_Light",
        intArrayOf(0x05000000, 0x99FFFFFF.toInt(), 0x66FFFFFF),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.SOFT_LIGHT.value, BlendModeToken.HARD_LIGHT.value),
        defaultBlurRadiusDp = 66f,
        fallbackColorArgb = 0xFFFFFFFF.toInt()
    )

    @JvmField
    val Overlay_Menu_Dark = ColorBlendConfig(
        "Overlay_Menu_Dark",
        intArrayOf(0x1A000000, 0x66565656, 0x993F3F3F.toInt()),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.LUMINOSITY.value, BlendModeToken.OVERLAY.value),
        defaultBlurRadiusDp = 66f,
        fallbackColorArgb = 0xFF242424.toInt()
    )

    @JvmField
    val Heavy_Light = ColorBlendConfig(
        "Heavy_Light",
        intArrayOf(0x75E3E3E3, 0xD9F7F7F7.toInt()),
        intArrayOf(BlendModeToken.MULTIPLY.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 66f
    )

    @JvmField
    val Heavy_Dark = ColorBlendConfig(
        "Heavy_Dark",
        intArrayOf(0x7F545454, 0xD8262626.toInt()),
        intArrayOf(BlendModeToken.SCREEN.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 66f
    )

    @JvmField
    val ExtraHeavy_Light = ColorBlendConfig(
        "ExtraHeavy_Light",
        intArrayOf(0x61ADADAD, 0xF2FFFFFF.toInt()),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 66f
    )

    @JvmField
    val ExtraHeavy_Dark = ColorBlendConfig(
        "ExtraHeavy_Dark",
        intArrayOf(0x616B6B6B, 0xF2242424.toInt()),
        intArrayOf(BlendModeToken.PLUS_LIGHTER.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 66f
    )

    // MIUIWeather / MiuiHome presets used in HyperShowcase:
    @JvmField
    val Dialog_Home_Light = ColorBlendConfig(
        "Dialog_Home_Light",
        intArrayOf(0x33F9F9F9, 0xB3FFFFFF.toInt()),
        intArrayOf(BlendModeToken.OVERLAY.value, BlendModeToken.HARD_LIGHT.value),
        defaultBlurRadiusDp = 32f,
        fallbackColorArgb = 0xFFF7F7F7.toInt()
    )

    @JvmField
    val Dialog_Home_Dark = ColorBlendConfig(
        "Dialog_Home_Dark",
        intArrayOf(0x75000000, 0x52000000),
        intArrayOf(BlendModeToken.COLOR_BURN.value, BlendModeToken.SRC_OVER.value),
        defaultBlurRadiusDp = 56f,
        fallbackColorArgb = 0xFF1F1F1F.toInt()
    )

    @JvmField
    val AppBar_Floating_Light = ColorBlendConfig(
        "AppBar_Floating_Light",
        intArrayOf(0x1CFFFFFF, 0x85A6A6A6.toInt()),
        intArrayOf(BlendModeToken.PLUS_LIGHTER.value, BlendModeToken.OVERLAY.value),
        defaultBlurRadiusDp = 20f,
        fallbackColorArgb = 0xFFF7F7F7.toInt()
    )

    @JvmField
    val AppBar_Floating_Dark = ColorBlendConfig(
        "AppBar_Floating_Dark",
        intArrayOf(0x33585858, 0x1A666666),
        intArrayOf(BlendModeToken.PLUS_DARKER.value, BlendModeToken.COLOR_BURN.value),
        defaultBlurRadiusDp = 20f,
        fallbackColorArgb = 0xFF1F1F1F.toInt()
    )

    @JvmField
    val ALL_TOKENS: Map<String, ColorBlendConfig> = linkedMapOf(
        "Info_Highlight_Light" to Info_Highlight_Light,
        "Info_Normal_Light" to Info_Normal_Light,
        "Info_Thin_Light" to Info_Thin_Light,
        "Info_Highlight_Dark" to Info_Highlight_Dark,
        "Info_Normal_Dark" to Info_Normal_Dark,
        "Info_Thin_Dark" to Info_Thin_Dark,
        "Colored_Thin_Light" to Colored_Thin_Light,
        "Colored_Thin_Dark" to Colored_Thin_Dark,
        "Colored_Regular_Light" to Colored_Regular_Light,
        "Colored_Regular_Dark" to Colored_Regular_Dark,
        "Colored_Thick_Light" to Colored_Thick_Light,
        "Colored_Thick_Dark" to Colored_Thick_Dark,
        "Pured_ExtraThin_Light" to Pured_ExtraThin_Light,
        "Pured_ExtraThin_Dark" to Pured_ExtraThin_Dark,
        "Pured_Thin_Light" to Pured_Thin_Light,
        "Pured_Thin_Dark" to Pured_Thin_Dark,
        "Pured_Thin_Glass_Light" to Pured_Thin_Glass_Light,
        "Pured_Thin_Glass_Dark" to Pured_Thin_Glass_Dark,
        "Pured_Regular_Light" to Pured_Regular_Light,
        "Pured_Regular_Dark" to Pured_Regular_Dark,
        "Pured_Regular_Glass_Light" to Pured_Regular_Glass_Light,
        "Pured_Regular_Glass_Dark" to Pured_Regular_Glass_Dark,
        "Pured_Thick_Light" to Pured_Thick_Light,
        "Pured_Thick_Dark" to Pured_Thick_Dark,
        "Pured_Thick_Glass_Light" to Pured_Thick_Glass_Light,
        "Pured_Thick_Glass_Dark" to Pured_Thick_Glass_Dark,
        "Overlay_Pill_Light" to Overlay_Pill_Light,
        "Overlay_Pill_Dark" to Overlay_Pill_Dark,
        "Overlay_Dialog_Light" to Overlay_Dialog_Light,
        "Overlay_Dialog_Dark" to Overlay_Dialog_Dark,
        "Overlay_Menu_Light" to Overlay_Menu_Light,
        "Overlay_Menu_Dark" to Overlay_Menu_Dark,
        "Heavy_Light" to Heavy_Light,
        "Heavy_Dark" to Heavy_Dark,
        "ExtraHeavy_Light" to ExtraHeavy_Light,
        "ExtraHeavy_Dark" to ExtraHeavy_Dark,
        "Dialog_Home_Light" to Dialog_Home_Light,
        "Dialog_Home_Dark" to Dialog_Home_Dark,
        "AppBar_Floating_Light" to AppBar_Floating_Light,
        "AppBar_Floating_Dark" to AppBar_Floating_Dark
    )

    @JvmStatic
    fun byName(name: String?): ColorBlendConfig? =
        if (name.isNullOrBlank()) null else ALL_TOKENS[name]
}
