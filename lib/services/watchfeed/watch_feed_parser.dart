import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/image.dart';
import '../../models/track.dart';
import '../../models/watch_feed.dart';
import 'proto_tree.dart';

/// Watch Feed 各接口响应 → 内存模型。字段号来自 Spotify Android 9.2.0.26 反编译与线上实测，
/// 见 docs/DISCOVERY_FEED_ANALYSIS.md。全部宽松解析：不认识的组件跳过，缺字段给空值，不抛错。
abstract final class WatchFeedParser {
  // ---------------------------------------------------------------------------
  // 入口：搜索页 Browse
  // ---------------------------------------------------------------------------

  /// `browsita/v1/browse` → 第一个 WatchFeed 区块（「Discover something new」）；没有则 null。
  ///
  /// ResolvedBrowse{1 BrowseStructure{1 repeated Section}}，
  /// Section{4 WatchFeed{1 Heading, 2 repeated WatchFeedItem{2 DecoratedEntrypointMetadata}}}。
  static WatchFeedShelf? parseBrowseShelf(List<int> bytes) {
    final sections = ProtoMsg.parse(bytes).msg(1).msgs(1);
    for (final section in sections) {
      if (!section.has(4)) continue;
      final watchFeed = section.msg(4);
      final entries = [
        for (final item in watchFeed.msgs(2)) ?_decoratedEntry(item.msg(2)),
      ];
      if (entries.isEmpty) continue;
      return WatchFeedShelf(
        title: _firstString(watchFeed.msg(1)),
        entries: entries,
      );
    }
    return null;
  }

  /// DecoratedEntrypointMetadata{1 uri, 2 first_item_uri, 3 overline, 4 title, 5 subtitle,
  /// 6 thumbnail{1 url}, 7 video_file{1 url}, 8 navigation_uri, 9 accessibility, 10 cover{1 url}}。
  static WatchFeedEntry? _decoratedEntry(ProtoMsg m) {
    final navigation = m.str(8).isNotEmpty ? m.str(8) : m.str(1);
    if (!navigation.startsWith('spotify:watch-feed')) return null;
    return WatchFeedEntry(
      title: m.str(4),
      subtitle: m.str(5),
      overline: m.str(3),
      feedUri: navigation,
      firstItemUri: m.str(2),
      thumbnailUrl: m.msg(6).str(1),
      videoUrl: _httpUrl(m.msg(7).str(1)),
      coverUrl: m.msg(10).str(1),
      accessibilityText: m.str(9),
    );
  }

  // ---------------------------------------------------------------------------
  // 入口：以曲目为种子（「Explore 某艺人」）
  // ---------------------------------------------------------------------------

  /// `discovery-from-seed` → DiscoveryFromSeedResponse{1 Any WatchFeedVideoCarouselComponent
  /// {1 title, 2 repeated Any WatchFeedVideoCardComponent}}；没有内容返回 null。
  static WatchFeedShelf? parseSeedShelf(List<int> bytes) {
    final carousel = ProtoMsg.parse(bytes).any(1);
    if (carousel == null ||
        carousel.typeName != 'WatchFeedVideoCarouselComponent') {
      return null;
    }
    final entries = <WatchFeedEntry>[];
    for (final card in carousel.value.anys(2)) {
      if (card.typeName != 'WatchFeedVideoCardComponent') continue;
      // {1 title, 2 subtitle, 3 thumbnail_image_url, 4 navigate_uri, 8 entity_uri,
      //  9 video_file{1 uri}, 10 accessibility_text, 11 overline}
      final m = card.value;
      if (!m.str(4).startsWith('spotify:watch-feed')) continue;
      entries.add(
        WatchFeedEntry(
          title: m.str(1),
          subtitle: m.str(2),
          overline: m.str(11),
          feedUri: m.str(4),
          thumbnailUrl: m.str(3),
          videoUrl: _httpUrl(m.msg(9).str(1)),
          accessibilityText: m.str(10),
        ),
      );
    }
    if (entries.isEmpty) return null;
    return WatchFeedShelf(title: carousel.value.str(1), entries: entries);
  }

  // ---------------------------------------------------------------------------
  // feed 本体
  // ---------------------------------------------------------------------------

