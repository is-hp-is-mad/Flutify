import 'dart:typed_data';

import 'package:flutify_app/core/theme/artist_artwork_scheme.dart';
import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dark artist artwork with luminance <= 0.1 keeps its original color', () {
    const plum = Color(0xFF1F0F2B);
    expect(ArtistArtworkScheme.appleLuminance(plum), lessThanOrEqualTo(0.10));

    final scheme = ArtistArtworkScheme.from(plum);
    expect(scheme.backgroundColor, plum);
    expect(scheme.isDark, isTrue);
    expect(scheme.sourceIsLight, isFalse);
    expect(scheme.labelColor, const Color(0xFFFFFFFF));
  });

  test('white artwork subtracts lum * 0.6 per channel to #666666', () {
    final scheme = ArtistArtworkScheme.from(const Color(0xFFFFFFFF));

    // lum(white) = 1.0 -> channel = round((1.0 - 0.6) * 255) = 102 (0x66)
    expect(scheme.backgroundColor, const Color(0xFF666666));
    expect(scheme.isDark, isTrue);
    expect(scheme.sourceIsLight, isTrue);
    expect(scheme.labelColor, const Color(0xFFFFFFFF));
  });

  test('bright monochrome studio backdrop darkens to warm medium gray', () {
    const studioWall = Color(0xFFB2AFAD);
    final scheme = ArtistArtworkScheme.from(studioWall);

    expect(scheme.backgroundColor.r, closeTo(112 / 255, 0.02));
    expect(scheme.backgroundColor.g, closeTo(109 / 255, 0.02));
    expect(scheme.backgroundColor.b, closeTo(107 / 255, 0.02));
    expect(scheme.isDark, isTrue);
  });

  test('additive dark blend tints secondary labels and dividers with background', () {
    const crimson = Color(0xFF3A0C18);
    final scheme = ArtistArtworkScheme.from(crimson);

    expect(
      scheme.secondaryLabelColor.r,
      greaterThan(scheme.secondaryLabelColor.g),
    );
    expect(scheme.dividerColor.r, greaterThan(scheme.dividerColor.g));
  });

  test('parseHexColor accepts 6-digit, #6-digit and 8-digit hex strings', () {
    expect(
      ArtistArtworkScheme.parseHexColor('6b6968'),
      const Color(0xFF6B6968),
    );
    expect(
      ArtistArtworkScheme.parseHexColor('#1f0f2b'),
      const Color(0xFF1F0F2B),
    );
    expect(
      ArtistArtworkScheme.parseHexColor('ff223344'),
      const Color(0xFF223344),
    );
    expect(ArtistArtworkScheme.parseHexColor('invalid'), isNull);
    expect(ArtistArtworkScheme.parseHexColor(null), isNull);
  });

  test('hero gradient has 20 monotonic eased stops from transparent to solid', () {
    final scheme = ArtistArtworkScheme.from(const Color(0xFF2A1838));
    final colors = scheme.heroGradientColors;
    final stops = ArtistArtworkScheme.heroGradientStops;

    expect(colors, hasLength(20));
    expect(stops, hasLength(20));
    expect(colors.first.a, 0);
    expect(colors.last, scheme.backgroundColor);
    for (var i = 1; i < colors.length; i++) {
      expect(colors[i].a, greaterThanOrEqualTo(colors[i - 1].a));
    }
  });

  test('artistPhotoColor favors studio backdrop over center dark coat', () {
    const w = 16, h = 16;
    final bytes = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final centerCoat = x >= 5 && x <= 10 && y >= 4 && y <= 11;
        final offset = (y * w + x) * 4;
        bytes.setAll(
          offset,
          centerCoat ? [18, 18, 18, 255] : [214, 212, 210, 255],
        );
      }
    }
    final extracted = ArtworkPalette.artistPhotoColor(
      ByteData.sublistView(bytes),
      width: w,
      height: h,
    )!;
    expect(extracted.computeLuminance(), greaterThan(0.5));
  });
}
