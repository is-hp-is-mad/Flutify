import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../services/network/proxy_mode.dart';
import 'lyrics_source.dart';
import 'playback_state.dart' show SpotifyRepeatMode;
import '../services/network/spotify_gateway.dart';

/// 网络代理：跟随系统 / 不使用（直连）/ 手动指定 HTTP 代理。
/// ProxyMode 已移至 services/network/proxy_mode.dart（纯 Dart，供命令行探针复用），这里再导出保持兼容。
export '../services/network/proxy_mode.dart' show ProxyMode;
export 'lyrics_source.dart';

/// 界面语言：跟随系统 / 固定中文 / 固定英文。
enum AppLanguage { system, zh, zhHant, en, ja }

/// 启动时打开的页面；[last] 为上次关闭时所在的 Tab。
enum StartPage { home, library, last }

/// 歌词行的对齐方式。
enum LyricsAlign { left, center }

/// 任务栏歌词的文字颜色：自动（按任务栏背景明暗取黑 / 白）、白、黑、跟随强调色、自定义。
enum TaskbarLyricsColor { auto, white, black, accent, custom }

/// 连接蓝牙音频设备时把系统媒体信息换成当前歌词行（车机屏幕上显示歌词）。
/// - [off]：不替换；
/// - [car]：只对识别为车载（车载音响 / 免提）的设备，以及用户手动加入的设备替换；
/// - [all]：所有蓝牙音频设备都替换。
enum BluetoothLyricsMode { off, car, all }

/// 非外观类的界面偏好（外观见 `AppearanceSettings`，播放类偏好由 PlaybackProvider 持有）。
///
/// 不可变；整体序列化为一段 JSON 存在 `app_prefs` 键下。
/// 解析规则：缺失 / 类型不对 / 越界的字段一律回退到默认值并夹到合法范围，
/// 旧版本或手改坏的数据不会导致启动失败。
@immutable
class AppPreferences {
  final AppLanguage language;

  /// 歌词字号倍率（乘在各歌词视图自身的基准字号上）。
  final double lyricsScale;
  final LyricsAlign lyricsAlign;

  /// 当前歌词行顶端在可见歌词区域中的纵向比例，避开顶部 / 底部控件。
  final double lyricsFocusPosition;

  final StartPage startPage;

  /// 启动时的循环方式（无循环 / 列表循环 / 单曲循环）；覆盖上次会话里记下的循环状态。
  final SpotifyRepeatMode defaultRepeatMode;

  /// 桌面端：记住窗口大小与位置（含最大化状态）。
  final bool rememberWindow;

  /// 是否接入 Spotify Connect（关闭后不再显示 / 遥控其他设备）。
  final bool connectEnabled;

  /// 启动后即使未播放，也把本机当前曲目（暂停）同步给 Connect，让其他设备看到 Flutify 的状态。
  final bool connectReportOnLaunch;

  /// 本机在其他设备「设备列表」里显示的名字；空表示默认「Web Player」。
  final String connectDeviceName;

  /// 远程播放时歌词的提前量（毫秒）：正数让歌词更早切行，负数推迟。只影响歌词，不影响进度条。
  final int remoteLyricsLeadMs;

  /// 桌面曲目表格用紧凑视图（无封面、艺人单独一列、行更矮），在歌单页的「查看方式」里切换。
  final bool compactTrackList;

  /// 网络代理方式；[proxyHost] / [proxyPort] 只在 [ProxyMode.manual] 下使用（端口 0 表示未填写）。
  final ProxyMode proxyMode;
  final String proxyHost;
  final int proxyPort;
  final SpotifyGateway gateway;

  /// 手动代理的认证用户名（空表示代理不需要认证）；密码是敏感信息，单独存在
  /// StorageService 的 `sp_proxy_password` 键下，不进这份 JSON。
  final String proxyUsername;

  /// 登录 / 播放前的网络出口地区检测（检测到中国大陆就停下列表）。
  /// 默认开启；关闭后不再发起任何检测，也不拦截登录和播放。
  final bool regionCheckEnabled;

