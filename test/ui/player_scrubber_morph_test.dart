import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/widgets/playback_scrubber.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_track_audio_source.dart';

void main() {
  Future<({ValueNotifier<double> progress, FakeAudioPlayerService audio})> pump(
    WidgetTester tester,
    double scale,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final audio = FakeAudioPlayerService();
    final playback = PlaybackProvider(
      audio,
      await StorageService.init(),
      audioLoader: FakeTrackAudioSource(),
    );
    await playback.playTrack(
      const SpotifyTrack(id: 'morph', name: 'Morph', durationMs: 180000),
    );
    audio.durationController.add(const Duration(minutes: 3));
    audio.positionController.add(const Duration(seconds: 30));
    final progress = ValueNotifier(0.0);
    addTearDown(progress.dispose);
    addTearDown(playback.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: playback,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 288,
                  child: ValueListenableBuilder<double>(
                    valueListenable: progress,
                    builder: (context, value, _) =>
                        PlaybackScrubber(compactProgress: value),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return (progress: progress, audio: audio);
  }

  for (final scale in [1.0, 1.8, 2.6]) {
    testWidgets('one slider and continuous time labels at text scale $scale', (
      tester,
    ) async {
      final fixture = await pump(tester, scale);
      final slider = find.byType(Slider);
      final elapsed = find.text('0:30');
      final element = tester.element(slider);
      final labelElement = tester.element(elapsed);
      final start = tester.getRect(slider);
      final labelStart = tester.getRect(elapsed);
      fixture.progress.value = 1;
      await tester.pump();
      final end = tester.getRect(slider);
      final labelEnd = tester.getRect(elapsed);
      expect(labelStart.top, greaterThanOrEqualTo(start.bottom));
      expect(labelEnd.center.dy, closeTo(end.center.dy, 0.1));
      expect(labelEnd.right, lessThanOrEqualTo(end.left));
      for (final value in [0.0, 0.15, 0.4, 0.8, 0.35, 0.0, 0.6, 1.0]) {
        fixture.progress.value = value;
        await tester.pump();
        expect(tester.element(slider), same(element));
        expect(tester.element(elapsed), same(labelElement));
        expect(
          tester.getRect(slider),
          rectMoreOrLessEquals(Rect.lerp(start, end, value)!),
        );
        expect(
          tester.getRect(elapsed),
          rectMoreOrLessEquals(Rect.lerp(labelStart, labelEnd, value)!),
        );
        expect(tester.takeException(), isNull);
      }
      expect(fixture.audio.seeks, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('a held seek survives reflow and commits only on release', (
    tester,
  ) async {
    final fixture = await pump(tester, 1);
    final slider = find.byType(Slider);
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(12, 0));
    await tester.pump();
    final value = tester.widget<Slider>(slider).value;
    fixture.progress.value = 0.6;
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, value);
    expect(fixture.audio.seeks, isEmpty);
    fixture.progress.value = 0.2;
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(fixture.audio.seeks, hasLength(1));
    expect(fixture.audio.seeks.single.inMilliseconds, value.round());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
