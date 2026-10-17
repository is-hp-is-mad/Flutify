import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../models/artist.dart';
import '../../../models/category.dart';
import '../../../models/playback_context.dart';
import '../../../models/playlist.dart';
import '../../../models/track.dart';
import '../../../providers/playback_provider.dart';
import '../../../providers/spotify_provider.dart';
import '../../navigation/app_routes.dart';
import '../../widgets/category_card.dart';
import '../../widgets/content_bottom_spacer.dart';
import '../../widgets/cover_image.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/filter_pill.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/track_tile.dart';
import '../detail/widgets/collection_widgets.dart';

/// 搜索页：浏览分类 / 最近搜索 / 多类型搜索结果。
///
/// 输入经 SpotifyProvider 300ms 防抖并丢弃过期结果；
/// 点击结果或回车时写入最近搜索。
///
/// 桌面端（宽度 ≥ 800）搜索框在顶栏：由 MainShell 传入同一个 [controller]，
/// 本页隐藏自己的标题与输入框，只显示分类浏览 / 结果。
class SearchScreen extends StatefulWidget {
  final TextEditingController? controller;

  const SearchScreen({super.key, this.controller});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final TextEditingController _searchController = widget.controller ?? TextEditingController();
  final FocusNode _focusNode = FocusNode();
  /// 结果过滤：0 全部 / 1 歌曲 / 2 艺人 / 3 歌单。
  int _searchFilterIndex = 0;

  @override
  void initState() {
    super.initState();
    // 顶栏输入时本页也要切换「浏览 / 结果」
    _searchController.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onQueryChanged);
    if (widget.controller == null) _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    if (mounted) setState(() {});
  }

  void _setQuery(String query) {
    _searchController.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    context.read<SpotifyProvider>().performSearch(query);
    // 选中最近搜索会立刻发起查询；清空只是准备重新输入，输入法留着。
    if (query.trim().isNotEmpty) _dismissKeyboard();
    setState(() {});
  }

  void _commit() => context.read<SpotifyProvider>().commitRecentSearch(_searchController.text);

  /// 一次搜索被确认后收起输入法。输入框若继续持有焦点，返回搜索页时路由会把焦点还回去，输入法再次弹出。
  /// 逐字输入不收起，否则无法继续打字。
  void _dismissKeyboard() {
    _focusNode.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _submitSearch() {
    _commit();
    _dismissKeyboard();
  }

  void _onResultTap() {
    _dismissKeyboard();
    _commit();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final searchFilters = [l10n.filterAll, l10n.filterSongs, l10n.filterArtists, l10n.filterPlaylists];
    final isQueryEmpty = _searchController.text.trim().isEmpty;
    final isDesktop = MediaQuery.sizeOf(context).width >= 800;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isDesktop) const SizedBox(height: 16),
            if (!isDesktop)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.navSearch,
                    style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _searchController,
                    focusNode: _focusNode,
                    textInputAction: TextInputAction.search,
                    onChanged: (val) {
                      context.read<SpotifyProvider>().performSearch(val);
                      setState(() {});
                    },
                    onSubmitted: (_) => _submitSearch(),
                    decoration: InputDecoration(
                      hintText: l10n.searchHint,
                      prefixIcon: const Icon(Icons.search_rounded, size: 24),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.close_rounded),
                              tooltip: l10n.commonClear,
                              onPressed: () => _setQuery(''),
                            )
                          : null,
                    ),
                  ),
                ],
              ),
            ),

            if (!isQueryEmpty)
              SizedBox(
                height: 40,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  itemCount: searchFilters.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    // Center：横向列表会给子项 40 高的紧约束，胶囊要按内容高度居中，不被拉满
                    child: Center(
                      child: FilterPill(
                        label: searchFilters[index],
                        isSelected: _searchFilterIndex == index,
                        onTap: () => setState(() => _searchFilterIndex = index),
                      ),
                    ),
                  ),
                ),
              ),

            Expanded(
              child: isQueryEmpty
                  ? _BrowseView(onRecentTap: _setQuery)
                  : _SearchResults(filterIndex: _searchFilterIndex, onResultTap: _onResultTap),
            ),
          ],
        ),
      ),
    );
  }
}