  /// 网络环境变动时自动复查出口地区（仅在 [regionCheckEnabled] 开启时有意义）。
  final bool regionCheckOnNetworkChange;

  /// 是否开启歌单备份功能（独立 WebView 多账号备份 + 本机账号自动备份落盘）。
  final bool backupEnabled;

  /// 开启歌单备份时，是否自动备份本机当前已登录的账号（且本机收藏改动立即落盘）。
  final bool backupAutoCurrentAccount;

  /// 多账号后台轮询备份间隔（分钟），最短 [minBackupIntervalMinutes]（20 分钟）防限流。
  final int backupIntervalMinutes;

  /// Spotify 没有逐行同步歌词（只有纯文本或完全没有）时，从 LRCLIB 补全。
  final bool lyricsFallback;

  /// 歌词来源优先级，始终包含 [LyricsSource.values] 里的每一项各一次。
  final List<LyricsSource> lyricsSourceOrder;
  final bool canvasEnabled;
  final List<String> lyricsExcludedLanguages;
  final bool lyricsExcludeInterfaceLanguage;
  final bool lyricsAutoTranslate;

  /// 双语歌词：在原文下方显示翻译（LRCLIB 对照版拆出的译文，或网易云社区翻译）。
  /// 默认关闭；开启后预取网易云译文。主动翻译 / 自动翻译仍可独立查询，会发送曲名与歌手。
  final bool lyricsBilingual;

  /// Windows：把当前歌词嵌入任务栏（天气小组件右侧）。
  final bool taskbarLyrics;
  final TaskbarLyricsColor taskbarLyricsColor;

  /// [TaskbarLyricsColor.custom] 时的颜色（ARGB）。
  final int taskbarLyricsCustomColor;

  /// 任务栏歌词文字整体不透明度（百分比，[minTaskbarLyricsOpacity] ~ 100）。
  final int taskbarLyricsOpacity;

  /// 任务栏歌词字号（百分比，[minTaskbarLyricsFontScale] ~ [maxTaskbarLyricsFontScale]）；
  /// 放不下时原生层仍会自动缩小或折行。
  final int taskbarLyricsFontScale;

  /// 蓝牙歌词（Android）：见 [BluetoothLyricsMode]。
  final BluetoothLyricsMode bluetoothLyrics;

  /// 蓝牙歌词附带译文（「原文 / 译文」）。
  final bool bluetoothLyricsTranslation;

  /// 手动加入蓝牙歌词的设备（蓝牙 MAC 地址）；[BluetoothLyricsMode.car] 下与自动识别的车载设备一起生效。
  final List<String> bluetoothLyricsDevices;

  /// 魅族 Flyme 状态栏歌词（Android，仅 Flyme 系统生效）。
  final bool flymeStatusBarLyrics;

  /// 本机音频输出设备 id；空串为跟随系统默认设备。
  final String audioOutputDevice;

  const AppPreferences({
    this.language = AppLanguage.zh,
    this.lyricsScale = 1.0,
    this.lyricsAlign = LyricsAlign.left,
    this.lyricsFocusPosition = 0.16,
    this.startPage = StartPage.home,
    this.defaultRepeatMode = SpotifyRepeatMode.off,
    this.rememberWindow = true,
    this.connectEnabled = true,
    this.connectReportOnLaunch = false,
    this.connectDeviceName = '',
    this.remoteLyricsLeadMs = 0,
    this.compactTrackList = false,
    this.proxyMode = ProxyMode.system,
    this.proxyHost = '',
    this.proxyPort = 0,
    this.gateway = const SpotifyGateway(),
    this.proxyUsername = '',
    this.regionCheckEnabled = true,
    this.regionCheckOnNetworkChange = true,
    this.backupEnabled = false,
    this.backupAutoCurrentAccount = true,
    this.backupIntervalMinutes = defaultBackupIntervalMinutes,
    this.lyricsFallback = true,
    this.lyricsSourceOrder = LyricsSource.defaultOrder,
    this.canvasEnabled = true,
    this.lyricsExcludedLanguages = const [],
    this.lyricsExcludeInterfaceLanguage = true,
    this.lyricsAutoTranslate = true,
    this.lyricsBilingual = false,
    this.taskbarLyrics = false,
    this.taskbarLyricsColor = TaskbarLyricsColor.auto,
    this.taskbarLyricsCustomColor = defaultTaskbarLyricsCustomColor,
    this.taskbarLyricsOpacity = 100,
    this.taskbarLyricsFontScale = 100,
    this.bluetoothLyrics = BluetoothLyricsMode.off,
    this.bluetoothLyricsTranslation = false,
    this.bluetoothLyricsDevices = const [],
    this.flymeStatusBarLyrics = false,
    this.audioOutputDevice = '',
  });

