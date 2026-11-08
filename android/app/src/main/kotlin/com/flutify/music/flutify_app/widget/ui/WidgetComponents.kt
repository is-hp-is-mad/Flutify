package com.flutify.music.flutify_app.widget.ui

import android.os.Build
import androidx.annotation.DrawableRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.action.Action
import androidx.glance.action.clickable
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.height
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.flutify.music.flutify_app.R
import com.flutify.music.flutify_app.widget.Artwork
import com.flutify.music.flutify_app.widget.WidgetState
import com.flutify.music.flutify_app.widget.actions.NextAction
import com.flutify.music.flutify_app.widget.actions.OpenAppAction
import com.flutify.music.flutify_app.widget.actions.PlayPauseAction
import com.flutify.music.flutify_app.widget.actions.PreviousAction

private val roundedCornersSupported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

/**
 * 一套小组件配色。有封面时全部取自封面主色（深色底白字，亮 / 暗模式都一样，Apple Music / Spotify 同款）；
 * 无封面时回落 GlanceTheme（31+ 随墙纸 Material You，低版本 Material 基线色）。
 */
class WidgetColors(
    val background: ColorProvider,
    val title: ColorProvider,
    val subtitle: ColorProvider,
    val control: ColorProvider,
    val onControl: ColorProvider,
    val primary: ColorProvider,
    val onPrimary: ColorProvider,
    val placeholder: ColorProvider,
    val onPlaceholder: ColorProvider,
)

@Composable
fun widgetColors(art: Artwork?): WidgetColors {
    if (art == null) {
        val c = GlanceTheme.colors
        return WidgetColors(
            background = c.widgetBackground,
            title = c.onSurface,
            subtitle = c.onSurfaceVariant,
            control = c.secondaryContainer,
            onControl = c.onSecondaryContainer,
            primary = c.primary,
            onPrimary = c.onPrimary,
            placeholder = c.surfaceVariant,
            onPlaceholder = c.onSurfaceVariant,
        )
    }
    val p = art.palette
    val white = ColorProvider(Color.White)
    return WidgetColors(
        background = ColorProvider(Color(p.base)),
        title = white,
        subtitle = ColorProvider(Color(0xC4FFFFFF)),
        control = ColorProvider(Color(p.control)),
        onControl = white,
        primary = white,
        onPrimary = ColorProvider(Color(p.base)),
        placeholder = ColorProvider(Color(p.control)),
        onPlaceholder = white,
    )
}

/** 圆角：31+ 交给系统（跟随桌面的小组件圆角），低版本 cornerRadius 本就不生效。 */
fun GlanceModifier.systemCorners(): GlanceModifier =
    if (roundedCornersSupported) cornerRadius(android.R.dimen.system_app_widget_background_radius) else this

/** 小组件根容器：主色底 + 模糊封面背景，内容叠在上面。 */
@Composable
fun WidgetFrame(art: Artwork?, colors: WidgetColors, content: @Composable () -> Unit) {
    Box(
        modifier = GlanceModifier.fillMaxSize()
            .appWidgetBackground()
            .background(colors.background)
            .systemCorners(),
    ) {
        if (art != null) {
            Image(
                provider = ImageProvider(art.backdrop),
                contentDescription = null,
                contentScale = ContentScale.FillBounds,
                modifier = GlanceModifier.fillMaxSize(),
            )
        }
        content()
    }
}

/** 封面缩略图；点按回 App。31 以下用预做圆角的小图。 */
@Composable
fun CoverThumb(art: Artwork?, colors: WidgetColors, size: Dp, corner: Dp) {
    val modifier = GlanceModifier.size(size).cornerRadius(corner)
        .clickable(actionRunCallback<OpenAppAction>())
    if (art != null) {
        Image(
            provider = ImageProvider(if (roundedCornersSupported) art.square else art.rounded),
            contentDescription = LocalContext.current.getString(R.string.widget_cd_open_app),
            contentScale = ContentScale.Crop,
            modifier = modifier,
        )
    } else {
        CoverPlaceholder(colors, modifier.background(colors.placeholder), size * 0.42f)
    }
}

@Composable
fun CoverPlaceholder(colors: WidgetColors, modifier: GlanceModifier, iconSize: Dp) {
    Box(modifier = modifier, contentAlignment = Alignment.Center) {
        Image(
            provider = ImageProvider(R.drawable.ic_stat_music),
            contentDescription = null,
            colorFilter = ColorFilter.tint(colors.onPlaceholder),
            modifier = GlanceModifier.size(iconSize),
        )
    }
}

/**
 * 圆形按钮。31+ 用 background + cornerRadius；低版本 cornerRadius 不生效，
 * 改用着色的圆形 drawable 当背景，保证各版本都是圆的。
 */
