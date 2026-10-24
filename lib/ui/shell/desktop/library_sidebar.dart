import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/library_provider.dart';
import '../../../providers/playback_provider.dart';
import '../../navigation/app_routes.dart';
import '../../screens/auth/login_screen.dart';
import '../../widgets/create_playlist_dialog.dart';
import '../../widgets/filter_pill.dart';
import '../panel_surface.dart';
import 'library_sidebar_entry.dart';
import 'library_sidebar_item.dart';

/// 桌面端左栏「音乐库」。
///
/// 展开时：标题（点击收起）+ 新建歌单 → 类型筛选胶囊 → 库内搜索 / 排序 → 条目列表；
/// 收起时（[compact]，72px）：图标按钮（点击展开）+ 新建 → 纯封面列表。
/// 未登录时显示登录引导卡片，不展示任何本地示例内容。
class LibrarySidebar extends StatefulWidget {
  final bool compact;

  /// 收起 / 展开；窗口过窄被强制收起时为 null（按钮不可用）。
  final VoidCallback? onToggleCompact;

  const LibrarySidebar({
    super.key,
    required this.compact,
    this.onToggleCompact,
  });

  @override
  State<LibrarySidebar> createState() => _LibrarySidebarState();
}

class _LibrarySidebarState extends State<LibrarySidebar> {
  LibraryKind? _filter;
  LibrarySort _sort = LibrarySort.recent;
  bool _searching = false;
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _createPlaylist() async {
    final library = context.read<LibraryProvider>();
    final name = await CreatePlaylistDialog.show(
      context,
      initialName: context.l10n.libraryNewPlaylistName(
        library.ownPlaylists.length + 1,
      ),
    );
    if (name == null || !mounted) return;
    AppRoutes.openPlaylist(context, library.createPlaylist(name));
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = context.select<AuthProvider, bool>((a) => a.isSignedIn);
    // 整个媒体库对象参与构建，任何收藏变化都会刷新；列表是写时复制的，开销可控
    final library = context.watch<LibraryProvider>();
    final playingUri = context.select<PlaybackProvider, String>(
      (p) => p.playbackContext.uri,
    );
    final l10n = context.l10n;

    final entries = signedIn
        ? LibrarySidebarEntry.build(
            library: library,
            l10n: l10n,
            filter: widget.compact ? null : _filter,
            sort: _sort,
            query: widget.compact ? '' : _query.text,
          )
        : const <LibrarySidebarEntry>[];

    return PanelSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            compact: widget.compact,
            onToggle: widget.onToggleCompact,
            onCreate: signedIn ? _createPlaylist : null,
          ),
          if (!widget.compact && signedIn) ...[
            _FilterRow(
              selected: _filter,
              onSelected: (k) => setState(() => _filter = k),
            ),
            _SearchSortRow(
              searching: _searching,
              controller: _query,
              sort: _sort,
              onSearchToggle: () => setState(() {
                _searching = !_searching;
                if (!_searching) _query.clear();
              }),
              onQueryChanged: (_) => setState(() {}),
              onSortChanged: (s) => setState(() => _sort = s),
            ),
          ],
          Expanded(
            child: !signedIn
                ? (widget.compact
                      ? const SizedBox.shrink()
                      : const _SignInCard())
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(
                      widget.compact ? 6 : 8,
                      0,
                      widget.compact ? 6 : 8,
                      // 末尾留白随底部播放栏占位（MediaQuery 底部 padding）：
                      // 悬浮胶囊盖在内容之上，不加的话最底部一条会被它遮住
                      12 + MediaQuery.paddingOf(context).bottom,
                    ),
                    itemCount: entries.length,
                    itemExtent: 60,
                    itemBuilder: (context, i) {
                      final entry = entries[i];
                      return LibrarySidebarItem(
                        key: ValueKey('${entry.kind.name}_${entry.id}'),
                        entry: entry,
                        compact: widget.compact,
                        playing:
                            playingUri.isNotEmpty && playingUri == entry.uri,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 标题行：展开时「▥ 音乐库 …… ＋」，收起时两个图标竖排。
class _Header extends StatelessWidget {
  final bool compact;
  final VoidCallback? onToggle;
  final VoidCallback? onCreate;

  const _Header({
    required this.compact,
    required this.onToggle,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;

    final createButton = IconButton(
      icon: const Icon(Icons.add_rounded, size: 22),
      tooltip: l10n.libraryCreatePlaylist,
      onPressed: onCreate,
      style: IconButton.styleFrom(
        backgroundColor: colorScheme.surfaceContainerHigh,
        foregroundColor: colorScheme.onSurface,
        fixedSize: const Size(36, 36),
        minimumSize: const Size(36, 36),
        padding: EdgeInsets.zero,
      ),
    );

    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
        child: Column(
          children: [
            IconButton(
              icon: const Icon(Icons.library_music_rounded),
              tooltip: l10n.shellExpandLibrary,
              color: colorScheme.onSurfaceVariant,
              onPressed: onToggle,
            ),
            const SizedBox(height: 8),
            createButton,
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 12, 8),
      child: Row(
        children: [
          Tooltip(
            message: l10n.shellCollapseLibrary,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              mouseCursor: onToggle == null
                  ? MouseCursor.defer
                  : SystemMouseCursors.click,
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.library_music_rounded,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      l10n.navLibrary,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Spacer(),
          createButton,
        ],
      ),
    );
  }
}

/// 类型筛选：歌单 / 专辑 / 艺人；再次点击已选中的项取消筛选。
class _FilterRow extends StatelessWidget {
  final LibraryKind? selected;
  final ValueChanged<LibraryKind?> onSelected;

  const _FilterRow({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final labels = {
      LibraryKind.playlist: l10n.filterPlaylists,
      LibraryKind.album: l10n.filterAlbums,
      LibraryKind.artist: l10n.filterArtists,
    };
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        children: [
          if (selected != null) ...[
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              tooltip: l10n.libraryClearFilter,
              onPressed: () => onSelected(null),
              style: IconButton.styleFrom(
                fixedSize: const Size(32, 32),
                minimumSize: const Size(32, 32),
                padding: EdgeInsets.zero,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHigh,
              ),
            ),
            const SizedBox(width: 8),
          ],
          for (final entry in labels.entries)
            if (selected == null || selected == entry.key)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterPill(
                  label: entry.value,
                  isSelected: selected == entry.key,
                  onTap: () =>
                      onSelected(selected == entry.key ? null : entry.key),
                ),
              ),
        ],
      ),
    );
  }
}

/// 库内搜索（点击放大镜展开输入框）与排序菜单。
class _SearchSortRow extends StatelessWidget {
  final bool searching;
  final TextEditingController controller;
  final LibrarySort sort;
  final VoidCallback onSearchToggle;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<LibrarySort> onSortChanged;

  const _SearchSortRow({
    required this.searching,
    required this.controller,
    required this.sort,
    required this.onSearchToggle,
    required this.onQueryChanged,
    required this.onSortChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    final sortLabel = sort == LibrarySort.recent
        ? l10n.librarySortRecent
        : l10n.librarySortAlphabetical;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Row(
        children: [
          if (searching)
            Expanded(
              child: SizedBox(
                height: 36,
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  onChanged: onQueryChanged,
                  style: theme.textTheme.bodyMedium,
                  decoration: InputDecoration(
                    hintText: l10n.librarySearchHint,
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16),
                      tooltip: l10n.libraryCloseSearch,
                      onPressed: onSearchToggle,
                    ),
                    contentPadding: EdgeInsets.zero,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.search_rounded, size: 20),
              tooltip: l10n.librarySearchHint,
              color: colorScheme.onSurfaceVariant,
              onPressed: onSearchToggle,
            ),
            const Spacer(),
          ],
          PopupMenuButton<LibrarySort>(
            tooltip: '',
            initialValue: sort,
            onSelected: onSortChanged,
            position: PopupMenuPosition.under,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: LibrarySort.recent,
                child: Text(l10n.librarySortRecent),
              ),
              PopupMenuItem(
                value: LibrarySort.alphabetical,
                child: Text(l10n.librarySortAlphabetical),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!searching)
                    Text(
                      sortLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.sort_rounded,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 未登录时的引导卡片。
class _SignInCard extends StatelessWidget {
  const _SignInCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.shellSignInTitle,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.shellSignInMessage,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            M3EButton.filled(
              onPressed: () => LoginScreen.open(context),
              decoration: M3EButtonDecoration(
                backgroundColor: WidgetStatePropertyAll(colorScheme.onSurface),
                foregroundColor: WidgetStatePropertyAll(colorScheme.surface),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
              ),
              child: Text(l10n.shellSignIn),
            ),
          ],
        ),
      ),
    );
  }
}
