import 'dart:convert';

import 'package:flutify_app/core/constants/app_info.dart';
import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/core/utils/byte_size.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/models/appearance.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/protocol/audio_cache_store.dart';
import 'package:flutify_app/services/protocol/track_audio_loader.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/screens/settings/settings_screen.dart';
import 'package:flutify_app/ui/screens/settings/sections/language_section.dart';
import 'package:flutify_app/ui/screens/settings/widgets/shortcuts_dialog.dart';
import 'package:flutify_app/ui/navigation/tab_navigator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton;

/// 带缓存管理能力的加载器替身（真实 TrackAudioLoader 同时实现两个接口）。
class _FakeCachingLoader extends FakeTrackAudioSource
    implements AudioCacheStore {
  int bytes = 3 * ByteSize.mb;

  @override
  int maxCacheBytes = 512 * ByteSize.mb;

  @override
  Future<int> sizeBytes() async => bytes;

  @override
  Future<int> clear() async {
    final freed = bytes;
    bytes = 0;
    return freed;
  }
}

/// 设置页新增分组端到端：语言 / 歌词 / 播放 / Connect / 存储 / 隐私 / 启动 / 关于。
/// 每项都验证「点选即生效 + 已持久化」。
void main() {
  late StorageService storage;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 关掉弹层并在「每次 pump 都推进」的条件下等它开合完成。
  ///
  /// [settle] 内是固定次数的 pump，即使树已经稳定也照样推进时间；弹层关闭动画
  /// 因此必然结束，不会有残影留在下一帧的命中测试列表里。
  Future<void> closeOverlay(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  // 高度给足：移动端设置页是懒加载单列，一屏放下全部分组，测试无需滚动
  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(500, 6400),
    TrackAudioSource? loader,
    Future<void> Function(StorageService storage)? seed,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ArtworkPalette.enabled = false;

    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.init();
    await seed?.call(storage);
    await tester.pumpWidget(
      FlutifyApp(
        key: UniqueKey(),
        storageService: storage,
        audioEngine: FakeAudioPlayerService(),
        emePlayer: EmePlayer(),
        spotifyApiService: FakeSpotifyApiService(storage),
        trackAudioLoader: loader ?? FakeTrackAudioSource(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> openSettings(WidgetTester tester) async {
    Navigator.of(
      tester.element(find.byType(MainShell)),
      rootNavigator: true,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
    await settle(tester);
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text).last);
    await settle(tester);
    await tester.tap(find.text(text).last);
    await settle(tester);
  }

  AppPreferences savedPrefs() => AppPreferences.decode(storage.preferencesJson);

  /// 在语言菜单里选中 [label]。
  ///
  /// 菜单项按 [label] 定位，按钮本身不加文字限制——无论按钮标题里恰好有哪个
  /// 语言名，命中的都只会是菜单里那一项，不会误点到按钮或别处的同名文字。
  ///
  /// 开菜单走键盘：按钮拿到焦点后回车展开。不用点按钮——菜单锚在按钮上、宽度又与
  /// 按钮相同时，展开后的第一项正好盖住按钮中心，落在中心（乃至左缘）的真实点击都
  /// 可能被菜单项或菜单自己的 TapRegion 吃掉：看着「刚开就关」，下一步什么都找不到。
  /// 键盘路径没有指针事件，也就没有这层竞争。
  ///
  /// 菜单开合都要等到动画走完：残留的弹层会留在命中测试列表里，下一次
  /// `find.text(...).last` 就可能落到正在淡出的旧文字上。
  Future<void> selectLanguage(WidgetTester tester, String label) async {
    final dropdown = find.byKey(const ValueKey('interface-language'));
    await tester.ensureVisible(dropdown);
    await settle(tester);
    tester.widget<FilledButton>(dropdown).focusNode!.requestFocus();
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await closeOverlay(tester);
    final item = find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(MenuItemButton)),
      matching: find.text(label),
    );
    expect(item, findsOneWidget, reason: '语言菜单里应恰好有一项「$label」');
    await tester.ensureVisible(item);
    await settle(tester);
    await tester.tap(item);
    await closeOverlay(tester);
  }

  int currentTab(WidgetTester tester) => tester
      .widget<IndexedStack>(
        find
            .ancestor(
              of: find.byType(TabNavigator).first,
              matching: find.byType(IndexedStack),
            )
            .first,
      )
      .index!;

  testWidgets('language switches the UI locale and persists', (tester) async {
    await pumpApp(tester);
    await openSettings(tester);

    await selectLanguage(tester, 'English');
    final context = tester.element(find.byType(SettingsScreen));
    expect(Localizations.localeOf(context).languageCode, 'en');
    expect(find.text('Language'), findsWidgets);
    expect(savedPrefs().language, AppLanguage.en);

    await selectLanguage(tester, '日本語');
    expect(Localizations.localeOf(context).languageCode, 'ja');
    expect(find.text('アプリの言語'), findsOneWidget);
    expect(savedPrefs().language, AppLanguage.ja);

    await selectLanguage(tester, '简体中文');
    expect(find.text('语言'), findsWidgets);
    expect(savedPrefs().language, AppLanguage.zh);
  });

  testWidgets('Japanese is selectable on a narrow screen with large text', (
    tester,
  ) async {
    await pumpApp(
      tester,
      size: const Size(320, 1800),
      seed: (s) => s.setAppearanceJson(
        jsonEncode(
          AppearanceSettings.defaults.copyWith(fontScale: 1.3).toJson(),
        ),
      ),
    );
    await openSettings(tester);
    await tester.scrollUntilVisible(
      find.byType(LanguageSection),
      500,
      scrollable: find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await settle(tester);
    await selectLanguage(tester, '日本語');
    expect(savedPrefs().language, AppLanguage.ja);
    expect(find.text('アプリの言語'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await selectLanguage(tester, '简体中文');
    expect(savedPrefs().language, AppLanguage.zh);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop language menu supports keyboard selection and cancel',
    (tester) async {
      await pumpApp(tester, size: const Size(1440, 2400));
      await openSettings(tester);
      final dropdown = find.byKey(const ValueKey('interface-language'));
      await tester.ensureVisible(dropdown);
      tester.widget<FilledButton>(dropdown).focusNode!.requestFocus();
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      // Select the first item (system), then the second item (Simplified Chinese).
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(savedPrefs().language, AppLanguage.zh);
      expect(
        find.descendant(of: dropdown, matching: find.text('简体中文')),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(savedPrefs().language, AppLanguage.zh);
      expect(
        find.descendant(of: dropdown, matching: find.text('简体中文')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('lyrics, playback and Connect options apply and persist', (
    tester,
  ) async {
    await pumpApp(tester);
    await openSettings(tester);

    await tapText(tester, '居中');
    expect(savedPrefs().lyricsAlign, LyricsAlign.center);

    await tapText(tester, '音量均衡');
    expect(storage.normalizeVolume, isTrue);

    // 关闭 Connect：提前量滑杆随之隐藏
    expect(find.text('远程歌词提前'), findsOneWidget);
    await tapText(tester, '启用 Spotify Connect');
    expect(savedPrefs().connectEnabled, isFalse);
    expect(find.text('远程歌词提前'), findsNothing);
  });

  testWidgets('storage: usage, limit change and clear', (tester) async {
    final loader = _FakeCachingLoader();
    await pumpApp(tester, loader: loader);
    await openSettings(tester);

    expect(find.text('已用 3 MB，上限 512 MB'), findsOneWidget);

    await tapText(tester, '1 GB');
    expect(storage.audioCacheLimitMb, 1024);
    expect(loader.maxCacheBytes, ByteSize.gb);
    expect(find.text('已用 3 MB，上限 1 GB'), findsOneWidget);

    await tapText(tester, '清除音频缓存');
    expect(find.text('清除音频缓存？'), findsOneWidget);
    await tester.tap(find.widgetWithText(M3EButton, '清除'));
    await settle(tester);
    expect(loader.bytes, 0);
    expect(find.text('已释放 3 MB，0 个使用中，0 个未成功'), findsOneWidget);
    expect(find.text('已用 0 KB，上限 1 GB'), findsOneWidget);
  });

  testWidgets('network: proxy mode and manual server persist', (tester) async {
    await pumpApp(tester);
    await openSettings(tester);

    expect(savedPrefs().proxyMode, ProxyMode.system);
    await tapText(tester, '不使用');
    expect(savedPrefs().proxyMode, ProxyMode.none);
    expect(find.byKey(const ValueKey('proxy-host')), findsNothing);

    await tapText(tester, '手动');
    expect(savedPrefs().proxyMode, ProxyMode.manual);

    // 地址框直接粘贴 host:port，自动拆分端口
    await tester.enterText(
      find.byKey(const ValueKey('proxy-host')),
      '127.0.0.1:7890',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(savedPrefs().proxyHost, '127.0.0.1');
    expect(savedPrefs().proxyPort, 7890);

    // 无效端口：提示且不覆盖已保存的值
    await tester.enterText(find.byKey(const ValueKey('proxy-port')), '0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.text('请填写有效的地址和 1–65535 之间的端口'), findsOneWidget);
    expect(savedPrefs().proxyPort, 7890);
  });

  testWidgets('privacy: clearing search history empties it', (tester) async {
    await pumpApp(tester, seed: (s) => s.addRecentSearch('lofi'));
    await openSettings(tester);

    await tapText(tester, '清除搜索记录');
    expect(storage.recentSearches, isEmpty);
    expect(find.text('没有搜索记录'), findsOneWidget);
    expect(find.text('已清除'), findsOneWidget);
  });

  testWidgets('start page: library and last position', (tester) async {
    await pumpApp(
      tester,
      seed: (s) => s.setPreferencesJson(
        const AppPreferences(startPage: StartPage.library).encode(),
      ),
    );
    expect(currentTab(tester), 2);

    await pumpApp(
      tester,
      seed: (s) async {
        await s.setPreferencesJson(
          const AppPreferences(startPage: StartPage.last).encode(),
        );
        await s.setLastTab(1);
      },
    );
    expect(currentTab(tester), 1);
  });

  testWidgets('desktop about: version and keyboard shortcuts dialog', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1440, 2400));
    await openSettings(tester);

    expect(find.text(AppInfo.displayVersion), findsOneWidget);
    await tapText(tester, '键盘快捷键');
    expect(find.byType(ShortcutsDialog), findsOneWidget);
    expect(find.text('Space'), findsOneWidget);
  });
}
