import 'dart:convert';

import 'package:flutify_app/services/apple_music/apple_music_artist_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _jwt(Map<String, Object> payload) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'ES256', 'typ': 'JWT', 'kid': 'WEBPLAYKID'})}.'
      '${part(payload)}.'
      'c2lnbmF0dXJlLXNpZ25hdHVyZS1zaWduYXR1cmU';
}

Map<String, Object?> _artist(
  String id,
  String name, {
  bool video = false,
  String bgColor = '6b6968',
  String? videoBgColor,
}) => {
  'id': id,
  'type': 'artists',
  'attributes': {
    'name': name,
    'artwork': {
      'url': 'https://is1-ssl.mzstatic.com/image/thumb/$id/{w}x{h}{c}.{f}',
      'bgColor': bgColor,
    },
    if (video)
      'editorialVideo': {
        'motionArtistSquare1x1': {
          'video': 'https://mvod.itunes.apple.com/a/$id/square.m3u8',
          if (videoBgColor != null)
            'previewFrame': {'bgColor': videoBgColor},
        },
        'motionArtistWide16x9': {
          'video': 'https://mvod.itunes.apple.com/a/$id/wide.m3u8',
        },
      },
  },
};

const _master = '''#EXTM3U
#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=182866,CODECS="avc1.64001f",RESOLUTION=486x486,URI="iframes.m3u8"
#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2167535,BANDWIDTH=2703492,VIDEO-RANGE=SDR,CODECS="avc1.64001f",RESOLUTION=768x768
https://mvod.itunes.apple.com/v/gr240_768.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2183440,VIDEO-RANGE=SDR,CODECS="hvc1.2.20000000.L123.B0",RESOLUTION=768x768
https://mvod.itunes.apple.com/v/hevc_768.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=325633,VIDEO-RANGE=SDR,CODECS="avc1.64001f",RESOLUTION=360x360
https://mvod.itunes.apple.com/v/gr203_360.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=6694579,VIDEO-RANGE=SDR,CODECS="avc1.640020",RESOLUTION=1080x1080
https://mvod.itunes.apple.com/v/gr290_1080.m3u8
''';

const _media = '''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-MAP:URI="clip-.mp4",BYTERANGE="897@0"
#EXTINF:3.58,
#EXT-X-BYTERANGE:1037078@897
clip-.mp4
#EXTINF:3.58,
#EXT-X-BYTERANGE:1212150@1037975
clip-.mp4
''';

