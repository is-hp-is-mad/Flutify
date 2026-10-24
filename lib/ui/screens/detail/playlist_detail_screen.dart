import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../l10n/l10n.dart';
import '../../../models/playback_context.dart';
import '../../../models/playlist.dart';
import '../../../models/share_target.dart';
import '../../../models/track.dart';
import '../../../providers/library_provider.dart';
import '../../../providers/preferences_provider.dart';
import '../../../services/backup/playlist_backup_service.dart';
import '../../../services/spotify_api_service.dart';
import '../../shell/shell_breakpoints.dart';
import '../../widgets/content_bottom_spacer.dart';
import '../../widgets/share/share_button.dart';
import '../../widgets/toast/app_toast.dart';
import '../../widgets/track_table/track_list_toolbar.dart';
import '../../widgets/track_table/track_sort.dart';
import '../../widgets/track_table/track_table_columns.dart';
import '../../widgets/track_table/track_table_header.dart';
import '../../widgets/track_tile.dart';
import 'widgets/collection_hero.dart';
import 'widgets/collection_widgets.dart';

/// 歌单详情页（含 Liked Songs 与自建歌单）。
///
/// - 媒体库中的歌单通过 select 实时反映增删歌曲。
/// - 从 Browse API 拿到的歌单通常不含曲目，打开时再请求 /playlists/{id}。
class PlaylistDetailScreen extends StatefulWidget {
  final SpotifyPlaylist playlist;
  final bool initialSelecting;

  const PlaylistDetailScreen({
    super.key,
    required this.playlist,
    this.initialSelecting = false,
  });

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  SpotifyPlaylist? _fetched;
  bool _loading = false;
  Object? _error;
  late bool _selecting = widget.initialSelecting;
  final Set<String> _selectedTrackIds = {};

  /// 歌单内搜索与排序（只在本页有效，离开即重置，与官方一致）。
  String _query = '';
  TrackSort _sort = TrackSort.custom;

  // 排序结果缓存：媒体库通知（点赞等）会重建本页，长歌单不必每次重排
  List<SpotifyTrack>? _sortedFrom;
  TrackSort? _sortedBy;
  List<SpotifyTrack> _sorted = const [];

  List<SpotifyTrack> _sortedTracks(List<SpotifyTrack> tracks) {
    if (!identical(tracks, _sortedFrom) || _sort != _sortedBy) {
      _sortedFrom = tracks;
      _sortedBy = _sort;
      _sorted = _sort.apply(tracks);
    }
    return _sorted;
  }

  @override
  void initState() {
    super.initState();
    final p = widget.playlist;
    if (widget.initialSelecting) {
      _selectedTrackIds.addAll(
        p.tracks.map((t) => t.id).where((id) => id.isNotEmpty),
      );
    }
    final isLibraryOwned =
        p.id == LibraryProvider.likedSongsId ||
        p.id.startsWith(BackupAccount.backupLikedPrefix) ||
        context.read<LibraryProvider>().isOwnPlaylist(p.id);
    // 卡片上的曲目数不可靠（主页 / 搜索卡片常缺，daylist 等动态歌单也可能报 0）：没带曲目就去拉
    if (!isLibraryOwned &&
        (p.tracks.isEmpty || p.tracks.length < p.totalTracks))
      _fetch();
  }

  /// 拉取完整歌单；失败时记录错误，由占位提供登录 / 重试。
  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final full = await context.read<SpotifyApiService>().getPlaylist(
        widget.playlist.id,
      );
      if (mounted) setState(() => _fetched = full);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryProvider>();

    final libraryVersion = context.select<LibraryProvider, SpotifyPlaylist?>(
      (l) => l.findPlaylist(widget.playlist.id),
    );
    final isSaved = context.select<LibraryProvider, bool>(
      (l) => l.isPlaylistSaved(widget.playlist.id),
    );

