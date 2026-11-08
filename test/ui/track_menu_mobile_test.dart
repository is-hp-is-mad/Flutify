import 'package:flutify_app/core/theme/flutify_tokens.dart';
import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutify_app/models/album.dart';
import 'package:flutify_app/models/artist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/widgets/menu/mobile_menu.dart';
import 'package:flutify_app/ui/widgets/track_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = SpotifyTrack(
  id: '4uLU6hMCjMI75M1A2tKUQC',
  name: 'Dancing in Starlight',
  uri: 'spotify:track:4uLU6hMCjMI75M1A2tKUQC',
  artists: [SpotifyArtist(id: 'a1', name: 'Sufjan Stevens')],
  album: SpotifyAlbum(id: 'al1', name: 'Seven Swans'),
);

Future<LibraryProvider> _pumpMenu(
  WidgetTester tester, {
  double width = 390,
}) async {
  SharedPreferences.setMockInitialValues({});
  final library = LibraryProvider(await StorageService.init());
  tester.view.physicalSize = Size(width, 844) * tester.view.devicePixelRatio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: library,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          extensions: const [
            FlutifyTokens(
              accent: Color(0xff277af7),
              onAccent: Colors.white,
              glassSigma: 20,
              glassTint: 0.1,
              glassOpacity: 0.5,
              cornerScale: 1.0,
              squareCorners: false,
              hyperMaterial: true,
            ),
          ],
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.more_horiz),
                onPressed: () => TrackMenu.show(context, _track),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byIcon(Icons.more_horiz));
  await tester.pumpAndSettle();
  return library;
}

void main() {
  testWidgets('手机上的柔光玻璃曲目菜单：顶部快捷操作 + 分组菜单行与副标题', (tester) async {
    await _pumpMenu(tester);

    expect(find.byType(MobileMenuActionRow<Object>), findsOneWidget);
    for (final label in ['添加', '点赞', '分享']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('添加到歌单'), findsOneWidget);
    expect(find.text('前往专辑'), findsOneWidget);
    // 副标题
    expect(find.text('Seven Swans'), findsOneWidget);
    expect(find.text('Sufjan Stevens'), findsOneWidget);
    expect(find.text('Dancing in Starlight'), findsOneWidget);
  });

  testWidgets('快捷操作「点赞」直接执行并关闭菜单', (tester) async {
    final library = await _pumpMenu(tester);

    await tester.tap(find.text('点赞'));
    await tester.pumpAndSettle();

    expect(library.isLiked(_track.id), isTrue);
    expect(find.byType(MobileMenuActionRow<Object>), findsNothing);
  });

  testWidgets('桌面宽度仍使用桌面菜单', (tester) async {
    await _pumpMenu(tester, width: 1280);

    expect(find.byType(MobileMenuActionRow<Object>), findsNothing);
    expect(find.text('添加到歌单'), findsOneWidget);
  });
}
