import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/l10n/l10n.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/lyrics_query.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyrics_view.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyrics_translation_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';

/// 回归：歌词跟随切行的滚动只能发生在歌词区自己身上。
///
/// 曾经用静态的 Scrollable.ensureVisible 对中当前行，它会沿嵌套滚动容器一路向外滚——
/// 右栏「正在播放」列表会跟着歌词切行整体滑动。
void main() {
  const track = SpotifyTrack(
    id: 'synthetic-1',
    name: 'Synthetic One',
    durationMs: 60000,
  );

  testWidgets(
    'shared translation toolbar follows cached track changes without build notifications',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      final playback = PlaybackProvider(FakeAudioPlayerService(), storage.playback,
        audioLoader: FakeTrackAudioSource(),
      );
      final spotify = SpotifyProvider(
        FakeSpotifyApiService(storage.auth,
          lyricsById: {
            for (final id in ['one', 'two'])
              id: SpotifyLyrics(
                language: 'ja',
                lines: [LyricLine(startTimeMs: 0, words: '歌詞 $id')],
                alternatives: [
                  LyricsAlternative(language: 'zh-Hans', lines: ['译词 $id']),
                ],
              ),
          },
        ),
        storage.library,
      );
      const first = SpotifyTrack(
        id: 'one',
        uri: 'spotify:track:one',
        name: 'One',
      );
      const second = SpotifyTrack(
        id: 'two',
        uri: 'spotify:track:two',
        name: 'Two',
      );
      await spotify.fetchLyrics(LyricsQuery.fromTrack(first));
      await spotify.fetchLyrics(LyricsQuery.fromTrack(second));
      final selected = ValueNotifier(first);
      addTearDown(selected.dispose);
      addTearDown(playback.dispose);
      addTearDown(spotify.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: playback),
            ChangeNotifierProvider.value(value: spotify),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(
              body: LyricsTranslationScope(
                child: Column(
                  children: [
                    const LyricsTranslationButton(),
                    Expanded(
                      child: ValueListenableBuilder<SpotifyTrack>(
                        valueListenable: selected,
                        builder: (_, value, _) => LyricsView(track: value),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('译词 one'), findsOneWidget);
      selected.value = second;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('译词 one'), findsNothing);
      expect(find.text('译词 two'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('歌词切行：内层歌词滚动，外层列表纹丝不动', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ArtworkPalette.enabled = false;

    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    final lyrics = SpotifyLyrics(
      lines: [
        for (var i = 0; i < 40; i++)
          LyricLine(startTimeMs: i * 1000, words: 'Line $i'),
      ],
    );
    final playback = PlaybackProvider(FakeAudioPlayerService(), storage.playback,
      audioLoader: FakeTrackAudioSource(),
    );
    addTearDown(playback.dispose);
    final outer = ScrollController();
    addTearDown(outer.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: playback),
          ChangeNotifierProvider(
            create: (_) => SpotifyProvider(FakeSpotifyApiService(storage.auth,
                lyricsById: {'synthetic-1': lyrics},
              ), storage.library,
            ),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            // 外层列表模拟右栏「正在播放」详情列表：歌词卡只是它的一个子项
            body: ListView(
              controller: outer,
              children: [
                const SizedBox(height: 120),
                const SizedBox(height: 300, child: LyricsView(track: track)),
                const SizedBox(height: 2000),
              ],
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Line 0'), findsOneWidget);

    final inner = tester
        .widget<SingleChildScrollView>(
          find.descendant(
            of: find.byType(LyricsView),
            matching: find.byType(SingleChildScrollView),
          ),
        )
        .controller!;
    expect(outer.offset, 0);

    // 进度推到靠后的行（切行提前量 300ms，25s → 第 25 行附近）
    playback.positionNotifier.value = const Duration(seconds: 25);
    await tester.pump();
    // 滚动动画的 Ticker 在下一帧才开始计时
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 700));

    expect(inner.offset, greaterThan(0), reason: '歌词区应滚到当前行');
    expect(outer.offset, 0, reason: '外层列表不能被歌词切行带着滚');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 11));
  });
}
