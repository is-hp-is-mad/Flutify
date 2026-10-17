import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/app_preferences.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/spotify_provider.dart';
import '../../services/storage_service.dart';
import '../navigation/app_routes.dart';
import '../navigation/content_history.dart';
import '../navigation/tab_navigator.dart';
import '../shell/desktop/desktop_shell.dart';
import '../shell/desktop/desktop_top_bar.dart';
import '../shell/desktop/mac_menu_bar.dart';
import '../shell/shell_breakpoints.dart';
import '../shell/mobile/mobile_bottom_bar.dart';
import '../shell/shell_layout_controller.dart';
import '../widgets/connect/playback_shortcuts.dart';
import '../widgets/keyboard_shortcuts.dart';
import '../widgets/playback_error_listener.dart';
import '../widgets/track_hotkeys.dart';
import 'home/home_screen.dart';
import 'library/library_screen.dart';
import 'player/immersive_lyrics_screen.dart';
import 'search/search_screen.dart';
import 'settings/settings_screen.dart';

/// 响应式主框架：持有三个 Tab 的嵌套 Navigator、导航历史、全局搜索词与桌面布局状态，
/// 按窗口宽度交给桌面三栏框架（[DesktopShell]）或移动端底部导航布局。
///
/// 两种布局共用同一组 Navigator 与根页面，窗口跨越断点时浏览位置不丢失。
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  static const int _home = 0;
  static const int _search = 1;
  static const int _library = 2;

  /// 初始 Tab 按设置页「启动时打开」决定（initState 中读取）。
  late int _currentIndex;

  final List<GlobalKey<NavigatorState>> _navigatorKeys = List.generate(
    3,
    (_) => GlobalKey<NavigatorState>(),
  );
  final List<ContentHistory> _histories = List.generate(
    3,
    (_) => ContentHistory(),
  );

  /// 搜索词在桌面顶栏与搜索页之间共享。
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'desktop-search');

  final ShellLayoutController _layout = ShellLayoutController();

  // 各 Tab 根页面只创建一次，切换 Tab 与窗口尺寸变化时不再重新构造
  late final List<Widget> _roots = [
    HomeScreen(onOpenSettings: _openSettings),
    SearchScreen(controller: _searchController),
    LibraryScreen(onOpenSettings: _openSettings),
  ];

  @override
  void initState() {
    super.initState();
    _currentIndex = _startIndex();
    AppRoutes.contentNavigator = () =>
        _navigatorKeys[_currentIndex].currentState;
    AppRoutes.navigateBack = _navigateBack;
    AppRoutes.navigateForward = _navigateForward;
    // macOS 菜单栏常驻在 App 根部（见 MacMenuBar），这里只登记依赖主界面的动作
    _menuActions = MacMenuActions(
      onSearch: _searchFocus.requestFocus,
      onBack: _navigateBack,
      onForward: _navigateForward,
      onHome: () => _select(_home),
      onOpenSettings: _openSettings,
      onImmersive: () => ImmersiveLyricsScreen.open(context),
      onTogglePlayPause: () => PlaybackShortcuts.togglePlayPause(context),
      playback: PlaybackShortcuts.actions(context),
    );
    MacMenuBar.actions.value = _menuActions;
  }

  late final MacMenuActions _menuActions;

  // 根部鼠标监听与原生菜单不受模态路由的焦点隔离保护。
  // 弹窗、播放器或全屏歌词覆盖主界面时，保留底下的内容历史。
  bool get _canNavigateContent =>
      mounted && ModalRoute.of(context)?.isCurrent == true;

  void _navigateBack() {
    if (!_canNavigateContent) return;
    _histories[_currentIndex].back();
  }

  void _navigateForward() {
    if (!_canNavigateContent) return;
    _histories[_currentIndex].forward();
  }

  /// 启动页：主页 / 音乐库 / 上次所在 Tab（未注入 Provider 的测试一律主页）。
  int _startIndex() {
    final prefs = Provider.of<PreferencesProvider?>(
      context,
      listen: false,
    )?.prefs;
    final storage = Provider.of<StorageService?>(context, listen: false);
    return switch (prefs?.startPage) {
      StartPage.library => _library,
      StartPage.last => (storage?.lastTab ?? _home).clamp(_home, _library),
      _ => _home,
    };
  }

  /// 切换 Tab 并记录（供「上次位置」使用）。
  void _setIndex(int index) {
    setState(() => _currentIndex = index);
    Provider.of<StorageService?>(context, listen: false)?.setLastTab(index);
  }

  @override
  void dispose() {
    AppRoutes.contentNavigator = null;
    AppRoutes.navigateBack = null;
    AppRoutes.navigateForward = null;
    if (identical(MacMenuBar.actions.value, _menuActions))
      MacMenuBar.actions.value = null;
    _searchController.dispose();
    _searchFocus.dispose();
    _layout.dispose();
    for (final h in _histories) {
      h.dispose();
    }
    super.dispose();
  }

  /// 打开设置：
  /// - 桌面布局：推入当前 Tab 的内容区，保留顶栏（后退 / 搜索 / 窗口按钮）、侧栏与播放栏；
  ///   已在设置页时不重复推入；
  /// - 移动端布局：根 Navigator 全屏推入（iOS「设置」式，盖住底部导航）。
  void _openSettings() {
    if (!ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width)) {
      Navigator.of(
        context,
        rootNavigator: true,
      ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
      return;
    }
    final navigator = _navigatorKeys[_currentIndex].currentState;
    if (navigator == null) return;
    Route<dynamic>? top;
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    if (top?.settings.name == SettingsScreen.routeName) return;
    navigator.push(
      MaterialPageRoute(
        settings: const RouteSettings(name: SettingsScreen.routeName),
        builder: (_) => const SettingsScreen(),
      ),
    );
  }

  /// 再次点击当前 Tab：回到该 Tab 根页面（Spotify 行为）。
  void _select(int index) {
    if (index == _currentIndex) {
      _histories[index].popToRoot();
      return;
    }
    _setIndex(index);
  }

  /// 桌面顶栏搜索：聚焦或输入即切到搜索页，并回到搜索根页（显示浏览 / 结果）。
  void _activateSearch() {
    if (_currentIndex != _search) _setIndex(_search);
    _histories[_search].popToRoot();
  }

  void _onSearchChanged(String query) {
    _activateSearch();
    context.read<SpotifyProvider>().performSearch(query);
  }

  void _onSearchSubmitted(String query) {
    _searchFocus.unfocus();
    context.read<SpotifyProvider>().commitRecentSearch(query);
  }

  /// 桌面快捷键（与 Spotify 桌面端一致）。输入框聚焦时空格会被 TextField 拦截，不会误触。
  /// 播放类按键在远程模式下控制正在播放的其他设备（[PlaybackShortcuts]）。
  /// 主修饰键按平台取（macOS ⌘，其余 Ctrl），见 [PlatformShortcuts]。
  Map<ShortcutActivator, VoidCallback> _shortcuts() => {
    ...PlaybackShortcuts.bindings(context),
    PlatformShortcuts.primary(LogicalKeyboardKey.keyK):
        _searchFocus.requestFocus,
    PlatformShortcuts.primary(LogicalKeyboardKey.keyL):
        _searchFocus.requestFocus,
    const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _navigateBack,
    const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
        _navigateForward,
    // 浏览器式后退 / 前进：鼠标驱动（如 Logi Options+）常把侧键模拟成 ⌘[ / ⌘]
    if (PlatformShortcuts.useMeta) ...{
      const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true):
          _navigateBack,
      const SingleActivator(LogicalKeyboardKey.bracketRight, meta: true):
          _navigateForward,
    },
    const SingleActivator(LogicalKeyboardKey.f11): () =>
        ImmersiveLyricsScreen.open(context),
    // Mac 键盘上 F11 默认是「显示桌面」：另给 ⌘⇧F（与 Apple Music 全屏播放器同键，菜单栏「窗口」里有同一项）
    if (PlatformShortcuts.useMeta)
      const SingleActivator(
        LogicalKeyboardKey.keyF,
        meta: true,
        shift: true,
      ): () =>
          ImmersiveLyricsScreen.open(context),
  };

  Widget _pages() => IndexedStack(
    index: _currentIndex,
    children: [
      for (var i = 0; i < _roots.length; i++)
        TabNavigator(
          navigatorKey: _navigatorKeys[i],
          root: _roots[i],
          active: i == _currentIndex,
          observers: [_histories[i]],
        ),
    ],
  );

  @override
  Widget build(BuildContext context) =>
      PlaybackErrorListener(child: _buildLayout(context));

  Widget _buildLayout(BuildContext context) {
    // sizeOf 只在尺寸变化时触发重建（MediaQuery.of 会随键盘动画每帧重建）
    final width = MediaQuery.sizeOf(context).width;
    final isDesktop = ShellBreakpoints.isDesktop(width);

    if (isDesktop) {
      // 先同步右栏形态，播放栏与三栏框架在同一帧里读到一致的可见状态
      _layout.docked = width >= ShellBreakpoints.threeColumn;
      return ChangeNotifierProvider<ShellLayoutController>.value(
        value: _layout,
        // 曲目快捷键在更外层：全局快捷键（Ctrl/⌘+S 等）先匹配，字母键再交给悬停的曲目行
        child: TrackHotkeys(
          child: CallbackShortcuts(
            bindings: _shortcuts(),
            child: Focus(
              autofocus: true,
              onKeyEvent: (_, event) =>
                  PlaybackShortcuts.onSpaceKey(context, event),
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerLowest,
                // Wide layouts also run on Android tablets and foldables.
                child: SafeArea(
                  child: DesktopShell(
                    pages: _pages(),
                    topBar: DesktopTopBar(
                      history: _histories[_currentIndex],
                      homeSelected: _currentIndex == _home,
                      onHome: () => _select(_home),
                      searchController: _searchController,
                      searchFocus: _searchFocus,
                      onSearchChanged: _onSearchChanged,
                      onSearchSubmitted: _onSearchSubmitted,
                      onSearchActivated: _activateSearch,
                      onOpenSettings: _openSettings,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // 移动端：内容铺到底部导航之下（毛玻璃透出内容），导航与迷你播放器高度经 MediaQuery 传给页面
    return Scaffold(
      extendBody: true,
      body: _pages(),
      bottomNavigationBar: MobileBottomBar(
        selectedIndex: _currentIndex,
        onSelected: _select,
      ),
    );
  }
}
