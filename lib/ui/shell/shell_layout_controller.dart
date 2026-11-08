import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shell_breakpoints.dart';

/// 右栏当前显示的面板。没有标签切换：两个面板分别由播放栏上各自的按钮打开。
enum RightPanel {
  /// 正在播放：封面、歌名、内嵌歌词卡（可放大撑满面板）、关于艺人、接下来播放。
  nowPlaying,

  /// 播放队列。
  queue,
}

/// 桌面端布局状态：音乐库栏宽度 / 是否收起、右栏是否打开、显示哪个面板，以及歌词卡是否放大。
///
/// 右栏有两种形态，开关状态分开记：
/// - 停靠（窗口 ≥ [ShellBreakpoints.threeColumn]）：用户的开关偏好写入 SharedPreferences，下次启动恢复；
/// - 浮层（更窄的窗口）：会遮住内容，所以默认关闭、只在用户点击时临时打开，不落盘；
///   跨越断点时浮层自动收起。
///
/// 窗口过窄时的「强制收起音乐库」由 DesktopShell 按分档计算，不写回这里。
class ShellLayoutController extends ChangeNotifier {
  static const String _keySidebarWidth = 'shell_sidebar_width';
  static const String _keySidebarCollapsed = 'shell_sidebar_collapsed';
  static const String _keyRightPanelOpen = 'shell_right_panel_open';
  static const String _keyLyricsExpanded = 'shell_lyrics_expanded';

  SharedPreferences? _prefs;

  double _sidebarWidth = ShellBreakpoints.sidebarDefault;
  bool _sidebarCollapsed = false;
  bool _dockedOpen = true;
  bool _overlayOpen = false;
  bool _docked = true;
  RightPanel _panel = RightPanel.nowPlaying;
  bool _lyricsExpanded = false;

  ShellLayoutController() {
    _restore();
  }

  double get sidebarWidth => _sidebarWidth;
  bool get sidebarCollapsed => _sidebarCollapsed;
  RightPanel get panel => _panel;

  /// 「正在播放」面板里的歌词卡是否放大撑满面板（记住偏好，下次启动沿用）。
  bool get lyricsExpanded => _lyricsExpanded;

  /// 右栏是否停靠为第三栏（否则以浮层显示）。
  bool get docked => _docked;

  /// 右栏当前是否可见（按当前形态取对应的开关）。
  bool get rightPanelVisible => _docked ? _dockedOpen : _overlayOpen;

  /// 由 MainShell 在构建时按窗口宽度同步，不触发通知（子树随后会一起重建）。
  set docked(bool value) {
    if (value == _docked) return;
    _docked = value;
    _overlayOpen = false;
  }

  Future<void> _restore() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    _sidebarWidth = (prefs.getDouble(_keySidebarWidth) ?? _sidebarWidth).clamp(
      ShellBreakpoints.sidebarMin,
      ShellBreakpoints.sidebarMax,
    );
    _sidebarCollapsed = prefs.getBool(_keySidebarCollapsed) ?? _sidebarCollapsed;
    _dockedOpen = prefs.getBool(_keyRightPanelOpen) ?? _dockedOpen;
    _lyricsExpanded = prefs.getBool(_keyLyricsExpanded) ?? _lyricsExpanded;
    notifyListeners();
  }

  /// 拖动过程中实时更新；[persist] 为 true（松手）时才落盘。
  void setSidebarWidth(double width, {bool persist = false}) {
    _sidebarWidth = width.clamp(ShellBreakpoints.sidebarMin, ShellBreakpoints.sidebarMax);
    if (persist) _prefs?.setDouble(_keySidebarWidth, _sidebarWidth);
    notifyListeners();
  }

  void toggleSidebar() {
    _sidebarCollapsed = !_sidebarCollapsed;
    _prefs?.setBool(_keySidebarCollapsed, _sidebarCollapsed);
    notifyListeners();
  }

  /// 指定面板当前是否正显示。
  bool isShowing(RightPanel panel) => rightPanelVisible && _panel == panel;

  /// 播放栏上的面板按钮：该面板正显示时再点关闭；否则打开右栏并切到该面板。
  void togglePanel(RightPanel panel) {
    final open = !isShowing(panel);
    _panel = panel;
    _setVisible(open);
  }

  /// 「正在播放」面板是否正显示（播放栏「播放状态」键与封面的高亮依据）。
  bool get playbackStatusVisible => isShowing(RightPanel.nowPlaying);

  /// 播放栏「播放状态」键 / 点击封面：开关「正在播放」面板（队列显示中时切过去而不是关闭）。
  void togglePlaybackStatus() => togglePanel(RightPanel.nowPlaying);

  /// 在右栏内部切换面板（如「接下来播放」卡片上的「播放队列」入口），右栏保持打开。
  void switchPanel(RightPanel panel) {
    if (_panel == panel && rightPanelVisible) return;
    _panel = panel;
    _setVisible(true);
  }

  /// 歌词卡放大 / 收起。
  void toggleLyricsExpanded() {
    _lyricsExpanded = !_lyricsExpanded;
    _prefs?.setBool(_keyLyricsExpanded, _lyricsExpanded);
    notifyListeners();
  }

  void closeRightPanel() {
    if (!rightPanelVisible) return;
    _setVisible(false);
  }

  void _setVisible(bool open) {
    if (_docked) {
      _dockedOpen = open;
      _prefs?.setBool(_keyRightPanelOpen, open);
    } else {
      _overlayOpen = open;
    }
    notifyListeners();
  }
}
