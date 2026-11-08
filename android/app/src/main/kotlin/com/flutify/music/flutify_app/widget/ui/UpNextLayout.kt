package com.flutify.music.flutify_app.widget.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceModifier
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.actionParametersOf
import androidx.glance.action.clickable
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.cornerRadius
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import com.flutify.music.flutify_app.R
import com.flutify.music.flutify_app.widget.Artwork
import com.flutify.music.flutify_app.widget.QueueItem
import com.flutify.music.flutify_app.widget.WidgetState
import com.flutify.music.flutify_app.widget.actions.PlayQueueItemAction

private val HEADER_HEIGHT = 52.dp
private val LABEL_HEIGHT = 26.dp
private val ROW_HEIGHT = 36.dp
private const val MAX_ROWS = 6

/**
 * 待播清单（对标 Apple Music「最近播放」的列表型小组件，内容换成本机队列）：
 * 顶部当前曲目 + 播放 / 下一首，下面按高度能放几行放几行，点一行直接跳到那首。
 */
@Composable
fun UpNextLayout(state: WidgetState, art: Artwork?) {
    val colors = widgetColors(art)
    val size = LocalSize.current
    WidgetFrame(art, colors) {
        if (!state.hasTrack) {
            EmptyContent(colors, showText = true, showHint = true)
            return@WidgetFrame
        }
        Column(modifier = GlanceModifier.fillMaxSize().padding(horizontal = 12.dp, vertical = 12.dp)) {
            Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                CoverThumb(art, colors, 48.dp, 10.dp)
                Spacer(GlanceModifier.width(12.dp))
                TrackText(state, colors, 14.sp, 12.sp, GlanceModifier.defaultWeight())
                Spacer(GlanceModifier.width(6.dp))
                PlayPauseButton(state, colors, 38.dp)
                Spacer(GlanceModifier.width(2.dp))
                SkipButton(next = true, colors = colors, size = 34.dp)
            }
            val fit = ((size.height - 24.dp - HEADER_HEIGHT - LABEL_HEIGHT) / ROW_HEIGHT).toInt()
                .coerceIn(0, MAX_ROWS)
            if (fit == 0) return@Column
            Spacer(GlanceModifier.height(10.dp))
            Text(
                text = LocalContext.current.getString(R.string.widget_up_next),
                style = TextStyle(color = colors.subtitle, fontSize = 12.sp, fontWeight = FontWeight.Bold),
                maxLines = 1,
                modifier = GlanceModifier.padding(start = 4.dp, bottom = 2.dp),
            )
            if (state.queue.isEmpty()) {
                Text(
                    text = LocalContext.current.getString(R.string.widget_queue_empty),
                    style = TextStyle(color = colors.subtitle, fontSize = 13.sp),
                    maxLines = 1,
                    modifier = GlanceModifier.padding(start = 4.dp, top = 8.dp),
                )
                return@Column
            }
            state.queue.take(fit).forEachIndexed { index, item ->
                QueueRow(index, item, colors)
            }
        }
    }
}

@Composable
private fun QueueRow(index: Int, item: QueueItem, colors: WidgetColors) {
    Row(
        modifier = GlanceModifier.fillMaxWidth().height(ROW_HEIGHT).cornerRadius(8.dp)
            .clickable(
                actionRunCallback<PlayQueueItemAction>(
                    actionParametersOf(
                        PlayQueueItemAction.IndexKey to index,
                        PlayQueueItemAction.TrackIdKey to item.id,
                    ),
                ),
            ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "${index + 1}",
            style = TextStyle(color = colors.subtitle, fontSize = 12.sp, textAlign = TextAlign.Center),
            modifier = GlanceModifier.width(24.dp),
        )
        Spacer(GlanceModifier.width(6.dp))
        Column(modifier = GlanceModifier.defaultWeight()) {
            Text(
                text = item.title,
                style = TextStyle(color = colors.title, fontSize = 13.sp, fontWeight = FontWeight.Medium),
                maxLines = 1,
            )
            if (item.artist.isNotEmpty()) {
                Text(
                    text = item.artist,
                    style = TextStyle(color = colors.subtitle, fontSize = 11.sp),
                    maxLines = 1,
                )
            }
        }
    }
}
