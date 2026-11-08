import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutify_app/core/theme/flutify_tokens.dart';
import 'package:flutify_app/l10n/app_locale.dart';
import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutify_app/l10n/model_labels.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/models/home_feed.dart';
import 'package:flutify_app/ui/screens/home/home_section_screen.dart';
import 'package:flutify_app/ui/screens/search/search_screen.dart';
import 'package:flutify_app/ui/widgets/hyper_surface.dart';
import 'package:hyper_glass/hyper_ui.dart' show HySegmented;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/controlled_search_api.dart';
import '../fakes/fake_audio_player_service.dart';
import '../fixtures/search_pages.dart';

void main() {
  group('ModelLabels localization interception', () {
    test('homeChipLabel intercepts english labels in Chinese locale', () {
      final l10n = lookupAppLocalizations(const Locale('zh'));
      expect(l10n.homeChipLabel('Following'), '已关注');
      expect(l10n.homeChipLabel('', 'sub-following'), '已关注');
      expect(l10n.homeChipLabel('Music'), '音乐');
      expect(l10n.homeChipLabel('Podcasts'), '播客');
      expect(l10n.homeChipLabel('Audiobooks'), '有声书');
      expect(l10n.homeChipLabel('Playlists'), '歌单');
      expect(l10n.homeChipLabel('Albums'), '专辑');
      expect(l10n.homeChipLabel('Artists'), '艺人');
      expect(l10n.homeChipLabel('Downloaded'), '已下载');
      expect(l10n.homeChipLabel('Custom'), 'Custom');
    });

    test('homeChipLabel intercepts in Traditional Chinese & Japanese', () {
      final zhHant = lookupAppLocalizations(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      );
      expect(zhHant.homeChipLabel('Following'), '已關注');
      expect(zhHant.homeChipLabel('Audiobooks'), '有聲書');
      expect(zhHant.homeChipLabel('Downloaded'), '已下載');

      final ja = lookupAppLocalizations(const Locale('ja'));
      expect(ja.homeChipLabel('Following'), 'フォロー中');
      expect(ja.homeChipLabel('Audiobooks'), 'オーディオブック');
      expect(ja.homeChipLabel('Music'), '音楽');
      expect(ja.homeChipLabel('Downloaded'), 'ダウンロード済み');
    });

    test('categoryName intercepts slugs into localized names', () {
      final l10n = lookupAppLocalizations(const Locale('zh'));
      expect(l10n.categoryName('toplists', 'toplists'), '排行榜');
      expect(l10n.categoryName('pop', 'pop'), '流行');
      expect(l10n.categoryName('rock', 'rock'), '摇滚');
      expect(l10n.categoryName('hiphop', 'hiphop'), '嘻哈');
      expect(l10n.categoryName('mandopop', 'mandopop'), '华语流行');
      expect(l10n.categoryName('blues', 'blues'), '蓝调');
      expect(l10n.categoryName('soul', 'soul'), '灵魂乐');
      expect(l10n.categoryName('wellness', 'wellness'), '疗愈健康');

      final ja = lookupAppLocalizations(const Locale('ja'));
      expect(ja.categoryName('toplists', 'toplists'), 'ランキング');
      expect(ja.categoryName('pop', 'pop'), 'ポップ');
      expect(ja.categoryName('rock', 'rock'), 'ロック');
      expect(ja.categoryName('mandopop', 'mandopop'), 'マンドポップ');
    });

    test('homeSectionTitle intercepts server dynamic titles', () {
      final l10n = lookupAppLocalizations(const Locale('zh'));
      expect(l10n.homeSectionTitle('Recently played'), '最近播放');
      expect(l10n.homeSectionTitle('Made For You'), '为你打造');
      expect(l10n.homeSectionTitle('Jump back in'), '继续收听');
      expect(l10n.homeSectionTitle('Your top mixes'), '你的专属合辑');
      expect(l10n.homeSectionTitle('Popular Playlists'), '热门歌单');
      expect(l10n.homeSectionTitle('Trending now'), '当前流行');
      expect(l10n.homeSectionTitle('New releases'), '最新发行');
      expect(l10n.homeSectionTitle('Radar'), '音乐雷达');

      final ja = lookupAppLocalizations(const Locale('ja'));
      expect(ja.homeSectionTitle('Recently played'), '最近の再生');
      expect(ja.homeSectionTitle('Made For You'), 'あなたへのおすすめ');
      expect(ja.homeSectionTitle('Jump back in'), 'もう一度聴く');
      expect(ja.homeSectionTitle('Popular Playlists'), '人気のプレイリスト');
      expect(ja.homeSectionTitle('Trending now'), '急上昇中');
    });
  });

  group('HyperBackButton and HyperCircleIcon use straight arrow', () {
    testWidgets('HyperBackButton uses Icons.arrow_back_rounded', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HyperBackButton(),
          ),
        ),
      );
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_ios_new), findsNothing);
    });

    testWidgets('HyperCircleIcon uses passed rounded icon without iOS conversion', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HyperCircleIcon(Icons.arrow_back_rounded),
          ),
        ),
      );
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_ios_new), findsNothing);
    });
  });

  testWidgets('SearchScreen in hyperMaterial mode uses HySegmented controller', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    final api = ControlledSearchApi(storage, signedIn: true);
    final spotify = SpotifyProvider(api, storage);
    final audio = FakeAudioPlayerService();
    final playback = PlaybackProvider(audio, storage);
    final library = LibraryProvider(storage);
    final controller = TextEditingController(text: 'test');

    addTearDown(() {
      spotify.dispose();
      playback.dispose();
      library.dispose();
      controller.dispose();
      audio.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<SpotifyApiService>.value(value: api),
          ChangeNotifierProvider.value(value: spotify),
          ChangeNotifierProvider.value(value: playback),
          ChangeNotifierProvider.value(value: library),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocale.supportedLocales,
          localizationsDelegates: AppLocale.delegates,
          theme: ThemeData(
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
          home: SearchScreen(controller: controller),
        ),
      ),
    );

    spotify.performSearch('test');
    await tester.pump(const Duration(milliseconds: 350));
    api.requests.single.result.complete(page(tracks: tracks(0, 5)));
    await tester.pumpAndSettle();

    // 验证搜索分类切换已升级为 HySegmented 分段控制器
    expect(find.byType(HySegmented), findsOneWidget);
  });

  testWidgets('HomeSectionScreen intercepts server dynamic title in AppBar', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    final api = ControlledSearchApi(storage, signedIn: true);

    const section = HomeSection(
      uri: 'spotify:section:recently_played',
      kind: HomeSectionKind.recents,
      title: 'Recently played',
      subtitle: '',
      items: [],
    );

    await tester.pumpWidget(
      Provider<SpotifyApiService>.value(
        value: api,
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocale.supportedLocales,
          localizationsDelegates: AppLocale.delegates,
          home: const HomeSectionScreen(section: section),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('最近播放'), findsOneWidget);
    expect(find.text('Recently played'), findsNothing);
  });
}