  static const AppPreferences defaults = AppPreferences();

  static const double minLyricsScale = 0.8;
  static const double maxLyricsScale = 1.4;
  static const double minLyricsFocusPosition = 0.10;
  static const double maxLyricsFocusPosition = 0.70;
  static const int maxRemoteLyricsLeadMs = 2000;
  static const int minTaskbarLyricsOpacity = 15;
  static const int defaultTaskbarLyricsCustomColor = 0xFF1ED760;
  static const int minTaskbarLyricsFontScale = 80;
  static const int maxTaskbarLyricsFontScale = 130;
  static const int minBackupIntervalMinutes = 20;
  static const int maxBackupIntervalMinutes = 1440;
  static const int defaultBackupIntervalMinutes = 60;
  static const List<int> backupIntervalOptions = [20, 60, 120, 720, 1440];

  AppPreferences copyWith({
    AppLanguage? language,
    double? lyricsScale,
    LyricsAlign? lyricsAlign,
    double? lyricsFocusPosition,
    StartPage? startPage,
    SpotifyRepeatMode? defaultRepeatMode,
    bool? rememberWindow,
    bool? connectEnabled,
    bool? connectReportOnLaunch,
    String? connectDeviceName,
    int? remoteLyricsLeadMs,
    bool? compactTrackList,
    ProxyMode? proxyMode,
    String? proxyHost,
    int? proxyPort,
    SpotifyGateway? gateway,
    String? proxyUsername,
    bool? regionCheckEnabled,
    bool? regionCheckOnNetworkChange,
    bool? backupEnabled,
    bool? backupAutoCurrentAccount,
    int? backupIntervalMinutes,
    bool? lyricsFallback,
    List<LyricsSource>? lyricsSourceOrder,
    bool? canvasEnabled,
    List<String>? lyricsExcludedLanguages,
    bool? lyricsExcludeInterfaceLanguage,
    bool? lyricsAutoTranslate,
    bool? lyricsBilingual,
    bool? taskbarLyrics,
    TaskbarLyricsColor? taskbarLyricsColor,
    int? taskbarLyricsCustomColor,
    int? taskbarLyricsOpacity,
    int? taskbarLyricsFontScale,
    BluetoothLyricsMode? bluetoothLyrics,
    bool? bluetoothLyricsTranslation,
    List<String>? bluetoothLyricsDevices,
    bool? flymeStatusBarLyrics,
    String? audioOutputDevice,
  }) {
    return AppPreferences(
      language: language ?? this.language,
      lyricsScale: lyricsScale ?? this.lyricsScale,
      lyricsAlign: lyricsAlign ?? this.lyricsAlign,
      lyricsFocusPosition: lyricsFocusPosition ?? this.lyricsFocusPosition,
      startPage: startPage ?? this.startPage,
      defaultRepeatMode: defaultRepeatMode ?? this.defaultRepeatMode,
      rememberWindow: rememberWindow ?? this.rememberWindow,
      connectEnabled: connectEnabled ?? this.connectEnabled,
      connectReportOnLaunch:
          connectReportOnLaunch ?? this.connectReportOnLaunch,
      connectDeviceName: connectDeviceName ?? this.connectDeviceName,
      remoteLyricsLeadMs: remoteLyricsLeadMs ?? this.remoteLyricsLeadMs,
      compactTrackList: compactTrackList ?? this.compactTrackList,
      proxyMode: proxyMode ?? this.proxyMode,
      proxyHost: proxyHost ?? this.proxyHost,
      proxyPort: proxyPort ?? this.proxyPort,
      gateway: gateway ?? this.gateway,
      proxyUsername: proxyUsername ?? this.proxyUsername,
      regionCheckEnabled: regionCheckEnabled ?? this.regionCheckEnabled,
      regionCheckOnNetworkChange:
          regionCheckOnNetworkChange ?? this.regionCheckOnNetworkChange,
      backupEnabled: backupEnabled ?? this.backupEnabled,
      backupAutoCurrentAccount:
          backupAutoCurrentAccount ?? this.backupAutoCurrentAccount,
      backupIntervalMinutes: backupIntervalMinutes != null
          ? backupIntervalMinutes.clamp(
              minBackupIntervalMinutes,
              maxBackupIntervalMinutes,
            )
          : this.backupIntervalMinutes,
      lyricsFallback: lyricsFallback ?? this.lyricsFallback,
      lyricsSourceOrder: lyricsSourceOrder == null
          ? this.lyricsSourceOrder
          : LyricsSource.parseOrder(
              lyricsSourceOrder.map((s) => s.name).toList(),
            ),
      canvasEnabled: canvasEnabled ?? this.canvasEnabled,
      lyricsExcludedLanguages:
          lyricsExcludedLanguages ?? this.lyricsExcludedLanguages,
      lyricsExcludeInterfaceLanguage:
          lyricsExcludeInterfaceLanguage ?? this.lyricsExcludeInterfaceLanguage,
      lyricsAutoTranslate: lyricsAutoTranslate ?? this.lyricsAutoTranslate,
      lyricsBilingual: lyricsBilingual ?? this.lyricsBilingual,
      taskbarLyrics: taskbarLyrics ?? this.taskbarLyrics,
      taskbarLyricsColor: taskbarLyricsColor ?? this.taskbarLyricsColor,
      taskbarLyricsCustomColor:
          taskbarLyricsCustomColor ?? this.taskbarLyricsCustomColor,
      taskbarLyricsOpacity: taskbarLyricsOpacity ?? this.taskbarLyricsOpacity,
      taskbarLyricsFontScale:
          taskbarLyricsFontScale ?? this.taskbarLyricsFontScale,
      bluetoothLyrics: bluetoothLyrics ?? this.bluetoothLyrics,
      bluetoothLyricsTranslation:
          bluetoothLyricsTranslation ?? this.bluetoothLyricsTranslation,
      bluetoothLyricsDevices:
          bluetoothLyricsDevices ?? this.bluetoothLyricsDevices,
      flymeStatusBarLyrics: flymeStatusBarLyrics ?? this.flymeStatusBarLyrics,
      audioOutputDevice: audioOutputDevice ?? this.audioOutputDevice,
    );
  }

