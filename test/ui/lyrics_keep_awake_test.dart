import 'package:flutify_app/core/theme/md3e_theme.dart';
import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/preferences_provider.dart';
import 'package:flutify_app/services/screen_awake/screen_awake.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/settings/sections/custom_features_section.dart';
import 'package:flutify_app/ui/widgets/lyrics_keep_awake.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';

void main() {
  late StorageService storage;
  late PreferencesProvider prefs;
  late PlaybackProvider playback;
  late List<Object?> calls;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.init();
    prefs = PreferencesProvider(storage.preferences);
    playback = PlaybackProvider(FakeAudioPlayerService(), storage.playback);
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutify/screen_awake'), (
          call,
        ) async {
          calls.add(call.arguments);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutify/screen_awake'),
          null,
        );
    playback.dispose();
    prefs.dispose();
  });

  Widget app(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider<PreferencesProvider>.value(value: prefs),
      ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
    ],
    child: MaterialApp(
      theme: MD3ETheme.light,
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );

  testWidgets(
    'keeps the screen on only while lyrics are shown and enabled',
    (tester) async {
      final show = ValueNotifier(true);
      await tester.pumpWidget(
        app(
          ValueListenableBuilder<bool>(
            valueListenable: show,
            builder: (_, visible, _) => visible
                ? const LyricsKeepAwake(child: Text('lyrics'))
                : const SizedBox(),
          ),
        ),
      );
      expect(ScreenAwake.isHeld, isFalse, reason: '默认关闭');
      expect(calls, isEmpty);

      prefs.update(prefs.prefs.copyWith(lyricsKeepScreenOn: true));
      await tester.pump();
      expect(ScreenAwake.isHeld, isTrue);
      expect(calls, [true]);

      show.value = false;
      await tester.pump();
      expect(ScreenAwake.isHeld, isFalse, reason: '离开歌词界面即恢复自动熄屏');
      expect(calls, [true, false]);

      show.value = true;
      await tester.pump();
      prefs.update(prefs.prefs.copyWith(lyricsKeepScreenOn: false));
      await tester.pump();
      expect(ScreenAwake.isHeld, isFalse);
      expect(calls, [true, false, true, false]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('turning it on asks first and warns about OLED burn-in', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(const CustomFeaturesSection()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Keep screen on for lyrics'));
    await tester.pumpAndSettle();
    expect(find.textContaining('burn-in'), findsWidgets);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(prefs.prefs.lyricsKeepScreenOn, isFalse);

    await tester.tap(find.text('Keep screen on for lyrics'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn on anyway'));
    await tester.pumpAndSettle();
    expect(prefs.prefs.lyricsKeepScreenOn, isTrue);

    // 关闭不再确认
    await tester.tap(find.text('Keep screen on for lyrics'));
    await tester.pumpAndSettle();
    expect(find.text('Turn on anyway'), findsNothing);
    expect(prefs.prefs.lyricsKeepScreenOn, isFalse);
  });
}
