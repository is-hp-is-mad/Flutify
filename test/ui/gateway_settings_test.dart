import 'dart:async';

import 'package:flutify_app/core/theme/md3e_theme.dart';
import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/providers/preferences_provider.dart';
import 'package:flutify_app/services/network/network_proxy.dart';
import 'package:flutify_app/services/network/spotify_gateway.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/settings/widgets/gateway_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EDialog, M3ESwitch;

const _gateway = SpotifyGateway(
  baseUrl: 'https://gateway.example/assets-test',
  username: 'user',
  password: 'pass',
);

void main() {
  late StorageService storage;
  late PreferencesProvider prefs;
  late NetworkProxy proxy;
  var country = 'CN';
  var offline = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.init();
    await storage.setPreferencesJson(
      const AppPreferences(gateway: _gateway).encode(),
    );
    prefs = PreferencesProvider(storage);
    country = 'CN';
    offline = false;
    proxy = NetworkProxy(
      countryReader: () async {
        if (offline) throw StateError('offline');
        return country;
      },
    );
    prefs.addListener(
      () => unawaited(
        proxy.configure(mode: ProxyMode.none, gateway: prefs.prefs.gateway),
      ),
    );
  });
  tearDown(() => prefs.dispose());

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PreferencesProvider>.value(value: prefs),
          Provider<NetworkProxy?>.value(value: proxy),
        ],
        child: MaterialApp(
          theme: MD3ETheme.light,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: GatewaySettings(onChanged: () {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> editAutomatic(WidgetTester tester) async {
    await tester.tap(find.text('Spotify gateway'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'country allowlist validates, persists and drives the displayed route',
    (tester) async {
      await pump(tester);
      await editAutomatic(tester);
      final codes = find.byKey(const ValueKey('gateway-countries'));
      await tester.enterText(codes, 'USA');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Use two-letter country/region codes, for example US, JP, HK.',
        ),
        findsOneWidget,
      );
      expect(prefs.prefs.gateway.automatic, isFalse);
      await tester.enterText(codes, 'us jp，US');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final saved = AppPreferences.decode(storage.preferencesJson).gateway;
      expect(saved.automatic, isTrue);
      expect(saved.directCountries, 'JP, US');
      expect(
        find.text('Network country/region: CN · Gateway enabled'),
        findsOneWidget,
      );
      expect(tester.widget<M3ESwitch>(find.byType(M3ESwitch)).onChanged, isNull);
      country = 'JP';
      await tester.tap(find.byTooltip('Check country/region again'));
      await tester.pumpAndSettle();
      expect(
        find.text('Network country/region: JP · Direct connection'),
        findsOneWidget,
      );
      offline = true;
      await tester.tap(find.byTooltip('Check country/region again'));
      await tester.pumpAndSettle();
      expect(
        find.text('Country/region lookup failed; keeping the current route.'),
        findsOneWidget,
      );
      expect(tester.widget<M3ESwitch>(find.byType(M3ESwitch)).value, isFalse);
    },
  );

  testWidgets('cancelling an automatic edit leaves settings unchanged', (
    tester,
  ) async {
    await pump(tester);
    await editAutomatic(tester);
    await tester.enterText(
      find.byKey(const ValueKey('gateway-countries')),
      'JP',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(prefs.prefs.gateway, _gateway);
    expect(AppPreferences.decode(storage.preferencesJson).gateway, _gateway);
  });

  testWidgets('turning automatic off ignores a hidden invalid country edit', (
    tester,
  ) async {
    await pump(tester);
    await editAutomatic(tester);
    await tester.enterText(
      find.byKey(const ValueKey('gateway-countries')),
      'USA',
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(M3EDialog), findsNothing);
    expect(prefs.prefs.gateway, _gateway);
  });
}
