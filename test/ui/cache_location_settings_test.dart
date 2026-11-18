import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutify_app/core/theme/md3e_theme.dart';
import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutify_app/services/cache/cache_location.dart';
import 'package:flutify_app/services/protocol/audio_cache_store.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/settings/sections/storage_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Picker extends FileSelectorPlatform {
  String? result;
  int calls = 0;
  bool fail = false;
  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    calls++;
    if (fail) throw StateError('picker unavailable');
    return result;
  }
}

void main() {
  late StorageService storage;
  late CacheLocation location;
  late Directory temp;
  late _Picker picker;
  late FileSelectorPlatform original;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.flutify/cache_directories'),
          (call) async => null,
        );
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.init();
    temp = await Directory.systemTemp.createTemp('flutify-cache-ui-');
    location = CacheLocation(storage.cache,
      p.join(temp.path, 'default'),
      applicationRoot: temp.path,
    );
    await location.initialize();
    original = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = picker = _Picker();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.flutify/cache_directories'),
          null,
        );
    FileSelectorPlatform.instance = original;
    location.dispose();
    await temp.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          Provider<PreferencesStore>.value(value: storage.preferences),
          Provider<CachePrefsStore>.value(value: storage.cache),
          ListenableProvider<CacheLocation?>.value(value: location),
          Provider<AudioCacheStore?>.value(value: null),
        ],
        child: MaterialApp(
          theme: MD3ETheme.light,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(child: StorageSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      '$platform hides locations while keeping clear and size controls',
      (tester) async {
        await pump(tester);
        expect(find.text('Audio cache location'), findsNothing);
        expect(find.text('Artwork cache location'), findsNothing);
        expect(find.text('Lyrics cache location'), findsNothing);
        expect(find.text('Clear all caches'), findsOneWidget);
        expect(find.text('512 MB'), findsOneWidget);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  Future<void> customDialog(WidgetTester tester) async {
    await tester.tap(find.text('Audio cache location'));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownMenu<CachePreset>), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cache-preset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom directory').last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'desktop native picker cancellation and errors preserve the path',
    (tester) async {
      await pump(tester);
      await customDialog(tester);
      final path = p.join(temp.path, 'chosen');
      await tester.enterText(
        find.byKey(const ValueKey('cache-custom-path')),
        path,
      );
      await tester.tap(find.text('Choose folder'));
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('cache-custom-path')))
            .controller!
            .text,
        path,
      );
      picker.fail = true;
      await tester.tap(find.text('Choose folder'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          "Couldn't open the folder picker. Try again or enter a path.",
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        location.selection(CacheCategory.audio).preset,
        CachePreset.appData,
      );
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'native folder selection migrates audio and removes the old cache',
    (tester) async {
      final old = File(p.join(location.audioPath, 'track.bin'));
      await tester.runAsync(() => old.writeAsString('cached audio'));
      await pump(tester);
      await customDialog(tester);
      picker.result = p.join(temp.path, 'new');
      await tester.tap(find.text('Choose folder'));
      await tester.pumpAndSettle();
      var migrated = false;
      void done() {
        migrated = true;
      }

      location.addListener(done);
      await tester.tap(find.text('Save'));
      // Disk futures and widget microtasks use different zones in widget tests.
      for (var i = 0; i < 200 && !migrated; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      location.removeListener(done);
      expect(migrated, isTrue);
      await tester.pumpAndSettle();
      expect(location.selection(CacheCategory.audio).customPath, picker.result);
      expect(await tester.runAsync(() => old.exists()), isFalse);
      expect(
        await tester.runAsync(
          () => File(p.join(location.audioPath, 'track.bin')).readAsString(),
        ),
        'cached audio',
      );
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
}
