import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../core/theme/md3e_shapes.dart';
import '../../../core/utils/pinyin_sort.dart';
import '../../../l10n/l10n.dart';
import '../../../models/album.dart';
import '../../../models/artist.dart';
import '../../../models/playlist.dart';
import '../../../providers/library_provider.dart';
import '../../navigation/app_routes.dart';
import '../../widgets/cover_image.dart';
import '../../widgets/create_playlist_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/filter_pill.dart';
import '../../widgets/user_avatar.dart';

enum _LibraryFilter { playlists, artists, albums }

enum _LibrarySort { recent, alphabetical }

/// 媒体库条目的统一视图模型（歌单 / 艺人 / 专辑）。
class _LibraryItem {
  final String id;
  final String title;
  final String subtitle;
  final String imageUrl;
  final bool circular;
  final bool pinned;
  final bool isLikedSongs;
  final VoidCallback onTap;

  const _LibraryItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.onTap,
    this.circular = false,
    this.pinned = false,
    this.isLikedSongs = false,
  });
}

/// Your Library：筛选、排序、列表/网格切换、库内搜索与新建歌单。
class LibraryScreen extends StatefulWidget {
  final VoidCallback onOpenSettings;

  const LibraryScreen({super.key, required this.onOpenSettings});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  _LibraryFilter? _filter;
  _LibrarySort _sort = _LibrarySort.recent;
  bool _isGridView = false;
  bool _searching = false;
  final TextEditingController _queryController = TextEditingController();

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _createPlaylist() async {
    final library = context.read<LibraryProvider>();
    final name = await CreatePlaylistDialog.show(
      context,
      initialName: context.l10n.libraryNewPlaylistName(library.ownPlaylists.length + 1),
    );
    if (name == null || !mounted) return;
    AppRoutes.openPlaylist(context, library.createPlaylist(name));
  }

