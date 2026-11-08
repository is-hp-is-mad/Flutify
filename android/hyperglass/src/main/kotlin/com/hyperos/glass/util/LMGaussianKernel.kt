package com.hyperos.glass.util

import kotlin.math.exp
import kotlin.math.sqrt

/**
 * Exact port of Xiaomi HyperOS `MiHyperMaterialEngine::ExecuteLMGaussianBlur` and
 * cubic Bézier luminance curve polynomial conversion (`adjustment_matrix`).
 */
object LMGaussianKernel {

    /**
     * State of the multi-level LM Gaussian blur (`MiLMGaussianState`).
     */
    class State(
        @JvmField val sigma: Float,
        @JvmField val variance: Float,
        @JvmField val factor: Int,
        @JvmField val level: Int,
        @JvmField val count: Int,
        @JvmField val weights: FloatArray,
        @JvmField val offsets: FloatArray
    )

    /**
     * Converts a HyperOS LM blur `radius` (clamped to `400.0`) to its effective Gaussian `sigma`:
     * `sigma = min(radius, 400.0) * 0.25 * 0.45 = min(radius, 400.0) * 0.1125`.
     */
    @JvmStatic
    fun radiusToSigma(radius: Float): Float {
        if (radius <= 0f) return 0f
        val r = radius.coerceAtMost(400.0f)
        return r * 0.25f * 0.45f
    }

    /**
     * Computes the exact `MiLMGaussianState` (downscale `factor = 1 << level`, variance, and
     * 7 bilinear tap pairs) as in `libhwui.so`'s `MiHyperMaterialEngine::ExecuteLMGaussianBlur`.
     */
    @JvmStatic
    fun forRadius(radius: Float): State {
        val r = radius.coerceIn(0f, 400f)
        val sigma = r * 0.25f * 0.45f
        val v0 = sigma * sigma

        val a = v0 * 0.015625f - 0.140625f
        val f25 = if (400.0f < v0) a else v0
        var level = if (f25 < 90.25f) 0 else 2
        var f55 = if (f25 < 90.25f) v0 else f25 * 0.0625f - 0.47265625f
        if (400.0f < v0) {
            level = 3
            f55 = a
        }
        val threshold = if (v0 <= 100.0f) 12.6f else 30.25f
        if (threshold <= f55) {
            level += 1
            f55 = f55 * 0.25f - 0.756625f
        }
        val variance = if (0.1f <= f55) f55 else 0.1f
        val factor = 1 shl level

        val norm = (1.0 / sqrt((variance * 3.141592655 + variance * 3.141592655))).toFloat()
        val w = FloatArray(14) { k ->
            (exp(-(k * k) * 0.5 / variance) * norm).toFloat()
        }
        var sum = w[0]
        for (k in 1 until 14) {
            sum += 2f * w[k]
        }
        for (k in 0 until 14) {
            w[k] /= sum
        }

        val weight = FloatArray(7)
        val offset = FloatArray(7)
        var pairSum = 0.0f
        var count = 0
        for (i in 0 until 6) {
            val lo = 2 + 2 * i
            val hi = lo + 1
            val ws = w[lo] + w[hi]
            val keep = ws >= 0.002f
            val pw = if (keep) ws else 0.0f
            pairSum += pw
            offset[i + 1] = if (keep) w[hi] / ws + lo else 0.0f
            weight[i + 1] = if (pw > 0f && pw < 1f) pw else 0.0f
            if (pw > 0f && pw < 1f) count++
        }
        offset[0] = w[1] / (w[0] * 0.5f + w[1])
        val center = 0.5f - pairSum
        if (center > 0f && center < 1f) {
            weight[0] = center
            count++
        }
        return State(sigma, variance, factor, level, count, weight, offset)
    }

    /**
     * Converts the 4 raw Bézier control values `[b0, b1, b2, b3]` from `GlassToken.blend.luminanceValues`
     * into the cubic polynomial coefficients `[c3, c2, c1, c0]` evaluated by `luminanceCurve`:
     * `L(x) = ((c3 * x + c2) * x + c1) * x + c0`.
     */
    @JvmStatic
    fun bezierToPolynomial(b0: Float, b1: Float, b2: Float, b3: Float): FloatArray = floatArrayOf(
        (3f * b1 - b0) - 3f * b2 + b3,
        -6f * b1 + 3f * b0 + 3f * b2,
        3f * b1 - 3f * b0,
        b0
    )
}
