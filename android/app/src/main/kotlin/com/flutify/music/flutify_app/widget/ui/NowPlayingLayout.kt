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
import androidx.glance.layout.padding
import androidx.glance.layout.width
import com.flutify.music.flutify_app.widget.Artwork
import com.flutify.music.flutify_app.widget.WidgetState

/**
 * 播放条，按桌面给的尺寸档分五种：
 * - 窄而高（2×2 / 3×2）：左上封面、右上播放键、底部歌名；
 * - 2×1（宽 <180）：封面 + 播放键；
 * - 3×1（宽 <250）：封面 + 歌名 + 播放键；
 * - 4×1（高 <100）：封面 + 歌名 + 上一首 / 播放 / 下一首；
 * - 4×2：大封面，右侧歌名在上、按键在下。
 */
@Composable
fun NowPlayingLayout(state: WidgetState, art: Artwork?) {
    val colors = widgetColors(art)
    val size = LocalSize.current
    WidgetFrame(art, colors) {
        when {
            !state.hasTrack -> EmptyContent(colors, showText = size.width >= 110.dp, showHint = size.width >= 180.dp)
            size.width < 250.dp && size.height >= 100.dp -> Column(modifier = GlanceModifier.fillMaxSize().padding(12.dp)) {
                Row(modifier = GlanceModifier.fillMaxWidth()) {
                    CoverThumb(art, colors, 48.dp, 10.dp)
                    Spacer(GlanceModifier.defaultWeight())
                    PlayPauseButton(state, colors, 40.dp)
                }
                Spacer(GlanceModifier.defaultWeight())
                TrackText(state, colors, 13.sp, 11.sp, GlanceModifier.fillMaxWidth())
            }
            size.width < 180.dp -> Row(
                modifier = GlanceModifier.fillMaxSize().padding(horizontal = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CoverThumb(art, colors, 36.dp, 8.dp)
                Spacer(GlanceModifier.defaultWeight())
                PlayPauseButton(state, colors, 36.dp)
            }
            size.width < 250.dp -> Row(
                modifier = GlanceModifier.fillMaxSize().padding(horizontal = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CoverThumb(art, colors, 36.dp, 8.dp)
                Spacer(GlanceModifier.width(10.dp))
                TrackText(state, colors, 13.sp, 11.sp, GlanceModifier.defaultWeight())
                Spacer(GlanceModifier.width(6.dp))
                PlayPauseButton(state, colors, 36.dp)
            }
            size.height < 100.dp -> Row(
                modifier = GlanceModifier.fillMaxSize().padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CoverThumb(art, colors, 40.dp, 9.dp)
                Spacer(GlanceModifier.width(12.dp))
                TrackText(state, colors, 14.sp, 12.sp, GlanceModifier.defaultWeight())
                Spacer(GlanceModifier.width(6.dp))
                TransportRow(state, colors, skipSize = 34.dp, playSize = 38.dp, gap = 2.dp)
            }
            else -> Row(
                modifier = GlanceModifier.fillMaxSize().padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CoverThumb(art, colors, 76.dp, 12.dp)
                Spacer(GlanceModifier.width(14.dp))
                Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight()) {
                    TrackText(state, colors, 15.sp, 12.sp, showContext = true)
                    Spacer(GlanceModifier.defaultWeight())
                    TransportRow(state, colors, skipSize = 34.dp, playSize = 38.dp, gap = 6.dp)
                }
            }
        }
    }
}
