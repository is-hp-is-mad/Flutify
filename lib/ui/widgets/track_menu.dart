import 'package:flutter/material.dart';
import '../../core/theme/flutify_tokens.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../models/share_target.dart';
import '../../models/track.dart';
import '../../providers/library_provider.dart';
import '../../providers/playback_provider.dart';
import '../../providers/sleep_timer_provider.dart';
import '../navigation/app_routes.dart';
import '../shell/shell_breakpoints.dart';
import 'cover_image.dart';
import 'create_playlist_dialog.dart';
import 'keyboard_shortcuts.dart';
import 'menu/desktop_menu.dart';
import 'menu/mobile_menu.dart';
import 'share/share_sheet.dart';
import 'sleep_timer/sleep_timer_menu.dart';
import 'toast/app_toast.dart';
import 'track_actions/song_radio.dart';
import 'track_actions/track_credits_view.dart';
import 'track_options_sheet.dart';

/// 曲目操作（菜单项与悬停快捷键共用）。
enum TrackAction {
  addToPlaylist(SingleActivator(LogicalKeyboardKey.keyP), 'P'),
  like(
    SingleActivator(LogicalKeyboardKey.keyB, alt: true, shift: true),
    'Alt+Shift+B',
  ),
  queue(SingleActivator(LogicalKeyboardKey.keyQ), 'Q'),
  sleepTimer(null, null),
  artist(SingleActivator(LogicalKeyboardKey.keyA, alt: true), 'Alt+A'),
  album(SingleActivator(LogicalKeyboardKey.keyA), 'A'),
  radio(SingleActivator(LogicalKeyboardKey.keyR), 'R'),
  credits(null, null),
  share(SingleActivator(LogicalKeyboardKey.keyS), 'S');

  /// 悬停在曲目行上时的快捷键；null 表示没有。
  final SingleActivator? activator;

  /// 菜单右侧的快捷键提示。
  final String? hint;

  const TrackAction(this.activator, this.hint);
}

/// 曲目操作统一入口。
///
/// - 桌面端：在鼠标位置（右键）或按钮下方（⋯）弹出菜单，与 Spotify 桌面端一致；
///   「加入歌单」「睡眠定时器」「前往艺人（多位）」在同一位置弹出二级菜单；菜单项右侧标出快捷键
///   （鼠标悬停在曲目行上按键即可，见 [TrackHotkeys]）；
/// - 移动端：底部操作面板 [TrackOptionsSheet]。
class TrackMenu {
  TrackMenu._();

