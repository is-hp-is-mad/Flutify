import 'dart:convert';

import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/l10n/app_locale.dart';
import 'package:flutify_app/models/album.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/detail/album_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';

/// 专辑页定位曲目：从发现流进入时只带专辑 id / 名称，按 id（或歌名）找到目标行、滚过去并高亮，
/// 同时补全专辑信息。
void main() {
  setUp(() => ArtworkPalette.enabled = false);
  tearDown(() => ArtworkPalette.enabled = true);

  Map<String, dynamic> trackJson(int i) => {
    'id': 'tr${i.toString().padLeft(2, '0')}',
    'name': 'Track $i',
    'duration_ms': 180000,
    'artists': [
      {'id': 'art', 'name': 'Album Artist'},
    ],
  };

  Future<void> pump(WidgetTester tester, SpotifyTrack focus) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 800);
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'sp_access_token': 'token'});
    final storage = await StorageService.init();
    final api = SpotifyApiService(
      storage,
      MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/albums/alb/tracks')) {
          return http.Response(
            jsonEncode({
              'items': [for (var i = 1; i <= 30; i++) trackJson(i)],
            }),
            200,
          );
        }
        if (path.endsWith('/albums/alb')) {
          return http.Response(
            jsonEncode({
              'id': 'alb',
              'name': 'Full Album',
              'album_type': 'album',
              'release_date': '2015-03-31',
              'images': [
                {'url': 'https://i.scdn.co/full'},
              ],
              'artists': [
                {'id': 'art', 'name': 'Album Artist'},
              ],
            }),
            200,
          );
        }
        return http.Response('{"items":[]}', 200);
      }),
    );
    final audio = FakeAudioPlayerService();
    final playback = PlaybackProvider(audio, storage);
    final library = LibraryProvider(storage);
    addTearDown(() {
      playback.dispose();
      library.dispose();
      audio.dispose();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<SpotifyApiService>.value(value: api),
          ChangeNotifierProvider.value(value: playback),
          ChangeNotifierProvider.value(value: library),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocale.supportedLocales,
          localizationsDelegates: AppLocale.delegates,
          home: AlbumDetailScreen(
            album: const SpotifyAlbum(id: 'alb', name: 'Partial'),
            focusTrack: focus,
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 目标行完整落在视口内且不在最顶上（已从顶部滚下来）。
  void expectFocused(WidgetTester tester, String name) {
    final row = find.text(name);
    expect(row, findsOneWidget);
    final rect = tester.getRect(row);
    expect(rect.top, greaterThan(0));
    expect(rect.bottom, lessThan(800));
    final highlight = find.ancestor(
      of: row,
      matching: find.byType(AnimatedContainer),
    );
    expect(highlight, findsOneWidget, reason: '定位行有高亮底');
  }

  testWidgets('按 id 定位到靠后的曲目并高亮，专辑信息被补全', (tester) async {
    await pump(tester, const SpotifyTrack(id: 'tr25', name: 'Track 25'));
    expectFocused(tester, 'Track 25');
    expect(find.text('Full Album'), findsWidgets);

    // 约 2 秒后高亮淡出（行仍在，只是颜色透明）。
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Track 25'), findsOneWidget);
  });

  testWidgets('id 对不上时按歌名定位', (tester) async {
    await pump(tester, const SpotifyTrack(id: 'relinked', name: 'track 20'));
    expectFocused(tester, 'Track 20');
    await tester.pump(const Duration(seconds: 3));
  });
}
