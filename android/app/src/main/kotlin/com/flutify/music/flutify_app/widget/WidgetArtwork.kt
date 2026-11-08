package com.flutify.music.flutify_app.widget

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import androidx.core.graphics.ColorUtils
import androidx.palette.graphics.Palette
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 封面取色结果（两家现行方案的同一思路：取色在状态生产侧预计算，组合层只消费）。
 * [base] 压暗到白字可读的深色；[control] 是在 [base] 上提亮的次级按钮底色（不透明，低版本 tint 无透明度问题）。
 */
data class CoverPalette(val base: Int, val control: Int, val accent: Int)

/**
 * 一首歌的封面素材：
 * - [square] 原图方形（大封面 / 满幅封面，圆角交给 31+ 的 cornerRadius）；
 * - [rounded] 预做圆角的小图（31 以下 cornerRadius 不生效时用）；
 * - [backdrop] 模糊封面叠主色的小图，FillBounds 拉伸做小组件背景（Apple Music 同款）；
 * - [scrim] 自上而下透明→主色的渐变条，满幅封面上托底文字。
 */
class Artwork(
    val square: Bitmap,
    val rounded: Bitmap,
    val backdrop: Bitmap,
    val scrim: Bitmap,
    val palette: CoverPalette,
)

/**
 * 按封面路径缓存素材：同一曲目复用同一 Bitmap 对象
 * （MIUI/澎湃对 RemoteViews 图「只渲染首次」的坑，通知侧已踩过：对象稳定即可规避）。
 */
object ArtworkCache {
    private const val SQUARE_PX = 480
    private const val ROUNDED_PX = 192
    private const val CORNER_RATIO = 10f / 48f
    private const val BACKDROP_PX = 64
    private const val MAX_ENTRIES = 4

    private val cache = LinkedHashMap<String, Artwork>(MAX_ENTRIES, 0.75f, true)

    fun peek(path: String?): Artwork? {
        if (path.isNullOrEmpty()) return null
        return synchronized(cache) { cache[path] }
    }

    suspend fun load(path: String?): Artwork? {
        if (path.isNullOrEmpty()) return null
        peek(path)?.let { return it }
        return withContext(Dispatchers.IO) { decode(path) }
    }

    private fun decode(path: String): Artwork? = runCatching {
        val src = decodeSampled(path, SQUARE_PX) ?: return null
        val square = centerSquare(src, SQUARE_PX)
        val palette = extractPalette(square)
        val artwork = Artwork(
            square = square,
            rounded = round(Bitmap.createScaledBitmap(square, ROUNDED_PX, ROUNDED_PX, true), ROUNDED_PX * CORNER_RATIO),
            backdrop = backdrop(square, palette.base),
            scrim = scrim(palette.base),
            palette = palette,
        )
        synchronized(cache) {
            cache[path] = artwork
            while (cache.size > MAX_ENTRIES) cache.remove(cache.keys.first())
        }
        artwork
    }.getOrNull()

    private fun decodeSampled(path: String, target: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (minOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= target) sample *= 2
        return BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
    }

    private fun centerSquare(src: Bitmap, size: Int): Bitmap {
        val side = minOf(src.width, src.height)
        val cropped = if (src.width == src.height) {
            src
        } else {
            Bitmap.createBitmap(src, (src.width - side) / 2, (src.height - side) / 2, side, side)
        }
        return if (side == size) cropped else Bitmap.createScaledBitmap(cropped, size, size, true)
    }

    private fun extractPalette(square: Bitmap): CoverPalette {
        val p = Palette.from(square).maximumColorCount(16).generate()
        // Apple Music：vibrant 优先，失败取中心像素，再失败 #444444
        val seed = p.vibrantSwatch?.rgb
            ?: p.darkVibrantSwatch?.rgb
            ?: p.dominantSwatch?.rgb
            ?: runCatching { square.getPixel(square.width / 2, square.height / 2) }.getOrNull()
            ?: 0xFF444444.toInt()
        val hsl = FloatArray(3)
        ColorUtils.colorToHSL(seed, hsl)
        // 背景：饱和度封顶、亮度压到 0.16~0.26，白字对比度 ≥ 7:1
        val base = ColorUtils.HSLToColor(floatArrayOf(hsl[0], hsl[1].coerceAtMost(0.62f), hsl[2].coerceIn(0.16f, 0.26f)))
        val control = ColorUtils.blendARGB(base, Color.WHITE, 0.16f)
        val accent = ColorUtils.HSLToColor(floatArrayOf(hsl[0], hsl[1].coerceIn(0.35f, 0.85f), 0.78f))
        return CoverPalette(base = base, control = control, accent = accent)
    }

