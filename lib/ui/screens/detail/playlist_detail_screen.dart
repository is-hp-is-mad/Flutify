import 'dart:async';

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
import '../../../providers/playback_provider.dart';
import '../../../providers/preferences_provider.dart';
import '../../../services/backup/playlist_backup_service.dart';
import '../../../services/spotify_api_service.dart';
import '../../shell/shell_breakpoints.dart';
import '../../widgets/content_bottom_spacer.dart';
import '../../widgets/menu/desktop_menu.dart';
import '../../widgets/menu/mobile_menu.dart';
import '../../widgets/share/share_button.dart';
import '../../widgets/sliver_clip.dart';
import '../../widgets/toast/app_toast.dart';
import '../../widgets/track_table/track_list_toolbar.dart';
import '../../widgets/track_table/track_sort.dart';
import '../../widgets/track_table/track_table_columns.dart';
import '../../widgets/track_table/track_table_header.dart';
import '../../widgets/track_swipe_actions.dart';
import '../../widgets/track_tile.dart';
import '../watchfeed/widgets/watch_feed_entity_button.dart';
import 'widgets/collection_hero.dart';
import 'widgets/collection_widgets.dart';
import '../../widgets/app_button.dart';

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
  bool _loadingMore = false;

  /// 本次拉取结束（拉完或出错）时完成；没在拉取时为 null。
  Future<void>? _loadDone;

  /// 正在从服务端刷新歌单（先显示的可能是本机缓存的旧快照，或只拉到了前几批）。
  bool _refreshing = false;

  /// 最近一次刷新失败：之后的播放按手头的缓存 / 已拿到的曲目播，并提示一句。
  bool _refreshFailed = false;

  /// 已点播放、正在等刷新结束（播放键转圈）；[_playRequest] 让后一次点击取代前一次。
  bool _playPending = false;
  int _playRequest = 0;
  StreamSubscription<SpotifyPlaylist>? _playlistSub;
  Object? _error;
  late bool _selecting = widget.initialSelecting;
  final Set<String> _selectedTrackIds = {};

  /// 歌单内搜索只在本页有效；排序按歌单记在偏好 `playlistTrackSorts` 里，下次打开同一歌单沿用。
  String _query = '';

  /// 搜索框是否展开（窄布局下输入框要单独占一行，见 CollectionActionRow.trailingExpanded）。
  bool _searchOpen = false;

  /// 没有 PreferencesProvider（部分测试）时只在本页内存里记排序。
  TrackSort? _unsavedSort;

  // 排序结果缓存：媒体库通知（点赞等）会重建本页，长歌单不必每次重排
  List<SpotifyTrack>? _sortedFrom;
  TrackSort? _sortedBy;
  List<SpotifyTrack> _sorted = const [];

  List<SpotifyTrack> _sortedTracks(List<SpotifyTrack> tracks, TrackSort sort) {
    if (!identical(tracks, _sortedFrom) || sort != _sortedBy) {
      _sortedFrom = tracks;
      _sortedBy = sort;
      _sorted = sort.apply(tracks);
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
    // Spotify 上真实存在的歌单每次都以服务端为准重新拉取：本机收藏 / 备份导入时存下的曲目只是快照，
    // 官方编辑歌单每周都在变。拿快照点歌会把旧顺序交给播放队列，与 Connect 服务端按当前歌单
    // 展开的顺序对不上，队列只剩服务端下发的两首。拉取期间先显示快照，拉取失败时继续用快照。
    if (!isLibraryOwned) {
      final hasSnapshot = p.tracks.isNotEmpty ||
          (context.read<LibraryProvider>().findPlaylist(p.id)?.tracks.isNotEmpty ?? false);
      _fetch(quiet: hasSnapshot);
    }
  }

  /// 懒加载/流式拉取歌单：首批 100 首到达即刻渲染，后续曲目在后台增量补齐。
  /// [quiet]：已有本机快照可显示，后台刷新、不显示加载占位。
  Future<void> _fetch({bool quiet = false}) async {
    await _playlistSub?.cancel();
    setState(() {
      _loading = !quiet;
      _loadingMore = false;
      _error = null;
      _refreshing = true;
      _refreshFailed = false;
    });
    final completer = Completer<void>();
    _loadDone = completer.future;
    _playlistSub = context
        .read<SpotifyApiService>()
        .watchPlaylist(widget.playlist.id)
        .listen(
          (snap) {
            if (!mounted) return;
            setState(() {
              _fetched = snap;
              _loading = false;
              _loadingMore =
                  snap.totalTracks > 0 && snap.tracks.length < snap.totalTracks;
            });
          },
          onError: (Object e) {
            if (mounted) {
              setState(() {
                // 有本机快照（如对方已设为私密的备份歌单）时继续显示快照，不当作错误
                final snapshot =
                    context.read<LibraryProvider>().findPlaylist(widget.playlist.id)?.tracks ??
                    widget.playlist.tracks;
                if (_fetched == null && snapshot.isEmpty) _error = e;
                _loading = false;
                _loadingMore = false;
                _refreshing = false;
                _refreshFailed = true;
              });
            }
            if (!completer.isCompleted) completer.complete();
          },
          onDone: () {
            if (mounted) {
              setState(() {
                _loading = false;
                _loadingMore = false;
                _refreshing = false;
              });
            }
            if (!completer.isCompleted) completer.complete();
          },
        );
    return completer.future;
  }

  @override
  void dispose() {
    _playlistSub?.cancel();
    super.dispose();
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
    final savedSort = context.select<PreferencesProvider?, String?>(
      (p) => p?.prefs.playlistTrackSorts[widget.playlist.id],
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
    // 歌曲数取歌单总数（分页接口第一页就给出 totalTracks），不是已加载的条数：长歌单分页加载时
    // 不再把「已加载 300 首」显示成「300 首歌曲」。动态歌单等可能报 0 或偏小，取两者较大值。
    final loadedCount = tracks.length;
    final totalCount =
        playlist.totalTracks > loadedCount ? playlist.totalTracks : loadedCount;
    final songs = l10n.songCount(totalCount);
    final String summary;
    if (loadedCount < totalCount) {
      // 没加载完（仍在加载或中途失败）：「1200 首歌曲 · 已加载 300 首」；时长只是已加载部分，不显示
      summary = '$songs · ${l10n.songCountLoaded(loadedCount)}';
    } else {
      // 「12 首歌曲，45 分 12 秒」；时长未知时只显示歌曲数
      final totalMs = tracks.fold<int>(0, (sum, t) => sum + t.durationMs);
      summary = totalMs > 0
          ? l10n.countAndDuration(
              songs,
              Formatters.formatLongDuration(l10n, totalMs),
            )
          : songs;
    }

    // 播放按排序后的顺序（与官方一致）；搜索只影响显示。
    // 记的是「添加日期」但这个歌单没有加入时间（自动生成的歌单 / 曲目还没拉到）：按自定义顺序显示，不改记录。
    final hasAddedAt = tracks.any((t) => t.addedAt != null);
    final sort = (_unsavedSort ?? TrackSort.decode(savedSort)).availableFor(
      tracks,
    );
    final sorted = _sortedTracks(tracks, sort);
    final visible = TrackSort.filter(sorted, _query);
    // 排过序时打上标记：Connect 点歌带上整列，远程才按用户排的顺序播（见 ConnectPlayRequest.from）
    final playbackContext = _contextFor(
      playlist,
      title: title,
      isLikedSongs: isLikedSongs,
      sort: sort,
    );
    // 歌单还在刷新时（先显示的是本机缓存的旧快照，或只拉到了前几批）不按手头的列表播：
    // 点播放先等刷新结束，再按最新的完整歌单排序后播放（见 _playWhenLoaded）。
    // 「已点赞的歌曲」跟着媒体库刷新，等媒体库读完。
    final likedRefreshing = context.select<LibraryProvider, bool>(
      (l) => isLikedSongs && l.isLoading,
    );
    final waitForRefresh = _refreshing || likedRefreshing || _playPending;
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
          sort: sort,
          title: title,
          description: description,
          summary: summary,
          isLikedSongs: isLikedSongs,
          isBackupLikedSongs: isBackupLikedSongs,
          isExternalBackupLikedSongs: isExternalBackupLikedSongs,
          isOwn: isOwn,
          isSaved: isSaved,
          playbackContext: playbackContext,
          waitForRefresh: waitForRefresh,
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
    required TrackSort sort,
    required String title,
    required String description,
    required String summary,
    required bool isLikedSongs,
    required bool isBackupLikedSongs,
    required bool isExternalBackupLikedSongs,
    required bool isOwn,
    required bool isSaved,
    required PlaybackContext playbackContext,
    required bool waitForRefresh,
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
              onPlay: waitForRefresh ? _playWhenLoaded : null,
              loading: _playPending,
            ),
          ),

          SliverToBoxAdapter(
            child: CollectionHeroFade(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: CollectionActionRow(
                  tracks: sorted,
                  playbackContext: playbackContext,
                  onPlay: waitForRefresh ? _playWhenLoaded : null,
                  playLoading: _playPending,
                  trailingExpanded: _searchOpen || _query.isNotEmpty,
                  // 官方歌单（非「已点赞」、非自建）才可能有视频流；没有内容时按钮自己不显示。
                  afterPlay: isLikedSongs || isBackupLikedSongs || isOwn
                      ? null
                      : WatchFeedEntityButton(
                          feedUri: 'spotify:watch-feed:playlist:${playlist.id}',
                          name: playlist.name,
                        ),
                  trailing: tracks.isEmpty
                      ? null
                      : TrackListToolbar(
                          query: _query,
                          onQueryChanged: (q) => setState(() => _query = q),
                          sort: sort,
                          onSortChanged: _setSort,
                          hasAddedAt: hasAddedAt,
                          compact: compact,
                          onCompactChanged: columns == null
                              ? null
                              : _setCompact,
                          onSearchOpenChanged: (open) =>
                              setState(() => _searchOpen = open),
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
                            ? l10n.backupExitMultiSelect
                            : (isExternalBackupLikedSongs
                                  ? l10n.backupPickTracksImport
                                  : l10n.backupPickTracks),
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
                      FlutifyPopupMenuButton<String>(
                        icon: const Icon(Icons.more_horiz_rounded, size: 28),
                        tooltip: l10n.commonMoreOptions,
                        morph: true,
                        onSelected: (value) {
                          if (value == 'delete') {
                            library.deletePlaylist(playlist.id);
                            Navigator.pop(context);
                          }
                        },
                        itemBuilder: (context) => [
                          // 手机上的形变菜单用 Apple 式菜单行（删除为红色）；桌面照旧
                          if (ShellBreakpoints.isDesktop(
                            MediaQuery.sizeOf(context).width,
                          ))
                            PopupMenuItem(
                              value: 'delete',
                              child: Text(l10n.playlistDelete),
                            )
                          else
                            MobileMenu.item(
                              'delete',
                              Icons.delete_outline_rounded,
                              l10n.playlistDelete,
                              destructive: true,
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
            if (_loadingMore)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    value: playlist.totalTracks > 0
                        ? (tracks.length / playlist.totalTracks).clamp(0.0, 1.0)
                        : null,
                  ),
                ),
              ),
            if (columns != null)
              TrackTableHeader(
                columns: columns,
                sort: sort,
                onSort: (key) => _setSort(sort.tap(key)),
              ),
            if (visible.isEmpty)
              CollectionPlaceholder(
                message: l10n.trackSearchNoResults(_query.trim()),
                icon: Icons.search_off_rounded,
              )
            else
              // 定高列表：行高由原型行量出（随字号缩放自适应）。长歌单滚动时不必逐行测量、
              // 也不用估算总长度，滚动条比例稳定，拖动滚动条跳到中段也只布局可见行。
              Builder(
                builder: (context) {
                  final list = SliverPrototypeExtentList(
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
                        waitForRefresh: waitForRefresh,
                        columns: columns,
                        ownPlaylistId: isOwn ? playlist.id : null,
                      ),
                      childCount: visible.length,
                    ),
                  );
                  if (columns != null) {
                    final stickyTop = 64.0 + TrackTableHeader.height + MediaQuery.paddingOf(context).top;
                    return SliverTopClip(top: stickyTop, sliver: list);
                  }
                  return list;
                },
              ),
          ],

          const ContentBottomSpacer(),
        ],
      ),
    );
  }

  /// 本页的播放上下文；排过序时打上标记，Connect 点歌带上整列，远程才按用户排的顺序播（见 ConnectPlayRequest.from）。
  static PlaybackContext _contextFor(
    SpotifyPlaylist playlist, {
    required String title,
    required bool isLikedSongs,
    required TrackSort sort,
  }) =>
      (isLikedSongs
              ? PlaybackContext.collection(
                  title,
                  uri: LibraryProvider.likedSongsUri,
                )
              : PlaybackContext.playlist(
                  playlist.name,
                  uri: playlist.contextUri,
                ))
          .withReordered(sort != TrackSort.custom);

  /// 歌单还在刷新时点播放（[start] 非空时从这首开始）：先等这次刷新结束，再按最新的完整歌单
  /// 重新排序后播放。手头的列表可能是本机缓存的旧快照或只拉到了前几批，拿它点歌会让播放队列
  /// 和歌单对不上（顺序错乱、Connect 下只剩几百首）。
  /// 刷新失败（如离线）时按手头的缓存播放，并提示一句。连续点击只播最后一次。
  Future<void> _playWhenLoaded({SpotifyTrack? start}) async {
    final playback = context.read<PlaybackProvider>();
    final library = context.read<LibraryProvider>();
    final request = ++_playRequest;
    final isLikedSongs = widget.playlist.id == LibraryProvider.likedSongsId;
    setState(() => _playPending = true);
    if (_refreshing) await _loadDone;
    if (isLikedSongs) await library.whenLoaded();
    if (!mounted || request != _playRequest) return;
    setState(() => _playPending = false);

    final playlist = _fetched ??
        library.findPlaylist(widget.playlist.id) ??
        widget.playlist;
    final tracks = playlist.tracks;
    if (tracks.isEmpty) return;
    if (_refreshFailed || (isLikedSongs && library.loadError != null)) {
      AppToast.show(
        context,
        context.l10n.playlistPlayingCachedCopy,
        icon: Icons.cloud_off_rounded,
      );
    }
    final savedSort = context
        .read<PreferencesProvider?>()
        ?.prefs
        .playlistTrackSorts[widget.playlist.id];
    final sort = (_unsavedSort ?? TrackSort.decode(savedSort)).availableFor(
      tracks,
    );
    final ctx = _contextFor(
      playlist,
      title: isLikedSongs ? context.l10n.likedSongs : playlist.name,
      isLikedSongs: isLikedSongs,
      sort: sort,
    );
    final queue = _sortedTracks(tracks, sort);
    if (start == null) {
      await playback.playContext(queue, ctx);
    } else {
      // 刷新后换成新列表里的同一首；新列表里已经没有这首时照样从它开始
      final fresh = queue.firstWhere((t) => t.id == start.id, orElse: () => start);
      await playback.playTrack(fresh, contextQueue: queue, context: ctx);
    }
  }

  void _setSort(TrackSort sort) {
    final prefs = context.read<PreferencesProvider?>();
    if (prefs == null || widget.playlist.id.isEmpty) {
      return setState(() => _unsavedSort = sort);
    }
    prefs.update(
      prefs.prefs.withPlaylistTrackSort(widget.playlist.id, sort.encode()),
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
            ? context.l10n.backupLikedMerged(
                context.l10n.songCount(selectedTracks.length),
                added,
              )
            : context.l10n.backupLikedSaved(
                context.l10n.songCount(selectedTracks.length),
                added,
              ),
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
        context.l10n.backupImportedAsPlaylist(
          context.l10n.songCount(selectedTracks.length),
          playlist.name,
        ),
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
              AppButton.icon(style: M3EButtonStyle.text, 
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
                label: Text(
                  allSelected ? context.l10n.backupDeselectAll : context.l10n.menuSelectAll,
                ),
              ),
              Text(
                context.l10n.backupSelectedCount(selectedTracks.length, visible.length),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              AppButton.icon(style: M3EButtonStyle.filled, 
                onPressed: selectedTracks.isEmpty ? null : likeSelectedTracks,
                icon: const Icon(Icons.favorite_rounded, size: 18),
                label: Text(
                  isExternalBackupLikedSongs
                      ? context.l10n.backupMergeLikedShort
                      : context.l10n.backupSaveSelected(selectedTracks.length),
                ),
              ),
              if (isExternalBackupLikedSongs)
                AppButton.icon(style: M3EButtonStyle.outlined, 
                  onPressed: selectedTracks.isEmpty ? null : importAsPlaylist,
                  icon: const Icon(Icons.library_add_rounded, size: 18),
                  label: Text(context.l10n.backupImportAsPlaylistShort),
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
    required bool waitForRefresh,
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
      onTap: waitForRefresh ? () => _playWhenLoaded(start: track) : null,
    );
    if (_selecting) {
      final selected = _selectedTrackIds.contains(track.id);
      tile = Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: AppCheckbox(
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
      return _ownPlaylistSwipe(tile, track, ownPlaylistId);
    }

    // 自定义功能里的滑动手势：右滑下个播放，左滑加入 / 移出音乐库。
    // 在行自己的 build 里判断（这里是列表委托回调，不能 select）。
    final row = tile;
    return Builder(
      key: ValueKey('row_${track.id}'),
      builder: (context) {
        if (!TrackSwipeGestures.active(context)) {
          return _ownPlaylistSwipe(row, track, ownPlaylistId);
        }
        final swipeToLibrary =
            context.read<PreferencesProvider?>()?.prefs.swipeToLibrary ?? false;
        final scheme = Theme.of(context).colorScheme;
        return TrackSwipeGestures(
          track: track,
          // 自建歌单没开左滑入库时，左滑仍是移出歌单
          trailingOverride: ownPlaylistId != null && !swipeToLibrary
              ? TrackSwipeAction(
                  icon: Icons.delete_rounded,
                  iconColor: scheme.onErrorContainer,
                  circleColor: scheme.errorContainer,
                  semanticLabel: context.l10n.commonRemove,
                  onTriggered: () => context
                      .read<LibraryProvider>()
                      .removeTrackFromPlaylist(ownPlaylistId, track.id),
                )
              : null,
          child: row,
        );
      },
    );
  }

  Widget _ownPlaylistSwipe(
    Widget tile,
    SpotifyTrack track,
    String? ownPlaylistId,
  ) {
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
                style: const TextStyle(fontWeight: FontWeight.w600),
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
