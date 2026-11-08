package com.flutify.music.flutify_app.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceId
import androidx.glance.GlanceTheme
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import com.flutify.music.flutify_app.widget.ui.AlbumCardLayout
import com.flutify.music.flutify_app.widget.ui.CoverLayout
import com.flutify.music.flutify_app.widget.ui.NowPlayingLayout
import com.flutify.music.flutify_app.widget.ui.UpNextLayout

/**
 * 小组件公共骨架：
 * - 组合内订阅 [WidgetStateStore.flow]，会话保活期间状态变化也会重组（一期「切歌不变 / 播停图标不变」的根因）；
 * - SizeMode.Responsive：各档布局一次性交给桌面，31+ 拖动缩放时桌面直接切换，不再先拉伸旧图再重绘；
 * - 首帧前预解码封面，之后由 WidgetBridgePlugin 在写状态前解码好，组合里只 peek。
 */
abstract class FlutifyGlanceWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val store = WidgetStateStore.flow(context)
        ArtworkCache.load(store.value.coverPath)
        provideContent {
            val state by store.collectAsState()
            val shown = state.withPauseTimeout()
            GlanceTheme {
                Content(shown, ArtworkCache.peek(shown.coverPath))
            }
        }
    }

    @Composable
    abstract fun Content(state: WidgetState, art: Artwork?)
}

/** 播放条（Apple Music Now Playing 同款横条，默认 4×1）。类名沿用一期，已添加的实例不失效。 */
class NowPlayingWidget : FlutifyGlanceWidget() {
    override val sizeMode = SizeMode.Responsive(
        setOf(
            DpSize(110.dp, 48.dp), DpSize(180.dp, 48.dp), DpSize(250.dp, 48.dp),
            DpSize(110.dp, 100.dp), DpSize(180.dp, 100.dp), DpSize(250.dp, 100.dp),
        ),
    )

    @Composable
    override fun Content(state: WidgetState, art: Artwork?) = NowPlayingLayout(state, art)
}

/** 专辑卡片（Spotify NPV 同款：封面取色模糊底 + 大封面 + 三键，默认 4×2）。 */
class AlbumCardWidget : FlutifyGlanceWidget() {
    override val sizeMode = SizeMode.Responsive(
        setOf(DpSize(110.dp, 110.dp), DpSize(250.dp, 110.dp), DpSize(250.dp, 140.dp), DpSize(250.dp, 180.dp)),
    )

    @Composable
    override fun Content(state: WidgetState, art: Artwork?) = AlbumCardLayout(state, art)
}

/** 方形封面（满幅封面 + 渐变托底文字 + 播放键，默认 2×2）。 */
class CoverWidget : FlutifyGlanceWidget() {
    override val sizeMode = SizeMode.Responsive(
        setOf(DpSize(48.dp, 48.dp), DpSize(110.dp, 110.dp), DpSize(180.dp, 180.dp)),
    )

    @Composable
    override fun Content(state: WidgetState, art: Artwork?) = CoverLayout(state, art)
}

/** 待播清单（当前曲目 + 接下来几首，点按直接播放，默认 4×3）。 */
class UpNextWidget : FlutifyGlanceWidget() {
    override val sizeMode = SizeMode.Responsive(
        // 高度档位细一些：清单按档位高度算能放几行，档位越贴近实际高度，底部留白越少
        listOf(110, 145, 180, 215, 250, 285, 320, 360).map { DpSize(250.dp, it.dp) }.toSet(),
    )

    @Composable
    override fun Content(state: WidgetState, art: Artwork?) = UpNextLayout(state, art)
}

class NowPlayingWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = NowPlayingWidget()
}

class AlbumCardWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = AlbumCardWidget()
}

class CoverWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = CoverWidget()
}

class UpNextWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = UpNextWidget()
}

object FlutifyWidgets {
    private val all: List<GlanceAppWidget> by lazy {
        listOf(NowPlayingWidget(), AlbumCardWidget(), CoverWidget(), UpNextWidget())
    }

    /** 刷新全部款式的全部实例；没添加的款式 updateAll 直接返回。 */
    suspend fun refreshAll(context: Context) {
        all.forEach { widget -> runCatching { widget.updateAll(context) } }
    }
}
