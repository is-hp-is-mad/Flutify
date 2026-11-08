package com.hyperos.glass.token

/**
 * Decoupled, standalone localization of Xiaomi HyperOS `miuix.theme.token.BlendModeToken`.
 *
 * Maps every HyperOS `mi_blend_blur` blend mode integer ID (`0..31`, `100..203`) to its
 * corresponding shader mode.
 */
enum class BlendModeToken(@JvmField val value: Int) {
    DEFAULT(-1),
    CLEAR(0),
    SRC(1),
    DST(2),
    SRC_OVER(3),
    DST_OVER(4),
    SRC_IN(5),
    DST_IN(6),
    SRC_OUT(7),
    DST_OUT(8),
    SRC_ATOP(9),
    DST_ATOP(10),
    XOR(11),
    PLUS(12),
    MODULATE(13),
    SCREEN(14),
    OVERLAY(15),
    DARKEN(16),
    LIGHTEN(17),
    COLOR_DODGE(18),
    COLOR_BURN(19),
    HARD_LIGHT(20),
    SOFT_LIGHT(21),
    DIFFERENCE(22),
    EXCLUSION(23),
    MULTIPLY(24),
    HUE(25),
    SATURATION(26),
    COLOR(27),
    LUMINOSITY(28),
    LAST_COEFF_MODE(29),
    LAST_SEPARABLE_MODE(30),
    LAST_MODE(31),
    LINEAR_LIGHT(100),
    LINEAR_LIGHT_WITH_GREY(101),
    MI_COLOR_DODGE(102),
    MI_COLOR_BURN(103),
    LAB(106),
    LAB_DARKEN(107),
    LAB_LIGHTEN(108),
    LINEAR_DODGE(110),
    LINEAR_BURN(111),
    PLUS_DARKER(120),
    PLUS_LIGHTER(121),
    SATURATION_200(200),
    BRIGHTNESS(201),
    LUMINANCE_CURVE(202),
    LUMINANCE(203);

    companion object {
        private val BY_VALUE = entries.associateBy { it.value }

        @JvmStatic
        fun fromValue(value: Int): BlendModeToken = BY_VALUE[value] ?: SRC_OVER
    }
}
