import 'package:flutify_app/core/debug_toggles.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(DebugToggles.instance.reset);

  test('临时关闭只记在内存里，reset 后全部恢复', () {
    final toggles = DebugToggles.instance;
    var notified = 0;
    void listener() => notified++;
    toggles.addListener(listener);
    addTearDown(() => toggles.removeListener(listener));

    expect(toggles.anyOff, isFalse);
    toggles.setOff(DebugToggle.lyricsScroll, true);
    expect(toggles.isOff(DebugToggle.lyricsScroll), isTrue);
    expect(toggles.isOff(DebugToggle.glassBackdrop), isFalse);
    expect(toggles.anyOff, isTrue);
    expect(notified, 1);

    // 重复设置同一状态不通知
    toggles.setOff(DebugToggle.lyricsScroll, true);
    expect(notified, 1);

    toggles.reset();
    expect(toggles.anyOff, isFalse);
    expect(toggles.isOff(DebugToggle.lyricsScroll), isFalse);
    expect(notified, 2);

    // 已经全部恢复时 reset 不通知
    toggles.reset();
    expect(notified, 2);
  });

  test('默认构建没有任何开关被构建时强制关闭', () {
    for (final toggle in DebugToggle.values) {
      expect(toggle.compileTimeOff, isFalse, reason: '$toggle');
    }
  });

  testWidgets('依赖开关的 build 会随变化重建', (tester) async {
    var builds = 0;
    await tester.pumpWidget(
      DebugTogglesScope(
        toggles: DebugToggles.instance,
        child: Builder(
          builder: (context) {
            builds++;
            DebugToggles.of(context).isOff(DebugToggle.lyricsMask);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(builds, 1);
    DebugToggles.instance.setOff(DebugToggle.lyricsMask, true);
    await tester.pump();
    expect(builds, 2);
  });

  testWidgets('DebugTogglesBinding 把「关闭所有过渡动画」交给 builder', (tester) async {
    bool? seen;
    await tester.pumpWidget(
      DebugTogglesBinding(
        builder: (context, motionOff) {
          seen = motionOff;
          return const SizedBox();
        },
      ),
    );
    expect(seen, isFalse);
    DebugToggles.instance.setOff(DebugToggle.allMotion, true);
    await tester.pump();
    expect(seen, isTrue);
  });
}
