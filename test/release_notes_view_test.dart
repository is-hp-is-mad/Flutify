import 'package:flutify_app/ui/widgets/release_notes_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const notes =
      'Windows x64 提供安装版；\r\n构建通过不代表已实机验证。\r\n\r\n\r\n'
      '## 主要更新\r\n'
      '- **自动播放相似歌曲**（#41）：设置 → 播放。\r\n'
      '  续行说明\r\n'
      '  - 子项\r\n'
      '\r\n'
      '> v0.16 已撤回。\r\n'
      '\r\n'
      '## ⚠️ 未实机测试，需测试\r\n'
      '* v0.16 by @x in https://github.com/is-hp-is-mad/Flutify/pull/38\r\n'
      '\r\n'
      '**Full Changelog**: https://github.com/is-hp-is-mad/Flutify/compare/v0.15...v0.16.1';

  test('拆分块：段落、标题、列表（含续行与缩进）、引用', () {
    const h = ReleaseNotesBlockKind.heading;
    const b = ReleaseNotesBlockKind.bullet;
    expect(parseReleaseNotes(notes), [
      const ReleaseNotesBlock(
        ReleaseNotesBlockKind.paragraph,
        'Windows x64 提供安装版；\n构建通过不代表已实机验证。',
      ),
      const ReleaseNotesBlock(h, '主要更新', level: 2),
      const ReleaseNotesBlock(b, '**自动播放相似歌曲**（#41）：设置 → 播放。\n续行说明'),
      const ReleaseNotesBlock(b, '子项', level: 1),
      const ReleaseNotesBlock(ReleaseNotesBlockKind.quote, 'v0.16 已撤回。'),
      const ReleaseNotesBlock(h, '⚠️ 未实机测试，需测试', level: 2),
      const ReleaseNotesBlock(
        b,
        'v0.16 by @x in https://github.com/is-hp-is-mad/Flutify/pull/38',
      ),
      const ReleaseNotesBlock(
        ReleaseNotesBlockKind.paragraph,
        '**Full Changelog**: https://github.com/is-hp-is-mad/Flutify/compare/v0.15...v0.16.1',
      ),
    ]);
  });

  testWidgets('渲染后不再出现 Markdown 标记，粗体与链接生效', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ReleaseNotesView(notes)),
        ),
      ),
    );
    expect(tester.takeException(), isNull);

    final texts = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((t) => t.text.toPlainText())
        .join('\n');
    expect(texts, isNot(contains('##')));
    expect(texts, isNot(contains('**')));
    expect(texts, contains('主要更新'));
    expect(texts, contains('自动播放相似歌曲'));

    final spans = <TextSpan>[];
    for (final t in tester.widgetList<RichText>(find.byType(RichText))) {
      t.text.visitChildren((s) {
        if (s is TextSpan) spans.add(s);
        return true;
      });
    }
    expect(
      spans.any(
        (s) =>
            s.text == '自动播放相似歌曲' &&
            s.style?.fontWeight == FontWeight.w600,
      ),
      isTrue,
    );
    final link = spans.firstWhere(
      (s) => s.text == 'https://github.com/is-hp-is-mad/Flutify/pull/38',
    );
    expect(link.recognizer, isNotNull);
    // 句末标点不算进链接
    expect(
      spans.any(
        (s) =>
            s.text ==
                'https://github.com/is-hp-is-mad/Flutify/compare/v0.15...v0.16.1' &&
            s.recognizer != null,
      ),
      isTrue,
    );
  });

  testWidgets('[文字](链接) 只显示文字', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReleaseNotesView('见 [README](https://example.com/readme)。'),
        ),
      ),
    );
    final plain = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((t) => t.text.toPlainText())
        .join();
    expect(plain, contains('见 README。'));
    expect(plain, isNot(contains('https://example.com')));
  });
}
