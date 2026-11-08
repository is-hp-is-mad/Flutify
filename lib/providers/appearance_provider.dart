import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/theme/accent_colors.dart';
import '../core/theme/md3e_theme.dart';
import '../models/appearance.dart';
import '../services/storage_service.dart';

/// 外观设置：主题模式、强调色、动态取色、液态玻璃、纯黑、字号、圆角、减弱动效。
///
/// - 修改立即通知（界面实时预览），写入存储做 300ms 防抖（拖动滑杆时不会每帧写盘）；
/// - 动态取色的封面色由 `DynamicAccentSync` 写入 [setArtworkColor]，关闭动态取色时忽略。
class AppearanceProvider extends ChangeNotifier {
  final StorageService _storage;

  AppearanceSettings _settings = AppearanceSettings.defaults;
  Color? _artworkAccent;
  Timer? _saveTimer;

  AppearanceProvider(this._storage) {
    final raw = _storage.appearanceJson;
    if (raw.isNotEmpty) {
      try {
        final json = jsonDecode(raw);
        if (json is Map<String, dynamic>) {
          _settings = AppearanceSettings.fromJson(json);
        }
      } catch (_) {
        // 存储内容损坏：沿用默认外观
      }
    }
  }

  AppearanceSettings get settings => _settings;

  /// 本次实际使用的强调色：动态取色且已有封面色时用封面色，否则用用户所选。
  Color get accent => _settings.dynamicAccent && _artworkAccent != null ? _artworkAccent! : _settings.accent;

  ThemeData theme(Brightness brightness) => MD3ETheme.build(brightness, _settings, accent);

  void update(AppearanceSettings settings) {
    if (settings == _settings) return;
    _settings = settings;
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _save);
  }

  void reset() => update(AppearanceSettings.defaults);

  /// 当前播放曲目的封面主色（null 表示无播放 / 取色失败）。
  void setArtworkColor(Color? artwork) {
    final vivid = artwork == null ? null : AccentColors.vivid(artwork);
    if (vivid == _artworkAccent) return;
    _artworkAccent = vivid;
    if (_settings.dynamicAccent) notifyListeners();
  }

  void _save() => _storage.setAppearanceJson(jsonEncode(_settings.toJson()));

  @override
  void dispose() {
    // 退出前把尚未写盘的修改落盘
    if (_saveTimer?.isActive ?? false) _save();
    _saveTimer?.cancel();
    super.dispose();
  }
}
