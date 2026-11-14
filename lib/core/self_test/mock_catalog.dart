import 'package:flutter/material.dart';

import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/category.dart';
import '../../models/connect_cluster.dart';
import '../../models/device.dart';
import '../../models/home_feed.dart';
import '../../models/image.dart';
import '../../models/lyrics.dart';
import '../../models/playlist.dart';
import '../../models/podcast.dart';
import '../../models/track.dart';
import '../../models/track_credits.dart';
import '../../models/user_profile.dart';
import 'mock_cover_server.dart';

/// Mock 模式使用的离线完整目录与媒体库初始数据。
///
/// 刻意涵盖多音字/汉字拼音排序、超 50 首专辑分页、多页艺人作品与搜索分页、
/// 账号可编辑歌单、双语同步歌词、播客节目与 Spotify Connect 设备等边界情况。
class MockCatalog {
  final MockCoverServer coverServer;

  MockCatalog(this.coverServer);

  late final SpotifyUser currentUser = SpotifyUser(
    id: 'flutify_mock_user',
    displayName: 'Flutify Self-Test',
    email: 'selftest@flutify.local',
    product: 'premium',
    country: 'JP',
    images: [_img('avatar_main')],
  );

  SpotifyImage _img(String seed) => SpotifyImage(
    url: coverServer.imageUrl(seed),
    width: 128,
    height: 128,
  );

  late final List<SpotifyArtist> artists = [
    SpotifyArtist(
      id: 'mock_artist_jay',
      name: '周杰伦',
      uri: 'spotify:artist:mock_artist_jay',
      images: [_img('artist_jay')],
      genres: const ['mandopop', 'c-pop', 'r&b'],
      followers: 18420000,
      popularity: 92,
    ),
    SpotifyArtist(
      id: 'mock_artist_eason',
      name: '陈奕迅',
      uri: 'spotify:artist:mock_artist_eason',
      images: [_img('artist_eason')],
      genres: const ['cantopop', 'mandopop'],
      followers: 11200000,
      popularity: 88,
    ),
    SpotifyArtist(
      id: 'mock_artist_aurora',
      name: 'AURORA',
      uri: 'spotify:artist:mock_artist_aurora',
      images: [_img('artist_aurora')],
      genres: const ['art pop', 'synthpop', 'nordic'],
      followers: 5600000,
      popularity: 84,
    ),
    SpotifyArtist(
      id: 'mock_artist_daft',
      name: 'Daft Punk',
      uri: 'spotify:artist:mock_artist_daft',
      images: [_img('artist_daft')],
      genres: const ['electronic', 'french house'],
      followers: 14800000,
      popularity: 90,
    ),
  ];

  late final List<SpotifyAlbum> albums = [
    SpotifyAlbum(
      id: 'mock_album_ye',
      name: '叶惠美',
      uri: 'spotify:album:mock_album_ye',
      albumType: 'album',
      releaseDate: '2003-07-31',
      totalTracks: 11,
      images: [_img('album_ye')],
      artists: [artists[0]],
    ),
    SpotifyAlbum(
      id: 'mock_album_h3m',
      name: 'H3M',
      uri: 'spotify:album:mock_album_h3m',
      albumType: 'album',
      releaseDate: '2009-03-23',
      totalTracks: 10,
      images: [_img('album_h3m')],
      artists: [artists[1]],
    ),
    SpotifyAlbum(
      id: 'mock_album_deluxe',
      name: 'Random Access Anthology (75-Track Collector Edition)',
      uri: 'spotify:album:mock_album_deluxe',
      albumType: 'compilation',
      releaseDate: '2025-05-12',
      totalTracks: 75,
      images: [_img('album_deluxe')],
      artists: [artists[3], artists[2]],
    ),
  ];

  /// Primary artist 额外发行条目（28 张，用于测试艺人作品页分页加载）。
  late final List<SpotifyAlbum> jayDiscography = [
    albums[0],
    for (var i = 2; i <= 28; i++)
      SpotifyAlbum(
        id: 'mock_album_jay_$i',
        name: i.isEven ? '幻听巡礼 Vol.$i' : '七里香典藏 #$i',
        uri: 'spotify:album:mock_album_jay_$i',
        albumType: i % 3 == 0 ? 'single' : 'album',
        releaseDate: '${2000 + (i % 25)}-06-15',
        totalTracks: i % 3 == 0 ? 3 : 6,
        images: [_img('album_jay_$i')],
        artists: [artists[0]],
      ),
  ];