@Composable
fun CircleButton(
    @DrawableRes icon: Int,
    desc: String,
    size: Dp,
    container: ColorProvider?,
    content: ColorProvider,
    action: Action,
    iconSize: Dp = size * 0.5f,
) {
    var modifier = GlanceModifier.size(size)
    if (container != null) {
        modifier = if (roundedCornersSupported) {
            modifier.background(container).cornerRadius(size / 2f)
        } else {
            modifier.background(ImageProvider(R.drawable.widget_circle), colorFilter = ColorFilter.tint(container))
        }
    } else if (roundedCornersSupported) {
        modifier = modifier.cornerRadius(size / 2f)
    }
    Box(modifier = modifier.clickable(action), contentAlignment = Alignment.Center) {
        Image(
            provider = ImageProvider(icon),
            contentDescription = desc,
            colorFilter = ColorFilter.tint(content),
            modifier = GlanceModifier.size(iconSize),
        )
    }
}

/** 主播放键：实心高亮底。 */
@Composable
fun PlayPauseButton(state: WidgetState, colors: WidgetColors, size: Dp, filled: Boolean = true) {
    CircleButton(
        icon = if (state.showsPause) R.drawable.ic_widget_pause else R.drawable.ic_widget_play,
        desc = LocalContext.current.getString(R.string.widget_cd_play_pause),
        size = size,
        container = if (filled) colors.primary else colors.control,
        content = if (filled) colors.onPrimary else colors.onControl,
        action = actionRunCallback<PlayPauseAction>(),
        iconSize = size * 0.52f,
    )
}

/** 上一首 / 下一首：[filled] 为 false 时只有图标（卡片、清单这类按钮多的地方更轻）。 */
@Composable
fun SkipButton(next: Boolean, colors: WidgetColors, size: Dp, filled: Boolean = false) {
    CircleButton(
        icon = if (next) R.drawable.ic_widget_next else R.drawable.ic_widget_prev,
        desc = LocalContext.current.getString(if (next) R.string.widget_cd_next else R.string.widget_cd_previous),
        size = size,
        container = if (filled) colors.control else null,
        content = if (filled) colors.onControl else colors.title,
        action = if (next) actionRunCallback<NextAction>() else actionRunCallback<PreviousAction>(),
        iconSize = size * (if (filled) 0.5f else 0.62f),
    )
}

/** 上一首 · 播放 · 下一首，间距 [gap]。 */
@Composable
fun TransportRow(state: WidgetState, colors: WidgetColors, skipSize: Dp, playSize: Dp, gap: Dp) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        SkipButton(next = false, colors = colors, size = skipSize)
        Spacer(GlanceModifier.width(gap))
        PlayPauseButton(state, colors, playSize)
        Spacer(GlanceModifier.width(gap))
        SkipButton(next = true, colors = colors, size = skipSize)
    }
}

/** 歌名 / 艺人（可选「来自 xx」小标题）；点按回 App。 */
@Composable
fun TrackText(
    state: WidgetState,
    colors: WidgetColors,
    titleSize: TextUnit,
    subtitleSize: TextUnit,
    modifier: GlanceModifier = GlanceModifier,
    titleLines: Int = 1,
    showContext: Boolean = false,
) {
    Column(modifier = modifier.clickable(actionRunCallback<OpenAppAction>())) {
        if (showContext && state.contextName.isNotEmpty()) {
            Text(
                text = LocalContext.current.getString(R.string.widget_playing_from, state.contextName),
                style = TextStyle(color = colors.subtitle, fontSize = 11.sp, fontWeight = FontWeight.Medium),
                maxLines = 1,
            )
            Spacer(GlanceModifier.height(2.dp))
        }
        Text(
            text = state.title,
            style = TextStyle(color = colors.title, fontSize = titleSize, fontWeight = FontWeight.Bold),
            maxLines = titleLines,
        )
        Spacer(GlanceModifier.height(2.dp))
        Text(
            text = state.artist,
            style = TextStyle(color = colors.subtitle, fontSize = subtitleSize),
            maxLines = 1,
        )
    }
}

/** 无曲目：音符 + 应用名 + 提示，点按回 App 挑歌。 */
@Composable
fun EmptyContent(colors: WidgetColors, showText: Boolean, showHint: Boolean) {
    Box(
        modifier = GlanceModifier.fillMaxSize().clickable(actionRunCallback<OpenAppAction>()),
        contentAlignment = Alignment.Center,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            CoverPlaceholder(
                colors,
                GlanceModifier.size(36.dp).cornerRadius(10.dp).background(colors.placeholder),
                18.dp,
            )
            if (showText) {
                Spacer(GlanceModifier.width(10.dp))
                Column {
                    Text(
                        text = LocalContext.current.getString(R.string.app_name),
                        style = TextStyle(color = colors.title, fontSize = 14.sp, fontWeight = FontWeight.Bold),
                        maxLines = 1,
                    )
                    if (showHint) {
                        Text(
                            text = LocalContext.current.getString(R.string.widget_empty_hint),
                            style = TextStyle(color = colors.subtitle, fontSize = 12.sp),
                            maxLines = 1,
                        )
                    }
                }
            }
        }
    }
}
