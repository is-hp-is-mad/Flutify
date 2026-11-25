import 'package:flutify_app/ui/widgets/track_swipe_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> fired;

  Widget harness() => MaterialApp(
    home: Scaffold(
      body: TrackSwipeActions(
        leading: TrackSwipeAction(
          icon: Icons.playlist_play_rounded,
          iconColor: Colors.white,
          circleColor: Colors.purple,
          semanticLabel: 'next',
          onTriggered: () => fired.add('next'),
        ),
        trailing: TrackSwipeAction(
          icon: Icons.add_rounded,
          iconColor: Colors.red,
          circleColor: Colors.grey,
          semanticLabel: 'library',
          onTriggered: () => fired.add('library'),
        ),
        child: ListTile(
          title: const Text('Song'),
          onTap: () => fired.add('tap'),
        ),
      ),
    ),
  );

  setUp(() => fired = []);

  testWidgets('long swipe right triggers play next', (tester) async {
    await tester.pumpWidget(harness());
    await tester.drag(find.text('Song'), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(fired, ['next']);
  });

  testWidgets('long swipe left triggers library', (tester) async {
    await tester.pumpWidget(harness());
    await tester.drag(find.text('Song'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(fired, ['library']);
  });

  testWidgets('short swipe reveals the button; tapping it triggers', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.timedDrag(
      find.text('Song'),
      const Offset(-70, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(fired, isEmpty);
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);

    // 展开时点行只收起，不播放
    await tester.tap(find.text('Song'));
    await tester.pumpAndSettle();
    expect(fired, isEmpty);
    expect(find.byIcon(Icons.add_rounded), findsNothing);

    await tester.timedDrag(
      find.text('Song'),
      const Offset(-70, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    expect(fired, ['library']);
  });

  testWidgets('swiping another row closes the one already open', (
    tester,
  ) async {
    TrackSwipeAction action(String id) => TrackSwipeAction(
      icon: Icons.add_rounded,
      iconColor: Colors.red,
      circleColor: Colors.grey,
      semanticLabel: id,
      onTriggered: () => fired.add(id),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final id in ['A', 'B'])
                TrackSwipeActions(
                  trailing: action(id),
                  child: ListTile(title: Text(id)),
                ),
            ],
          ),
        ),
      ),
    );
    Future<void> reveal(String id) async {
      await tester.timedDrag(
        find.text(id),
        const Offset(-70, 0),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();
    }

    double dx(String id) => tester.getTopLeft(find.text(id)).dx;
    final rest = dx('A');

    await reveal('A');
    expect(dx('A'), lessThan(rest));
    await reveal('B');
    expect(dx('B'), lessThan(rest));
    expect(dx('A'), rest, reason: '只保留一行滑开');
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    expect(fired, isEmpty);
  });

  testWidgets('plain tap reaches the row', (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.text('Song'));
    expect(fired, ['tap']);
  });
}
