import 'package:flutify_app/ui/screens/player/player_lyrics_layout.dart';
import 'package:flutify_app/ui/screens/player/player_lyrics_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [
    const Size(320, 480),
    const Size(390, 800),
    const Size(430, 932),
    const Size(844, 390),
  ]) {
    for (final titleHeight in [56.0, 80.0]) {
      testWidgets(
        'cover moves and scales on one straight path at $size, title $titleHeight',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final progress = ValueNotifier(0.0);
          addTearDown(progress.dispose);
          final geometry = PlayerLyricsGeometry();
          await tester.pumpWidget(
            MaterialApp(
              home: ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (context, value, _) => CustomMultiChildLayout(
                  delegate: PlayerLyricsLayout(
                    progress: value,
                    chrome: 1,
                    geometry: geometry,
                    controlsHeightReduction: 24,
                    footerHeightReduction: 12,
                  ),
                  children: [
                    for (final slot in PlayerSceneSlot.values)
                      LayoutId(
                        id: slot,
                        child: SizedBox(
                          key: ValueKey(slot),
                          width: 48,
                          height: switch (slot) {
                            PlayerSceneSlot.top => 56,
                            PlayerSceneSlot.title => titleHeight,
                            PlayerSceneSlot.controls => 124 - 24 * value,
                            PlayerSceneSlot.footer => 60 - 12 * value,
                            _ => 48,
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
          final cover = find.byKey(const ValueKey(PlayerSceneSlot.artwork));
          final title = find.byKey(const ValueKey(PlayerSceneSlot.title));
          final start = tester.getRect(cover);
          final startTitle = tester.getRect(title);
          progress.value = 1;
          await tester.pump();
          final end = tester.getRect(cover);
          final endTitle = tester.getRect(title);
          // Sample both directions and interrupted flights. The controller already
          // applies Apple easing; geometry must not ease size a second time.
          for (final time in [
            for (var frame = 0; frame <= 80; frame++) frame / 80,
            for (var frame = 40; frame >= 0; frame--) frame / 40,
            0.6,
            0.3,
            0.7,
            0.0,
          ]) {
            final value = PlayerLyricsMotion.curve.transform(time);
            progress.value = value;
            await tester.pump();
            expect(
              tester.getRect(title),
              rectMoreOrLessEquals(Rect.lerp(startTitle, endTitle, value)!),
              reason: 'metadata must not wait, overshoot, and then slide back',
            );
            expect(
              tester.getRect(cover),
              rectMoreOrLessEquals(
                Rect.lerp(start, end, value)!,
                epsilon: 0.001,
              ),
              reason: 'position and scale must share progress $value',
            );
            // The foreground cover can cross the metadata during the handoff.
            // Do not route text around it: that caused the unwanted reversal.
            if (size.height >= 600 && value <= 0.3) {
              expect(
                tester.getRect(title).width,
                greaterThanOrEqualTo(size.width * 0.4),
                reason:
                    'do not squeeze the title before the cover approaches it',
              );
            }
            expect(tester.takeException(), isNull);
          }
        },
      );
    }
  }
}