  late final List<SpotifyTrack> coreTracks = [
    _track(
      id: 'mock_track_01',
      name: '晴天',
      artist: artists[0],
      album: albums[0],
      durationMs: 269000,
      daysAgo: 1,
      explicit: false,
    ),
    _track(
      id: 'mock_track_02',
      name: '夜曲',
      artist: artists[0],
      album: albums[0],
      durationMs: 226000,
      daysAgo: 2,
    ),
    _track(
      id: 'mock_track_03',
      name: '以父之名',
      artist: artists[0],
      album: albums[0],
      durationMs: 342000,
      daysAgo: 4,
      explicit: true,
    ),
    _track(
      id: 'mock_track_04',
      name: '富士山下',
      artist: artists[1],
      album: albums[1],
      durationMs: 259000,
      daysAgo: 5,
    ),
    _track(
      id: 'mock_track_05',
      name: '沙龙',
      artist: artists[1],
      album: albums[1],
      durationMs: 274000,
      daysAgo: 7,
    ),
    _track(
      id: 'mock_track_06',
      name: 'Runaway',
      artist: artists[2],
      album: SpotifyAlbum(
        id: 'mock_album_aurora',
        name: 'All My Demons Greeting Me as a Friend',
        uri: 'spotify:album:mock_album_aurora',
        releaseDate: '2016-03-11',
        totalTracks: 12,
        images: [_img('album_aurora')],
        artists: [artists[2]],
      ),
      durationMs: 248000,
      daysAgo: 9,
    ),
    _track(
      id: 'mock_track_07',
      name: 'Instant Crush',
      artist: artists[3],
      album: albums[2],
      durationMs: 337000,
      daysAgo: 11,
    ),
    _track(
      id: 'mock_track_08',
      name: '星辰大海',
      artist: artists[1],
      album: albums[1],
      durationMs: 215000,
      daysAgo: 15,
    ),
    _track(
      id: 'mock_track_09',
      name: '阿尔卑斯之风',
      artist: artists[2],
      album: albums[2],
      durationMs: 198000,
      daysAgo: 21,
    ),
    _track(
      id: 'mock_track_10',
      name: 'Midnight Espresso',
      artist: artists[3],
      album: albums[2],
      durationMs: 204000,
      daysAgo: 28,
    ),
    for (var i = 11; i <= 24; i++)
      _track(
        id: 'mock_track_${i.toString().padLeft(2, '0')}',
        name: i.isEven ? '城市漫游 #$i' : 'Velvet Horizon $i',
        artist: artists[i % artists.length],
        album: albums[i % albums.length],
        durationMs: (180 + i * 5) * 1000,
        daysAgo: i + 10,
      ),
  ];

  /// 75 首大专辑曲目（用于验证专辑详情超过 50 首分页）。
  late final List<SpotifyTrack> deluxeAlbumTracks = List.generate(75, (index) {
    final n = index + 1;
    return _track(
      id: 'mock_deluxe_${n.toString().padLeft(2, '0')}',
      name: 'Anthology Movement ${n.toString().padLeft(2, '0')}',
      artist: artists[index % artists.length],
      album: albums[2],
      durationMs: (190 + (index % 7) * 15) * 1000,
      daysAgo: index + 1,
    );
  });

  SpotifyTrack _track({
    required String id,
    required String name,
    required SpotifyArtist artist,
    required SpotifyAlbum album,
    required int durationMs,
    int daysAgo = 1,
    bool explicit = false,
  }) => SpotifyTrack(
    id: id,
    name: name,
    uri: 'spotify:track:$id',
    artists: [artist],
    album: album,
    durationMs: durationMs,
    explicit: explicit,
    isPlayable: true,
    addedAt: DateTime(2026, 11, 14).subtract(Duration(days: daysAgo)),
  );