  /// `watch-feed-view/v1/feed` → WatchFeedResponse{1 Any header, 2 repeated Any items,
  /// 3 Any onboarding, 99 pivoting{1 repeated uri}, 100 pagination{2 next_page_token}}。
  static WatchFeedPage parseFeed(List<int> bytes) {
    final response = ProtoMsg.parse(bytes);
    final items = <WatchFeedItem>[
      for (final layout in response.anys(2)) ?_item(layout),
    ];
    final onboarding = response.any(3);
    var vertical = '';
    var associated = '';
    if (onboarding != null && onboarding.typeName == 'OnboardingComponentV2') {
      // {1 Any main(VerticalOnboarding{1 title}), 2 Any associated(AssociatedFeedsOnboarding{1 title})}
      vertical = onboarding.value.any(1)?.value.str(1) ?? '';
      associated = onboarding.value.any(2)?.value.str(1) ?? '';
    } else if (onboarding?.typeName == 'VerticalOnboardingComponent') {
      vertical = onboarding!.value.str(1);
    }
    final next = response.msg(100).bytes(2);
    return WatchFeedPage(
      headerTitles: _headerTitles(response.any(1)),
      items: items,
      nextPageToken: next == null || next.isEmpty ? null : next,
      associatedFeedUris: response
          .msg(99)
          .strs(1)
          .where((u) => u.startsWith('spotify:watch-feed'))
          .toList(),
      verticalOnboardingText: vertical,
      associatedOnboardingText: associated,
    );
  }

  /// FeedHeaderComponent{2 title, 6 Any body}；body 为 PivotingHeaderBody{1 repeated Any bodies}
  /// 时每个 body 的标题对应一个横向 feed。
  static List<String> _headerTitles(ProtoAny? header) {
    if (header == null) return const [];
    final m = header.value;
    final body = m.any(6);
    if (body != null && body.typeName == 'PivotingHeaderBodyComponent') {
      return [
        for (final b in body.value.anys(1))
          if (_bodyTitle(b) case final t when t.isNotEmpty) t,
      ];
    }
    final single = body == null ? '' : _bodyTitle(body);
    if (single.isNotEmpty) return [single];
    return [if (m.str(2).isNotEmpty) m.str(2)];
  }

  /// 头部 body 的标题：TextHeaderBody{2 title} / NavigationHeaderBody{1 title} / AnimationHeaderBody{2 subtitle}。
  static String _bodyTitle(ProtoAny body) => switch (body.typeName) {
    'TextHeaderBodyComponent' => body.value.str(2),
    'NavigationHeaderBodyComponent' => body.value.str(1),
    'AnimationHeaderBodyComponent' => body.value.str(2),
    _ => '',
  };

