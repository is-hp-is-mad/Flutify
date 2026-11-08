import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/flutify_tokens.dart';
import '../../core/theme/md3e_shapes.dart';
import '../../core/utils/added_date_format.dart';
import '../../core/utils/formatters.dart';
import '../../l10n/l10n.dart';
import '../../models/playback_context.dart';
import '../../models/track.dart';
import '../../providers/connect_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/playback_provider.dart';
import '../shell/shell_breakpoints.dart';
import 'connect/connect_actions.dart';
import 'connect/now_playing_source.dart';
import 'cover_image.dart';
import 'hover_builder.dart';
import 'menu/desktop_menu.dart';
import 'track_hotkeys.dart';
import 'track_menu.dart';
import 'track_table/track_table_columns.dart';
import 'waveform_visualizer.dart';

/// 曲目行。
///
/// 通过 `context.select` 只订阅「是否当前曲目 / 是否正在播放 / 是否已点赞」，
/// 播放进度变化、其它曲目切换都不会让整张列表重建。
///
/// 桌面端悬停（Spotify 桌面端行为）：序号 / 封面变为 ▶（当前曲目播放中为 ⏸），
/// 未点赞的爱心与「⋯」只在悬停时出现；右键弹出曲目菜单。移动端长按弹出底部面板。
class TrackTile extends StatelessWidget {
  final SpotifyTrack track;
  final int? index;
  final bool showCover;
  final List<SpotifyTrack>? contextQueue;
  final PlaybackContext? playbackContext;
  final VoidCallback? onTap;

  /// Context-specific second line, e.g. album and year in an artist's catalog.
  final String? subtitle;

  /// Keep the menu discoverable in catalog lists even before pointer hover.
  final bool alwaysShowMore;

  /// 桌面表格列（歌单页）：给出时按列显示艺人 / 专辑 / 添加日期，紧凑视图不显示封面；
  /// 为 null 时是普通曲目行（封面 + 歌名 / 艺人两行）。
  final TrackTableColumns? columns;

  const TrackTile({
    super.key,
    required this.track,
    this.index,
    this.showCover = true,
    this.contextQueue,
    this.playbackContext,
    this.onTap,
    this.subtitle,
    this.alwaysShowMore = false,
    this.columns,
  });

  void _play(BuildContext context) {
    context.read<PlaybackProvider>().playTrack(
      track,
      contextQueue: contextQueue,
      context: playbackContext,
    );
  }

