import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/home_feed.dart';
import '../../models/playlist.dart';
import 'pathfinder_parsers.dart';

/// Pathfinder `home` 响应 → [HomeFeed]。
///
/// 分区类型（`sections.items[].data.__typename`）与官方桌面端的渲染方式对应：
/// - `HomeShortsSectionData`：顶部快捷入口；
/// - `HomeGenericSectionData`：普通卡架（标题、副标题、可带艺人头像 headerEntity）；
/// - `HomeRecentlyPlayedSectionData`：最近播放（条目包在一个 List 里，字段为 trait 结构）；
/// - `HomeFeedBaselineSectionData`：每个分区只有一张卡，连续出现的合并为一个推荐流网格，
///   分区标题作为卡片上方的推荐理由；
/// - 其余类型（广告、引导、视频流等）不展示，与官方客户端一致。
///
/// 所有字段按可缺失宽松读取；单个条目解析失败只跳过该条目。
class HomeParser {
  HomeParser._();

  /// 快捷入口最多显示的数量（官方：最多 8 个，不足 8 个且为奇数时去掉最后一个凑成整行）。
  static const int maxShortcuts = 8;

  static HomeFeed parse(Map<String, dynamic> data) {
    final home = _map(data['home']);
    if (home == null) return HomeFeed.empty;

    var shortcuts = const <HomeItem>[];
    final sections = <HomeSection>[];
    // 正在累积的推荐流（遇到非 FeedBaseline 分区即结束）
    List<HomeItem>? feed;

    for (final raw in _list(
      _map(_map(home['sectionContainer'])?['sections'])?['items'],
    )) {
      final section = _map(raw);
      if (section == null) continue;
      final data = _map(section['data']);
      final typename = data?['__typename'];
      final uri = section['uri'] as String? ?? '';
      final sectionItems = _map(section['sectionItems']);
      final rawItems = _list(sectionItems?['items']);

      if (typename == 'HomeFeedBaselineSectionData') {
        if (feed == null) {
          feed = [];
          sections.add(
            HomeSection(
              uri: uri,
              kind: HomeSectionKind.feed,
              title: '',
              items: feed,
            ),
          );
        }
        final reason = _label(data?['title']);
        final reasonArtist = PathfinderParsers.artist(data?['headerEntity']);
        for (final item in rawItems.map(item).whereType<HomeItem>()) {
          if (item.kind == HomeItemKind.artist)
            continue; // 官方推荐流只展示专辑 / 歌单 / 单集
          feed.add(item.withReason(reason, reasonArtist));
        }
        continue;
      }
      feed = null;

      switch (typename) {
        case 'HomeShortsSectionData':
          shortcuts = _shortcuts(
            rawItems.map(item).whereType<HomeItem>().toList(),
          );
        case 'HomeGenericSectionData' || 'HomeRecentlyPlayedSectionData':
          final recents = typename == 'HomeRecentlyPlayedSectionData';
          final items = recents
              ? _recentItems(rawItems)
              : rawItems.map(item).whereType<HomeItem>().toList();
          if (items.isEmpty) continue;
          sections.add(
            HomeSection(
              uri: uri,
              kind: recents ? HomeSectionKind.recents : HomeSectionKind.shelf,
              title: _label(data?['title']),
              subtitle: _label(data?['subtitle']),
              headerArtist: PathfinderParsers.artist(data?['headerEntity']),
              items: items,
              totalCount: recents
                  ? items.length
                  : (_int(sectionItems?['totalCount']) ?? items.length),
            ),
          );
      }
    }

    // 推荐流若一张卡都没解析出来就去掉
    sections.removeWhere(
      (s) => s.kind == HomeSectionKind.feed && s.items.isEmpty,
    );

    return HomeFeed(
      greeting: _label(home['greeting']),
      chips: _list(home['homeChips']).map(_chip).whereType<HomeChip>().toList(),
      shortcuts: shortcuts,
      sections: sections,
    );
  }

  /// 在完整响应中按 URI 找回某个分区（「显示全部」用更大的 sectionItemsLimit 重新请求后调用）。
  static HomeSection? section(Map<String, dynamic> data, String uri) {
    for (final s in parse(data).sections) {
      if (s.uri == uri) return s;
    }
    return null;
  }

