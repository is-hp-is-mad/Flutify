import 'package:flutify_app/core/utils/formatters.dart';
import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('紧凑数字：简体 万 / 亿，繁体 萬 / 億，英文 K / M', () {
    final zh = lookupAppLocalizations(const Locale('zh'));
    final hant = lookupAppLocalizations(
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    );
    final en = lookupAppLocalizations(const Locale('en'));
    expect(Formatters.formatCompactNumber(zh, 12000), '1.2 万');
    expect(Formatters.formatCompactNumber(hant, 12000), '1.2 萬');
    expect(Formatters.formatCompactNumber(zh, 340000000), '3.4 亿');
    expect(Formatters.formatCompactNumber(hant, 340000000), '3.4 億');
    expect(Formatters.formatCompactNumber(en, 1200000), '1.2M');
  });
}