void main() {
  group('helpers', () {
    test('extractToken picks the AMPWebPlay JWT and reads its expiry', () {
      final other = _jwt({'iss': 'someone-else', 'exp': 1});
      final token = _jwt({'iss': 'AMPWebPlay', 'iat': 1793900708, 'exp': 1799948708});
      final script = 'const a="$other";const devToken="$token";';
      expect(AppleMusicArtistService.extractToken(script), token);
      expect(
        AppleMusicArtistService.tokenExpiry(token),
        DateTime.fromMillisecondsSinceEpoch(1799948708 * 1000),
      );
      expect(AppleMusicArtistService.extractToken('no token here'), isNull);
    });

    test('names match across case, punctuation and Chinese script', () {
      String n(String s) => AppleMusicArtistService.normalize(s);
      expect(n('周杰倫'), n('周杰伦'));
      expect(n('G.E.M.'), n('gem'));
      expect(n('Tyler, The Creator'), n('tyler the creator'));
      expect(n('YOASOBI'), isNot(n('Ayase')));
    });

    test('matchArtist only accepts exact names and prefers one with video', () {
      final artists = [
        _artist('1', 'Coldplay Mindfulness', video: true),
        _artist('2', 'Coldplay'),
        _artist('3', 'COLDPLAY', video: true),
      ].cast<Map<String, dynamic>>();
      expect(AppleMusicArtistService.matchArtist('Coldplay', artists)?['id'], '3');
      expect(AppleMusicArtistService.matchArtist('Cold', artists), isNull);
    });

    test('pickVideo follows Apple Music flavor choice with a singular fallback', () {
      final videos = {
        'motionArtistSquare1x1': {'video': 'https://x/square.m3u8'},
        'motionArtistWide16x9': {'video': 'https://x/wide.m3u8'},
      };
      expect(AppleMusicArtistService.pickVideo(videos, wide: false), ('https://x/square.m3u8', 1.0));
      expect(AppleMusicArtistService.pickVideo(videos, wide: true), ('https://x/wide.m3u8', 16 / 9));
      final singular = {
        'motionArtistSingular16x9': {'video': 'https://x/s.m3u8'},
      };
      expect(AppleMusicArtistService.pickVideo(singular, wide: false), ('https://x/s.m3u8', 16 / 9));
      expect(AppleMusicArtistService.pickVideo(null, wide: false).$1, isNull);
      expect(
        AppleMusicArtistService.pickVideo({
          'motionArtistSquare1x1': {'video': 'http://insecure'},
        }, wide: false).$1,
        isNull,
      );
    });

    test('pickVariant takes the best H.264 rendition within the target size', () {
      expect(
        AppleMusicArtistService.pickVariant(_master, wide: false),
        'https://mvod.itunes.apple.com/v/gr240_768.m3u8',
      );
      // Nothing fits under 576 lines except the 360 rendition.
      expect(
        AppleMusicArtistService.pickVariant(_master, wide: true),
        'https://mvod.itunes.apple.com/v/gr203_360.m3u8',
      );
    });

    test('mediaFile accepts a single fMP4 and rejects encrypted playlists', () {
      expect(AppleMusicArtistService.mediaFile(_media), 'clip-.mp4');
      expect(
        AppleMusicArtistService.mediaFile('#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x"\n$_media'),
        isNull,
      );
      expect(AppleMusicArtistService.mediaFile('a.ts\nb.ts\n'), isNull);
    });

    test('storefront and display language follow the interface language', () {
      expect(AppleMusicArtistService.storefrontFor('zh-CN'), ('cn', 'zh-Hans-CN'));
      expect(AppleMusicArtistService.storefrontFor('zh-TW'), ('tw', 'zh-Hant-TW'));
      expect(AppleMusicArtistService.storefrontFor('ja'), ('jp', 'ja'));
      expect(AppleMusicArtistService.storefrontFor('en'), ('us', 'en-US'));
    });

    test('pickBgColor prefers active editorialVideo previewFrame over artwork', () {
      expect(
        AppleMusicArtistService.pickBgColor(
          artwork: const {'bgColor': '6b6968'},
          videos: const {
            'motionArtistSquare1x1': {
              'video': 'https://x/square.m3u8',
              'previewFrame': {'bgColor': '#1f0f2b'},
            },
          },
          wide: false,
        ),
        '1f0f2b',
      );
      expect(
        AppleMusicArtistService.pickBgColor(
          artwork: const {'bgColor': '6b6968'},
          videos: null,
          wide: false,
        ),
        '6b6968',
      );
    });
  });

  group('find / video', () {
    late List<http.Request> requests;
    late Map<String, List<Map<String, Object?>>> catalog;
    late int tokenFetches;

    AppleMusicArtistService service() {
      requests = [];
      tokenFetches = 0;
      final token = _jwt({
        'iss': 'AMPWebPlay',
        'exp': DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000,
      });
      final client = MockClient((request) async {
        requests.add(request);
        final url = request.url;
        if (url.host == 'music.apple.com' && url.path == '/us/browse') {
          tokenFetches++;
          return http.Response('<script src="/assets/index~abc.js"></script>', 200);
        }
        if (url.host == 'music.apple.com' && url.path == '/assets/index~abc.js') {
          return http.Response('x="$token"', 200);
        }
        if (url.host == 'amp-api.music.apple.com') {
          expect(request.headers['Authorization'], 'Bearer $token');
          expect(request.headers['Origin'], 'https://music.apple.com');
          final storefront = url.pathSegments[2];
          final key = '$storefront|${url.queryParameters['l']}|${url.queryParameters['term']}';
          return http.Response(
            jsonEncode({
              'results': {
                'artists': {'data': catalog[key] ?? []},
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (url.path.endsWith('square.m3u8') || url.path.endsWith('wide.m3u8')) {
          return http.Response(_master, 200);
        }
        if (url.path.endsWith('gr240_768.m3u8') || url.path.endsWith('gr203_360.m3u8')) {
          return http.Response(_media, 200);
        }
        if (url.path.endsWith('clip-.mp4')) {
          return http.Response.bytes([0, 0, 0, 0x1c, 0x66, 0x74, 0x79, 0x70], 200);
        }
        return http.Response('not found', 404);
      });
      return AppleMusicArtistService(client);
    }

    test('finds the localized artist, then downloads the square video', () async {
      final s = service();
      catalog = {
        'cn|zh-Hans-CN|周杰伦': [_artist('300117743', '周杰伦', video: true)],
      };
      final media = await s.find('周杰伦', language: 'zh-CN', wide: false);
      expect(media, isNotNull);
      expect(
        media!.artworkUrl(1200, 1200),
        'https://is1-ssl.mzstatic.com/image/thumb/300117743/1200x1200cc.jpg',
      );
      expect(media.videoUrl, endsWith('square.m3u8'));
      final video = await s.video(media);
      expect(video, isNotNull);
      expect(requests.last.url.toString(), 'https://mvod.itunes.apple.com/v/clip-.mp4');

      // Cached: neither the lookup nor the token are fetched again.
      final before = requests.length;
      await s.find('周杰伦', language: 'zh-CN', wide: false);
      await s.video(media);
      expect(requests.length, before);
      expect(tokenFetches, 1);
    });

    test('falls back to the US English catalog when the local name differs', () async {
      final s = service();
      catalog = {
        'jp|ja|Jay Chou': [_artist('9', 'ジェイ・チョウ')],
        'us|en-US|Jay Chou': [_artist('300117743', 'Jay Chou')],
      };
      final media = await s.find('Jay Chou', language: 'ja', wide: true);
      expect(media?.artworkTemplate, contains('300117743'));
      expect(media?.videoUrl, isNull);
      expect(await s.video(media!), isNull);
    });

    test('returns null instead of guessing when no artist name matches', () async {
      final s = service();
      catalog = {
        'us|en-US|Nobody': [_artist('1', 'Nobody Tribute')],
      };
      expect(await s.find('Nobody', language: 'en', wide: false), isNull);
    });

    test('disabled service makes no requests', () async {
      final client = MockClient((_) async => fail('no request expected'));
      final s = AppleMusicArtistService(client, enabled: false);
      expect(await s.find('Billie Eilish', language: 'en', wide: false), isNull);
    });
  });
}
