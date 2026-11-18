import 'dart:io';

import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutify_app/providers/connect_provider.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/connect/connect_service.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/widgets/desktop_player_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../ui/connect_ui_test.dart' show FakeConnectService, syntheticCluster;

/// 远程模式播放栏（玻璃胶囊 + 附挂小条）的离屏渲染审查。
///
/// 默认跳过；需要时运行：
///   $env:FLUTIFY_AUDIT='1'; flutter test --update-goldens test/audit/remote_bar_audit_test.dart
/// 截图输出到 build/audit/remote_bar.png，供人工检查衔接处圆角。
void main() {
  final enabled = Platform.environment['FLUTIFY_AUDIT'] == '1';

  testWidgets('remote bar audit', skip: !enabled, (tester) async {
    tester.view.physicalSize = const Size(1280, 400);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    final service = FakeConnectService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          Provider<PreferencesStore>.value(value: storage.preferences),
          Provider<CachePrefsStore>.value(value: storage.cache),
          ChangeNotifierProvider(create: (_) => SpotifyProvider(SpotifyApiService(storage.auth), storage.library)),
          ChangeNotifierProvider(create: (_) => LibraryProvider(storage.library)),
          ChangeNotifierProvider(create: (_) => PlaybackProvider(FakeAudioPlayerService(), storage.playback)),
          ChangeNotifierProvider(
            create: (_) => ConnectProvider(service, available: () => true, resolveTrack: (_) async => null),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            // 花背景：看清玻璃模糊与小条衔接
            body: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF5B3A8E), Color(0xFF1E5E4A), Color(0xFF8E3A5B)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Align(alignment: Alignment.bottomCenter, child: DesktopPlayerBar()),
            ),
          ),
        ),
      ),
    );
    service.setStatus(ConnectStatus.online);
    service.push(syntheticCluster());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../../build/audit/remote_bar.png'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
