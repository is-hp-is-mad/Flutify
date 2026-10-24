import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutify_app/providers/auth_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/auth/login_screen.dart';
import 'package:flutify_app/ui/screens/auth/web_login_screen.dart';
import 'package:flutify_app/ui/screens/auth/widgets/login_hero.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/shell/desktop/desktop_window.dart';
import 'package:flutify_app/ui/shell/desktop/window_frame.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_audio_player_service.dart';

class _LoginAuth extends Fake with ChangeNotifier implements AuthProvider {
  @override
  bool get isSignedIn => false;

  @override
  String? get error => null;
}

/// 登录页在小屏手机上的冒烟测试：只有「在浏览器中登录」一种方式、无布局溢出、可关闭。
void main() {
  const channel = MethodChannel('window_manager');
  final windowCalls = <String>[];
  var maximized = false;

  setUp(() {
    windowCalls.clear();
    maximized = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          windowCalls.add(call.method);
          if (call.method == 'isMaximized') return maximized;
          if (call.method == 'isFullScreen') return false;
          if (call.method == 'maximize') maximized = true;
          if (call.method == 'unmaximize') maximized = false;
          return null;
        });
  });

  tearDown(() {
    DesktopWindow.debugEnabledOverride = null;
    DesktopWindow.debugMacNativeWindowOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<_LoginAuth> pumpLogin(
    WidgetTester tester, {
    double width = 1280,
    bool enabled = true,
    bool mac = true,
  }) async {
    DesktopWindow.debugEnabledOverride = enabled;
    DesktopWindow.debugMacNativeWindowOverride = mac;
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = _LoginAuth();
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: WindowFrame(child: child!),
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => LoginScreen.open(context),
                child: const Text('Open login'),
              ),
            ),
          ),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      auth.dispose();
    });
    await tester.tap(find.text('Open login'));
    await settle(tester);
    windowCalls.clear();
    return auth;
  }

  Finder loginBackButton() => find
      .descendant(
        of: find.byType(LoginScreen),
        matching: find.byType(IconButton),
      )
      .first;

  testWidgets('login: single in-app sign-in page renders and closes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ArtworkPalette.enabled = false;

    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await tester.pumpWidget(
      FlutifyApp(
        storageService: storage,
        audioEngine: FakeAudioPlayerService(),
        emePlayer: EmePlayer(),
        spotifyApiService: SpotifyApiService(storage),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    LoginScreen.open(tester.element(find.byType(MainShell)));
    await settle(tester);

    expect(find.byType(LoginHero), findsOneWidget);
    expect(find.text('登录 Spotify'), findsOneWidget);
    expect(find.widgetWithText(M3EButton, '登录'), findsOneWidget);
    // 其他登录方式已移除
    expect(find.text('账号密码'), findsNothing);
    expect(find.text('更多方式'), findsNothing);

    await tester.tap(find.byTooltip('关闭'));
    await settle(tester);
    expect(find.byType(LoginScreen), findsNothing);
  });

  for (final width in [800.0, 1280.0]) {
    {
      testWidgets(
        'macOS login header drags and maximizes/restores at width $width',
        (tester) async {
          await pumpLogin(tester, width: width);
          const blank = Offset(260, 28);
          await tester.dragFrom(
            blank,
            const Offset(60, 30),
            kind: PointerDeviceKind.mouse,
          );
          await settle(tester);
          expect(windowCalls, ['startDragging']);
          windowCalls.clear();
          await tester.tapAt(blank, kind: PointerDeviceKind.mouse);
          await tester.pump(const Duration(milliseconds: 100));
          await tester.tapAt(blank, kind: PointerDeviceKind.mouse);
          await settle(tester);
          expect(windowCalls, ['isMaximized', 'maximize']);
          windowCalls.clear();
          await tester.tapAt(blank, kind: PointerDeviceKind.mouse);
          await tester.pump(const Duration(milliseconds: 100));
          await tester.tapAt(blank, kind: PointerDeviceKind.mouse);
          await settle(tester);
          expect(windowCalls, ['isMaximized', 'unmaximize']);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );
    }
  }

  testWidgets(
    'macOS login controls avoid traffic lights and do not drag the window',
    (tester) async {
      await pumpLogin(tester);
      final close = loginBackButton();
      expect(
        tester.getRect(close).left,
        greaterThanOrEqualTo(DesktopWindow.macTrafficLightsInset),
      );
      for (final control in [close, find.widgetWithText(M3EButton, '登录')]) {
        await tester.drag(
          control,
          const Offset(40, 30),
          kind: PointerDeviceKind.mouse,
        );
        await settle(tester);
        expect(find.byType(WebLoginScreen), findsNothing);
        expect(windowCalls, isEmpty);
      }
      expect(windowCalls, isEmpty);
      expect(find.byType(LoginScreen), findsOneWidget);
      final navigator = Navigator.of(tester.element(find.byType(LoginScreen)));
      await tester.tap(close, kind: PointerDeviceKind.mouse);
      await settle(tester);
      expect(navigator.canPop(), isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(LoginScreen), findsNothing);
      expect(windowCalls, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'narrow macOS login keeps the existing window caption drag area',
    (tester) async {
      await pumpLogin(tester, width: 760);
      expect(
        find.descendant(
          of: find.byType(LoginScreen),
          matching: find.byType(WindowDragArea),
        ),
        findsNothing,
      );
      await tester.dragFrom(
        const Offset(260, 28),
        const Offset(60, 30),
        kind: PointerDeviceKind.mouse,
      );
      await settle(tester);
      expect(windowCalls, ['startDragging']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'disabled desktop integration does not add login window gestures',
    (tester) async {
      await pumpLogin(tester, enabled: false);
      await tester.dragFrom(
        const Offset(260, 28),
        const Offset(60, 30),
        kind: PointerDeviceKind.mouse,
      );
      await settle(tester);
      expect(windowCalls, isEmpty);
      expect(tester.getRect(loginBackButton()).left, 8);
    },
  );

  testWidgets(
    'non-macOS login layout is unchanged',
    (tester) async {
      await pumpLogin(tester, mac: false);
      expect(
        find.descendant(
          of: find.byType(LoginScreen),
          matching: find.byType(WindowDragArea),
        ),
        findsNothing,
      );
      expect(tester.getRect(loginBackButton()).left, 8);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );
}