/// 未输入时：最近搜索 + 分类浏览。
class _BrowseView extends StatelessWidget {
  final ValueChanged<String> onRecentTap;

  const _BrowseView({required this.onRecentTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final categories = context.select<SpotifyProvider, List<SpotifyCategory>>((s) => s.categories);
    final recent = context.select<SpotifyProvider, List<String>>((s) => s.recentSearches);
    final isLoading = context.select<SpotifyProvider, bool>((s) => s.isLoadingHome);

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        if (recent.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(l10n.searchRecent, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                  TextButton(
                    onPressed: () => context.read<SpotifyProvider>().clearRecentSearches(),
                    child: Text(l10n.searchClearAll),
                  ),
                ],
              ),
            ),
          ),
          SliverList.builder(
            itemCount: recent.length.clamp(0, 6),
            itemBuilder: (context, i) => ListTile(
              dense: true,
              leading: const Icon(Icons.history_rounded),
              title: Text(recent[i], style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: l10n.commonRemove,
                onPressed: () => context.read<SpotifyProvider>().removeRecentSearch(recent[i]),
              ),
              onTap: () => onRecentTap(recent[i]),
            ),
          ),
        ],

        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Text(l10n.searchBrowseAll, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          ),
        ),
        if (categories.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            sliver: SliverToBoxAdapter(
              child: isLoading
                  ? const SkeletonGrid()
                  : EmptyState(
                      icon: Icons.wifi_off_rounded,
                      title: l10n.searchCategoriesFailedTitle,
                      message: l10n.searchCategoriesFailedMessage,
                      actionLabel: l10n.commonRetry,
                      onAction: () => context.read<SpotifyProvider>().loadInitialData(),
                    ),
            ),
          )
        else
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.crossAxisExtent;
              final columns = width >= 1400 ? 5 : width >= 1000 ? 4 : width >= 640 ? 3 : 2;

              return SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: 1.6,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final category = categories[index];
                    return CategoryCard(
                      category: category,
                      onTap: () => AppRoutes.openCategory(context, category),
                    );
                  },
                  childCount: categories.length,
                ),
              );
            },
          ),
        ),
        const ContentBottomSpacer(),
      ],
    );
  }
}

class _SearchResults extends StatelessWidget {
  final int filterIndex;
  final VoidCallback onResultTap;

  const _SearchResults({required this.filterIndex, required this.onResultTap});