  /// [position] 为全局坐标；为空时按 [context] 对应组件的左下角弹出（用于按钮触发）。
  static Future<void> show(
    BuildContext context,
    SpotifyTrack track, {
    Offset? position,
    VoidCallback? onConnect,
  }) {
    // 柔光玻璃主题下：全尺寸统一使用小米 ArcAnimation 悬浮果冻菜单，手机上换成移动端版式
    if (context.tokens.hyperMaterial) {
      if (_isMobile(context)) {
        return _showMobile(
          context,
          track,
          position ?? DesktopMenu.anchorOf(context),
          onConnect,
        );
      }
      return _showDesktop(
        context,
        track,
        position ?? DesktopMenu.anchorOf(context),
        onConnect,
      );
    }
    if (!GlassMenuScope.of(context) &&
        !ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width)) {
      return TrackOptionsSheet.show(context, track);
    }
    return _showDesktop(
      context,
      track,
      position ?? DesktopMenu.anchorOf(context),
      onConnect,
    );
  }

  /// 柔光玻璃菜单是否按移动端版式排（窗口宽度低于桌面断点）。
  static bool _isMobile(BuildContext context) =>
      context.tokens.hyperMaterial &&
      !ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width);

  static void _toast(BuildContext context, String message, IconData icon) {
    if (!context.mounted) return;
    AppToast.show(context, message, icon: icon, tone: ToastTone.success);
  }

  /// 当前情境下可用的操作（菜单与快捷键共用同一判断）。
  static bool isAvailable(
    BuildContext context,
    SpotifyTrack track,
    TrackAction action,
  ) => switch (action) {
    TrackAction.artist => track.artists.isNotEmpty,
    TrackAction.album => track.album != null && track.album!.id.isNotEmpty,
    TrackAction.share => ShareTarget.track(track).isShareable,
    TrackAction.sleepTimer => context.read<SleepTimerProvider?>() != null,
    _ => true,
  };

  static Future<void> _showDesktop(
    BuildContext context,
    SpotifyTrack track,
    Offset position,
    VoidCallback? onConnect,
  ) async {
    final l10n = context.l10n;
    final liked = context.read<LibraryProvider>().isLiked(track.id);
    final timerOn = context.read<SleepTimerProvider?>()?.active ?? false;
    final primary = Theme.of(context).colorScheme.primary;
    const connectId = '\u0000connect';

    PopupMenuItem<Object> item(
      TrackAction action,
      IconData icon,
      String label, {
      Color? color,
      bool sub = false,
    }) => DesktopMenu.item<Object>(
      action,
      icon,
      label,
      iconColor: color,
      // 快捷键提示按平台渲染（macOS ⌥⇧B 式紧凑排，其余 Alt+Shift+B）
      shortcut: action.hint == null
          ? null
          : PlatformShortcuts.hintText(action.hint!),
      submenu: sub,
    );
    bool has(TrackAction a) => isAvailable(context, track, a);

    final action = await DesktopMenu.show<Object>(context, position, [
      item(
        TrackAction.addToPlaylist,
        Icons.add_rounded,
        l10n.trackAddToPlaylist,
        sub: true,
      ),
      item(
        TrackAction.like,
        liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        liked ? l10n.likeRemove : l10n.likeAdd,
        color: liked ? primary : null,
      ),
      item(TrackAction.queue, Icons.queue_music_rounded, l10n.trackAddToQueue),
      if (has(TrackAction.sleepTimer))
        item(
          TrackAction.sleepTimer,
          timerOn ? Icons.bedtime_rounded : Icons.bedtime_outlined,
          l10n.sleepTimer,
          color: timerOn ? primary : null,
          sub: true,
        ),
      DesktopMenu.divider,
      item(TrackAction.radio, Icons.sensors_rounded, l10n.trackGoToRadio),
      if (has(TrackAction.artist))
        item(
          TrackAction.artist,
          Icons.person_outline_rounded,
          l10n.trackGoToArtist(track.artists.length),
        ),
      if (has(TrackAction.album))
        item(TrackAction.album, Icons.album_outlined, l10n.trackGoToAlbum),
      item(TrackAction.credits, Icons.groups_outlined, l10n.trackViewCredits),
      if (has(TrackAction.share)) ...[
        DesktopMenu.divider,
        item(TrackAction.share, Icons.ios_share_rounded, l10n.commonShare),
      ],
      if (onConnect != null) ...[
        DesktopMenu.divider,
        DesktopMenu.item<Object>(
          connectId,
          Icons.cast_connected_rounded,
          l10n.deviceConnectShort,
        ),
      ],
    ]);
    if (action == null || !context.mounted) return;
    if (action == connectId) {
      onConnect?.call();
      return;
    }
    if (action is! TrackAction) return;
    await perform(context, track, action, position: position);
  }

  /// 移动端柔光玻璃菜单：顶部「添加 / 点赞 / 分享」快捷操作，下面分组排列，
  /// 「添加到播放队列」「前往专辑」「前往艺人」带一行副标题。
  static Future<void> _showMobile(
    BuildContext context,
    SpotifyTrack track,
    Offset position,
    VoidCallback? onConnect,
  ) async {
    final l10n = context.l10n;
    final liked = context.read<LibraryProvider>().isLiked(track.id);
    final timerOn = context.read<SleepTimerProvider?>()?.active ?? false;
    final primary = Theme.of(context).colorScheme.primary;
    const connectId = '\u0000connect';
    bool has(TrackAction a) => isAvailable(context, track, a);

    final action = await DesktopMenu.show<Object>(context, position, [
      MobileMenuActionRow<Object>([
        MobileMenuAction(
          TrackAction.addToPlaylist,
          Icons.add_circle_outline_rounded,
          l10n.trackQuickAdd,
        ),
        MobileMenuAction(
          TrackAction.like,
          liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          liked ? l10n.trackQuickLiked : l10n.trackQuickLike,
          color: liked ? primary : null,
        ),
        if (has(TrackAction.share))
          MobileMenuAction(
            TrackAction.share,
            Icons.ios_share_rounded,
            l10n.commonShare,
          ),
      ]),
      MobileMenu.divider,
      MobileMenu.item(
        TrackAction.addToPlaylist,
        Icons.playlist_add_rounded,
        l10n.trackAddToPlaylist,
        submenu: true,
      ),
      MobileMenu.divider,
      MobileMenu.item(
        TrackAction.queue,
        Icons.queue_music_rounded,
        l10n.trackAddToQueue,
        subtitle: track.name,
      ),
      MobileMenu.item(
        TrackAction.radio,
        Icons.sensors_rounded,
        l10n.trackGoToRadio,
      ),
      if (has(TrackAction.sleepTimer))
        MobileMenu.item(
          TrackAction.sleepTimer,
          timerOn ? Icons.bedtime_rounded : Icons.bedtime_outlined,
          l10n.sleepTimer,
          iconColor: timerOn ? primary : null,
          submenu: true,
        ),
      MobileMenu.divider,
      if (has(TrackAction.album))
        MobileMenu.item(
          TrackAction.album,
          Icons.album_outlined,
          l10n.trackGoToAlbum,
          subtitle: track.album!.name,
        ),
      if (has(TrackAction.artist))
        MobileMenu.item(
          TrackAction.artist,
          Icons.person_outline_rounded,
          l10n.trackGoToArtist(track.artists.length),
          subtitle: track.artistNames,
          submenu: track.artists.length > 1,
        ),
      MobileMenu.item(
        TrackAction.credits,
        Icons.info_outline_rounded,
        l10n.trackViewCredits,
      ),
      if (onConnect != null) ...[
        MobileMenu.divider,
        MobileMenu.item<Object>(
          connectId,
          Icons.cast_connected_rounded,
          l10n.deviceConnectShort,
        ),
      ],
    ]);
    if (action == null || !context.mounted) return;
    if (action == connectId) {
      onConnect?.call();
      return;
    }
    if (action is! TrackAction) return;
    await perform(context, track, action, position: position);
  }

  /// 执行操作；[position] 为二级菜单弹出位置（快捷键触发时为鼠标位置）。
  static Future<void> perform(
    BuildContext context,
    SpotifyTrack track,
    TrackAction action, {
    Offset? position,
  }) async {
    if (!isAvailable(context, track, action)) return;
    final l10n = context.l10n;
    final anchor = position ?? DesktopMenu.anchorOf(context);
    switch (action) {
      case TrackAction.like:
        final library = context.read<LibraryProvider>();
        final liked = library.isLiked(track.id);
        library.toggleLike(track);
        _toast(
          context,
          liked ? l10n.toastLikeRemoved : l10n.toastLikeAdded,
          liked ? Icons.heart_broken_rounded : Icons.favorite_rounded,
        );
      case TrackAction.queue:
        context.read<PlaybackProvider>().addToQueue(track);
        _toast(context, l10n.toastAddedToQueue, Icons.queue_music_rounded);
      case TrackAction.sleepTimer:
        await SleepTimerMenu.show(context, position: anchor);
      case TrackAction.album:
        AppRoutes.openAlbum(context, track.album!);
      case TrackAction.artist:
        await _goToArtist(context, track, anchor);
      case TrackAction.addToPlaylist:
        await _addToPlaylist(context, track, anchor);
      case TrackAction.radio:
        await SongRadio.open(context, track);
      case TrackAction.credits:
        await TrackCreditsView.show(context, track);
      case TrackAction.share:
        await ShareSheet.show(context, ShareTarget.track(track));
    }
  }

  static Future<void> _goToArtist(
    BuildContext context,
    SpotifyTrack track,
    Offset position,
  ) async {
    if (track.artists.length == 1) {
      AppRoutes.openArtist(context, track.artists.first);
      return;
    }
    final picked = await DesktopMenu.show<int>(context, position, [
      for (var i = 0; i < track.artists.length; i++)
        PopupMenuItem<int>(
          value: i,
          height: 44,
          child: Row(
            children: [
              CoverImage(
                url: track.artists[i].avatarUrl,
                size: 28,
                circular: true,
                placeholderIcon: Icons.person_rounded,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  track.artists[i].name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
    ]);
    if (picked != null && context.mounted)
      AppRoutes.openArtist(context, track.artists[picked]);
  }

  /// 二级菜单：「新建歌单」+ 自建歌单（已包含该曲目的打勾）。
  static Future<void> _addToPlaylist(
    BuildContext context,
    SpotifyTrack track,
    Offset position,
  ) async {
    final l10n = context.l10n;
    final library = context.read<LibraryProvider>();
    final primary = Theme.of(context).colorScheme.primary;
    const createId = '\u0000new';

    final mobile = _isMobile(context);
    final item = mobile ? MobileMenu.item<String> : DesktopMenu.item<String>;
    final id = await DesktopMenu.show<String>(context, position, [
      item(createId, Icons.add_rounded, l10n.trackNewPlaylist),
      if (library.ownPlaylists.isNotEmpty)
        mobile ? MobileMenu.divider : DesktopMenu.divider,
      for (final playlist in library.ownPlaylists)
        item(
          playlist.id,
          playlist.tracks.any((t) => t.id == track.id)
              ? Icons.check_circle_rounded
              : Icons.queue_music_rounded,
          playlist.name,
          iconColor: playlist.tracks.any((t) => t.id == track.id)
              ? primary
              : null,
        ),
    ]);
    if (id == null || !context.mounted) return;

    if (id == createId) {
      final name = await CreatePlaylistDialog.show(context);
      if (name == null || !context.mounted) return;
      final created = library.createPlaylist(name);
      library.addTrackToPlaylist(created.id, track);
      _toast(
        context,
        l10n.toastAddedTo(created.name),
        Icons.playlist_add_check_rounded,
      );
      return;
    }
    final playlist = library.findPlaylist(id);
    if (playlist == null) return;
    final added = library.addTrackToPlaylist(id, track);
    _toast(
      context,
      added
          ? l10n.toastAddedTo(playlist.name)
          : l10n.toastAlreadyIn(playlist.name),
      added ? Icons.playlist_add_check_rounded : Icons.playlist_play_rounded,
    );
  }
}