  late final List<SpotifyPlaylist> playlists = [
    SpotifyPlaylist(
      id: 'mock_pl_account_1',
      name: '深夜漫步 Night Drive',
      uri: 'spotify:playlist:mock_pl_account_1',
      description: 'Mock 账号自建歌单：夜色都市合成器与华语R&B',
      ownerName: currentUser.displayName,
      images: [_img('pl_night')],
      tracks: coreTracks.sublist(0, 12),
      totalTracks: 12,
      isPublic: false,
    ),
    SpotifyPlaylist(
      id: 'mock_pl_account_2',
      name: '编程专注 Focus Flow',
      uri: 'spotify:playlist:mock_pl_account_2',
      description: 'Mock 账号歌单：氛围电子与纯音乐节拍',
      ownerName: currentUser.displayName,
      images: [_img('pl_focus')],
      tracks: coreTracks.sublist(4, 16),
      totalTracks: 12,
      isPublic: true,
    ),
    SpotifyPlaylist(
      id: 'mock_pl_account_3',
      name: '华语精选 Mandopop Gold',
      uri: 'spotify:playlist:mock_pl_account_3',
      description: '可编辑测试歌单：支持「添加到歌单」计数联动验证',
      ownerName: currentUser.displayName,
      images: [_img('pl_mando')],
      tracks: coreTracks.sublist(0, 5),
      totalTracks: 5,
      isPublic: true,
    ),
    SpotifyPlaylist(
      id: 'mock_pl_curated',
      name: 'Daily Discovery Mix',
      uri: 'spotify:playlist:mock_pl_curated',
      description: '精选推荐电台歌单，含全曲目列表',
      ownerName: 'Flutify Editorial',
      images: [_img('pl_daily')],
      tracks: coreTracks,
      totalTracks: coreTracks.length,
      isPublic: true,
    ),
  ];

  late final List<PodcastEpisode> episodes = [
    PodcastEpisode(
      id: 'mock_ep_01',
      uri: 'spotify:episode:mock_ep_01',
      name: 'EP.42 声学与柔光设计：移动端渲染性能实践',
      description: '深入浅出讨论高刷屏渲染管线、歌词着色器与音画同步。',
      durationMs: 1840000,
      releaseDate: '2026-11-01',
      images: [_img('pod_01')],
      showUri: 'spotify:show:mock_show_01',
      showName: 'Design & Acoustic Talk',
      resumeMs: 120000,
      played: false,
    ),
    PodcastEpisode(
      id: 'mock_ep_02',
      uri: 'spotify:episode:mock_ep_02',
      name: 'EP.41 独立唱片制作人的数字工作流',
      description: '母带动态范围、空间音频与无损流媒体。',
      durationMs: 2150000,
      releaseDate: '2026-10-20',
      images: [_img('pod_02')],
      showUri: 'spotify:show:mock_show_01',
      showName: 'Design & Acoustic Talk',
      resumeMs: 0,
      played: true,
    ),
  ];

  late final PodcastShow podcastShow = PodcastShow(
    id: 'mock_show_01',
    uri: 'spotify:show:mock_show_01',
    name: 'Design & Acoustic Talk',
    publisher: 'Flutify Studio',
    description: '围绕音乐工程、界面动效与声音体验的深度对谈播客。',
    images: [_img('pod_show')],
    episodes: episodes,
  );

  late final List<SpotifyCategory> categories = [
    SpotifyCategory(
      id: 'mandopop',
      name: '华语流行',
      iconUrl: coverServer.imageUrl('cat_mandopop'),
      color: const Color(0xFFE11D48),
    ),
    SpotifyCategory(
      id: 'electronic',
      name: '电子舞曲',
      iconUrl: coverServer.imageUrl('cat_electronic'),
      color: const Color(0xFF2563EB),
    ),
    SpotifyCategory(
      id: 'focus',
      name: '专注律动',
      iconUrl: coverServer.imageUrl('cat_focus'),
      color: const Color(0xFF059669),
    ),
    SpotifyCategory(
      id: 'chill',
      name: '夜晚放松',
      iconUrl: coverServer.imageUrl('cat_chill'),
      color: const Color(0xFF7C3AED),
    ),
    SpotifyCategory(
      id: 'indie',
      name: '独立民谣',
      iconUrl: coverServer.imageUrl('cat_indie'),
      color: const Color(0xFFD97706),
    ),
    SpotifyCategory(
      id: 'acg',
      name: 'ACG / 游戏原声',
      iconUrl: coverServer.imageUrl('cat_acg'),
      color: const Color(0xFF0891B2),
    ),
  ];