  Map<String, dynamic> toJson() => {
    'language': language.name,
    'lyricsScale': lyricsScale,
    'lyricsAlign': lyricsAlign.name,
    'lyricsFocusPosition': lyricsFocusPosition,
    'startPage': startPage.name,
    'defaultRepeatMode': defaultRepeatMode.name,
    'rememberWindow': rememberWindow,
    'connectEnabled': connectEnabled,
    'connectReportOnLaunch': connectReportOnLaunch,
    'connectDeviceName': connectDeviceName,
    'remoteLyricsLeadMs': remoteLyricsLeadMs,
    'compactTrackList': compactTrackList,
    'proxyMode': proxyMode.name,
    'proxyHost': proxyHost,
    'proxyPort': proxyPort,
    'gateway': gateway.toJson(),
    'proxyUsername': proxyUsername,
    'regionCheckEnabled': regionCheckEnabled,
    'regionCheckOnNetworkChange': regionCheckOnNetworkChange,
    'backupEnabled': backupEnabled,
    'backupAutoCurrentAccount': backupAutoCurrentAccount,
    'backupIntervalMinutes': backupIntervalMinutes,
    'lyricsFallback': lyricsFallback,
    'lyricsSourceOrder': [for (final s in lyricsSourceOrder) s.name],
    'canvasEnabled': canvasEnabled,
    'lyricsExcludedLanguages': lyricsExcludedLanguages,
    'lyricsExcludeInterfaceLanguage': lyricsExcludeInterfaceLanguage,
    'lyricsAutoTranslate': lyricsAutoTranslate,
    'lyricsBilingual': lyricsBilingual,
    'taskbarLyrics': taskbarLyrics,
    'taskbarLyricsColor': taskbarLyricsColor.name,
    'taskbarLyricsCustomColor': taskbarLyricsCustomColor,
    'taskbarLyricsOpacity': taskbarLyricsOpacity,
    'taskbarLyricsFontScale': taskbarLyricsFontScale,
    'bluetoothLyrics': bluetoothLyrics.name,
    'bluetoothLyricsTranslation': bluetoothLyricsTranslation,
    'bluetoothLyricsDevices': bluetoothLyricsDevices,
    'flymeStatusBarLyrics': flymeStatusBarLyrics,
    'audioOutputDevice': audioOutputDevice,
  };

