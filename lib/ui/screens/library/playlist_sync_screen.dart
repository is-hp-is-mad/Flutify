import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../models/playlist.dart';
import '../../../providers/library_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/cover_image.dart';
import '../../widgets/flutify_progress.dart';
import '../../../l10n/l10n.dart';

enum _SyncState { pending, running, done, failed }

/// 「同步歌单到 Spotify」页：列出只存在本机的歌单，勾选后逐个写进当前账号。
///
/// 旧版本里在 Flutify 收藏、新建或从备份导入的歌单只保存在本机，没有写进账号的音乐库
/// （rootlist），在官方客户端 / 网页版里看不到。这里把它们补写过去：
/// - 别人的歌单：加入音乐库（加不进去且本机有曲目时，新建同名副本）；
/// - 本机新建 / 只在本机的歌单：在账号里新建同名歌单并写入曲目。
class PlaylistSyncScreen extends StatefulWidget {
  const PlaylistSyncScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute(builder: (_) => const PlaylistSyncScreen()),
      );

  @override
  State<PlaylistSyncScreen> createState() => _PlaylistSyncScreenState();
}

class _PlaylistSyncScreenState extends State<PlaylistSyncScreen> {
  /// 打开页面时的待同步列表（同步过程中 provider 的列表会变，这里固定住）。
  late final List<SpotifyPlaylist> _items =
      List.of(context.read<LibraryProvider>().unsyncedPlaylists);
  late final Set<String> _selected = {for (final p in _items) p.id};
  final Map<String, _SyncState> _states = {};
  final Map<String, String> _errors = {};
  bool _running = false;

  int _count(_SyncState s) => _states.values.where((v) => v == s).length;

  Future<void> _start() async {
    final library = context.read<LibraryProvider>();
    setState(() => _running = true);
    for (final p in _items) {
      if (!_selected.contains(p.id) || _states[p.id] == _SyncState.done) continue;
      if (!mounted) return;
      setState(() {
        _states[p.id] = _SyncState.running;
        _errors.remove(p.id);
      });
      try {
        await library.syncPlaylistToAccount(p);
        _states[p.id] = _SyncState.done;
      } catch (e) {
        _states[p.id] = _SyncState.failed;
        _errors[p.id] = '$e';
      }
      if (mounted) setState(() {});
    }
    if (!mounted) return;
    setState(() => _running = false);
    // 以账号为准重新读一遍（新建的歌单拿到封面、曲目数等）
    await library.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = context.l10n;
    final done = _count(_SyncState.done);
    final failed = _count(_SyncState.failed);
    final finished = !_running && (done + failed) > 0;
    final pendingSelected = _items
        .where((p) => _selected.contains(p.id) && _states[p.id] != _SyncState.done)
        .length;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.playlistSyncTitle),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: _running ? null : () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              l10n.playlistSyncIntro,
              style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          if (finished)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                failed == 0
                    ? l10n.playlistSyncDone(done)
                    : l10n.playlistSyncPartial(done, failed),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: failed == 0 ? colors.primary : colors.error,
                ),
              ),
            ),
          Expanded(
            child: _items.isEmpty
                ? Center(child: Text(l10n.playlistSyncAllDone, style: theme.textTheme.bodyLarge))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: _items.length,
                    itemBuilder: (context, i) => _row(context, _items[i]),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _running
                          ? l10n.playlistSyncRunning
                          : l10n.playlistSyncSelected(pendingSelected),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  if (_running)
                    const SizedBox(width: 24, height: 24, child: FlutifyLoadingIndicator())
                  else if (finished && pendingSelected == 0)
                    AppButton.filled(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l10n.commonDone),
                    )
                  else
                    AppButton.filled(
                      onPressed: pendingSelected == 0 ? null : _start,
                      child: Text(failed > 0 ? l10n.commonRetry : l10n.playlistSyncStart),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, SpotifyPlaylist p) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final library = context.read<LibraryProvider>();
    final own = library.isOwnPlaylist(p.id);
    final count = p.tracks.isNotEmpty ? p.tracks.length : p.totalTracks;
    final state = _states[p.id] ?? _SyncState.pending;
    final l10n = context.l10n;
    final action = own ? l10n.playlistSyncCreate(l10n.songCount(count)) : l10n.playlistSyncAdd;
    final (String status, Color color) = switch (state) {
      _SyncState.pending => (action, colors.onSurfaceVariant),
      _SyncState.running => (l10n.playlistSyncStateRunning, colors.primary),
      _SyncState.done => (l10n.playlistSyncStateDone, colors.primary),
      _SyncState.failed => (l10n.playlistSyncStateFailed(_errors[p.id] ?? ''), colors.error),
    };
    final locked = _running || state == _SyncState.done;
    return InkWell(
      borderRadius: context.tokens.radius(12),
      onTap: locked
          ? null
          : () => setState(() {
                if (!_selected.remove(p.id)) _selected.add(p.id);
              }),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            AppCheckbox(
              value: _selected.contains(p.id),
              onChanged: locked
                  ? null
                  : (v) => setState(() {
                        if (v == true) {
                          _selected.add(p.id);
                        } else {
                          _selected.remove(p.id);
                        }
                      }),
            ),
            const SizedBox(width: 4),
            CoverImage(
              url: p.coverUrl,
              size: 48,
              borderRadius: context.tokens.radius(8),
              placeholderIcon: Icons.queue_music_rounded,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: color),
                  ),
                ],
              ),
            ),
            if (state == _SyncState.done)
              Icon(Icons.check_circle_rounded, color: colors.primary)
            else if (state == _SyncState.failed)
              Icon(Icons.error_rounded, color: colors.error),
          ],
        ),
      ),
    );
  }
}
