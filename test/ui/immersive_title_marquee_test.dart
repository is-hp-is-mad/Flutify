import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/connect_provider.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/connect/connect_service.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/player/immersive_lyrics_screen.dart';
import 'package:flutify_app/ui/shell/desktop/desktop_window.dart';
import 'package:flutify_app/ui/widgets/marquee_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_track_audio_source.dart';
import 'connect_ui_test.dart' show FakeConnectService, syntheticCluster;

const _longTrack = SpotifyTrack(
  id: 'synthetic-immersive-title',
  name:
      'A Very Long Synthetic Song Title That Must Scroll In The Immersive '
      'Lyrics Header Without Changing Its Layout',
  durationMs: 200000,
);

Future<PlaybackProvider> _pumpScreen(
  WidgetTester tester,
  double width, {
  SpotifyTrack track = _longTrack,
  bool reduceMotion = false,
  bool remote = false,
  bool pinned = false,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final oldPalette = ArtworkPalette.enabled;
  ArtworkPalette.enabled = false;
  DesktopWindow.debugMacNativeWindowOverride = true;
  addTearDown(() {
    ArtworkPalette.enabled = oldPalette;
    DesktopWindow.debugMacNativeWindowOverride = null;
  });

  SharedPreferences.setMockInitialValues({'ui_immersive_pinned': pinned});
  final storage = await StorageService.init();
  final service = FakeConnectService();
  late PlaybackProvider playback;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<StorageService>.value(value: storage),
        ChangeNotifierProvider(
          create: (_) => SpotifyProvider(SpotifyApiService(storage), storage),
        ),
        ChangeNotifierProvider(create: (_) => LibraryProvider(storage)),
        ChangeNotifierProvider(
          create: (_) => playback = PlaybackProvider(
            FakeAudioPlayerService(),
            storage,
            audioLoader: FakeTrackAudioSource(),
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => ConnectProvider(
            service,
            available: () => true,
            resolveTrack: (_) async => null,
          ),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: const ImmersiveLyricsScreen(),
      ),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  if (remote) {
    service.setStatus(ConnectStatus.online);
    service.push(syntheticCluster(playing: false));
  } else {
    await playback.playTrack(track, contextQueue: [track]);
  }
  // Layout configures the marquee after the frame; start its clock at zero.
  await tester.pump();
  await tester.pump();
  await tester.pump();
  // The shared player scene eases the cover into the lyrics card (and the
  // title with it); the marquee restarts once that transition has settled.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
  return playback;
}

Finder get _title => find.descendant(
  of: find.byType(ImmersiveLyricsScreen),
  matching: find.byType(MarqueeText),
);

Finder get _titleScroll =>
    find.descendant(of: _title, matching: find.byType(SingleChildScrollView));

double _offset(WidgetTester tester) =>
    tester.widget<SingleChildScrollView>(_titleScroll).controller!.offset;

void main() {
  // 360px is the native Mac window's minimum width; include both layouts.
  for (final width in [360.0, 768.0, 1024.0, 1440.0]) {
    testWidgets('immersive long titles scroll at ${width.round()}px', (
      tester,
    ) async {
      await _pumpScreen(tester, width);
      expect(_title, findsOneWidget);
      final title = tester.widget<MarqueeText>(_title);
      expect(title.text, _longTrack.name);
      // Same metadata as the mobile lyrics card: bold, shrunk with the cover.
      expect(title.style?.fontSize, closeTo(22 * 0.65, 0.5));
      expect(title.style?.fontWeight, FontWeight.w600);
      expect(_titleScroll, findsOneWidget);
      expect(_offset(tester), 0);
      await tester.pump(const Duration(seconds: 3));
      expect(_offset(tester), 0);
      await tester.pump(const Duration(seconds: 2));
      expect(_offset(tester), greaterThan(0));
      expect(
        find.descendant(of: _title, matching: find.bySubtype<ShaderMask>()),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [768.0, 1280.0]) {
    testWidgets('immersive short titles remain static at ${width.round()}px', (
      tester,
    ) async {
      await _pumpScreen(tester, width, track: _longTrack.copyWith(name: 'Hi'));
      expect(_title, findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(_titleScroll, findsNothing);
      expect(
        find.descendant(of: _title, matching: find.text('Hi')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'immersive titles respect reduced motion at ${width.round()}px',
      (tester) async {
        await _pumpScreen(tester, width, reduceMotion: true);
        expect(_title, findsOneWidget);
        await tester.pump(const Duration(seconds: 6));
        expect(_titleScroll, findsNothing);
        expect(
          find.descendant(of: _title, matching: find.text(_longTrack.name)),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('remote immersive titles also scroll at ${width.round()}px', (
      tester,
    ) async {
      await _pumpScreen(tester, width, remote: true);
      expect(_title, findsOneWidget);
      expect(
        tester.widget<MarqueeText>(_title).text,
        syntheticCluster().player.title,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(_offset(tester), greaterThan(0));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('switching tracks with the same title restarts the pause', (
    tester,
  ) async {
    // 固定控制区：不让卡片在等待期间收成迷你栏，标题布局保持稳定
    final playback = await _pumpScreen(tester, 1280, pinned: true);
    expect(_title, findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(_offset(tester), greaterThan(0));

    final next = _longTrack.copyWith(id: 'synthetic-next-track');
    await playback.playTrack(next, contextQueue: [next]);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    // The shared title cross-fades between tracks; wait for the old one to go.
    await tester.pump(const Duration(milliseconds: 300));
    expect(_offset(tester), 0);
    await tester.pump(const Duration(seconds: 3));
    expect(_offset(tester), 0);
    await tester.pump(const Duration(seconds: 2));
    expect(_offset(tester), greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('looping immersive titles are announced only once', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pumpScreen(tester, 1280);
      await tester.pump(const Duration(seconds: 5));
      expect(
        find.descendant(of: _title, matching: find.text(_longTrack.name)),
        findsNWidgets(2),
      );
      expect(find.bySemanticsLabel(_longTrack.name), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
