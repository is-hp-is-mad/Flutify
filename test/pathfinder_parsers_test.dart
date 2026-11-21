import 'package:flutify_app/models/connect_cluster.dart';
import 'package:flutify_app/services/pathfinder/pathfinder_parsers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pathfinder / spclient 解析器测试。
///
/// 夹具均为合成数据，只保留与桌面端 1.3.1.234 实测响应相同的字段结构。
void main() {
  Map<String, dynamic> trackJson(String id, {Map<String, dynamic>? albumOfTrack}) => {
        'uri': 'spotify:track:$id',
        'name': 'Song $id',
        'artists': {
          'items': [
            {'uri': 'spotify:artist:a1', 'profile': {'name': 'Artist One'}},
          ],
        },
        'duration': {'totalMilliseconds': 201000},
        'contentRating': {'label': 'EXPLICIT'},
        'playability': {'playable': true},
        'albumOfTrack': ?albumOfTrack,
      };

  final cover = {
    'sources': [
      {'url': 'https://i.scdn.co/image/small', 'width': 64, 'height': 64},
      {'url': 'https://i.scdn.co/image/large', 'width': 640, 'height': 640},
    ],
  };

  group('通用', () {
    test('idFromUri 取最后一段', () {
      expect(PathfinderParsers.idFromUri('spotify:album:abc'), 'abc');
      expect(PathfinderParsers.idFromUri(''), '');
    });

    test('images 按宽度降序并支持 maxWidth 与缺省宽高时的分辨率推断', () {
      final list = PathfinderParsers.images([
        {'url': 'a', 'maxWidth': 300},
        ...cover['sources']!,
        {'url': ''},
      ]);
      expect(list.map((i) => i.url), ['https://i.scdn.co/image/large', 'a', 'https://i.scdn.co/image/small']);

      final withoutWidths = PathfinderParsers.images([
        {'url': 'https://i.scdn.co/image/ab67616d00004851aaa'},
        {'url': 'https://i.scdn.co/image/ab67616d00001e02bbb'},
        {'url': 'https://i.scdn.co/image/ab67616d0000b273ccc'},
      ]);
      expect(
        withoutWidths.first.url,
        'https://i.scdn.co/image/ab67616d0000b273ccc',
      );

      final connectState = ConnectPlayerState.fromJson({
        'track': {
          'uri': 'spotify:track:t1',
          'metadata': {
            'title': 'Song',
            'image_url': 'spotify:image:ab67616d00001e02bbb',
            'image_large_url': 'spotify:image:ab67616d00001e02bbb',
            'image_xlarge_url': 'spotify:image:ab67616d0000b273ccc',
          },
        },
      });
      expect(
        connectState.imageUrl,
        'https://i.scdn.co/image/ab67616d0000b273ccc',
      );
    });

    test('stripHtml 与 hexColor', () {
      expect(PathfinderParsers.stripHtml('Hi <a href="x">there</a> &amp; you'), 'Hi there & you');
      expect(PathfinderParsers.hexColor('#dc148c'), const Color(0xFFDC148C));
      expect(PathfinderParsers.hexColor('zz'), isNull);
    });
  });

  test('getAlbum：专辑信息与曲目回填专辑', () {
    final page = PathfinderParsers.albumPage({
      'albumUnion': {
        'uri': 'spotify:album:al1',
        'name': 'Album',
        'type': 'SINGLE',
        'date': {'isoString': '2024-05-01T00:00:00Z'},
        'coverArt': cover,
        'artists': {
          'items': [
            {'id': 'a1', 'uri': 'spotify:artist:a1', 'profile': {'name': 'Artist One'}},
          ],
        },
        'tracksV2': {
          'totalCount': 2,
          'items': [
            {'track': trackJson('t1'), 'uid': 'u1'},
            {'track': {'uri': 'spotify:episode:x'}, 'uid': 'u2'},
          ],
        },
      },
    });

    expect(page, isNotNull);
    expect(page!.album.albumType, 'single');
    expect(page.album.releaseDate, '2024-05-01');
    expect(page.album.totalTracks, 2);
    expect(page.tracks, hasLength(1));
    expect(page.tracks.single.explicit, isTrue);
    expect(page.tracks.single.durationMs, 201000);
    expect(page.tracks.single.album?.images.first.url, 'https://i.scdn.co/image/large');
  });

  test('queryArtistOverview：艺人与热门曲目', () {
    final page = PathfinderParsers.artistPage({
      'artistUnion': {
        'id': 'a1',
        'uri': 'spotify:artist:a1',
        'profile': {'name': 'Artist One'},
        'visuals': {'avatarImage': cover},
        'stats': {'followers': 1234},
        'discography': {
          'topTracks': {
            'items': [
              {'track': trackJson('t1', albumOfTrack: {'uri': 'spotify:album:al1', 'coverArt': cover})},
            ],
          },
        },
      },
    });

    expect(page!.artist.name, 'Artist One');
    expect(page.artist.followers, 1234);
    expect(page.topTracks.single.album?.id, 'al1');
  });

  test('queryArtistOverview：头图、简介、月听众、最新发行、专辑 / 单曲、类似艺人', () {
    Map<String, dynamic> release(String id, String type) => {
      'releases': {
        'items': [
          {'id': id, 'uri': 'spotify:album:$id', 'name': id.toUpperCase(), 'type': type, 'date': {'year': 2024}, 'coverArt': cover},
        ],
      },
    };
    final overview = PathfinderParsers.artistOverview({
      'artistUnion': {
        'id': 'a1',
        'uri': 'spotify:artist:a1',
        'profile': {
          'name': 'Artist One',
          'biography': {'text': 'Born in <a href="spotify:x">Seoul</a> &amp; raised in LA.'},
        },
        'visuals': {
          'avatarImage': cover,
          'headerImage': {
            'sources': [
              {'url': 'https://i.scdn.co/header-small', 'width': 640, 'height': 200},
              {'url': 'https://i.scdn.co/header-large', 'width': 2660, 'height': 1140},
            ],
          },
        },
        'stats': {'followers': 1234, 'monthlyListeners': 15852288},
        'discography': {
          'latest': {'id': 'new', 'uri': 'spotify:album:new', 'name': 'New', 'type': 'SINGLE', 'date': {'isoString': '2026-10-31T00:00:00Z'}, 'coverArt': cover},
          'albums': {'items': [release('al1', 'ALBUM'), {'releases': {'items': []}}]},
          'singles': {'items': [release('sg1', 'SINGLE')]},
        },
        'relatedContent': {
          'relatedArtists': {
            'items': [
              {'id': 'r1', 'uri': 'spotify:artist:r1', 'profile': {'name': 'Related'}, 'visuals': {'avatarImage': cover}},
            ],
          },
        },
      },
    });

    expect(overview.headerImageUrl, 'https://i.scdn.co/header-large');
    expect(overview.biography, 'Born in Seoul & raised in LA.');
    expect(overview.monthlyListeners, 15852288);
    expect(overview.latestRelease?.releaseDate, '2026-10-31');
    expect(overview.latestRelease?.albumType, 'single');
    expect(overview.latestRelease?.artists.single.name, 'Artist One');
    expect(overview.albums.single.id, 'al1');
    expect(overview.singles.single.id, 'sg1');
    expect(overview.relatedArtists.single.name, 'Related');
  });

  test('queryArtistOverview：缺失的分区为空', () {
    final overview = PathfinderParsers.artistOverview({
      'artistUnion': {'uri': 'spotify:artist:a1', 'profile': {'name': 'A'}},
    });
    expect(overview.headerImageUrl, isEmpty);
    expect(overview.biography, isEmpty);
    expect(overview.monthlyListeners, isNull);
    expect(overview.latestRelease, isNull);
    expect(overview.albums, isEmpty);
    expect(overview.relatedArtists, isEmpty);
  });

  test('queryArtistDiscographyAll：取每个条目的首个版本，缺艺人时回填', () {
    final artist = PathfinderParsers.artist({'uri': 'spotify:artist:a1', 'profile': {'name': 'Artist One'}});
    final albums = PathfinderParsers.discography({
      'artistUnion': {
        'discography': {
          'all': {
            'items': [
              {
                'releases': {
                  'items': [
                    {
                      'id': 'al2',
                      'uri': 'spotify:album:al2',
                      'name': 'Second',
                      'type': 'ALBUM',
                      'date': {'year': 2020},
                      'coverArt': cover,
                      'tracks': {'totalCount': 9},
                    },
                  ],
                },
              },
              {'releases': {'items': []}},
            ],
          },
        },
      },
    }, artist: artist);

    expect(albums, hasLength(1));
    expect(albums.single.releaseDate, '2020');
    expect(albums.single.totalTracks, 9);
    expect(albums.single.artists.single.name, 'Artist One');
  });

  test('searchDesktop：解开 ResponseWrapper', () {
    final result = PathfinderParsers.search({
      'searchV2': {
        'tracksV2': {
          'items': [
            {'item': {'__typename': 'TrackResponseWrapper', 'data': trackJson('t1')}},
          ],
        },
        'artists': {
          'items': [
            {'__typename': 'ArtistResponseWrapper', 'data': {'uri': 'spotify:artist:a1', 'profile': {'name': 'A'}}},
          ],
        },
        'playlists': {
          'items': [
            {
              '__typename': 'PlaylistResponseWrapper',
              'data': {
                'uri': 'spotify:playlist:p1',
                'name': 'Mix',
                'description': '<b>Best</b>',
                'images': {'items': [cover]},
                'ownerV2': {'__typename': 'UserResponseWrapper', 'data': {'name': 'Someone'}},
              },
            },
          ],
        },
      },
    });

    expect(result.tracks.single.id, 't1');
    expect(result.artists.single.name, 'A');
    expect(result.playlists.single.description, 'Best');
    expect(result.playlists.single.ownerName, 'Someone');
  });

  test('browseAll：分类卡片', () {
    final categories = PathfinderParsers.categories({
      'browseStart': {
        'sections': {
          'items': [
            {
              'sectionItems': {
                'items': [
                  {
                    'uri': 'spotify:page:0JQ5DAqbMKFQ00XGBls6ym',
                    'content': {
                      '__typename': 'BrowseSectionContainerWrapper',
                      'data': {
                        '__typename': 'BrowseSectionContainer',
                        'data': {
                          'cardRepresentation': {
                            'artwork': cover,
                            'backgroundColor': {'hex': '#8D67AB'},
                            'title': {'transformedLabel': 'Pop'},
                          },
                        },
                      },
                    },
                  },
                ],
              },
            },
          ],
        },
      },
    });

    expect(categories.single.name, 'Pop');
    expect(categories.single.id, 'spotify:page:0JQ5DAqbMKFQ00XGBls6ym');
    expect(categories.single.color, const Color(0xFF8D67AB));
  });

  test('spclient playlist v2：元数据与曲目 URI', () {
    final parsed = PathfinderParsers.playlistV2('p1', {
      'attributes': {
        'name': 'Daily',
        'description': 'Fresh &amp; new',
        'pictureSize': [
          {'targetName': 'default', 'url': 'https://img/default'},
          {'targetName': 'large', 'url': 'https://img/large'},
        ],
      },
      'ownerUsername': 'spotify',
      'length': 120,
      'contents': {
        'items': [
          {
            'uri': 'spotify:track:t1',
            'attributes': {'timestamp': '1700000000000'},
          },
          {'uri': 'spotify:episode:e1'},
          // 自动生成歌单的条目没有加入时间
          {'uri': 'spotify:track:t2', 'attributes': <String, dynamic>{}},
        ],
      },
    });

    expect(parsed!.playlist.images.single.url, 'https://img/large');
    expect(parsed.playlist.ownerName, 'Spotify');
    expect(parsed.playlist.description, 'Fresh & new');
    expect(parsed.playlist.totalTracks, 120);
    expect(parsed.trackUris, ['spotify:track:t1', 'spotify:track:t2']);
    expect(parsed.addedAt, {'spotify:track:t1': DateTime.fromMillisecondsSinceEpoch(1700000000000)});
  });

  test('decorateContextTracks', () {
    final tracks = PathfinderParsers.decoratedTracks({
      'tracks': [trackJson('t1'), null, trackJson('t2')],
    });
    expect(tracks.map((t) => t.id), ['t1', 't2']);
  });
}
