package com.flutify.music.flutify_app.widget.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import com.flutify.music.flutify_app.R
import com.flutify.music.flutify_app.widget.Artwork
import com.flutify.music.flutify_app.widget.WidgetState
import com.flutify.music.flutify_app.widget.actions.OpenAppAction

/**
 * 方形封面：封面满幅铺底，底部主色渐变托住文字。
 * - 1×1（<110）：只有封面 + 右下角小播放键；
 * - 2×2：歌名 / 艺人 + 播放键；
 * - 3×3 及以上：再加一行三键。
 */
@Composable
fun CoverLayout(state: WidgetState, art: Artwork?) {
    val colors = widgetColors(art)
    val size = LocalSize.current
    WidgetFrame(art, colors) {
        if (!state.hasTrack) {
            EmptyContent(colors, showText = size.width >= 180.dp, showHint = false)
            return@WidgetFrame
        }
        val openApp = GlanceModifier.fillMaxSize().clickable(actionRunCallback<OpenAppAction>())
        if (art != null) {
            Image(
                provider = ImageProvider(art.square),
                contentDescription = LocalContext.current.getString(R.string.widget_cd_open_app),
                contentScale = ContentScale.Crop,
                modifier = openApp,
            )
        } else {
            CoverPlaceholder(colors, openApp, size.width * 0.32f)
        }
        when {
            size.width < 110.dp -> Box(
                modifier = GlanceModifier.fillMaxSize().padding(5.dp),
                contentAlignment = Alignment.BottomEnd,
            ) {
                PlayPauseButton(state, colors, 26.dp)
            }
            size.width < 180.dp -> {
                ScrimImage(art)
                Box(
                    modifier = GlanceModifier.fillMaxSize().padding(12.dp),
                    contentAlignment = Alignment.BottomStart,
                ) {
                    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                        TrackText(state, colors, 13.sp, 11.sp, GlanceModifier.defaultWeight())
                        Spacer(GlanceModifier.width(8.dp))
                        PlayPauseButton(state, colors, 36.dp)
                    }
                }
            }
            else -> {
                ScrimImage(art)
                Column(
                    modifier = GlanceModifier.fillMaxSize().padding(16.dp),
                    verticalAlignment = Alignment.Bottom,
                ) {
                    TrackText(state, colors, 16.sp, 13.sp, GlanceModifier.fillMaxWidth())
                    Spacer(GlanceModifier.height(10.dp))
                    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        SkipButton(next = false, colors = colors, size = 40.dp)
                        Spacer(GlanceModifier.defaultWeight())
                        PlayPauseButton(state, colors, 48.dp)
                        Spacer(GlanceModifier.defaultWeight())
                        SkipButton(next = true, colors = colors, size = 40.dp)
                    }
                }
            }
        }
    }
}

@Composable
private fun ScrimImage(art: Artwork?) {
    if (art == null) return
    Image(
        provider = ImageProvider(art.scrim),
        contentDescription = null,
        contentScale = ContentScale.FillBounds,
        modifier = GlanceModifier.fillMaxSize(),
    )
}