    final playlist = _fetched ?? libraryVersion ?? widget.playlist;
    final tracks = playlist.tracks;
    final isLikedSongs = playlist.id == LibraryProvider.likedSongsId;
    final isBackupLikedSongs =
        playlist.id.startsWith(BackupAccount.backupLikedPrefix);
    final backupService = context.watch<PlaylistBackupService?>();
    final isExternalBackupLikedSongs = isBackupLikedSongs &&
        (backupService?.isExternalBackupLikedPlaylist(playlist.id) ?? true);
    final isOwn = library.isOwnPlaylist(playlist.id);
    final l10n = context.l10n;
    // 「已点赞的歌曲」由 LibraryProvider 生成，名称与简介按界面语言展示
    final title = isLikedSongs ? l10n.likedSongs : playlist.name;
    final description = isLikedSongs
        ? l10n.likedSongsDescription
        : playlist.description;
    final playbackContext = isLikedSongs
        ? PlaybackContext.collection(title, uri: LibraryProvider.likedSongsUri)
        : PlaybackContext.playlist(playlist.name, uri: playlist.contextUri);
    final totalMs = tracks.fold<int>(0, (sum, t) => sum + t.durationMs);
    // 「12 首歌曲，45 分 12 秒」；时长未知时只显示歌曲数
    final songs = l10n.songCount(tracks.length);
    final summary = totalMs > 0
        ? l10n.countAndDuration(
            songs,
            Formatters.formatLongDuration(l10n, totalMs),
          )
        : songs;

    // 播放按排序后的顺序（与官方一致）；搜索只影响显示
    final sorted = _sortedTracks(tracks);
    final visible = TrackSort.filter(sorted, _query);
    final hasAddedAt = tracks.any((t) => t.addedAt != null);
    final desktop = ShellBreakpoints.isDesktop(
      MediaQuery.sizeOf(context).width,
    );
    final compact = context.select<PreferencesProvider?, bool>(
      (p) => p?.prefs.compactTrackList ?? false,
    );