  /// `browsePage`（分类页）响应 → 分区列表。
  ///
  /// 与 home 同源的分区结构（`sections.items[]` + `sectionItems.items[]`，条目共用 [item]）；
  /// 根字段为 `browse`，个别版本写作 `browsePage`，都兼容；单条条目解析失败只跳过。
  static List<HomeSection> browseSections(Map<String, dynamic> data) {
    final root = _map(data['browse']) ??
        _map(data['browsePage']) ??
        _firstSectionsContainer(data);
    if (root == null) return const [];
    final sectionsMap = _map(_map(root['sectionContainer'])?['sections']) ??
        _map(root['sections']);
    final sections = <HomeSection>[];
    for (final raw in _list(sectionsMap?['items'])) {
      final section = _map(raw);
      if (section == null) continue;
      final sectionItems = _map(section['sectionItems']);
      final items = _list(sectionItems?['items'])
          .map(item)
          .whereType<HomeItem>()
          .toList();
      if (items.isEmpty) continue;
      final meta = _map(section['data']);
      sections.add(
        HomeSection(
          uri: section['uri'] as String? ?? '',
          kind: HomeSectionKind.shelf,
          title: _label(meta?['title']),
          subtitle: _label(meta?['subtitle']),
          items: items,
          totalCount: _int(sectionItems?['totalCount']) ?? items.length,
        ),
      );
    }
    return sections;
  }

  /// 根字段名对不上时兜底：在响应里找第一个带 `sections` 的对象（最多下探两层）。
  static Map<String, dynamic>? _firstSectionsContainer(
    Map<String, dynamic> data, [
    int depth = 2,
  ]) {
    for (final value in data.values) {
      final m = _map(value);
      if (m == null) continue;
      if (m['sections'] != null || m['sectionContainer'] != null) return m;
      if (depth > 0) {
        final nested = _firstSectionsContainer(m, depth - 1);
        if (nested != null) return nested;
      }
    }
    return null;
  }

  static List<HomeItem> _shortcuts(List<HomeItem> items) {
    var list = items.take(maxShortcuts).toList();
    if (list.length < maxShortcuts && list.length.isOdd)
      list = list.sublist(0, list.length - 1);
    return list;
  }

  static HomeChip? _chip(Object? raw) {
    final m = _map(raw);
    final id = m?['id'];
    final label = _label(m?['label']);
    if (id is! String || id.isEmpty || label.isEmpty) return null;
    return HomeChip(
      id: id,
      label: label,
      subChips: _list(m!['subChips']).map(_chip).whereType<HomeChip>().toList(),
    );
  }

  // ---------------------------------------------------------------------------
  // 条目
  // ---------------------------------------------------------------------------

  /// 分区条目 `{uri, content: {__typename: XxxResponseWrapper | UnknownType, data}}`。
  static HomeItem? item(Object? raw) {
    final m = _map(raw);
    if (m == null) return null;
    final content = _map(m['content']);
    final uri = m['uri'] as String? ?? content?['uri'] as String? ?? '';
    if (isLikedSongsUri(uri))
      return HomeItem(kind: HomeItemKind.likedSongs, uri: uri, title: '');

    final entity = PathfinderParsers.unwrap(content);
    switch (entity?['__typename']) {
      case 'Playlist':
        final p = PathfinderParsers.playlist(entity);
        if (p == null) return null;
        return HomeItem(
          kind: HomeItemKind.playlist,
          uri: p.uri,
          title: p.name,
          subtitle: p.description.isNotEmpty ? p.description : p.ownerName,
          images: p.images,
          playlist: p,
        );
      case 'Album':
        final a = PathfinderParsers.album(entity);
        if (a == null) return null;
        return HomeItem(
          kind: HomeItemKind.album,
          uri: a.uri,
          title: a.name,
          subtitle: a.artistNames,
          images: a.images,
          album: a,
        );
      case 'Artist':
        final a = PathfinderParsers.artist(entity);
        if (a == null) return null;
        return HomeItem(
          kind: HomeItemKind.artist,
          uri: a.uri,
          title: a.name,
          images: a.images,
          artist: a,
        );
      case 'Podcast':
        return _media(
          HomeItemKind.podcast,
          entity!,
          subtitle: _map(entity['publisher'])?['name'] as String?,
        );
      case 'Episode':
        final show = PathfinderParsers.unwrap(entity!['podcastV2']);
        return _media(
          HomeItemKind.episode,
          entity,
          subtitle: show?['name'] as String?,
          parentUri: show?['uri'] as String?,
        );
    }
    return null;
  }

  static HomeItem? _media(
    HomeItemKind kind,
    Map<String, dynamic> m, {
    String? subtitle,
    String? parentUri,
  }) {
    final uri = m['uri'];
    if (uri is! String || uri.isEmpty) return null;
    return HomeItem(
      kind: kind,
      uri: uri,
      title: m['name'] as String? ?? '',
      subtitle: subtitle ?? '',
      images: PathfinderParsers.images(_map(m['coverArt'])?['sources']),
      parentUri: parentUri ?? '',
    );
  }

