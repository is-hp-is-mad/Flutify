import 'dart:ui' show Tristate;

import 'package:flutify_app/core/theme/md3e_theme.dart';
import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/providers/appearance_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/screens/settings/settings_screen.dart';
import 'package:flutify_app/ui/screens/settings/widgets/settings_section.dart';
import 'package:flutify_app/ui/shell/desktop/desktop_top_bar.dart';
import 'package:flutify_app/ui/widgets/desktop_player_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3ESwitch;

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpApp(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.padding = const FakeViewPadding(top: 32, bottom: 24, left: 12);
    tester.view.viewPadding = const FakeViewPadding(
      top: 32,
      bottom: 24,
      left: 12,
    );
    addTearDown(tester.view.reset);
    final paletteEnabled = ArtworkPalette.enabled;
    ArtworkPalette.enabled = false;
    addTearDown(() => ArtworkPalette.enabled = paletteEnabled);
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await tester.pumpWidget(
      FlutifyApp(
        storageService: storage,
        audioEngine: FakeAudioPlayerService(),
        emePlayer: EmePlayer(),
        spotifyApiService: FakeSpotifyApiService(storage),
        trackAudioLoader: FakeTrackAudioSource(),
      ),
    );
    await settle(tester);
  }

  testWidgets('phone settings: system icons, insets and route restoration', (
    tester,
  ) async {
    await pumpApp(tester, const Size(390, 844));
    final root = tester.element(find.byType(MainShell));
    final appearance = root.read<AppearanceProvider>();
    appearance.update(appearance.settings.copyWith(themeMode: ThemeMode.light));
    Navigator.of(
      root,
      rootNavigator: true,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
    await settle(tester);

    expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.dark);
    expect(
      SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
      Brightness.dark,
    );
    final appBar = find.byType(AppBar);
    final title = find.descendant(of: appBar, matching: find.text('设置'));
    expect(tester.getTopLeft(title).dy, greaterThanOrEqualTo(32));
    final list = find.descendant(
      of: find.byType(SettingsScreen),
      matching: find.byType(ListView),
    );
    expect(tester.getTopLeft(list).dy, 32 + kToolbarHeight);
    expect(tester.getTopLeft(list).dx, greaterThanOrEqualTo(12));
    await tester.drag(list, const Offset(0, -250));
    await settle(tester);
    expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.dark);

    appearance.update(
      appearance.settings.copyWith(themeMode: ThemeMode.dark, pureBlack: true),
    );
    await settle(tester);
    expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.light);
    expect(
      SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
      Brightness.light,
    );
    Navigator.of(root, rootNavigator: true).pop();
    await settle(tester);
    appearance.update(appearance.settings.copyWith(themeMode: ThemeMode.light));
    await settle(tester);
    expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.dark);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('tablet wide shell clears top, side and navigation insets', (
    tester,
  ) async {
    await pumpApp(tester, const Size(1024, 800));
    expect(tester.getTopLeft(find.byType(DesktopTopBar)).dy, 32);
    expect(tester.getTopLeft(find.byType(DesktopTopBar)).dx, 12);
    expect(
      tester.getBottomRight(find.byType(DesktopPlayerBar)).dy,
      lessThanOrEqualTo(776),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets(
    'settings switch exposes its label and toggles once from touch or TalkBack',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var enabled = false;
      var changes = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: MD3ETheme.light,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SettingsSection(
                title: 'Playback',
                children: [
                  SettingsSwitchTile(
                    title: 'Normalize volume',
                    subtitle: 'Keep a consistent level',
                    value: enabled,
                    onChanged: (value) => setState(() {
                      enabled = value;
                      changes++;
                    }),
                  ),
                  SettingsTile(title: 'Reset', onTap: () {}),
                ],
              ),
            ),
          ),
        ),
      );
      final finder = find.bySemanticsLabel(
        'Normalize volume\nKeep a consistent level',
      );
      expect(finder, findsOneWidget);
      final node = tester.getSemantics(finder);
      expect(
        node.getSemanticsData().flagsCollection.isToggled,
        Tristate.isFalse,
      );
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pump();
      expect(enabled, isTrue);
      expect(changes, 1);
      await tester.tap(find.byType(M3ESwitch));
      await tester.pump();
      expect(enabled, isFalse);
      expect(changes, 2);
      await tester.tap(find.text('Normalize volume'));
      await tester.pump();
      expect(changes, 3);
      final reset = find.ancestor(
        of: find.text('Reset'),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(reset).height, greaterThanOrEqualTo(48));
      semantics.dispose();
    },
  );
}