  /// 一个布局 → 条目；只认 TwoColumns / StorytellingDefault，其余（调查页、标签云结尾页等）跳过。
  static WatchFeedItem? _item(ProtoAny layout) {
    final m = layout.value;
    final ProtoAny? content;
    final List<ProtoAny> overlays;
    final String id;
    final String uri;
    switch (layout.typeName) {
      case 'WatchFeedTwoColumnsLayout':
        // {1 item_id, 2 content, 3 top, 4 main, 5 action, 6 bottom, 8 uri, 11 separated_bottom}
        content = m.any(2);
        overlays = [
          ...m.anys(3),
          ...m.anys(4),
          ...m.anys(5),
          ...m.anys(6),
          ...m.anys(11),
        ];
        id = m.str(1);
        uri = m.str(8);
      case 'StorytellingDefaultLayout':
        // {1 content, 2 top, 3 center, 4 bottom, 5 item_id, 8 uri}
        content = m.any(1);
        overlays = [...m.anys(2), ...m.anys(3), ...m.anys(4)];
        id = m.str(5);
        uri = m.str(8);
      default:
        return null;
    }
    final parsedContent = content == null ? null : _content(content);
    if (parsedContent == null) return null;

    WatchFeedCreator? creator;
    WatchFeedEntityRow? entityRow;
    SpotifyTrack? track;
    final hashtags = <WatchFeedHashtag>[];
    final texts = <String>[];
    var canShare = false;
    var hasMenu = false;
    var canSave = false;
    var hasProgressBar = false;
    for (final overlay in overlays) {
      final o = overlay.value;
      switch (overlay.typeName) {
        case 'CreatorRowComponent':
          creator ??= _creator(o);
        case 'HashtagRowComponent':
          // {1 repeated Any<Hashtag>}：官方客户端不校验内层 type_url，这里也一样。
          for (final h in o.anys(1)) {
            if (_hashtag(h.value) case final tag?) hashtags.add(tag);
          }
        case 'HashtagCloudComponent':
          for (final h in o.msgs(2)) {
            if (_hashtag(h) case final tag?) hashtags.add(tag);
          }
        case 'BoxedEntityRowComponentV2':
          entityRow ??= _entityRow(o);
          if (o.any(8)?.typeName.contains('AddToCollection') ?? false) {
            canSave = true;
          }
        case 'TrackContextMenuButtonComponent':
          hasMenu = true;
          track ??= _menuTrack(o);
        case 'EntityShareButtonComponent' || 'LabeledShareButtonComponent':
          canShare = true;
        case 'AddToCollectionButtonComponent' ||
            'LabeledAddToCollectionButtonComponent':
          canSave = true;
        case 'ProgressBarComponent':
          hasProgressBar = true;
        case 'TextHeaderBodyComponent':
          if (o.str(2).isNotEmpty) texts.add(o.str(2));
        case 'StyledTextRowComponent':
          if (o.str(1).isNotEmpty) texts.add(o.str(1));
      }
    }
    final (visual, audio, contentUri) = parsedContent;
    return WatchFeedItem(
      id: id,
      uri: uri.isNotEmpty ? uri : contentUri,
      visual: visual,
      audio: audio,
      creator: creator,
      hashtags: hashtags,
      entityRow: entityRow,
      texts: texts,
      track: track,
      canShare: canShare,
      hasMenu: hasMenu,
      canSave: canSave,
      hasProgressBar: hasProgressBar,
    );
  }

  /// 画面 + 试听 + 内容实体 uri；不支持的内容类型返回 null（整条跳过）。
  static (WatchFeedVisual, WatchFeedAudio?, String)? _content(
    ProtoAny content,
  ) {
    final m = content.value;
    switch (content.typeName) {
      case 'CanvasContent':
        // {1 track_uri, 2 video_file{1 uri}, 3 audio_file, 4 thumbnail{1 url}, 5 should_loop, 7 increase_volume_gradually}
        final video = _httpUrl(m.msg(2).str(1));
        return (
          WatchFeedVisual(
            kind: video.isEmpty
                ? WatchFeedVisualKind.image
                : WatchFeedVisualKind.canvas,
            videoUrl: video,
            imageUrl: m.msg(4).str(1),
          ),
          _audio(m.msg(3), loop: m.flag(5), fadeIn: m.flag(7)),
          m.str(1),
        );
      case 'TrackPreviewContent':
        // {1 entity_uri, 2 audio_file, 3 thumbnail{1 url}, 4 animation_url, 5 should_loop, 7 increase_volume_gradually}
        return (
          WatchFeedVisual(
            kind: WatchFeedVisualKind.trackPreview,
            imageUrl: m.msg(3).str(1),
            animationUrl: m.str(4),
          ),
          _audio(m.msg(2), loop: m.flag(5), fadeIn: m.flag(7)),
          m.str(1),
        );
      case 'VideoContent':
        // {1 video_uri, 2 video_file{1 uri, 2 type}, 3 thumbnail}；只支持直链（type URL=0）。
        final file = m.msg(2);
        final video = file.integer(2) == 0 ? _httpUrl(file.str(1)) : '';
        return (
          WatchFeedVisual(
            kind: video.isEmpty
                ? WatchFeedVisualKind.image
                : WatchFeedVisualKind.canvas,
            videoUrl: video,
            imageUrl: m.msg(3).str(1),
          ),
          null,
          m.str(1),
        );
      case 'ImageContent':
        // {1 image{1 url}, 2 background_audio_preview{1 audio_file, 2 should_loop, 3 entity_uri}, 3 increase}
        final bg = m.msg(2);
        return (
          WatchFeedVisual(
            kind: WatchFeedVisualKind.image,
            imageUrl: m.msg(1).str(1),
          ),
          _audio(bg.msg(1), loop: bg.flag(2), fadeIn: m.flag(3)),
          bg.str(3),
        );
      case 'LinearGradientContent' || 'LottieAnimationContent':
        // Gradient{1 repeated colors, 2 bg audio, 3 increase}；Lottie{1 url, 2 bg audio, 3 increase} 按默认渐变画。
        final bg = m.msg(2);
        return (
          WatchFeedVisual(
            kind: WatchFeedVisualKind.gradient,
            colors: content.typeName == 'LinearGradientContent'
                ? m.strs(1)
                : const [],
          ),
          _audio(bg.msg(1), loop: bg.flag(2), fadeIn: m.flag(3)),
          bg.str(3),
        );
      default:
        return null;
    }
  }