  /// 最近播放：唯一条目是一个 List，真正的条目在 `content.data.items.items[].entity` 中，
  /// 字段为 trait 结构（identityTrait 名称 / 描述 / 作者，visualIdentityTrait 封面）。
  static List<HomeItem> _recentItems(List<Object?> rawItems) {
    final result = <HomeItem>[];
    for (final raw in rawItems) {
      final list = PathfinderParsers.unwrap(_map(raw)?['content']);
      for (final entry in _list(_map(list?['items'])?['items'])) {
        final parsed = _recent(_map(_map(entry)?['entity']));
        if (parsed != null) result.add(parsed);
      }
    }
    return result;
  }

  static HomeItem? _recent(Map<String, dynamic>? entity) {
    final data = _map(entity?['data']);
    final uri = entity?['_uri'] as String? ?? data?['uri'] as String? ?? '';
    if (uri.isEmpty) return null;
    if (isLikedSongsUri(uri))
      return HomeItem(kind: HomeItemKind.likedSongs, uri: uri, title: '');

    final identity = _map(data?['identityTrait']);
    final name = identity?['name'] as String? ?? '';
    final description = PathfinderParsers.stripHtml(
      identity?['description'] as String? ?? '',
    );
    final contributors = _list(_map(identity?['contributors'])?['items'])
        .map(_map)
        .whereType<Map<String, dynamic>>()
        .map(
          (c) => SpotifyArtist(
            id: PathfinderParsers.idFromUri(c['uri'] as String? ?? ''),
            name: c['name'] as String? ?? '',
            uri: c['uri'] as String? ?? '',
          ),
        )
        .where((c) => c.name.isNotEmpty)
        .toList();
    final cover = _map(_map(data?['visualIdentityTrait'])?['squareCoverImage']);
    final images = PathfinderParsers.images(
      _map(_map(cover?['image'])?['data'])?['sources'],
    );
    final id = PathfinderParsers.idFromUri(uri);
    final byline = contributors.map((c) => c.name).join(', ');

    switch (uri.split(':').elementAtOrNull(1)) {
      case 'playlist':
        final playlist = SpotifyPlaylist(
          id: id,
          name: name,
          uri: uri,
          description: description,
          ownerName: contributors.isEmpty ? 'Spotify' : contributors.first.name,
          images: images,
        );
        return HomeItem(
          kind: HomeItemKind.playlist,
          uri: uri,
          title: name,
          subtitle: description.isNotEmpty ? description : byline,
          images: images,
          playlist: playlist,
        );
      case 'album':
        final album = SpotifyAlbum(
          id: id,
          name: name,
          uri: uri,
          images: images,
          artists: contributors,
        );
        return HomeItem(
          kind: HomeItemKind.album,
          uri: uri,
          title: name,
          subtitle: byline,
          images: images,
          album: album,
        );
      case 'artist':
        final artist = SpotifyArtist(
          id: id,
          name: name,
          uri: uri,
          images: images,
        );
        return HomeItem(
          kind: HomeItemKind.artist,
          uri: uri,
          title: name,
          images: images,
          artist: artist,
        );
      case 'show':
        return HomeItem(
          kind: HomeItemKind.podcast,
          uri: uri,
          title: name,
          subtitle: byline,
          images: images,
        );
      case 'episode':
        return HomeItem(
          kind: HomeItemKind.episode,
          uri: uri,
          title: name,
          subtitle: byline,
          images: images,
        );
    }
    return null;
  }

  /// 「已点赞的歌曲」的两种写法：快捷入口用 `spotify:user:{用户名}:collection`（用户名可能是 `@`
  /// 代指当前用户），最近播放用 `spotify:collection:tracks`。
  static bool isLikedSongsUri(String uri) =>
      uri == 'spotify:collection:tracks' ||
      (uri.startsWith('spotify:user:') && uri.endsWith(':collection'));

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  /// `{transformedLabel, translatedBaseText}` → 本地化后的文本。
  static String _label(Object? value) {
    final m = _map(value);
    final text = m?['transformedLabel'] ?? m?['translatedBaseText'];
    return text is String ? text.trim() : '';
  }

  static Map<String, dynamic>? _map(Object? v) =>
      v is Map<String, dynamic> ? v : null;
  static List<Object?> _list(Object? v) => v is List ? v : const [];
  static int? _int(Object? v) => v is num ? v.toInt() : null;
}