  @override
  Widget build(BuildContext context) {
    final spotify = context.watch<SpotifyProvider>();
    final l10n = context.l10n;
    if (spotify.isSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (spotify.searchError != null) {
      if (spotify.searchRequiresSignIn) {
        return CustomScrollView(
          slivers: [
            CollectionErrorPlaceholder(
              signedOut: true,
              onRetry: spotify.retrySearch,
            ),
            const ContentBottomSpacer(),
          ],
        );
      }
      return Center(
        child: SingleChildScrollView(
          child: EmptyState(
            icon: Icons.wifi_off_rounded,
            title: l10n.searchFailedTitle,
            message: l10n.searchFailedMessage,
            actionLabel: l10n.commonRetry,
            onAction: spotify.retrySearch,
          ),
        ),
      );
    }

    final List<SpotifyTrack> tracks = spotify.searchTracks;
    final List<SpotifyArtist> artists = spotify.searchArtists;
    final List<SpotifyPlaylist> playlists = spotify.searchPlaylists;
    final hasSongs =
        tracks.isNotEmpty || spotify.searchHasMore(SearchResultType.tracks);
    final hasArtists =
        artists.isNotEmpty || spotify.searchHasMore(SearchResultType.artists);
    final hasPlaylists =
        playlists.isNotEmpty ||
        spotify.searchHasMore(SearchResultType.playlists);

    if (!hasSongs && !hasArtists && !hasPlaylists) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 120),
          child: EmptyState(
            icon: Icons.search_off_rounded,
            title: l10n.searchNoResultsTitle(spotify.searchQuery.trim()),
            message: l10n.searchNoResultsMessage,
          ),
        ),
      );
    }

    final showSongs = filterIndex == 0 || filterIndex == 1;
    final showArtists = filterIndex == 0 || filterIndex == 2;
    final showPlaylists = filterIndex == 0 || filterIndex == 3;
    final searchContext = PlaybackContext.search(spotify.searchQuery.trim());

    // 当前过滤标签下没有结果（其他类型有）时，给出占位而不是一片空白
    final hasVisible =
        (showSongs && hasSongs) ||
        (showArtists && hasArtists) ||
        (showPlaylists && hasPlaylists);
    if (!hasVisible) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 120),
          child: EmptyState(
            icon: Icons.filter_alt_off_rounded,
            title: l10n.searchFilterEmptyTitle,
            message: l10n.searchFilterEmptyMessage,
          ),
        ),
      );
    }

    return CustomScrollView(
      key: ValueKey('${spotify.searchQuery}-$filterIndex'),
      physics: const BouncingScrollPhysics(),
      slivers: [
        if (showSongs && hasSongs) ...[
          SliverToBoxAdapter(child: _ResultHeader(l10n.filterSongs)),
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, index) {
              final track = tracks[index];
              return TrackTile(
                key: ValueKey('search-track-${track.id}'),
                track: track,
                contextQueue: tracks,
                playbackContext: searchContext,
                onTap: () {
                  onResultTap();
                  context.read<PlaybackProvider>().playTrack(
                    track,
                    contextQueue: tracks,
                    context: searchContext,
                  );
                },
              );
            },
          ),
          const SliverToBoxAdapter(
            child: _SearchPageControl(type: SearchResultType.tracks),
          ),
        ],
        if (showArtists && hasArtists) ...[
          SliverToBoxAdapter(child: _ResultHeader(l10n.filterArtists)),
          SliverList.builder(
            itemCount: artists.length,
            itemBuilder: (context, index) {
              final artist = artists[index];
              return ListTile(
                key: ValueKey('search-artist-${artist.id}'),
                leading: CoverImage(
                  url: artist.avatarUrl,
                  size: 48,
                  circular: true,
                  placeholderIcon: Icons.person_rounded,
                ),
                title: Text(
                  artist.name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(l10n.typeArtist),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  onResultTap();
                  AppRoutes.openArtist(context, artist);
                },
              );
            },
          ),
          const SliverToBoxAdapter(
            child: _SearchPageControl(type: SearchResultType.artists),
          ),
        ],
        if (showPlaylists && hasPlaylists) ...[
          SliverToBoxAdapter(child: _ResultHeader(l10n.filterPlaylists)),
          SliverList.builder(
            itemCount: playlists.length,
            itemBuilder: (context, index) {
              final playlist = playlists[index];
              return ListTile(
                key: ValueKey('search-playlist-${playlist.id}'),
                leading: CoverImage(
                  url: playlist.coverUrl,
                  size: 48,
                  borderRadius: BorderRadius.circular(6),
                ),
                title: Text(
                  playlist.name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  l10n.subtitleJoin(l10n.typePlaylist, playlist.ownerName),
                ),
                onTap: () {
                  onResultTap();
                  AppRoutes.openPlaylist(context, playlist);
                },
              );
            },
          ),
          const SliverToBoxAdapter(
            child: _SearchPageControl(type: SearchResultType.playlists),
          ),
        ],
        const ContentBottomSpacer(),
      ],
    );
  }
}

class _SearchPageControl extends StatelessWidget {
  final SearchResultType type;

  const _SearchPageControl({required this.type});

  @override
  Widget build(BuildContext context) {
    final spotify = context.watch<SpotifyProvider>();
    final l10n = context.l10n;
    if (!spotify.searchHasMore(type)) return const SizedBox.shrink();
    if (spotify.isLoadingMoreSearch(type)) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(
              key: ValueKey('search-loading-${type.name}'),
              semanticsLabel: l10n.commonLoadMore,
            ),
          ),
        ),
      );
    }
    final hasError = spotify.searchPageError(type) != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          if (hasError)
            Text(
              l10n.searchFailedMessage,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          TextButton.icon(
            key: ValueKey('search-load-more-${type.name}'),
            onPressed: () => spotify.loadMoreSearch(type),
            icon: Icon(
              hasError ? Icons.refresh_rounded : Icons.expand_more_rounded,
            ),
            label: Text(hasError ? l10n.commonRetry : l10n.commonLoadMore),
          ),
        ],
      ),
    );
  }
}

class _ResultHeader extends StatelessWidget {
  final String title;

  const _ResultHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
      ),
    );
  }
}