    return Scaffold(
      body: LayoutBuilder(
        // 表格列随内容区宽度收起（只在窗口尺寸变化时重算）
        builder: (context, box) => _buildBody(
          context,
          playlist: playlist,
          tracks: tracks,
          sorted: sorted,
          visible: visible,
          title: title,
          description: description,
          summary: summary,
          isLikedSongs: isLikedSongs,
          isBackupLikedSongs: isBackupLikedSongs,
          isExternalBackupLikedSongs: isExternalBackupLikedSongs,
          isOwn: isOwn,
          isSaved: isSaved,
          playbackContext: playbackContext,
          hasAddedAt: hasAddedAt,
          compact: desktop && compact,
          columns: desktop
              ? TrackTableColumns.forWidth(
                  box.maxWidth,
                  compact: compact,
                  hasAddedAt: hasAddedAt,
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required SpotifyPlaylist playlist,
    required List<SpotifyTrack> tracks,
    required List<SpotifyTrack> sorted,
    required List<SpotifyTrack> visible,
    required String title,
    required String description,
    required String summary,
    required bool isLikedSongs,
    required bool isBackupLikedSongs,
    required bool isExternalBackupLikedSongs,
    required bool isOwn,
    required bool isSaved,
    required PlaybackContext playbackContext,
    required bool hasAddedAt,
    required bool compact,
    required TrackTableColumns? columns,
  }) {
    final l10n = context.l10n;
    final library = context.read<LibraryProvider>();
    return CollectionTintScope(
      imageUrl: (isLikedSongs || isBackupLikedSongs) ? '' : playlist.coverUrl,
      fallback: (isLikedSongs || isBackupLikedSongs)
          ? kLikedSongsTint
          : const Color(0xFF3A3A48),
      child: CustomScrollView(
        slivers: [
          CollectionHero(
            typeLabel: l10n.typePlaylist,
            title: title,
            imageUrl: playlist.coverUrl,
            coverOverride: (isLikedSongs || isBackupLikedSongs)
                ? const _LikedSongsCover()
                : null,
            meta: _PlaylistMeta(
              description: description,
              ownerName: playlist.ownerName,
              summary: summary,
            ),
            collapsedAction: ContextPlayButton(
              tracks: sorted,
              playbackContext: playbackContext,
              size: 44,
              elevated: false,
            ),
          ),

          SliverToBoxAdapter(
            child: CollectionHeroFade(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: CollectionActionRow(
                  tracks: sorted,
                  playbackContext: playbackContext,
                  trailing: tracks.isEmpty
                      ? null
                      : TrackListToolbar(
                          query: _query,
                          onQueryChanged: (q) => setState(() => _query = q),
                          sort: _sort,
                          onSortChanged: (s) => setState(() => _sort = s),
                          hasAddedAt: hasAddedAt,
                          compact: compact,
                          onCompactChanged: columns == null
                              ? null
                              : _setCompact,
                        ),
                  leading: [
                    if (!isLikedSongs && !isBackupLikedSongs && !isOwn)
                      SaveToggleButton(
                        saved: isSaved,
                        onPressed: () => library.togglePlaylistSaved(playlist),
                      ),
                    if (!isLikedSongs && tracks.isNotEmpty)
                      IconButton(
                        icon: Icon(
                          _selecting
                              ? Icons.check_box_rounded
                              : Icons.playlist_add_check_rounded,
                          size: 26,
                          color: _selecting
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        tooltip: _selecting
                            ? '退出多选'
                            : (isExternalBackupLikedSongs
                                  ? '选择部分歌曲一键导入到本账号'
                                  : '多选收藏歌曲'),
                        onPressed: () {
                          setState(() {
                            _selecting = !_selecting;
                            if (_selecting && _selectedTrackIds.isEmpty) {
                              _selectedTrackIds.addAll(
                                visible
                                    .map((t) => t.id)
                                    .where((id) => id.isNotEmpty),
                              );
                            }
                          });
                        },
                      ),
                    if (!isBackupLikedSongs)
                      ShareButton(target: ShareTarget.playlist(playlist)),
                    if (isOwn)
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_horiz_rounded, size: 28),
                        tooltip: l10n.commonMoreOptions,
                        onSelected: (value) {
                          if (value == 'delete') {
                            library.deletePlaylist(playlist.id);
                            Navigator.pop(context);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(l10n.playlistDelete),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),

          if (_selecting && tracks.isNotEmpty)
            SliverToBoxAdapter(
              child: _buildSelectionBar(
                context,
                playlist: playlist,
                visible: visible,
                isExternalBackupLikedSongs: isExternalBackupLikedSongs,
              ),
            ),

          if (_loading)
            const CollectionPlaceholder(loading: true)
          else if (_error != null)
            CollectionErrorPlaceholder(
              signedOut: identical(_error, SpotifyDataException.notSignedIn),
              onRetry: _fetch,
            )
          else if (tracks.isEmpty)
            CollectionPlaceholder(
              message: isLikedSongs
                  ? l10n.playlistLikedEmpty
                  : isOwn
                  ? l10n.playlistOwnEmpty
                  : l10n.playlistEmpty,
              icon: isLikedSongs
                  ? Icons.favorite_border_rounded
                  : Icons.queue_music_rounded,
            )
          else ...[
            if (columns != null)
              TrackTableHeader(
                columns: columns,
                sort: _sort,
                onSort: (key) => setState(() => _sort = _sort.tap(key)),
              ),
            if (visible.isEmpty)
              CollectionPlaceholder(
                message: l10n.trackSearchNoResults(_query.trim()),
                icon: Icons.search_off_rounded,
              )
            else
              // 定高列表：行高由原型行量出（随字号缩放自适应）。长歌单滚动时不必逐行测量、
              // 也不用估算总长度，滚动条比例稳定，拖动滚动条跳到中段也只布局可见行。
              SliverPrototypeExtentList(
                prototypeItem: TrackTile(
                  track: visible.first,
                  index: visible.length,
                  showCover: true,
                  columns: columns,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildTile(
                    visible[index],
                    index,
                    queue: sorted,
                    ctx: playbackContext,
                    columns: columns,
                    ownPlaylistId: isOwn ? playlist.id : null,
                  ),
                  childCount: visible.length,
                ),
              ),
          ],

          const ContentBottomSpacer(),
        ],
      ),
    );
  }

  void _setCompact(bool compact) {
    final prefs = context.read<PreferencesProvider>();
    prefs.update(prefs.prefs.copyWith(compactTrackList: compact));
  }

  Widget _buildSelectionBar(
    BuildContext context, {
    required SpotifyPlaylist playlist,
    required List<SpotifyTrack> visible,
    required bool isExternalBackupLikedSongs,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final visibleIds = visible
        .map((t) => t.id)
        .where((id) => id.isNotEmpty)
        .toList();
    final allSelected =
        visibleIds.isNotEmpty && visibleIds.every(_selectedTrackIds.contains);
    final selectedTracks = [
      for (final t in visible)
        if (_selectedTrackIds.contains(t.id)) t,
    ];

    Future<void> likeSelectedTracks() async {
      if (selectedTracks.isEmpty) return;
      final backup = context.read<PlaylistBackupService?>();
      final library = context.read<LibraryProvider>();
      var added = 0;
      if (backup != null) {
        added = await backup.importSelectedTracksToLiked(selectedTracks);
      } else {
        for (final t in selectedTracks.reversed) {
          if (t.id.isNotEmpty && !library.isLiked(t.id)) {
            library.toggleLike(t);
            added++;
          }
        }
      }
      if (!context.mounted) return;
      AppToast.show(
        context,
        isExternalBackupLikedSongs
            ? '已将所选 ${selectedTracks.length} 首歌曲合并导入到本账号「已点赞的歌曲」（新增 $added 首）'
            : '已收藏所选 ${selectedTracks.length} 首歌曲（新增 $added 首）',
        icon: Icons.favorite_rounded,
        tone: ToastTone.success,
      );
    }

    void importAsPlaylist() {
      if (selectedTracks.isEmpty) return;
      final library = context.read<LibraryProvider>();
      final imported = playlist.copyWith(
        id: 'imported_${DateTime.now().millisecondsSinceEpoch}',
        uri: '',
        tracks: selectedTracks,
        totalTracks: selectedTracks.length,
      );
      library.upsertLocalPlaylist(imported);
      AppToast.show(
        context,
        '已导入歌单「${playlist.name}」（包含所选 ${selectedTracks.length} 首歌曲）到本账号',
        icon: Icons.playlist_add_check_rounded,
        tone: ToastTone.success,
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              M3EButton.icon(style: M3EButtonStyle.text, 
                onPressed: () {
                  setState(() {
                    if (allSelected) {
                      _selectedTrackIds.removeAll(visibleIds);
                    } else {
                      _selectedTrackIds.addAll(visibleIds);
                    }
                  });
                },
                icon: Icon(
                  allSelected
                      ? Icons.check_box_rounded
                      : Icons.check_box_outline_blank_rounded,
                  size: 20,
                ),
                label: Text(allSelected ? '取消全选' : '全选'),
              ),
              Text(
                '已选 ${selectedTracks.length} / ${visible.length} 首',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              M3EButton.icon(style: M3EButtonStyle.filled, 
                onPressed: selectedTracks.isEmpty ? null : likeSelectedTracks,
                icon: const Icon(Icons.favorite_rounded, size: 18),
                label: Text(
                  isExternalBackupLikedSongs
                      ? '一键合并到本账号已点赞歌曲'
                      : '收藏所选歌曲（${selectedTracks.length}）',
                ),
              ),
              if (isExternalBackupLikedSongs)
                M3EButton.icon(style: M3EButtonStyle.outlined, 
                  onPressed: selectedTracks.isEmpty ? null : importAsPlaylist,
                  icon: const Icon(Icons.library_add_rounded, size: 18),
                  label: const Text('将所选导入为本账号歌单'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// [queue] 是排序后的完整歌单（搜索时也从完整列表接着播），[index] 是在显示列表里的位置。
  Widget _buildTile(
    SpotifyTrack track,
    int index, {
    required List<SpotifyTrack> queue,
    required PlaybackContext ctx,
    required TrackTableColumns? columns,
    required String? ownPlaylistId,
  }) {
    Widget tile = TrackTile(
      key: ValueKey(track.id),
      track: track,
      index: index + 1,
      showCover: true,
      contextQueue: queue,
      playbackContext: ctx,
      columns: columns,
    );
    if (_selecting) {
      final selected = _selectedTrackIds.contains(track.id);
      tile = Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: M3ECheckbox(
              value: selected,
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _selectedTrackIds.add(track.id);
                  } else {
                    _selectedTrackIds.remove(track.id);
                  }
                });
              },
            ),
          ),
          Expanded(child: tile),
        ],
      );
    }
    if (ownPlaylistId == null) return tile;

    // 自建歌单支持左滑移除曲目。定高列表里行不能收缩，滑出后立即移除（不做收起动画）
    return Dismissible(
      key: ValueKey('own_${track.id}'),
      direction: DismissDirection.endToStart,
      resizeDuration: null,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: Theme.of(context).colorScheme.errorContainer,
        child: Icon(Icons.delete_rounded, color: Theme.of(context).colorScheme.onErrorContainer),
      ),
      onDismissed: (_) => context
          .read<LibraryProvider>()
          .removeTrackFromPlaylist(ownPlaylistId, track.id),
      child: tile,
    );
  }
}

/// 头部元信息：简介（一行）+ 作者 · 歌曲数与总时长。
class _PlaylistMeta extends StatelessWidget {
  final String description;
  final String ownerName;
  final String summary;

  const _PlaylistMeta({
    required this.description,
    required this.ownerName,
    required this.summary,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (description.isNotEmpty) ...[
          Text(
            description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
        ],
        Row(
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: context.tokens.accent,
              child: Icon(
                Icons.music_note_rounded,
                color: context.tokens.onAccent,
                size: 14,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                ownerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Flexible(
              child: Text(
                ' · $summary',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Liked Songs 的渐变爱心封面（不依赖网络图片）。
class _LikedSongsCover extends StatelessWidget {
  const _LikedSongsCover();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 180,
      height: 180,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: kLikedSongsGradient,
      ),
      child: const Icon(Icons.favorite_rounded, color: Colors.white, size: 72),
    );
  }
}
