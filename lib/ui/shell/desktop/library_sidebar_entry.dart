import 'package:flutter/widgets.dart';

import '../../../core/utils/pinyin_sort.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers/library_provider.dart';
import '../../navigation/app_routes.dart';

/// 音乐库栏的筛选类型。
enum LibraryKind { playlist, album, artist }

/// 音乐库栏的排序方式。
enum LibrarySort { recent, alphabetical }

/// 音乐库栏中一行的视图模型（歌单 / 专辑 / 艺人统一呈现）。
class LibrarySidebarEntry {
  final String id;
  final String uri;
  final LibraryKind kind;
  final String title;
  final String subtitle;
  final String imageUrl;
  final bool pinned;
  final bool isLikedSongs;
  final void Function(BuildContext context) open;

  const LibrarySidebarEntry({
    required this.id,
    required this.uri,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.open,
    this.pinned = false,
    this.isLikedSongs = false,
  });

  bool get circular => kind == LibraryKind.artist;

  /// 由媒体库数据生成条目。
  ///
  /// 规则（对齐 Spotify 桌面端）：
  /// - 「已点赞的歌曲」固定置顶，只在「全部 / 歌单」筛选下出现，不参与排序与搜索过滤外的变化；
  /// - 最近添加：保持各类型在媒体库中的原始顺序（最新在前），类型之间按 歌单 → 专辑 → 艺人；
  /// - 按字母顺序：对非置顶条目按标题排序（中文按拼音）；
  /// - 搜索：标题或副标题包含关键词（不区分大小写）。
  static List<LibrarySidebarEntry> build({
    required LibraryProvider library,
    required AppLocalizations l10n,
    required LibraryKind? filter,
    required LibrarySort sort,
    required String query,
  }) {
    final entries = <LibrarySidebarEntry>[];
    final showPlaylists = filter == null || filter == LibraryKind.playlist;

    if (showPlaylists) {
      entries.add(LibrarySidebarEntry(
        id: LibraryProvider.likedSongsId,
        uri: LibraryProvider.likedSongsUri,
        kind: LibraryKind.playlist,
        title: l10n.likedSongs,
        subtitle: l10n.subtitleJoin(l10n.typePlaylist, l10n.songCount(library.likedTracks.length)),
        imageUrl: '',
        pinned: true,
        isLikedSongs: true,
        open: (context) => AppRoutes.openPlaylist(context, library.likedSongsPlaylist),
      ));
      for (final p in library.playlists) {
        entries.add(LibrarySidebarEntry(
          id: p.id,
          uri: p.uri,
          kind: LibraryKind.playlist,
          title: p.name,
          subtitle: l10n.subtitleJoin(l10n.typePlaylist, p.ownerName),
          imageUrl: p.coverUrl,
          open: (context) => AppRoutes.openPlaylist(context, p),
        ));
      }
    }
    if (filter == null || filter == LibraryKind.album) {
      for (final a in library.albums) {
        entries.add(LibrarySidebarEntry(
          id: a.id,
          uri: a.uri,
          kind: LibraryKind.album,
          title: a.name,
          subtitle: l10n.subtitleJoin(l10n.typeAlbum, a.artistNames),
          imageUrl: a.coverUrl,
          open: (context) => AppRoutes.openAlbum(context, a),
        ));
      }
    }
    if (filter == null || filter == LibraryKind.artist) {
      for (final a in library.artists) {
        entries.add(LibrarySidebarEntry(
          id: a.id,
          uri: a.uri,
          kind: LibraryKind.artist,
          title: a.name,
          subtitle: l10n.typeArtist,
          imageUrl: a.avatarUrl,
          open: (context) => AppRoutes.openArtist(context, a),
        ));
      }
    }

    final q = query.trim().toLowerCase();
    var result = q.isEmpty
        ? entries
        : entries.where((e) => e.title.toLowerCase().contains(q) || e.subtitle.toLowerCase().contains(q)).toList();

    if (sort == LibrarySort.alphabetical) {
      final pinned = result.where((e) => e.pinned);
      final rest = result.where((e) => !e.pinned).toList()
        ..sort((a, b) => compareByPinyin(a.title, b.title));
      result = [...pinned, ...rest];
    }
    return result;
  }
}