  List<_LibraryItem> _buildItems(
    List<SpotifyPlaylist> playlists,
    List<SpotifyArtist> artists,
    List<SpotifyAlbum> albums,
    int likedCount,
  ) {
    final library = context.read<LibraryProvider>();
    final l10n = context.l10n;
    final items = <_LibraryItem>[];

    if (_filter == null || _filter == _LibraryFilter.playlists) {
      items.add(_LibraryItem(
        id: LibraryProvider.likedSongsId,
        title: l10n.likedSongs,
        subtitle: l10n.subtitleJoin(l10n.typePlaylist, l10n.songCount(likedCount)),
        imageUrl: '',
        pinned: true,
        isLikedSongs: true,
        onTap: () => AppRoutes.openPlaylist(context, library.likedSongsPlaylist),
      ));
      items.addAll(playlists.map((p) => _LibraryItem(
            id: p.id,
            title: p.name,
            subtitle: l10n.subtitleJoin(l10n.typePlaylist, p.ownerName),
            imageUrl: p.coverUrl,
            onTap: () => AppRoutes.openPlaylist(context, p),
          )));
    }
    if (_filter == null || _filter == _LibraryFilter.artists) {
      items.addAll(artists.map((a) => _LibraryItem(
            id: a.id,
            title: a.name,
            subtitle: l10n.typeArtist,
            imageUrl: a.avatarUrl,
            circular: true,
            onTap: () => AppRoutes.openArtist(context, a),
          )));
    }
    if (_filter == null || _filter == _LibraryFilter.albums) {
      items.addAll(albums.map((a) => _LibraryItem(
            id: a.id,
            title: a.name,
            subtitle: l10n.subtitleJoin(l10n.typeAlbum, a.artistNames),
            imageUrl: a.coverUrl,
            onTap: () => AppRoutes.openAlbum(context, a),
          )));
    }

    final query = _queryController.text.trim().toLowerCase();
    var result = query.isEmpty
        ? items
        : items.where((i) => i.title.toLowerCase().contains(query) || i.subtitle.toLowerCase().contains(query)).toList();

    if (_sort == _LibrarySort.alphabetical) {
      final pinned = result.where((i) => i.pinned);
      final rest = result.where((i) => !i.pinned).toList()
        ..sort((a, b) => compareByPinyin(a.title, b.title));
      result = [...pinned, ...rest];
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    final playlists = context.select<LibraryProvider, List<SpotifyPlaylist>>((l) => l.playlists);
    final artists = context.select<LibraryProvider, List<SpotifyArtist>>((l) => l.artists);
    final albums = context.select<LibraryProvider, List<SpotifyAlbum>>((l) => l.albums);
    final likedCount = context.select<LibraryProvider, int>((l) => l.likedTracks.length);
    final items = _buildItems(playlists, artists, albums, likedCount);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 顶栏
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: widget.onOpenSettings,
                      child: const UserAvatar(size: 36),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _searching
                        ? TextField(
                            controller: _queryController,
                            autofocus: true,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              hintText: l10n.librarySearchHint,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            ),
                          )
                        : Text(
                            l10n.navLibrary,
                            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
                          ),
                  ),
                  IconButton(
                    icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded),
                    tooltip: _searching ? l10n.libraryCloseSearch : l10n.librarySearchHint,
                    onPressed: () => setState(() {
                      _searching = !_searching;
                      if (!_searching) _queryController.clear();
                    }),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_rounded),
                    tooltip: l10n.libraryCreatePlaylist,
                    onPressed: _createPlaylist,
                  ),
                ],
              ),
            ),

            // 筛选药丸（再次点击取消筛选）
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                children: [
                  if (_filter != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: IconButton.filledTonal(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        tooltip: l10n.libraryClearFilter,
                        onPressed: () => setState(() => _filter = null),
                      ),
                    ),
                  for (final f in _LibraryFilter.values)
                    if (_filter == null || _filter == f)
                      Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: FilterPill(
                          label: switch (f) {
                            _LibraryFilter.playlists => l10n.filterPlaylists,
                            _LibraryFilter.artists => l10n.filterArtists,
                            _LibraryFilter.albums => l10n.filterAlbums,
                          },
                          isSelected: _filter == f,
                          onTap: () => setState(() => _filter = _filter == f ? null : f),
                        ),
                      ),
                ],
              ),
            ),

            // 排序与视图切换
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(
                children: [
                  PopupMenuButton<_LibrarySort>(
                    initialValue: _sort,
                    onSelected: (s) => setState(() => _sort = s),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: _LibrarySort.recent, child: Text(l10n.librarySortRecent)),
                      PopupMenuItem(value: _LibrarySort.alphabetical, child: Text(l10n.librarySortAlphabetical)),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.swap_vert_rounded, size: 18, color: colorScheme.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Text(
                            _sort == _LibrarySort.recent ? l10n.librarySortRecent : l10n.librarySortAlphabetical,
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(
                      _isGridView ? Icons.view_list_rounded : Icons.grid_view_rounded,
                      size: 20,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    tooltip: _isGridView ? l10n.libraryListView : l10n.libraryGridView,
                    onPressed: () => setState(() => _isGridView = !_isGridView),
                  ),
                ],
              ),
            ),

            Expanded(
              child: items.isEmpty
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.only(top: 40, bottom: 120),
                      child: EmptyState(
                        icon: Icons.library_music_outlined,
                        title: l10n.libraryEmptyTitle,
                        message: l10n.libraryEmptyMessage,
                      ),
                    )
                  : _isGridView
                      ? _LibraryGrid(items: items)
                      : _LibraryList(items: items),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryList extends StatelessWidget {
  final List<_LibraryItem> items;

  const _LibraryList({required this.items});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 32),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return ListTile(
          key: ValueKey(item.id),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          leading: _ItemCover(item: item, size: 56),
          title: Text(
            item.title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Row(
            children: [
              if (item.pinned) ...[
                Icon(Icons.push_pin_rounded, color: colorScheme.primary, size: 14),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  item.subtitle,
                  style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          onTap: item.onTap,
        );
      },
    );
  }
}

class _LibraryGrid extends StatelessWidget {
  final List<_LibraryItem> items;

  const _LibraryGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GridView.builder(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.paddingOf(context).bottom + 32),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.74,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return InkWell(
          key: ValueKey(item.id),
          borderRadius: context.tokens.radius(MD3EShapes.radiusMedium),
          mouseCursor: SystemMouseCursors.click,
          onTap: item.onTap,
          child: Column(
            crossAxisAlignment: item.circular ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              AspectRatio(aspectRatio: 1, child: _ItemCover(item: item)),
              const SizedBox(height: 8),
              Text(
                item.title,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                item.subtitle,
                style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ItemCover extends StatelessWidget {
  final _LibraryItem item;
  final double? size;

  const _ItemCover({required this.item, this.size});

  @override
  Widget build(BuildContext context) {
    if (item.isLikedSongs) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: kLikedSongsGradient,
          borderRadius: context.tokens.radius(MD3EShapes.radiusSmall),
        ),
        child: const Icon(Icons.favorite_rounded, color: Colors.white, size: 28),
      );
    }
    return CoverImage(
      url: item.imageUrl,
      size: size,
      circular: item.circular,
      borderRadius: item.circular ? null : context.tokens.radius(MD3EShapes.radiusSmall),
      placeholderIcon: item.circular ? Icons.person_rounded : Icons.music_note_rounded,
    );
  }
}