  factory AppPreferences.fromJson(Map<String, dynamic> json) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    double number(Object? v, double fallback, double min, double max) =>
        v is num && v.isFinite ? v.toDouble().clamp(min, max) : fallback;
    bool flag(Object? v, bool fallback) => v is bool ? v : fallback;

    const d = defaults;
    final lead = json['remoteLyricsLeadMs'];
    final port = json['proxyPort'];
    final customColor = json['taskbarLyricsCustomColor'];
    final opacity = json['taskbarLyricsOpacity'];
    final fontScale = json['taskbarLyricsFontScale'];
    final backupInterval = json['backupIntervalMinutes'];
    return AppPreferences(
      language: pick(AppLanguage.values, json['language'], d.language),
      lyricsScale: number(
        json['lyricsScale'],
        d.lyricsScale,
        minLyricsScale,
        maxLyricsScale,
      ),
      lyricsAlign: pick(LyricsAlign.values, json['lyricsAlign'], d.lyricsAlign),
      lyricsFocusPosition: number(
        json['lyricsFocusPosition'],
        d.lyricsFocusPosition,
        minLyricsFocusPosition,
        maxLyricsFocusPosition,
      ),
      startPage: pick(StartPage.values, json['startPage'], d.startPage),
      defaultRepeatMode: pick(
        SpotifyRepeatMode.values,
        json['defaultRepeatMode'],
        d.defaultRepeatMode,
      ),
      rememberWindow: flag(json['rememberWindow'], d.rememberWindow),
      connectEnabled: flag(json['connectEnabled'], d.connectEnabled),
      connectReportOnLaunch: flag(
        json['connectReportOnLaunch'],
        d.connectReportOnLaunch,
      ),
      connectDeviceName: json['connectDeviceName'] is String
          ? (json['connectDeviceName'] as String).trim()
          : d.connectDeviceName,
      remoteLyricsLeadMs: lead is int
          ? lead.clamp(-maxRemoteLyricsLeadMs, maxRemoteLyricsLeadMs)
          : 0,
      compactTrackList: flag(json['compactTrackList'], d.compactTrackList),
      proxyMode: pick(ProxyMode.values, json['proxyMode'], d.proxyMode),
      proxyHost: json['proxyHost'] is String
          ? (json['proxyHost'] as String).trim()
          : d.proxyHost,
      proxyPort: port is int && port > 0 && port <= 65535 ? port : d.proxyPort,
      gateway: SpotifyGateway.fromJson(json['gateway']),
      proxyUsername: json['proxyUsername'] is String
          ? (json['proxyUsername'] as String).trim()
          : d.proxyUsername,
      regionCheckEnabled: flag(
        json['regionCheckEnabled'],
        d.regionCheckEnabled,
      ),
      regionCheckOnNetworkChange: flag(
        json['regionCheckOnNetworkChange'],
        d.regionCheckOnNetworkChange,
      ),
      backupEnabled: flag(json['backupEnabled'], d.backupEnabled),
      backupAutoCurrentAccount: flag(
        json['backupAutoCurrentAccount'],
        d.backupAutoCurrentAccount,
      ),
      backupIntervalMinutes: backupInterval is int
          ? backupInterval.clamp(
              minBackupIntervalMinutes,
              maxBackupIntervalMinutes,
            )
          : d.backupIntervalMinutes,
      lyricsFallback: flag(json['lyricsFallback'], d.lyricsFallback),
      lyricsSourceOrder: LyricsSource.parseOrder(json['lyricsSourceOrder']),
      canvasEnabled: flag(json['canvasEnabled'], d.canvasEnabled),
      lyricsExcludedLanguages: json['lyricsExcludedLanguages'] is List
          ? List.unmodifiable(
              (json['lyricsExcludedLanguages'] as List)
                  .whereType<String>()
                  .map((v) => v.trim().replaceAll('_', '-'))
                  .where(
                    (v) => RegExp(
                      r'^[a-zA-Z]{2,3}(?:-[a-zA-Z]{2,4})?$',
                    ).hasMatch(v),
                  )
                  .toSet(),
            )
          : d.lyricsExcludedLanguages,
      lyricsExcludeInterfaceLanguage: flag(
        json['lyricsExcludeInterfaceLanguage'],
        d.lyricsExcludeInterfaceLanguage,
      ),
      lyricsAutoTranslate: flag(
        json['lyricsAutoTranslate'],
        d.lyricsAutoTranslate,
      ),
      lyricsBilingual: flag(json['lyricsBilingual'], d.lyricsBilingual),
      taskbarLyrics: flag(json['taskbarLyrics'], d.taskbarLyrics),
      taskbarLyricsColor: pick(
        TaskbarLyricsColor.values,
        json['taskbarLyricsColor'],
        d.taskbarLyricsColor,
      ),
      // 只认不透明颜色：自定义色存的总是 0xFFxxxxxx
      taskbarLyricsCustomColor:
          customColor is int && customColor >= 0 && customColor <= 0xFFFFFFFF
          ? 0xFF000000 | customColor
          : d.taskbarLyricsCustomColor,
      taskbarLyricsOpacity: opacity is int
          ? opacity.clamp(minTaskbarLyricsOpacity, 100)
          : d.taskbarLyricsOpacity,
      taskbarLyricsFontScale: fontScale is int
          ? fontScale.clamp(
              minTaskbarLyricsFontScale,
              maxTaskbarLyricsFontScale,
            )
          : d.taskbarLyricsFontScale,
      bluetoothLyrics: pick(
        BluetoothLyricsMode.values,
        json['bluetoothLyrics'],
        d.bluetoothLyrics,
      ),
      bluetoothLyricsTranslation: flag(
        json['bluetoothLyricsTranslation'],
        d.bluetoothLyricsTranslation,
      ),
      bluetoothLyricsDevices: json['bluetoothLyricsDevices'] is List
          ? List.unmodifiable(
              (json['bluetoothLyricsDevices'] as List)
                  .whereType<String>()
                  .where((v) => v.isNotEmpty)
                  .toSet(),
            )
          : d.bluetoothLyricsDevices,
      flymeStatusBarLyrics: flag(
        json['flymeStatusBarLyrics'],
        d.flymeStatusBarLyrics,
      ),
      audioOutputDevice: json['audioOutputDevice'] is String
          ? json['audioOutputDevice'] as String
          : d.audioOutputDevice,
    );
  }

  /// 从持久化字符串解析；空串或损坏时返回默认值。
  factory AppPreferences.decode(String raw) {
    if (raw.isEmpty) return defaults;
    try {
      final json = jsonDecode(raw);
      return json is Map<String, dynamic>
          ? AppPreferences.fromJson(json)
          : defaults;
    } catch (_) {
      return defaults;
    }
  }

  String encode() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is AppPreferences &&
      other.language == language &&
      other.lyricsScale == lyricsScale &&
      other.lyricsAlign == lyricsAlign &&
      other.lyricsFocusPosition == lyricsFocusPosition &&
      other.startPage == startPage &&
      other.defaultRepeatMode == defaultRepeatMode &&
      other.rememberWindow == rememberWindow &&
      other.connectEnabled == connectEnabled &&
      other.connectReportOnLaunch == connectReportOnLaunch &&
      other.connectDeviceName == connectDeviceName &&
      other.remoteLyricsLeadMs == remoteLyricsLeadMs &&
      other.compactTrackList == compactTrackList &&
      other.proxyMode == proxyMode &&
      other.proxyHost == proxyHost &&
      other.proxyPort == proxyPort &&
      other.gateway == gateway &&
      other.proxyUsername == proxyUsername &&
      other.regionCheckEnabled == regionCheckEnabled &&
      other.regionCheckOnNetworkChange == regionCheckOnNetworkChange &&
      other.backupEnabled == backupEnabled &&
      other.backupAutoCurrentAccount == backupAutoCurrentAccount &&
      other.backupIntervalMinutes == backupIntervalMinutes &&
      other.lyricsFallback == lyricsFallback &&
      listEquals(other.lyricsSourceOrder, lyricsSourceOrder) &&
      other.canvasEnabled == canvasEnabled &&
      listEquals(other.lyricsExcludedLanguages, lyricsExcludedLanguages) &&
      other.lyricsExcludeInterfaceLanguage == lyricsExcludeInterfaceLanguage &&
      other.lyricsAutoTranslate == lyricsAutoTranslate &&
      other.lyricsBilingual == lyricsBilingual &&
      other.taskbarLyrics == taskbarLyrics &&
      other.taskbarLyricsColor == taskbarLyricsColor &&
      other.taskbarLyricsCustomColor == taskbarLyricsCustomColor &&
      other.taskbarLyricsOpacity == taskbarLyricsOpacity &&
      other.taskbarLyricsFontScale == taskbarLyricsFontScale &&
      other.bluetoothLyrics == bluetoothLyrics &&
      other.bluetoothLyricsTranslation == bluetoothLyricsTranslation &&
      listEquals(other.bluetoothLyricsDevices, bluetoothLyricsDevices) &&
      other.flymeStatusBarLyrics == flymeStatusBarLyrics &&
      other.audioOutputDevice == audioOutputDevice;

  @override
  int get hashCode => Object.hashAll([
    language,
    lyricsScale,
    lyricsAlign,
    lyricsFocusPosition,
    startPage,
    defaultRepeatMode,
    rememberWindow,
    connectEnabled,
    connectReportOnLaunch,
    connectDeviceName,
    remoteLyricsLeadMs,
    compactTrackList,
    proxyMode,
    proxyHost,
    proxyPort,
    gateway,
    proxyUsername,
    regionCheckEnabled,
    regionCheckOnNetworkChange,
    backupEnabled,
    backupAutoCurrentAccount,
    backupIntervalMinutes,
    lyricsFallback,
    Object.hashAll(lyricsSourceOrder),
    canvasEnabled,
    Object.hashAll(lyricsExcludedLanguages),
    lyricsExcludeInterfaceLanguage,
    lyricsAutoTranslate,
    lyricsBilingual,
    taskbarLyrics,
    taskbarLyricsColor,
    taskbarLyricsCustomColor,
    taskbarLyricsOpacity,
    taskbarLyricsFontScale,
    bluetoothLyrics,
    bluetoothLyricsTranslation,
    Object.hashAll(bluetoothLyricsDevices),
    flymeStatusBarLyrics,
    audioOutputDevice,
  ]);
}
