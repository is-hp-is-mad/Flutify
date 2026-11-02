package com.flutify.music.flutify_app.widget

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.PixelCopy
import android.view.View
import android.widget.FrameLayout
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceTheme
import androidx.glance.appwidget.ExperimentalGlanceRemoteViewsApi
import androidx.glance.appwidget.GlanceRemoteViews
import com.flutify.music.flutify_app.R
import com.flutify.music.flutify_app.widget.ui.AlbumCardLayout
import com.flutify.music.flutify_app.widget.ui.CoverLayout
import com.flutify.music.flutify_app.widget.ui.NowPlayingLayout
import com.flutify.music.flutify_app.widget.ui.UpNextLayout
import java.io.File
import kotlin.coroutines.resume
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * 仅 debug 包：用真实的小组件布局 + 示例曲目渲染选择器预览图，转 WebP 后放进 res/drawable*-nodpi/widget_preview_*.webp
 * （默认目录 = 简体中文，与 App 默认语言一致；en / ja / zh-rTW / zh-rHK 另出；播放条与方形封面不含文案，只放默认目录）。
 *
 * 澎湃 OS 等桌面的小组件列表只读 previewImage（previewLayout 只在详情页用），所以要有真实截图。
 * 用法（换了设计后重跑）：
 * ```
 * adb push cover.png /data/local/tmp/ && adb shell run-as com.flutify.music.flutify_app cp /data/local/tmp/cover.png files/preview_cover.png
 * adb shell cmd locale set-app-locales com.flutify.music.flutify_app --locales zh-CN   # 或 en-US / ja-JP / zh-TW
 * adb shell am start -n com.flutify.music.flutify_app/.widget.WidgetPreviewActivity
 * adb shell run-as com.flutify.music.flutify_app ls files/widget_previews
 * ```
 * 逐款上屏后用 PixelCopy 截窗口（硬件渲染，圆角裁切与桌面一致），PNG 写到 files/widget_previews/。
 */
@OptIn(ExperimentalGlanceRemoteViewsApi::class)
class WidgetPreviewActivity : Activity() {

    private class Spec(val name: String, val size: DpSize, val content: @Composable (WidgetState, Artwork?) -> Unit)

    private val specs = listOf(
        Spec("now_playing", DpSize(320.dp, 76.dp)) { s, a -> NowPlayingLayout(s, a) },
        Spec("album_card", DpSize(320.dp, 156.dp)) { s, a -> AlbumCardLayout(s, a) },
        Spec("cover", DpSize(156.dp, 156.dp)) { s, a -> CoverLayout(s, a) },
        Spec("up_next", DpSize(320.dp, 220.dp)) { s, a -> UpNextLayout(s, a) },
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var host: FrameLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFormat(PixelFormat.TRANSLUCENT)
        window.setBackgroundDrawableResource(android.R.color.transparent)
        host = FrameLayout(this).apply { setBackgroundColor(Color.TRANSPARENT) }
        setContentView(host)
        scope.launch {
            val out = File(filesDir, "widget_previews").apply { mkdirs() }
            val coverPath = File(filesDir, "preview_cover.png").path
            val art = ArtworkCache.load(coverPath)
            val state = sampleState(coverPath)
            for (spec in specs) {
                val result = GlanceRemoteViews().compose(this@WidgetPreviewActivity, spec.size) {
                    GlanceTheme { spec.content(state, art) }
                }
                val bitmap = capture(result.remoteViews.apply(this@WidgetPreviewActivity, host), spec.size)
                File(out, "widget_preview_${spec.name}.png").outputStream().use {
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
                Log.i(TAG, "rendered ${spec.name} ${bitmap.width}x${bitmap.height}")
            }
            Log.i(TAG, "done -> ${out.path}")
            finish()
        }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun sampleState(coverPath: String) = WidgetState(
        id = "preview",
        title = "Midnight City",
        artist = "M83",
        isPlaying = true,
        coverPath = coverPath,
        updatedAt = System.currentTimeMillis(),
        contextName = getString(R.string.widget_preview_context),
        queue = listOf(
            QueueItem("q1", "Blinding Lights", "The Weeknd"),
            QueueItem("q2", "Levitating", "Dua Lipa"),
            QueueItem("q3", "As It Was", "Harry Styles"),
        ),
    )

    /** 把视图按 [size] 摆到窗口左上角，等它真正画出来再 PixelCopy。 */
    private suspend fun capture(view: View, size: DpSize): Bitmap {
        val density = resources.displayMetrics.density
        val w = (size.width.value * density).toInt()
        val h = (size.height.value * density).toInt()
        host.removeAllViews()
        // 避开状态栏：窗口顶部会被系统栏遮罩盖住
        host.addView(view, FrameLayout.LayoutParams(w, h).apply { topMargin = (160 * density).toInt() })
        awaitFrames(view, 3)
        val location = IntArray(2).also { view.getLocationInWindow(it) }
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        return suspendCancellableCoroutine { cont ->
            PixelCopy.request(
                window,
                Rect(location[0], location[1], location[0] + w, location[1] + h),
                bitmap,
                { cont.resume(bitmap) },
                Handler(Looper.getMainLooper()),
            )
        }
    }

    private suspend fun awaitFrames(view: View, count: Int) {
        repeat(count) {
            suspendCancellableCoroutine { cont ->
                view.postOnAnimation { cont.resume(Unit) }
            }
        }
        // 位图解码、ImageView 异步加载留一点余量
        suspendCancellableCoroutine { cont -> view.postDelayed({ cont.resume(Unit) }, 300) }
    }

    private companion object {
        const val TAG = "WidgetPreview"
    }
}
