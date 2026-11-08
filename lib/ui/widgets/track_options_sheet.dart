import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../models/artist.dart';
import '../../models/share_target.dart';
import '../../models/track.dart';
import '../../providers/library_provider.dart';
import '../../providers/playback_provider.dart';
import '../../providers/sleep_timer_provider.dart';
import '../navigation/app_routes.dart';
import 'cover_image.dart';
import 'create_playlist_dialog.dart';
import 'share/share_sheet.dart';
import 'sleep_timer/sleep_timer_menu.dart';
import 'toast/app_toast.dart';
import 'track_actions/song_radio.dart';
import 'track_actions/track_credits_view.dart';
import 'app_modal.dart';

/// 曲目「更多」操作面板（Spotify 长按 / ⋮ 菜单）。
class TrackOptionsSheet extends StatelessWidget {
  final SpotifyTrack track;

  /// 打开面板前的页面 context，用于关闭面板后展示提示与导航。
  final BuildContext hostContext;

  const TrackOptionsSheet({super.key, required this.track, required this.hostContext});

  static Future<void> show(BuildContext context, SpotifyTrack track) {
    return showAppBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (_) => TrackOptionsSheet(track: track, hostContext: context),
    );
  }

  void _toast(String message, IconData icon) {
    if (!hostContext.mounted) return;
    AppToast.show(hostContext, message, icon: icon, tone: ToastTone.success);
  }

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();
    final l10n = context.l10n;
    final isLiked = context.select<LibraryProvider, bool>((l) => l.isLiked(track.id));
    final album = track.album;

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: CoverImage(url: track.coverUrl, size: 48, borderRadius: BorderRadius.circular(6)),
              title: Text(track.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(track.artistNames, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(
                isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                color: isLiked ? Theme.of(context).colorScheme.primary : null,
              ),
              title: Text(isLiked ? l10n.likeRemove : l10n.likeAdd),
              onTap: () {
                library.toggleLike(track);
                Navigator.pop(context);
                _toast(
                  isLiked ? l10n.toastLikeRemoved : l10n.toastLikeAdded,
                  isLiked ? Icons.heart_broken_rounded : Icons.favorite_rounded,
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_rounded),
              title: Text(l10n.trackAddToPlaylist),
              onTap: () {
                Navigator.pop(context);
                _showAddToPlaylist(hostContext);
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music_rounded),
              title: Text(l10n.trackAddToQueue),
              onTap: () {
                context.read<PlaybackProvider>().addToQueue(track);
                Navigator.pop(context);
                _toast(l10n.toastAddedToQueue, Icons.queue_music_rounded);
              },
            ),
            if (context.read<SleepTimerProvider?>() != null)
              ListTile(
                leading: const Icon(Icons.bedtime_outlined),
                title: Text(l10n.sleepTimer),
                onTap: () {
                  Navigator.pop(context);
                  if (hostContext.mounted) SleepTimerMenu.show(hostContext);
                },
              ),
            ListTile(
              leading: const Icon(Icons.sensors_rounded),
              title: Text(l10n.trackGoToRadio),
              onTap: () {
                Navigator.pop(context);
                if (hostContext.mounted) SongRadio.open(hostContext, track);
              },
            ),
            if (album != null && album.id.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.album_rounded),
                title: Text(l10n.trackGoToAlbum),
                onTap: () => AppRoutes.openAlbum(hostContext, album),
              ),
            if (track.artists.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.person_rounded),
                title: Text(l10n.trackGoToArtist(track.artists.length)),
                onTap: () => _goToArtist(context),
              ),
            ListTile(
              leading: const Icon(Icons.groups_outlined),
              title: Text(l10n.trackViewCredits),
              onTap: () {
                Navigator.pop(context);
                if (hostContext.mounted) TrackCreditsView.show(hostContext, track);
              },
            ),
            if (_share.isShareable)
              ListTile(
                leading: const Icon(Icons.ios_share_rounded),
                title: Text(l10n.commonShare),
                onTap: () {
                  Navigator.pop(context);
                  if (hostContext.mounted) ShareSheet.show(hostContext, _share);
                },
              ),
          ],
        ),
      ),
    );
  }

  ShareTarget get _share => ShareTarget.track(track);

  /// 曲目里的 artist 是 simplified 对象（无头像）；艺人详情页会按 id 再补全完整信息。
  SpotifyArtist _resolveArtist(SpotifyArtist a) => a;

  void _goToArtist(BuildContext sheetContext) {
    if (track.artists.length == 1) {
      AppRoutes.openArtist(hostContext, _resolveArtist(track.artists.first));
      return;
    }
    Navigator.pop(sheetContext);
    showAppBottomSheet(
      context: hostContext,
      useRootNavigator: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: track.artists.map((a) {
            final artist = _resolveArtist(a);
            return ListTile(
              leading: CoverImage(
                url: artist.avatarUrl,
                size: 40,
                circular: true,
                placeholderIcon: Icons.person_rounded,
              ),
              title: Text(artist.name),
              onTap: () => AppRoutes.openArtist(hostContext, artist),
            );
          }).toList(),
        ),
      ),
    );
  }

  void _showAddToPlaylist(BuildContext host) {
    showAppBottomSheet(
      context: host,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (ctx) {
        final library = ctx.watch<LibraryProvider>();
        final l10n = ctx.l10n;
        final own = library.ownPlaylists.map((p) => p.id).toList();
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Text(
                    l10n.trackAddToPlaylist,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                ListTile(
                  leading: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.add_rounded),
                  ),
                  title: Text(l10n.trackNewPlaylist, style: const TextStyle(fontWeight: FontWeight.w600)),
                  onTap: () async {
                    final name = await CreatePlaylistDialog.show(ctx);
                    if (name == null) return;
                    final created = library.createPlaylist(name);
                    library.addTrackToPlaylist(created.id, track);
                    if (ctx.mounted) Navigator.pop(ctx);
                    _toast(l10n.toastAddedTo(created.name), Icons.playlist_add_check_rounded);
                  },
                ),
                for (final id in own)
                  Builder(
                    builder: (_) {
                      final playlist = library.findPlaylist(id)!;
                      final contains = playlist.tracks.any((t) => t.id == track.id);
                      return ListTile(
                        leading: CoverImage(url: playlist.coverUrl, size: 48, borderRadius: BorderRadius.circular(6)),
                        title: Text(playlist.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(l10n.songCount(playlist.tracks.length)),
                        trailing: contains
                            ? Icon(Icons.check_circle_rounded, color: Theme.of(ctx).colorScheme.primary)
                            : null,
                        onTap: () {
                          final added = library.addTrackToPlaylist(id, track);
                          Navigator.pop(ctx);
                          _toast(
                            added ? l10n.toastAddedTo(playlist.name) : l10n.toastAlreadyIn(playlist.name),
                            added ? Icons.playlist_add_check_rounded : Icons.playlist_play_rounded,
                          );
                        },
                      );
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
