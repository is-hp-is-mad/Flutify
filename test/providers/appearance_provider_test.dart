import 'package:flutify_app/models/appearance.dart';
import 'package:flutify_app/providers/appearance_provider.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<StorageService> freshStorage([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    return StorageService.init();
  }

  test('settings survive a restart', () async {
    final storage = await freshStorage();
    final provider = AppearanceProvider(storage);
    provider.update(provider.settings.copyWith(
      themeMode: ThemeMode.dark,
      accent: AccentPreset.violet.color,
      cornerStyle: CornerStyle.rounded,
      fontScale: 1.15,
    ));
    provider.dispose(); // dispose 会把防抖中的修改立即落盘

    final restored = AppearanceProvider(storage).settings;
    expect(restored.themeMode, ThemeMode.dark);
    expect(restored.accent, AccentPreset.violet.color);
    expect(restored.cornerStyle, CornerStyle.rounded);
    expect(restored.fontScale, 1.15);
  });

  test('corrupt or partial storage falls back to defaults field by field', () async {
    final storage = await freshStorage({'ui_appearance': '{"themeMode":"nope","glassBlur":7,"pureBlack":true}'});
    final s = AppearanceProvider(storage).settings;
    expect(s.themeMode, AppearanceSettings.defaults.themeMode);
    expect(s.glassBlur, 1.0); // 越界值被夹到 0~1
    expect(s.pureBlack, isTrue);

    final broken = await freshStorage({'ui_appearance': 'not json'});
    expect(AppearanceProvider(broken).settings, AppearanceSettings.defaults);
  });

  test('glass material persists and old or unknown values fall back to liquid glass', () async {
    final storage = await freshStorage();
    final provider = AppearanceProvider(storage);
    provider.update(provider.settings.copyWith(glassMaterial: GlassMaterial.hyper));
    provider.dispose();
    expect(AppearanceProvider(storage).settings.glassMaterial, GlassMaterial.hyper);

    final old = await freshStorage({'ui_appearance': '{"glassBlur":0.4}'});
    expect(AppearanceProvider(old).settings.glassMaterial, GlassMaterial.liquid);
    final unknown = await freshStorage({'ui_appearance': '{"glassMaterial":"chrome"}'});
    expect(AppearanceProvider(unknown).settings.glassMaterial, GlassMaterial.liquid);
  });

  test('dynamic accent uses the artwork colour only when enabled', () async {
    final provider = AppearanceProvider(await freshStorage());
    provider.setArtworkColor(const Color(0xFF203080));
    expect(provider.accent, AppearanceSettings.defaults.accent);

    provider.update(provider.settings.copyWith(dynamicAccent: true));
    expect(provider.accent, isNot(AppearanceSettings.defaults.accent));

    provider.setArtworkColor(null);
    expect(provider.accent, AppearanceSettings.defaults.accent);
    provider.dispose();
  });

  test('theme reflects pure black and accent', () async {
    final provider = AppearanceProvider(await freshStorage());
    provider.update(provider.settings.copyWith(pureBlack: true, accent: AccentPreset.ocean.color));
    final dark = provider.theme(Brightness.dark);
    expect(dark.colorScheme.surface, Colors.black);
    expect(dark.colorScheme.primary, isNot(AccentPreset.spotify.color));
    provider.dispose();
  });
}
