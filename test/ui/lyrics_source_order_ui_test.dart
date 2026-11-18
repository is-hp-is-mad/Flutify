import 'package:flutify_app/l10n/l10n.dart';
import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/providers/preferences_provider.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/settings/sections/lyrics_section.dart';
import 'package:flutify_app/ui/screens/settings/widgets/lyrics_source_order_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<PreferencesProvider> settingsHost(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    final prefs = PreferencesProvider(storage.preferences);
    addTearDown(prefs.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: prefs,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(child: LyricsSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return prefs;
  }

  List<String> shownOrder(WidgetTester tester) {
    // 行内第一个 Text 是序号，第二个是来源名称，按纵向位置排序即当前显示顺序。
    final names = {
      'Spotify': LyricsSource.spotify,
      'QQ 音乐': LyricsSource.qqMusic,
      '网易云音乐': LyricsSource.netease,
      'LRCLIB': LyricsSource.lrclib,
    };
    final rows = [
      for (final entry in names.entries)
        (
          entry.key,
          tester
              .getTopLeft(
                find.descendant(
                  of: find.byType(LyricsSourceOrderTile),
                  matching: find.text(entry.key),
                ),
              )
              .dy,
        ),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final r in rows) r.$1];
  }

  testWidgets('settings lists sources in the default order', (tester) async {
    await settingsHost(tester);
    await tester.ensureVisible(find.byType(LyricsSourceOrderTile));
    await tester.pumpAndSettle();
    expect(shownOrder(tester), ['Spotify', 'QQ 音乐', '网易云音乐', 'LRCLIB']);
  });

  testWidgets('dragging a handle reorders sources and persists the order', (
    tester,
  ) async {
    final prefs = await settingsHost(tester);
    await tester.ensureVisible(find.byType(LyricsSourceOrderTile));
    await tester.pumpAndSettle();

    final handles = find.byIcon(Icons.drag_handle_rounded);
    expect(handles, findsNWidgets(4));
    // 把最后一项（LRCLIB）拖到最前面
    final gesture = await tester.startGesture(tester.getCenter(handles.last));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(prefs.prefs.lyricsSourceOrder, [
      LyricsSource.lrclib,
      LyricsSource.spotify,
      LyricsSource.qqMusic,
      LyricsSource.netease,
    ]);
    expect(shownOrder(tester), ['LRCLIB', 'Spotify', 'QQ 音乐', '网易云音乐']);

    final restored = PreferencesProvider((await StorageService.init()).preferences);
    addTearDown(restored.dispose);
    expect(restored.prefs.lyricsSourceOrder, prefs.prefs.lyricsSourceOrder);
    expect(tester.takeException(), isNull);
  });

  testWidgets('LRCLIB row explains it is off when completion is disabled', (
    tester,
  ) async {
    final prefs = await settingsHost(tester);
    prefs.update(prefs.prefs.copyWith(lyricsFallback: false));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(LyricsSourceOrderTile));
    await tester.pumpAndSettle();
    expect(find.text('已在「补全歌词」中关闭'), findsOneWidget);
    prefs.update(prefs.prefs.copyWith(lyricsFallback: true));
    await tester.pumpAndSettle();
    expect(find.text('已在「补全歌词」中关闭'), findsNothing);
  });
}