  List<HomeItem> _homeItems() => [
    HomeItem(
      kind: HomeItemKind.playlist,
      uri: playlists[0].uri,
      title: playlists[0].name,
      subtitle: playlists[0].ownerName,
      images: playlists[0].images,
      playlist: playlists[0],
    ),
    HomeItem(
      kind: HomeItemKind.album,
      uri: albums[2].uri,
      title: albums[2].name,
      subtitle: albums[2].artistNames,
      images: albums[2].images,
      album: albums[2],
    ),
    HomeItem(
      kind: HomeItemKind.artist,
      uri: artists[0].uri,
      title: artists[0].name,
      subtitle: '艺人',
      images: artists[0].images,
      artist: artists[0],
    ),
    HomeItem(
      kind: HomeItemKind.playlist,
      uri: playlists[3].uri,
      title: playlists[3].name,
      subtitle: playlists[3].description,
      images: playlists[3].images,
      playlist: playlists[3],
    ),
    HomeItem(
      kind: HomeItemKind.album,
      uri: albums[0].uri,
      title: albums[0].name,
      subtitle: artists[0].name,
      images: albums[0].images,
      album: albums[0],
    ),
    HomeItem(
      kind: HomeItemKind.podcast,
      uri: podcastShow.uri,
      title: podcastShow.name,
      subtitle: podcastShow.publisher,
      images: podcastShow.images,
    ),
  ];

  HomeFeed buildHome({String facet = ''}) {
    final items = _homeItems();
    final filtered = facet == 'podcast-chip'
        ? [items.last]
        : facet == 'sub-electronic'
        ? [items[1], items[3]]
        : items;

    final chips = const [
      HomeChip(
        id: 'music-chip',
        label: '音乐',
        subChips: [
          HomeChip(id: 'sub-pop', label: '流行'),
          HomeChip(id: 'sub-electronic', label: '电子'),
          HomeChip(id: 'sub-focus', label: '专注'),
        ],
      ),
      HomeChip(id: 'podcast-chip', label: '播客与节目'),
    ];

    final shortcuts = [
      HomeItem(
        kind: HomeItemKind.likedSongs,
        uri: 'spotify:collection:tracks',
        title: '已点赞的歌曲',
        subtitle: '歌单',
        images: [_img('liked_songs')],
      ),
      ...filtered.take(5),
    ];

    final sections = [
      HomeSection(
        uri: 'spotify:section:mock_recents',
        kind: HomeSectionKind.recents,
        title: '最近播放',
        items: filtered,
        totalCount: filtered.length,
      ),
      HomeSection(
        uri: 'spotify:section:mock_shelf',
        kind: HomeSectionKind.shelf,
        title: '为你精心挑选',
        subtitle: 'Mock 推荐专题（可展开全部）',
        headerArtist: artists[0],
        items: filtered.take(4).toList(),
        totalCount: 10,
      ),
      HomeSection(
        uri: 'spotify:section:mock_feed',
        kind: HomeSectionKind.feed,
        title: '发现更多好歌',
        items: [
          for (var i = 0; i < filtered.length; i++)
            filtered[i].withReason(
              i.isEven ? '与 ${artists[0].name} 相似' : '今日推荐流',
              artists[i % artists.length],
            ),
        ],
        totalCount: filtered.length,
      ),
    ];

    return HomeFeed(
      greeting: facet.isEmpty ? '下午好 · Self-Test Mock' : '精选筛选 · $facet',
      chips: chips,
      shortcuts: shortcuts,
      sections: sections,
    );
  }

  HomeSection buildHomeSection(String uri) {
    final expanded = [
      ..._homeItems(),
      for (final pl in playlists)
        HomeItem(
          kind: HomeItemKind.playlist,
          uri: pl.uri,
          title: pl.name,
          subtitle: pl.description,
          images: pl.images,
          playlist: pl,
        ),
    ];
    return HomeSection(
      uri: uri,
      kind: HomeSectionKind.shelf,
      title: '为你精心挑选（全部条目）',
      subtitle: 'Mock 自测完整分区',
      items: expanded,
      totalCount: expanded.length,
    );
  }