  /// AudioFile{1 cdn_url, 2 file_id}：完整地址 = cdn_url + file_id。
  static WatchFeedAudio? _audio(
    ProtoMsg file, {
    required bool loop,
    required bool fadeIn,
  }) {
    final url = _httpUrl('${file.str(1)}${file.str(2)}');
    if (url.isEmpty) return null;
    return WatchFeedAudio(url: url, shouldLoop: loop, fadeIn: fadeIn);
  }

  /// CreatorRow{1 repeated creator_uris, 2 repeated Visual{1 Artwork{1 uri}}, 3 title, 4 subtitle,
  /// 5 FollowAction{1 follow_uri, 2 follow_text, 3 following_text}}。
  static WatchFeedCreator? _creator(ProtoMsg m) {
    final uris = m.strs(1);
    final name = m.str(3);
    if (name.isEmpty) return null;
    final visuals = m.msgs(2);
    final follow = m.msg(5);
    return WatchFeedCreator(
      uri: uris.isEmpty ? '' : uris.first,
      name: name,
      subtitle: m.str(4),
      imageUrl: visuals.isEmpty ? '' : visuals.first.msg(1).str(1),
      followUri: follow.str(1),
      followText: follow.str(2),
      followingText: follow.str(3),
    );
  }

  /// Hashtag{1 id, 2 title, 3 seed_item_uri, 4 navigation_uri}。
  static WatchFeedHashtag? _hashtag(ProtoMsg m) {
    final title = m.str(2);
    final navigation = m.str(4);
    if (title.isEmpty || !navigation.startsWith('spotify:watch-feed')) {
      return null;
    }
    return WatchFeedHashtag(
      id: m.str(1),
      title: title,
      navigationUri: navigation,
      seedItemUri: m.str(3),
    );
  }

  /// BoxedEntityRowV2{1 title, 2 subtitle, 3 image{1 url}, 6 tap_action{1 navigation{1 uri} | 2 play{1 uri}}, 7 a11y}。
  static WatchFeedEntityRow? _entityRow(ProtoMsg m) {
    final tap = m.msg(6);
    final play = tap.msg(2).str(1).isNotEmpty
        ? tap.msg(2).str(1)
        : tap.msg(1).str(1);
    if (m.str(1).isEmpty || play.isEmpty) return null;
    return WatchFeedEntityRow(
      title: m.str(1),
      subtitle: m.str(2),
      imageUrl: m.msg(3).str(1),
      playUri: play,
      accessibilityText: m.str(7),
    );
  }

  /// TrackContextMenuButton{1 Track{1 uri, 2 name}, 2 Album{1 uri, 2 name, 3 image{1 url}},
  /// 3 repeated Artist{1 uri, 2 name}} → 最小可用曲目。
  static SpotifyTrack? _menuTrack(ProtoMsg m) {
    final t = m.msg(1);
    final uri = t.str(1);
    if (!uri.startsWith('spotify:track:')) return null;
    final album = m.msg(2);
    final cover = album.msg(3).str(1);
    return SpotifyTrack(
      id: _id(uri),
      uri: uri,
      name: t.str(2),
      artists: [
        for (final a in m.msgs(3))
          if (a.str(1).isNotEmpty)
            SpotifyArtist(id: _id(a.str(1)), name: a.str(2), uri: a.str(1)),
      ],
      album: album.str(1).isEmpty
          ? null
          : SpotifyAlbum(
              id: _id(album.str(1)),
              name: album.str(2),
              uri: album.str(1),
              images: [if (cover.isNotEmpty) SpotifyImage(url: cover)],
            ),
    );
  }

  // ---------------------------------------------------------------------------
  // 实体 feed（桌面版：Pathfinder watchFeedEntity，JSON）
  // ---------------------------------------------------------------------------

