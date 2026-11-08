package com.hyperos.glass.util

import android.app.ActivityManager
import android.content.Context
import android.graphics.Canvas
import android.os.Build

/**
 * Standard Android hardware & rendering capability detector.
 *
 * Completely replaces Xiaomi ROM private system property sniffing
 * (`persist.sys.background_blur_supported`, `ro.miui.ui.version.*`, `ro.mi.os.version.code`)
 * with standard Android SDK checks (`Canvas.isHardwareAccelerated()`, `Build.VERSION.SDK_INT`,
 * OpenGL ES 3.0 configuration, and RAM tier).
 */
object HyperGlassCapabilities {

    enum class RenderBackend {
        /** Automatically selects the highest-fidelity backend supported by the device. */
        AUTO,
        /** Android 13+ (API 33+) standard AGSL `RuntimeShader` + `RenderEffect` pipeline. */
        AGSL_RUNTIME_SHADER,
        /** Android 5.0–12L (API 21–32) standard OpenGL ES 3.0 offscreen FBO pipeline. */
        OPENGL_ES_30,
        /** Android 12+ (API 31+) standard `RenderEffect.createBlurEffect` + color tint fallback. */
        RENDER_EFFECT_BLUR_ONLY,
        /** Software / low-RAM graceful degradation: semi-transparent rounded-rect mask. */
        FALLBACK_MASK_ONLY
    }

    /**
     * Optional override for testing specific degradation tiers on any device/emulator.
     */
    @Volatile
    @JvmStatic
    var forcedBackend: RenderBackend = RenderBackend.AUTO

    /**
     * Whether AGSL (`android.graphics.RuntimeShader` and `RenderEffect.createRuntimeShaderEffect`)
     * is available on the running Android OS version (Android 13 / API 33+).
     */
    @JvmStatic
    fun isAgslSupported(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU

    /**
     * Whether `android.graphics.RenderEffect.createBlurEffect` is available (Android 12 / API 31+).
     */
    @JvmStatic
    fun isRenderEffectBlurSupported(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

    /**
     * Checks whether the device supports OpenGL ES 3.0 or higher using standard [ActivityManager].
     */
    @JvmStatic
    fun isOpenGlEs30Supported(context: Context?): Boolean {
        return try {
            val am = context?.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                ?: return true
            am.deviceConfigurationInfo.reqGlEsVersion >= 0x00030000
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Checks whether the device is flagged as a low-RAM device (`ActivityManager.isLowRamDevice`),
     * allowing automatic graceful degradation when needed.
     */
    @JvmStatic
    fun isLowRamDevice(context: Context?): Boolean {
        return try {
            val am = context?.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                ?: return false
            am.isLowRamDevice
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Resolves the active [RenderBackend] for the current [Canvas] and [Context].
     * Never throws; safely degrades to [RenderBackend.FALLBACK_MASK_ONLY] if hardware acceleration
     * is disabled or shaders cannot run.
     */
    @JvmStatic
    fun resolveBackend(context: Context?, canvas: Canvas?): RenderBackend {
        val forced = forcedBackend
        if (forced != RenderBackend.AUTO) {
            if (forced == RenderBackend.AGSL_RUNTIME_SHADER && !isAgslSupported()) {
                return if (isOpenGlEs30Supported(context)) RenderBackend.OPENGL_ES_30 else RenderBackend.FALLBACK_MASK_ONLY
            }
            return forced
        }

        if (canvas != null && !canvas.isHardwareAccelerated) {
            return RenderBackend.FALLBACK_MASK_ONLY
        }

        if (isLowRamDevice(context)) {
            return if (isRenderEffectBlurSupported()) {
                RenderBackend.RENDER_EFFECT_BLUR_ONLY
            } else {
                RenderBackend.FALLBACK_MASK_ONLY
            }
        }

        return when {
            isAgslSupported() -> RenderBackend.AGSL_RUNTIME_SHADER
            isOpenGlEs30Supported(context) -> RenderBackend.OPENGL_ES_30
            isRenderEffectBlurSupported() -> RenderBackend.RENDER_EFFECT_BLUR_ONLY
            else -> RenderBackend.FALLBACK_MASK_ONLY
        }
    }
}