  /// 悬停播放键：当前曲目 → 播放 / 暂停切换（远程模式下切换远程设备）；其它曲目 → 从这首开始播放。
  void _playOrToggle(BuildContext context, bool isCurrent) {
    if (isCurrent && ConnectActions.isRemoteNow(context)) {
      final connect = context.read<ConnectProvider>();
      ConnectActions.run(context, connect.togglePlayPause);
    } else if (isCurrent) {
      context.read<PlaybackProvider>().togglePlayPause();
    } else if (onTap != null) {
      onTap!();
    } else {
      _play(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 菜单打开后鼠标会离开行，悬停按钮随即卸载。后续分享 / 二级菜单
    // 必须使用曲目行的 context，按钮 context 只用于同步计算锚点。
    final actionContext = context;
    final colorScheme = theme.colorScheme;
    final hoverCapable = ShellBreakpoints.isDesktop(
      MediaQuery.sizeOf(context).width,
    );

    // 遥控远程设备时按远程曲目高亮（与播放栏一致）
    final (isCurrent, isPlaying) = NowPlayingSource.trackState(
      context,
      track.id,
    );
    final isLiked = context.select<LibraryProvider, bool>(
      (l) => l.isLiked(track.id),
    );
    final columns = this.columns;
    final showCover = columns != null ? !columns.compact : this.showCover;
    // 紧凑视图且艺人单独成列：标题只占一行
    final artistInline = !(columns?.artist ?? false);

    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) {
        final revealed = hovered || !hoverCapable;
        final playIcon = isPlaying
            ? Icons.pause_rounded
            : Icons.play_arrow_rounded;
        final secondary = theme.textTheme.bodySmall?.copyWith(
          color: hovered ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
        );

        final row = InkWell(
          mouseCursor: SystemMouseCursors.click,
          onTap: onTap ?? () => _play(context),
          onLongPress: () => TrackMenu.show(context, track),
          onSecondaryTapUp: (details) =>
              TrackMenu.show(context, track, position: details.globalPosition),
          borderRadius: context.tokens.radius(MD3EShapes.radiusMedium),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: TrackTableColumns.horizontalPadding,
              vertical: (columns?.compact ?? false) ? 4.0 : 8.0,
            ),
            child: Row(
              children: [
                // 序号 / 波形 / 悬停播放键
                if (index != null && !showCover)
                  SizedBox(
                    width: 32,
                    child: Center(
                      child: hovered
                          ? _HoverPlayIcon(
                              icon: playIcon,
                              color: colorScheme.onSurface,
                              onTap: () => _playOrToggle(context, isCurrent),
                            )
                          : isCurrent
                          ? WaveformVisualizer(
                              isPlaying: isPlaying,
                              color: colorScheme.primary,
                            )
                          : Text(
                              '$index',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  )
                else if (showCover)
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CoverImage(
                          url: track.coverUrl,
                          size: 48,
                          borderRadius: context.tokens.radius(8),
                        ),
                        if (isCurrent || hovered)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: context.tokens.radius(8),
                            ),
                            child: Center(
                              child: hovered
                                  ? _HoverPlayIcon(
                                      icon: playIcon,
                                      color: Colors.white,
                                      onTap: () =>
                                          _playOrToggle(context, isCurrent),
                                    )
                                  : WaveformVisualizer(
                                      isPlaying: isPlaying,
                                      color: colorScheme.primary,
                                    ),
                            ),
                          ),
                      ],
                    ),
                  ),

                const SizedBox(width: TrackTableColumns.leadGap),

                // 歌名与艺人（艺人单独成列时只有歌名一行）
                Expanded(
                  flex: TrackTableColumns.titleFlex,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (track.explicit && !artistInline)
                            const _ExplicitBadge(),
                          Flexible(
                            child: Text(
                              track.name,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                                color: isCurrent
                                    ? colorScheme.primary
                                    : colorScheme.onSurface,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      if (artistInline) ...[
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            if (track.explicit) const _ExplicitBadge(),
                            Expanded(
                              child: Text(
                                subtitle ?? track.artistNames,
                                style: secondary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),

                if (columns != null) ...[
                  if (columns.artist)
                    _TextCell(
                      flex: TrackTableColumns.artistFlex,
                      text: track.artistNames,
                      style: secondary,
                    ),
                  if (columns.album)
                    _TextCell(
                      flex: TrackTableColumns.albumFlex,
                      text: track.album?.name ?? '',
                      style: secondary,
                      // 点专辑名打开专辑页（与官方一致）
                      onTap:
                          TrackMenu.isAvailable(
                            context,
                            track,
                            TrackAction.album,
                          )
                          ? () => TrackMenu.perform(
                              context,
                              track,
                              TrackAction.album,
                            )
                          : null,
                    ),
                  if (columns.addedAt)
                    SizedBox(
                      width: TrackTableColumns.addedAtWidth,
                      child: Text(
                        track.addedAt == null
                            ? ''
                            : AddedDateFormat.format(
                                context.l10n,
                                track.addedAt!,
                              ),
                        style: secondary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],

                // 已点赞常驻；未点赞只在悬停或移动端时出现（始终保留 40dp 占位，保证各行爱心绝对严格对齐）
                _Reveal(
                  visible: revealed,
                  fixedExtent: true,
                  idle: isLiked
                      ? Icon(
                          Icons.favorite_rounded,
                          color: colorScheme.primary,
                          size: 22,
                        )
                      : null,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                    icon: Icon(
                      isLiked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: isLiked
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                      size: 22,
                    ),
                    tooltip: isLiked
                        ? context.l10n.likeRemove
                        : context.l10n.likeAdd,
                    onPressed: () =>
                        context.read<LibraryProvider>().toggleLike(track),
                  ),
                ),

                SizedBox(
                  width: TrackTableColumns.durationWidth,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      Formatters.formatDurationMs(track.durationMs),
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),

                _Reveal(
                  visible: revealed || alwaysShowMore,
                  fixedExtent: true,
                  child: Builder(
                    // 独立 context：桌面菜单锚定在按钮下方
                    builder: (buttonContext) => IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      icon: Icon(
                        hoverCapable
                            ? Icons.more_horiz_rounded
                            : Icons.more_vert_rounded,
                        size: 20,
                      ),
                      color: colorScheme.onSurfaceVariant,
                      tooltip: context.l10n.commonMoreOptions,
                      onPressed: () => TrackMenu.show(
                        actionContext,
                        track,
                        position: DesktopMenu.anchorOf(buttonContext),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        if (!hoverCapable) return row;
        // 悬停行接收曲目快捷键（Q 加入队列、P 加入歌单…）
        return MouseRegion(
          onHover: (e) => TrackHotkeys.hover(context, track, e.position),
          onExit: (_) => TrackHotkeys.leave(context),
          child: row,
        );
      },
    );
  }
}

/// 表格里的文字列（艺人 / 专辑）：单行省略，右侧留出列间距；[onTap] 非空时悬停下划线、可点击。
class _TextCell extends StatelessWidget {
  final int flex;
  final String text;
  final TextStyle? style;
  final VoidCallback? onTap;

  const _TextCell({
    required this.flex,
    required this.text,
    this.style,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final tap = onTap;
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.only(right: 16),
        child: tap == null
            ? label
            : Align(
                alignment: Alignment.centerLeft,
                child: HoverBuilder(
                  cursor: SystemMouseCursors.click,
                  builder: (context, hovered) => GestureDetector(
                    onTap: tap,
                    child: Text(
                      text,
                      style: style?.copyWith(
                        decoration: hovered ? TextDecoration.underline : null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

/// 悬停出现的行内按钮。
///
/// 性能：IconButton 自带 Tooltip / Focus / Ink / Theme 等二十多个组件，长歌单每行两个，
/// 滚动时新进入视口的行几乎全部开销都在这里。因此未悬停时不构建按钮，
/// 只放同尺寸占位（[idle] 为常驻的静态图标，例如已点赞的爱心）；悬停后才换成真按钮。
/// 鼠标总是先悬停再点击，所以静态图标无需响应点击。
///
/// [fixedExtent]（桌面）：两种状态都放进固定 40×40 的格子，切换时时长列不会左右跳动。
class _Reveal extends StatelessWidget {
  static const double _extent = 40;

  final bool visible;
  final bool fixedExtent;
  final Widget? idle;
  final Widget child;

  const _Reveal({
    required this.visible,
    required this.fixedExtent,
    required this.child,
    this.idle,
  });

  @override
  Widget build(BuildContext context) {
    if (!fixedExtent) return visible ? child : const SizedBox.shrink();
    return SizedBox.square(
      dimension: _extent,
      child: visible ? child : Center(child: idle),
    );
  }
}

/// 序号 / 封面位置上的小播放键（点击不触发整行的 onTap）。
class _HoverPlayIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _HoverPlayIcon({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Icon(icon, color: color, size: 24),
      ),
    );
  }
}

/// 「E」显式内容角标。
class _ExplicitBadge extends StatelessWidget {
  const _ExplicitBadge();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 1.0),
      margin: const EdgeInsets.only(right: 6.0),
      decoration: BoxDecoration(
        color: colorScheme.onSurfaceVariant.withAlpha(60),
        borderRadius: BorderRadius.circular(3.0),
      ),
      child: Text(
        'E',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),
    );
  }
}
