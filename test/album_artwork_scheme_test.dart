import 'dart:typed_data';

import 'package:flutify_app/core/theme/album_artwork_scheme.dart';
import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/models/appearance.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Color gray(int level) => Color.fromARGB(255, level, level, level);

  test('gray 175 is a dark cover and gray 176 is a light cover', () {
    final dark = AlbumArtworkScheme.from(gray(175));
    final light = AlbumArtworkScheme.from(gray(176));

    expect(dark.isDark, isTrue);
    expect(dark.foreground, const Color(0xFFFFFFFF));
    expect(light.isDark, isFalse);
    expect(light.foreground, const Color(0xFF000000));
  });

  test('black uses the Apple Music 7.0 dark lightness floor', () {
    final scheme = AlbumArtworkScheme.from(const Color(0xFF000000));

    expect(scheme.isDark, isTrue);
    expect(scheme.foreground, const Color(0xFFFFFFFF));
    expect(
      albumOklchLightness(scheme.darkBackground),
      greaterThanOrEqualTo(0.18 - 0.01),
    );
    expect(scheme.darkBackground, isNot(const Color(0xFF000000)));
    expect(albumOklchLightness(scheme.darkBackground), lessThanOrEqualTo(0.30));
    expect(albumOklchChroma(scheme.darkBackground), lessThanOrEqualTo(0.125));
    expect(scheme.forBrightness(Brightness.dark), scheme.darkBackground);
    expect(scheme.forBrightness(Brightness.light), scheme.lightBackground);
  });

  test('white uses black text', () {
    final scheme = AlbumArtworkScheme.from(const Color(0xFFFFFFFF));

    expect(scheme.isDark, isFalse);
    expect(scheme.foreground, const Color(0xFF000000));
  });

  test('a vivid cover keeps the light floor and the dark caps', () {
    final scheme = AlbumArtworkScheme.from(const Color(0xFFFF2200));

    expect(
      albumOklchLightness(scheme.lightBackground),
      greaterThanOrEqualTo(0.18 - 0.01),
    );
    // 转回 sRGB 再读 OKLCH 会有一点色域误差。
    expect(
      albumOklchLightness(scheme.darkBackground),
      lessThanOrEqualTo(0.30 + 0.02),
    );
    expect(
      albumOklchChroma(scheme.darkBackground),
      lessThanOrEqualTo(0.125 + 0.02),
    );
  });

  test('section background subtracts 4% toward black', () {
    const page = Color(0xFF808080);
    final scheme = AlbumArtworkScheme.from(page);

    expect(scheme.sectionBackground(page).toARGB32(), 0xFF757575);
    expect(
      AlbumArtworkScheme.mixTowardBlack(const Color(0xFFFFFFFF)).toARGB32(),
      0xFFF4F4F4,
    );
  });

  test('missing increaseContrast stays off and round-trips', () {
    expect(AppearanceSettings.fromJson(const {}).increaseContrast, isFalse);
    expect(
      AppearanceSettings.fromJson(const {
        'increaseContrast': 'yes',
      }).increaseContrast,
      isFalse,
    );

    const on = AppearanceSettings(increaseContrast: true);
    expect(AppearanceSettings.fromJson(on.toJson()).increaseContrast, isTrue);
    expect(AppearanceSettings.fromJson(on.toJson()), on);
  });

  test(
    'resolveDominant returns an injected color while extraction is off',
    () async {
      ArtworkPalette.enabled = false;
      addTearDown(ArtworkPalette.clear);
      ArtworkPalette.debugDominantOverrides['https://cover'] = const Color(
        0xFF112233,
      );

      expect(
        await ArtworkPalette.resolveDominant('https://cover'),
        const Color(0xFF112233),
      );
      expect(await ArtworkPalette.resolveDominant(''), isNull);
      expect(await ArtworkPalette.resolve('https://cover'), isNull);
    },
  );

  /// 人物暗部占 75%，橙红背景占 25% 的封面。
  ByteData portraitCover() {
    final bytes = Uint8List(64 * 4);
    for (var i = 0; i < 64; i++) {
      final foreground = i < 48;
      bytes.setAll(i * 4, foreground ? [28, 25, 24, 255] : [224, 112, 72, 255]);
    }
    return ByteData.sublistView(bytes);
  }

  test(
    'cover source keeps its theme color with a large dark foreground',
    () async {
      final color = await ArtworkPalette.dominantColor(portraitCover());

      expect(color, isNotNull);
      expect(color!.r, greaterThan(color.g * 1.4));
      expect(color.g, greaterThan(color.b));
      expect(color.b, lessThan(0.35));
    },
  );

  test(
    'monochrome cover uses its real color instead of a blue fallback',
    () async {
      final bytes = Uint8List(16 * 4);
      for (var i = 0; i < 16; i++) {
        bytes.setAll(i * 4, [32, 32, 32, 255]);
      }

      final color = await ArtworkPalette.dominantColor(
        ByteData.sublistView(bytes),
      );

      expect(color, isNotNull);
      expect(color!.r, moreOrLessEquals(color.g, epsilon: 0.01));
      expect(color.g, moreOrLessEquals(color.b, epsilon: 0.01));
      expect(color.r, lessThan(0.25));
    },
  );

  test('fully transparent cover has no source color', () async {
    final color = await ArtworkPalette.dominantColor(
      ByteData.sublistView(Uint8List(16 * 4)),
    );

    expect(color, isNull);
  });

  test('page text follows the background actually shown', () {
    // 浅色封面在深色主题下被压暗：字必须换成白色
    final scheme = AlbumArtworkScheme.from(const Color(0xFFF2E6A0));
    expect(scheme.foreground, const Color(0xFF000000));
    expect(scheme.foregroundFor(Brightness.dark), const Color(0xFFFFFFFF));
    expect(scheme.foregroundFor(Brightness.light), const Color(0xFF000000));
    expect(
      AlbumArtworkScheme.onColor(const Color(0xFF101010)),
      const Color(0xFFFFFFFF),
    );
    expect(
      AlbumArtworkScheme.onColor(const Color(0xFFF0F0F0)),
      const Color(0xFF000000),
    );
  });
}
