import 'dart:typed_data';

import 'package:flutify_app/services/auth/proto_codec.dart';

/// 按官方字段号手工拼出的 Watch Feed 响应（结构同线上实测，内容为合成数据）。

const _t = 'type.googleapis.com/spotify.watchfeed.component';

ProtoWriter any(String typeUrl, ProtoWriter value) => ProtoWriter()
  ..string(1, typeUrl)
  ..message(2, value);

ProtoWriter _image(String url) => ProtoWriter()..string(1, url);

ProtoWriter _audio(String id) => ProtoWriter()
  ..string(1, 'https://p.scdn.co/mp3-preview/')
  ..string(2, id);

ProtoWriter hashtag(String id, String title) => ProtoWriter()
  ..string(1, id)
  ..string(2, title)
  ..string(3, 'spotify:track:seed')
  ..string(4, 'spotify:watch-feed:discovery-feed:$id?isNestedFeed=true');

/// 一条 Canvas 条目（TwoColumns）：艺人行、#标签行、曲目行、分享 / 菜单 / 保存 / 进度条。
ProtoWriter canvasItem(String trackId, {String name = 'Song'}) {
  final uri = 'spotify:track:$trackId';
  final content = ProtoWriter()
    ..string(1, uri)
    ..message(
      2,
      ProtoWriter()..string(1, 'https://canvaz.scdn.co/$trackId.mp4'),
    )
    ..message(3, _audio('a$trackId'))
    ..message(4, _image('https://i.scdn.co/thumb-$trackId'))
    ..boolValue(5, true)
    ..boolValue(7, true);
  final creator = ProtoWriter()
    ..string(1, 'spotify:artist:art1')
    ..message(2, ProtoWriter()..message(1, _image('https://i.scdn.co/artist')))
    ..string(3, 'Artist One')
    ..string(4, '2.8M followers')
    ..message(
      5,
      ProtoWriter()
        ..string(1, 'spotify:artist:art1')
        ..string(2, 'Follow')
        ..string(3, 'Following'),
    );
  final hashtags = ProtoWriter()
    ..message(1, any('$_t.item.v1.Hashtag', hashtag('h1', '#chamber pop')))
    ..message(1, any('$_t.item.v1.Hashtag', hashtag('h2', '#sad')));
  final entityRow = ProtoWriter()
    ..string(1, name)
    ..string(2, 'Artist One')
    ..message(3, _image('https://i.scdn.co/cover-$trackId'))
    ..message(6, ProtoWriter()..message(1, ProtoWriter()..string(1, uri)))
    ..string(7, 'Play song: $name')
    ..message(
      8,
      any(
        '$_t.item.v1.AddToCollectionButtonComponent',
        ProtoWriter()..string(1, uri),
      ),
    );
  final menu = ProtoWriter()
    ..message(
      1,
      ProtoWriter()
        ..string(1, uri)
        ..string(2, name),
    )
    ..message(
      2,
      ProtoWriter()
        ..string(1, 'spotify:album:alb1')
        ..string(2, 'Album One')
        ..message(3, _image('https://i.scdn.co/album')),
    )
    ..message(
      3,
      ProtoWriter()
        ..string(1, 'spotify:artist:art1')
        ..string(2, 'Artist One'),
    );
  final layout = ProtoWriter()
    ..string(1, 'item-$trackId')
    ..message(2, any('$_t.content.v1.CanvasContent', content))
    ..message(4, any('$_t.item.v1.CreatorRowComponent', creator))
    ..message(4, any('$_t.item.v1.HashtagRowComponent', hashtags))
    ..message(4, any('$_t.item.v2.BoxedEntityRowComponentV2', entityRow))
    ..message(
      5,
      any(
        '$_t.item.v1.EntityShareButtonComponent',
        ProtoWriter()..string(1, uri),
      ),
    )
    ..message(5, any('$_t.item.v1.TrackContextMenuButtonComponent', menu))
    ..message(
      5,
      any(
        '$_t.item.v1.AddToCollectionButtonComponent',
        ProtoWriter()..string(1, uri),
      ),
    )
    ..message(6, ProtoWriter()..string(1, '$_t.item.v1.ProgressBarComponent'))
    ..string(8, uri);
  return any('$_t.layout.v1.WatchFeedTwoColumnsLayout', layout);
}

/// 一条无视频条目（TrackPreview + 波形动画），只带曲目行。
/// [withAlbum] 为 true 时附带曲目菜单组件（含专辑信息），曲目行可以跳转专辑。
ProtoWriter previewItem(
  String trackId, {
  String name = 'Preview',
  bool withAlbum = false,
}) {
  final uri = 'spotify:track:$trackId';
  final content = ProtoWriter()
    ..string(1, uri)
    ..message(2, _audio('p$trackId'))
    ..message(3, _image('https://i.scdn.co/album-$trackId'))
    ..string(
      4,
      'https://misc.spotifycdn.com/watch-feed/playback-animation.json',
    )
    ..boolValue(5, true);
  final entityRow = ProtoWriter()
    ..string(1, name)
    ..string(2, 'Artist Two')
    ..message(6, ProtoWriter()..message(1, ProtoWriter()..string(1, uri)));
  final layout = ProtoWriter()
    ..string(1, 'item-$trackId')
    ..message(2, any('$_t.content.v1.TrackPreviewContent', content))
    ..message(
      4,
      any(
        '$_t.item.v1.HashtagRowComponent',
        ProtoWriter()
          ..message(1, any('$_t.item.v1.Hashtag', hashtag('h3', '#autumn'))),
      ),
    )
    ..message(4, any('$_t.item.v2.BoxedEntityRowComponentV2', entityRow))
    ..string(8, uri);
  if (withAlbum) {
    layout.message(
      5,
      any(
        '$_t.item.v1.TrackContextMenuButtonComponent',
        ProtoWriter()
          ..message(
            1,
            ProtoWriter()
              ..string(1, uri)
              ..string(2, name),
          )
          ..message(
            2,
            ProtoWriter()
              ..string(1, 'spotify:album:alb$trackId')
              ..string(2, 'Album of $name'),
          ),
      ),
    );
  }
  return any('$_t.layout.v1.WatchFeedTwoColumnsLayout', layout);
}

