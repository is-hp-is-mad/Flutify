import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../models/app_preferences.dart';
import 'app_localizations.dart';

/// App 语言配置（MaterialApp 使用）。
///
/// 规则：
/// * 默认简体中文；可选繁体中文、英文、日语或跟随系统（[localeFor]）。
///   跟随系统时识别中文脚本及地区；不支持的语言回退到简体中文。
/// * Global*Localizations 让系统组件（日期选择器、文本选择菜单、Tooltip、返回按钮等）同样随之切换。
/// * 实际生效的语言由 [resolved] 回写，决定请求 Spotify 时的 Accept-Language。
class AppLocale {
  AppLocale._();

  /// 偏好对应的固定语言；跟随系统时返回 null，交给 MaterialApp 按系统语言解析。
  static Locale? localeFor(AppLanguage language) => switch (language) {
    AppLanguage.system => null,
    AppLanguage.zh => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hans',
    ),
    AppLanguage.zhHant => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
    ),
    AppLanguage.en => const Locale('en'),
    AppLanguage.ja => const Locale('ja'),
  };

  static String _spotifyLanguage = 'zh-CN';

  /// 请求 Spotify 接口时的 Accept-Language：zh-CN 简体、zh-TW 繁体、en 英文、ja 日语。
  /// 服务端据此本地化主页问候语、分区标题、筛选标签等文案。
  static String get spotifyLanguage => _spotifyLanguage;

  /// 界面实际使用的语言确定后调用（MaterialApp.builder 内）；返回值表示是否发生了变化。
  static bool resolved(Locale locale) {
    final traditional =
        locale.scriptCode == 'Hant' ||
        const ['TW', 'HK', 'MO'].contains(locale.countryCode);
    final next = locale.languageCode == 'zh'
        ? (traditional ? 'zh-TW' : 'zh-CN')
        : locale.languageCode == 'ja'
        ? 'ja'
        : 'en';
    if (next == _spotifyLanguage) return false;
    _spotifyLanguage = next;
    return true;
  }

  /// 支持的全部语言（与生成的 AppLocalizations 一致）；zh 在前，系统语言都不匹配时回退到中文。
  static const List<Locale> supportedLocales = [
    Locale('zh'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
      countryCode: 'TW',
    ),
    Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
      countryCode: 'HK',
    ),
    Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
      countryCode: 'MO',
    ),
    Locale('en'),
    Locale('ja'),
  ];

  /// App 文案 + Material / Cupertino / Widgets 系统文案。
  static const List<LocalizationsDelegate<dynamic>> delegates = [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];
}