  SpotifyLyrics lyricsFor(SpotifyTrack track) {
    final baseLines = [
      const LyricLine(
        startTimeMs: 0,
        words: '故事的小黄花 从出生那年就飘着',
        translation: 'Little yellow flowers from the day this story began',
      ),
      const LyricLine(
        startTimeMs: 4200,
        words: '童年的荡秋千 随记忆一直晃到现在',
        translation: 'Swings of childhood swaying through memory till today',
      ),
      const LyricLine(
        startTimeMs: 9000,
        words: 'Re So So Si Do Si La So La Si Si Si La Si La So',
        translation: 'Melodic hum echoing across the afternoon breeze',
      ),
      const LyricLine(
        startTimeMs: 15000,
        words: '吹着前奏望着天空 我想起花瓣试着掉落',
        translation: 'Watching the sky in the prelude, petals drifting down',
      ),
      const LyricLine(
        startTimeMs: 22000,
        words: '为你翘课的那一天 花落的那一天',
        translation: 'The day I skipped class for you, the day blossoms fell',
      ),
      const LyricLine(
        startTimeMs: 30000,
        words: '教室的那一间 我怎么看不见',
        translation: 'Inside that classroom, why could I no longer see you',
      ),
      const LyricLine(
        startTimeMs: 42000,
        words: '消失的下雨天 我好想再淋一遍',
        translation: 'Those vanished rainy days I wish to walk through once more',
      ),
      const LyricLine(
        startTimeMs: 60000,
        words: '刮风这天 我试过握着你手',
        translation: 'On that windy afternoon, I tried holding onto your hand',
      ),
      const LyricLine(
        startTimeMs: 90000,
        words: '但偏偏 雨渐渐 大到我看你不见',
        translation: 'Yet the rain poured harder until you faded out of sight',
      ),
      const LyricLine(
        startTimeMs: 130000,
        words: '还要多久 我才能在你身边',
        translation: 'How much longer before I can stand beside you again',
      ),
    ];
    return SpotifyLyrics(
      syncType: 'LINE_SYNCED',
      lines: baseLines,
      language: 'zh',
      provider: LyricsProvider.spotify,
      translationProvider: LyricsProvider.qqMusic,
      alternatives: [
        LyricsAlternative(
          language: 'en',
          lines: [for (final l in baseLines) l.translation],
        ),
      ],
    );
  }

  TrackCredits creditsFor(SpotifyTrack track) => TrackCredits(
    trackName: track.name,
    groups: [
      CreditGroup(
        name: '表演者',
        people: [
          for (final a in track.artists)
            CreditPerson(name: a.name, roles: const ['主唱', '演奏'], artistId: a.id),
        ],
      ),
      const CreditGroup(
        name: '制作兼工程',
        people: [
          CreditPerson(name: 'Mock Mastering Studio', roles: ['混音工程师', '母带制作']),
        ],
      ),
    ],
    sources: const ['Flutify Mock Records (Self-Test Catalog)'],
  );

  List<ConnectDevice> connectDevices() => const [
    ConnectDevice(
      id: 'mock_device_speaker',
      name: 'Living Room HomePod (Mock)',
      type: ConnectDeviceType.speaker,
      volume: 0.72,
      volumeSteps: 100,
      canPlay: true,
      isControllable: true,
      isSameNetwork: true,
    ),
    ConnectDevice(
      id: 'mock_device_desktop',
      name: 'Workstation Monitor (Mock)',
      type: ConnectDeviceType.computer,
      volume: 0.85,
      volumeSteps: 100,
      canPlay: true,
      isControllable: true,
      isSameNetwork: true,
    ),
  ];

  List<SpotifyDevice> webDevices() => const [
    SpotifyDevice(
      id: 'mock_device_speaker',
      name: 'Living Room HomePod (Mock)',
      type: 'Speaker',
      isActive: false,
      volumePercent: 72,
    ),
    SpotifyDevice(
      id: 'mock_device_desktop',
      name: 'Workstation Monitor (Mock)',
      type: 'Computer',
      isActive: true,
      volumePercent: 85,
    ),
  ];

  SpotifyTrack? findTrackByIdOrUri(String idOrUri) {
    final id = idOrUri.startsWith('spotify:track:')
        ? idOrUri.substring('spotify:track:'.length)
        : idOrUri;
    for (final t in coreTracks) {
      if (t.id == id || t.uri == idOrUri) return t;
    }
    for (final t in deluxeAlbumTracks) {
      if (t.id == id || t.uri == idOrUri) return t;
    }
    return null;
  }
}