/// 一页 feed：头部轮换标题、条目、引导、关联 feed、下一页令牌。
Uint8List feedResponse({
  List<ProtoWriter> items = const [],
  List<String> headerTitles = const ['Similar to Song', '#folk'],
  List<String> associated = const [],
  List<int>? nextToken,
  String vertical = 'Swipe up to see more',
  String associatedHint = 'Swipe for more feeds',
}) {
  final pivoting = ProtoWriter();
  for (final t in headerTitles) {
    pivoting.message(
      1,
      any('$_t.item.v1.TextHeaderBodyComponent', ProtoWriter()..string(2, t)),
    );
  }
  final header = ProtoWriter()
    ..message(
      5,
      any(
        '$_t.item.v2.MuteButtonComponent',
        ProtoWriter()..string(1, 'Unmute'),
      ),
    )
    ..message(6, any('$_t.item.v1.PivotingHeaderBodyComponent', pivoting));
  final onboarding = ProtoWriter()
    ..message(
      1,
      any(
        '$_t.item.v1.VerticalOnboardingComponent',
        ProtoWriter()..string(1, vertical),
      ),
    )
    ..message(
      2,
      any(
        '$_t.item.v1.AssociatedFeedsOnboardingComponent',
        ProtoWriter()..string(1, associatedHint),
      ),
    );
  final response = ProtoWriter()
    ..message(1, any('$_t.item.v2.FeedHeaderComponent', header));
  for (final item in items) {
    response.message(2, item);
  }
  // 不认识的布局应被跳过。
  response
    ..message(
      2,
      any('$_t.layout.v1.WatchFeedSurveyLayout', ProtoWriter()..string(1, 'x')),
    )
    ..message(3, any('$_t.item.v2.OnboardingComponentV2', onboarding))
    ..string(4, 'decision');
  final pivot = ProtoWriter();
  for (final u in associated) {
    pivot.string(1, u);
  }
  response.message(99, pivot);
  final pagination = ProtoWriter();
  if (nextToken != null) pagination.bytes(2, nextToken);
  response.message(100, pagination);
  return response.toBytes();
}

/// 搜索页 browse：一个推广区块 + 一个 WatchFeed 区块（两张卡）。
Uint8List browseResponse() {
  ProtoWriter card(String id, String title) => ProtoWriter()
    ..message(
      1,
      ProtoWriter()..string(1, 'spotify:watch-feed:discovery-feed:$id'),
    )
    ..message(
      2,
      ProtoWriter()
        ..string(1, 'spotify:watch-feed:discovery-feed:$id')
        ..string(2, 'spotify:track:first-$id')
        ..string(4, title)
        ..message(6, _image('https://i.scdn.co/thumb-$id'))
        ..message(7, ProtoWriter()..string(1, 'https://canvaz.scdn.co/$id.mp4'))
        ..string(
          8,
          'spotify:watch-feed:discovery-feed:$id?firstItemUris=spotify:track:first-$id',
        )
        ..string(9, 'Explore $title')
        ..message(10, _image('https://i.scdn.co/cover-$id')),
    );
  final promo = ProtoWriter()
    ..message(1, ProtoWriter()..string(1, 'spotify:section:promo'))
    ..message(3, ProtoWriter()..string(1, 'promo'));
  final watchFeed = ProtoWriter()
    ..message(
      1,
      ProtoWriter()
        ..message(1, ProtoWriter()..string(1, 'Discover something new')),
    )
    ..message(2, card('feedA', 'Music for you'))
    ..message(2, card('feedB', '#mellow indie'));
  final section = ProtoWriter()
    ..message(1, ProtoWriter()..string(1, 'spotify:section:watch'))
    ..message(4, watchFeed);
  final structure = ProtoWriter()
    ..message(1, promo)
    ..message(1, section);
  return (ProtoWriter()..message(1, structure)).toBytes();
}

/// discovery-from-seed：WatchFeedVideoCarouselComponent，两张卡。
Uint8List seedResponse() {
  ProtoWriter card(String title, String id) => any(
    'type.googleapis.com/spotify.watchfeedentrypoints.component.item.v1.WatchFeedVideoCardComponent',
    ProtoWriter()
      ..string(1, title)
      ..string(3, 'https://i.scdn.co/seed-$id')
      ..string(4, 'spotify:watch-feed:discovery-feed:$id')
      ..message(
        9,
        ProtoWriter()..string(1, 'https://canvaz.scdn.co/seed-$id.mp4'),
      )
      ..string(10, 'Explore $title'),
  );
  final carousel = ProtoWriter()
    ..string(1, 'Explore Artist One')
    ..message(2, card('Songs by Artist One', 's1'))
    ..message(2, card('Similar to Artist One', 's2'));
  return (ProtoWriter()..message(
        1,
        any(
          'type.googleapis.com/spotify.watchfeedentrypoints.component.item.v1.WatchFeedVideoCarouselComponent',
          carousel,
        ),
      ))
      .toBytes();
}