  /// `data.getWatchFeedForEntity{items[TrackResponseWrapper{data: Track}], totalCount,
  /// pagingInfo{nextOffset}}` → 条目。Track 里：canvas（有则播视频）、previews.audioPreviews（试听）、
  /// discoveryFeedHashtags（#标签，标题不带 #）、albumOfTrack.coverArt.extractedColors.colorDark（背景色）。
  static WatchFeedEntityPage parseEntityFeed(Map<String, dynamic> data) {
    final feed = _map(data['getWatchFeedForEntity']);
    final items = <WatchFeedItem>[];
    for (final wrapper in _list(feed['items'])) {
      final track = _map(_map(wrapper)['data']);
      if (track['__typename'] != 'Track') continue;
      final item = _entityTrack(track);
      if (item != null) items.add(item);
    }
    final next = _map(feed['pagingInfo'])['nextOffset'];
    return WatchFeedEntityPage(
      items: items,
      totalCount: (feed['totalCount'] as num?)?.toInt() ?? items.length,
      nextOffset: next is num ? next.toInt() : null,
    );
  }

  static WatchFeedItem? _entityTrack(Map<String, dynamic> t) {
    final uri = _str(t['uri']);
    if (!uri.startsWith('spotify:track:')) return null;
    final album = _map(t['albumOfTrack']);
    final coverArt = _map(album['coverArt']);
    final cover = _largest(_list(coverArt['sources']));
    final artists = [
      for (final a in _list(_map(t['artists'])['items'])) _map(a),
    ];
    final first = artists.isEmpty ? const <String, dynamic>{} : artists.first;
    final canvas = _map(t['canvas']);
    final canvasUrl = _httpUrl(_str(canvas['url']));
    final canvasThumb = _largest(_list(_map(canvas['thumbnail'])['sources']));
    final preview = _list(_map(_map(t['previews'])['audioPreviews'])['items']);
    final previewUrl = preview.isEmpty
        ? ''
        : _httpUrl(_str(_map(preview.first)['url']));
    final dark = _map(_map(coverArt['extractedColors'])['colorDark']);
    final darkHex = dark['isFallback'] == true ? '' : _str(dark['hex']);
    final firstUri = _str(first['uri']);
    final track = SpotifyTrack(
      id: _id(uri),
      uri: uri,
      name: _str(t['name']),
      explicit: _str(_map(t['contentRating'])['label']) == 'EXPLICIT',
      artists: [
        for (final a in artists)
          if (_str(a['uri']).isNotEmpty)
            SpotifyArtist(
              id: _id(_str(a['uri'])),
              uri: _str(a['uri']),
              name: _str(_map(a['profile'])['name']),
            ),
      ],
      album: _str(album['uri']).isEmpty
          ? null
          : SpotifyAlbum(
              id: _id(_str(album['uri'])),
              uri: _str(album['uri']),
              name: _str(album['name']),
              images: [if (cover.isNotEmpty) SpotifyImage(url: cover)],
            ),
    );
    final listeners = _map(first['stats'])['monthlyListeners'];
    return WatchFeedItem(
      id: uri,
      uri: uri,
      visual: canvasUrl.isNotEmpty
          ? WatchFeedVisual(
              kind: WatchFeedVisualKind.canvas,
              videoUrl: canvasUrl,
              imageUrl: canvasThumb.isNotEmpty ? canvasThumb : cover,
            )
          : WatchFeedVisual(
              kind: WatchFeedVisualKind.trackPreview,
              imageUrl: cover,
            ),
      audio: previewUrl.isEmpty
          ? null
          : WatchFeedAudio(url: previewUrl, shouldLoop: true),
      creator: firstUri.isEmpty
          ? null
          : WatchFeedCreator(
              uri: firstUri,
              name: _str(_map(first['profile'])['name']),
              imageUrl: _largest(
                _list(_map(_map(first['visuals'])['avatarImage'])['sources']),
                smallest: true,
              ),
              monthlyListeners: listeners is num ? listeners.toInt() : null,
              followUri: firstUri,
            ),
      hashtags: [
        for (final h in _list(t['discoveryFeedHashtags']))
          if (_str(_map(h)['title']).isNotEmpty &&
              _str(_map(h)['uri']).startsWith('spotify:watch-feed'))
            WatchFeedHashtag(
              id: _id(_str(_map(h)['uri']).split('?').first),
              title: '#${_str(_map(h)['title'])}',
              navigationUri: _str(_map(h)['uri']),
              seedItemUri: uri,
            ),
      ],
      track: track,
      backgroundColor: _hexColor(darkHex),
      canShare: true,
      hasMenu: true,
      canSave: true,
      hasProgressBar: true,
    );
  }

