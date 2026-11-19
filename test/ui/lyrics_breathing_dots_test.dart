import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/l10n/l10n.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/player/lyrics/breathing_dots.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyrics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';

/// 无人声片段的呼吸点：只在前奏 / 间奏进行中出现，唱到下一句即消失，歌曲末尾的无人声不显示。
void main() {
  const track = SpotifyTrack(
    id: 'synthetic-dots',
    name: 'Synthetic Dots',
    durationMs: 90000,
  );

  testWidgets('呼吸点只在前奏与间奏中出现', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ArtworkPalette.enabled = false;

    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    const lyrics = SpotifyLyrics(
      lines: [
        LyricLine(startTimeMs: 8000, words: 'First words'),
        LyricLine(startTimeMs: 12000, words: 'Second words'),
        LyricLine(startTimeMs: 16000, words: '♪'),
        LyricLine(startTimeMs: 30000, words: 'After the break'),
        LyricLine(startTimeMs: 34000, words: 'Last words'),
        LyricLine(startTimeMs: 38000, words: ''),
      ],
    );
    final playback = PlaybackProvider(FakeAudioPlayerService(), storage.playback,
      audioLoader: FakeTrackAudioSource(),
    );
    addTearDown(playback.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: playback),
          ChangeNotifierProvider(
            create: (_) => SpotifyProvider(FakeSpotifyApiService(storage.auth,
                lyricsById: {'synthetic-dots': lyrics},
              ), storage.library,
            ),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(body: LyricsView(track: track)),
        ),
      ),
    );
    Future<void> seek(int ms) async {
      playback.positionNotifier.value = Duration(milliseconds: ms);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
    }

    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 前奏：第一句 8s 才开唱
    expect(find.byType(BreathingDots), findsOneWidget);
    expect(find.text('•  •  •'), findsNothing, reason: '同步歌词的空行不再显示圆点文字');

    await seek(9000);
    expect(find.byType(BreathingDots), findsNothing, reason: '开唱后呼吸点收起');

    await seek(20000);
    expect(find.byType(BreathingDots), findsOneWidget, reason: '间奏中显示呼吸点');

    await seek(31000);
    expect(find.byType(BreathingDots), findsNothing);

    await seek(60000);
    expect(find.byType(BreathingDots), findsNothing, reason: '歌曲末尾的无人声不显示');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 11));
  });
}
