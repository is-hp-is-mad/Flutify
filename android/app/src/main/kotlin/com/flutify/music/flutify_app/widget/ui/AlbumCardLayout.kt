package com.flutify.music.flutify_app.widget.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceModifier
import androidx.glance.LocalSize
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import com.flutify.music.flutify_app.widget.Artwork
import com.flutify.music.flutify_app.widget.WidgetState

/**
 * 专辑卡片（Spotify NPV / Apple Music 大尺寸同款）：
 * - 2×2 / 3×2（宽 <250）：左上封面、右上播放键、底部歌名；
 * - 4×2：左侧大封面占满高度，右侧「来自 xx」+ 歌名 + 三键；
 * - 4×3 及以上：上半封面 + 歌名，下半三键均分整行。
 */
@Composable
fun AlbumCardLayout(state: WidgetState, art: Artwork?) {
    val colors = widgetColors(art)
    val size = LocalSize.current
    WidgetFrame(art, colors) {
        when {
            !state.hasTrack -> EmptyContent(colors, showText = true, showHint = size.width >= 180.dp)
            size.width < 250.dp -> Column(modifier = GlanceModifier.fillMaxSize().padding(14.dp)) {
                Row(modifier = GlanceModifier.fillMaxWidth()) {
                    CoverThumb(art, colors, 52.dp, 10.dp)
                    Spacer(GlanceModifier.defaultWeight())
                    PlayPauseButton(state, colors, 40.dp)
                }
                Spacer(GlanceModifier.defaultWeight())
                TrackText(state, colors, 14.sp, 12.sp, GlanceModifier.fillMaxWidth())
            }
            size.height < 180.dp -> {
                val cover = (size.height - 28.dp).coerceIn(64.dp, 120.dp)
                Row(
                    modifier = GlanceModifier.fillMaxSize().padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CoverThumb(art, colors, cover, 12.dp)
                    Spacer(GlanceModifier.width(14.dp))
                    Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight()) {
                        TrackText(state, colors, 16.sp, 13.sp, showContext = true, titleLines = 2)
                        Spacer(GlanceModifier.defaultWeight())
                        TransportRow(state, colors, skipSize = 36.dp, playSize = 42.dp, gap = 8.dp)
                    }
                }
            }
            else -> Column(modifier = GlanceModifier.fillMaxSize().padding(16.dp)) {
                Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    CoverThumb(art, colors, (size.height * 0.5f).coerceIn(88.dp, 140.dp), 14.dp)
                    Spacer(GlanceModifier.width(16.dp))
                    TrackText(
                        state, colors, 18.sp, 14.sp, GlanceModifier.defaultWeight(),
                        titleLines = 2, showContext = true,
                    )
                }
                Spacer(GlanceModifier.defaultWeight())
                Spacer(GlanceModifier.height(8.dp))
                Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Spacer(GlanceModifier.defaultWeight())
                    SkipButton(next = false, colors = colors, size = 44.dp, filled = true)
                    Spacer(GlanceModifier.defaultWeight())
                    PlayPauseButton(state, colors, 56.dp)
                    Spacer(GlanceModifier.defaultWeight())
                    SkipButton(next = true, colors = colors, size = 44.dp, filled = true)
                    Spacer(GlanceModifier.defaultWeight())
                }
            }
        }
    }
}