  static Map<String, dynamic> _map(Object? v) =>
      v is Map<String, dynamic> ? v : const <String, dynamic>{};

  static List<Object?> _list(Object? v) => v is List ? v : const [];

  static String _str(Object? v) => v is String ? v : '';

  /// 图片源里最大（或 [smallest] 时最小）的一张。
  static String _largest(List<Object?> sources, {bool smallest = false}) {
    String best = '';
    num bestSize = smallest ? double.infinity : -1;
    for (final s in sources) {
      final m = _map(s);
      final url = _str(m['url']);
      if (url.isEmpty) continue;
      final size = (m['width'] ?? m['maxWidth'] ?? 0) as num;
      if (smallest ? size < bestSize : size > bestSize) {
        best = url;
        bestSize = size;
      }
    }
    return best;
  }

  /// `#RRGGBB` → 不透明 ARGB；格式不对返回 null。
  static int? _hexColor(String hex) {
    final v = hex.startsWith('#') ? hex.substring(1) : hex;
    if (v.length != 6) return null;
    final rgb = int.tryParse(v, radix: 16);
    return rgb == null ? null : 0xFF000000 | rgb;
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  static String _id(String uri) => uri.split(':').last;

  /// 只接受 https 地址；VideoFile 等字段偶尔是 manifest id。
  static String _httpUrl(String value) =>
      value.startsWith('https://') ? value : '';

  /// 嵌套消息里的第一个非空字符串（Heading 的结构是多层 oneof，只关心标题文字）。
  static String _firstString(ProtoMsg m, [int depth = 0]) {
    for (var field = 1; field <= 4; field++) {
      final s = m.str(field);
      if (s.isNotEmpty && !s.codeUnits.any((c) => c < 0x20)) return s;
      if (depth < 3) {
        final nested = _firstString(m.msg(field), depth + 1);
        if (nested.isNotEmpty) return nested;
      }
    }
    return '';
  }
}

/// `spotify:watch-feed:…` URI → 请求参数（对齐官方 twa.java：第 2 段为 feed_id，剩余段数为奇数时
/// 下一段为 entity_id，其余成对的段与 query 全部进 parameters，值里的 `/` 还原为 `:`）。
class WatchFeedRequestSpec {
  final String feedId;
  final String? entityId;
  final Map<String, String> parameters;

  const WatchFeedRequestSpec({
    required this.feedId,
    this.entityId,
    this.parameters = const {},
  });

  static const _prefix = 'spotify:watch-feed:';

  /// 解析失败（不是 watch-feed URI）返回 null。
  static WatchFeedRequestSpec? fromUri(String uri) {
    if (!uri.startsWith(_prefix)) return null;
    final rest = uri.substring(_prefix.length);
    final q = rest.indexOf('?');
    final path = q < 0 ? rest : rest.substring(0, q);
    final query = q < 0 ? '' : rest.substring(q + 1);
    final segments = path.split(':').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null;
    final feedId = segments.first;
    final remaining = segments.sublist(1);
    String? entityId;
    var start = 0;
    if (remaining.length.isOdd) {
      entityId = remaining.first;
      start = 1;
    }
    final parameters = <String, String>{};
    for (var i = start; i + 1 < remaining.length; i += 2) {
      parameters[remaining[i]] = remaining[i + 1];
    }
    for (final pair in query.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      final key = _decode(eq < 0 ? pair : pair.substring(0, eq));
      final value = eq < 0
          ? ''
          : _decode(pair.substring(eq + 1)).replaceAll('/', ':');
      if (key.isEmpty || key == 'presentAsOverlay') continue;
      parameters[key] = value;
    }
    return WatchFeedRequestSpec(
      feedId: feedId,
      entityId: entityId,
      parameters: parameters,
    );
  }

  /// 百分号解码；编码不合法时原样返回。
  static String _decode(String value) {
    try {
      return Uri.decodeQueryComponent(value);
    } catch (_) {
      return value;
    }
  }
}
