import 'package:flutify_app/ui/screens/player/lyrics/apple_music_motion.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyric_line_view.dart';
import 'package:flutify_app/ui/screens/player/lyrics/breathing_dots.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Apple dots mirror in RTL and freeze their exact frame on pause',
    (tester) async {
      final position = ValueNotifier(const Duration(seconds: 3));
      addTearDown(position.dispose);
      Widget host(bool playing) => MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: BreathingDots(
            position: position,
            isPlaying: playing,
            startMs: 0,
            endMs: 12000,
            dotSize: 10,
            appleMusicStyle: true,
          ),
        ),
      );
      await tester.pumpWidget(host(true));
      await tester.pump(const Duration(milliseconds: 240));
      final dots = find.descendant(
        of: find.byType(BreathingDots),
        matching: find.byType(Container),
      );
      expect(
        tester.getCenter(dots.at(0)).dx,
        greaterThan(tester.getCenter(dots.at(2)).dx),
      );
      List<Color?> colors() => tester
          .widgetList<Container>(dots)
          .map((w) => (w.decoration as BoxDecoration).color)
          .toList();
      final before = colors();
      await tester.pumpWidget(host(false));
      await tester.pump(const Duration(seconds: 2));
      expect(colors(), before);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test('Apple cascade delays saturate at four rows below the anchor', () {
    expect(
      [for (var i = -1; i <= 5; i++) AppleMusicMotion.delayMs(i)],
      [0, 0, 25, 44, 56, 63, 63],
    );
    expect(AppleMusicMotion.remainingMove(100, 0), 1);
    expect(AppleMusicMotion.remainingMove(100, 813), 0);
    expect(
      AppleMusicMotion.remainingMove(1, 100),
      greaterThan(AppleMusicMotion.remainingMove(0, 100)),
    );
  });

  test(
    'interlude fill derives from the entire gap and exits before singing',
    () {
      final early = AppleMusicMotion.dots(0, 10000);
      expect(early.opacity, [0, 0, 0]);
      final middle = AppleMusicMotion.dots(5000, 10000);
      expect(middle.opacity[0], closeTo(.94, .001));
      expect(middle.opacity[1], greaterThan(.18));
      expect(middle.opacity[2], closeTo(.18, .001));
      expect(AppleMusicMotion.dots(9700, 10000).fade, 0);
      expect(AppleMusicMotion.dots(9700, 10000).scale, closeTo(.5, .001));
      expect(AppleMusicMotion.dots(5000, 20000).opacity[1], .18);
    },
  );

  testWidgets('line sync has no distance blur and uses delayed focus', (
    tester,
  ) async {
    Widget host(int distance) => MaterialApp(
      home: LyricLineView(
        text: 'Apple line sync',
        distance: distance,
        appleMusicStyle: true,
      ),
    );
    await tester.pumpWidget(host(1));
    Text text() => tester.widget<Text>(find.text('Apple line sync'));
    expect(text().style!.color!.a, closeTo(.18, .001));
    expect(find.byType(ImageFiltered), findsNothing);
    await tester.pumpWidget(host(0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(text().style!.color!.a, closeTo(.18, .001));
    await tester.pump(const Duration(milliseconds: 350));
    expect(text().style!.color!.a, closeTo(.94, .001));
  });
}