    /** 缩到 64px 做三遍盒式模糊再叠 62% 主色；系统按 FillBounds 双线性放大后就是柔和的模糊底。 */
    private fun backdrop(square: Bitmap, base: Int): Bitmap {
        val small = Bitmap.createScaledBitmap(square, BACKDROP_PX, BACKDROP_PX, true)
        val pixels = IntArray(BACKDROP_PX * BACKDROP_PX)
        small.getPixels(pixels, 0, BACKDROP_PX, 0, 0, BACKDROP_PX, BACKDROP_PX)
        repeat(3) { boxBlur(pixels, BACKDROP_PX, BACKDROP_PX, 4) }
        val out = Bitmap.createBitmap(BACKDROP_PX, BACKDROP_PX, Bitmap.Config.ARGB_8888)
        out.setPixels(pixels, 0, BACKDROP_PX, 0, 0, BACKDROP_PX, BACKDROP_PX)
        val canvas = Canvas(out)
        canvas.drawColor(ColorUtils.setAlphaComponent(base, 158))
        // 底部再压暗一点，按钮行更稳
        canvas.drawRect(
            0f, 0f, BACKDROP_PX.toFloat(), BACKDROP_PX.toFloat(),
            Paint().apply {
                shader = LinearGradient(
                    0f, 0f, 0f, BACKDROP_PX.toFloat(),
                    Color.TRANSPARENT, ColorUtils.setAlphaComponent(base, 120), Shader.TileMode.CLAMP,
                )
            },
        )
        return out
    }

    private fun scrim(base: Int): Bitmap {
        val height = 64
        val out = Bitmap.createBitmap(1, height, Bitmap.Config.ARGB_8888)
        for (y in 0 until height) {
            val t = y / (height - 1f)
            // 上 35% 全透明，往下平滑过渡到 92% 主色
            val eased = ((t - 0.35f) / 0.65f).coerceIn(0f, 1f).let { it * it * (3 - 2 * it) }
            out.setPixel(0, y, ColorUtils.setAlphaComponent(base, (eased * 235).toInt()))
        }
        return out
    }

    private fun round(src: Bitmap, radius: Float): Bitmap {
        val out = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = BitmapShader(src, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        }
        Canvas(out).drawRoundRect(RectF(0f, 0f, src.width.toFloat(), src.height.toFloat()), radius, radius, paint)
        return out
    }

    /** 可分离的盒式模糊（横 + 竖各一遍），边缘按夹取处理。 */
    private fun boxBlur(px: IntArray, w: Int, h: Int, r: Int) {
        val tmp = IntArray(px.size)
        pass(px, tmp, w, h, r, horizontal = true)
        pass(tmp, px, w, h, r, horizontal = false)
    }

    private fun pass(src: IntArray, dst: IntArray, w: Int, h: Int, r: Int, horizontal: Boolean) {
        val lines = if (horizontal) h else w
        val length = if (horizontal) w else h
        val span = 2 * r + 1
        for (line in 0 until lines) {
            fun at(i: Int): Int {
                val c = i.coerceIn(0, length - 1)
                return if (horizontal) src[line * w + c] else src[c * w + line]
            }
            var a = 0; var red = 0; var g = 0; var b = 0
            for (i in -r..r) {
                val c = at(i)
                a += c ushr 24; red += (c shr 16) and 0xFF; g += (c shr 8) and 0xFF; b += c and 0xFF
            }
            for (i in 0 until length) {
                val out = ((a / span) shl 24) or ((red / span) shl 16) or ((g / span) shl 8) or (b / span)
                if (horizontal) dst[line * w + i] = out else dst[i * w + line] = out
                val add = at(i + r + 1)
                val sub = at(i - r)
                a += (add ushr 24) - (sub ushr 24)
                red += ((add shr 16) and 0xFF) - ((sub shr 16) and 0xFF)
                g += ((add shr 8) and 0xFF) - ((sub shr 8) and 0xFF)
                b += (add and 0xFF) - (sub and 0xFF)
            }
        }
    }
}
