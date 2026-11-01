import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../../l10n/l10n.dart';
import '../../widgets/connect/playback_shortcuts.dart';
import '../../widgets/keyboard_shortcuts.dart';
import 'desktop_window.dart';
import 'package:provider/provider.dart';
import '../../../models/shortcut_settings.dart';
import '../../../providers/preferences_provider.dart';

/// 菜单里依赖主界面的动作，由 [MainShell] 挂载时注册进 [MacMenuBar.actions]、卸载时清空。
///
/// 菜单栏本身挂在 App 根部、整个运行期常驻（[PlatformMenuBar] 卸载会把系统菜单清空，
/// ⌘Q / ⌘H 随之失效）；主界面不在时这些菜单项显示为禁用。
class MacMenuActions {
  /// 「搜索」：聚焦桌面顶栏搜索框（获得焦点即切到搜索页）。
  final VoidCallback onSearch;

  /// 「后退 / 前进」：当前 Tab 的内容导航历史。
  final VoidCallback onBack;
  final VoidCallback onForward;

  /// 「主页」：切到主页 Tab。
  final VoidCallback onHome;

  /// 「设置…」：打开设置页。
  final VoidCallback onOpenSettings;

  /// 「全屏歌词」（⌘⇧F）：打开沉浸式歌词。Mac 键盘上 F11 默认是「显示桌面」，F11 需配合 fn。
  final VoidCallback onImmersive;

  /// 播放菜单：与页面内 [PlaybackShortcuts] 同一组动作（远程模式同样路由到其他设备）。
  final VoidCallback onTogglePlayPause;
  final PlaybackShortcutActions playback;

  const MacMenuActions({
    required this.onSearch,
    required this.onBack,
    required this.onForward,
    required this.onHome,
    required this.onOpenSettings,
    required this.onImmersive,
    required this.onTogglePlayPause,
    required this.playback,
  });
}

/// macOS 原生菜单栏（[PlatformMenuBar] 渲染进系统菜单条）。
///
/// 挂在 MaterialApp.builder 里、整个运行期常驻；只在 macOS 桌面真实运行
///（[DesktopWindow.macNativeWindow]）时生效，Windows / Linux / 移动端 / Widget 测试
/// 原样返回 [child]，不占用任何平台通道。
///
/// 菜单结构与动作：
/// - 「Flutify」程序菜单：系统提供的关于 / 服务 / 隐藏 / 退出，外加「设置…」（⌘,）；
/// - 「编辑」：撤销 / 重做 / 剪切 / 拷贝 / 粘贴 / 全选（见 [_EditMenu]）；
/// - 「播放」：播放 / 暂停、上一首、下一首、音量、随机、循环；
/// - 「导航」：后退 / 前进 / 主页 / 搜索，对应页面内同一组快捷键；
/// - 「窗口」：系统提供的最小化 / 缩放 / 进入全屏，外加「关闭」（⌘W，走红按钮同一条
///   只隐藏不销毁的路径）、「Flutify」（⌘0，把隐藏的主窗口叫回来）与「全屏歌词」（⌘⇧F）。
///
/// 作用在主窗口上的菜单项（设置、搜索、全屏歌词）先把窗口叫回前台：红色按钮只是隐藏窗口，
/// 应用还在、菜单栏照常可用。
class MacMenuBar extends StatefulWidget {
  final Widget child;

  /// 主界面注册的动作；为 null 时依赖主界面的菜单项禁用。
  static final ValueNotifier<MacMenuActions?> actions = ValueNotifier(null);

  const MacMenuBar({super.key, required this.child});

  @override
  State<MacMenuBar> createState() => _MacMenuBarState();
}

class _MacMenuBarState extends State<MacMenuBar> {
  List<PlatformMenuItem>? _menus;

  /// 菜单按语言与注册的动作缓存：两者变化时才重建，
  /// 避免窗口拖动等高频重建反复序列化菜单走原生通道。
  Locale? _menuLocale;
  ShortcutSettings? _menuKeys;
  MacMenuActions? _menuActions;

  @override
  void initState() {
    super.initState();
    MacMenuBar.actions.addListener(_onActionsChanged);
  }

  @override
  void dispose() {
    MacMenuBar.actions.removeListener(_onActionsChanged);
    super.dispose();
  }

  /// 注册 / 注销发生在主界面的挂载与卸载过程中（构建期、树已锁定），推迟到帧后再重建菜单。
  void _onActionsChanged() {
    if (!DesktopWindow.macNativeWindow) return;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (mounted) setState(_rebuildMenus);
      })
      ..scheduleFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 非 macOS 原生窗口模式（其他平台 / 测试）不构建菜单
    if (!DesktopWindow.macNativeWindow) return;
    context.watch<PreferencesProvider?>(); // 改键后菜单上显示的键位跟着变
    _rebuildMenus();
  }

  void _rebuildMenus() {
    final locale = Localizations.localeOf(context);
    final actions = MacMenuBar.actions.value;
    final keys = AppShortcuts.of(context);
    if (_menus == null ||
        _menuLocale != locale ||
        _menuKeys != keys ||
        !identical(_menuActions, actions)) {
      _menuLocale = locale;
      _menuKeys = keys;
      _menuActions = actions;
      _menus = _buildMenus(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!DesktopWindow.macNativeWindow) return widget.child;
    final menus = _menus;
    if (menus == null) return widget.child;
    return PlatformMenuBar(menus: menus, child: widget.child);
  }

  List<PlatformMenuItem> _buildMenus(BuildContext context) {
    final l10n = context.l10n;
    // 与页面内 CallbackShortcuts 同一组动作：键位一致（⌘ 系列见 PlatformShortcuts）。
    // 引擎先把按键交给 Flutter，页面内绑定命中就不再触发菜单；菜单项主要提供点击入口与键位展示
    final shell = _menuActions;
    final playback = shell?.playback;
    final keys = AppShortcuts.of(context);
    SingleActivator? shortcut(AppShortcut action) =>
        AppShortcuts.activator(keys, action);

    List<PlatformMenuItem> provided(List<PlatformProvidedMenuItemType> types) =>
        [
          for (final type in types)
            if (PlatformProvidedMenuItem.hasMenu(type))
              PlatformProvidedMenuItem(type: type),
        ];

    return [
      // 程序菜单：系统渲染为加粗的应用名菜单
      PlatformMenu(
        label: 'Flutify',
        menus: [
          PlatformMenuItemGroup(
            members: provided([PlatformProvidedMenuItemType.about]),
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: l10n.menuSettings,
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.comma,
                  meta: true,
                ),
                onSelected: shell == null
                    ? null
                    : () => _showWindowThen(shell.onOpenSettings),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: provided([PlatformProvidedMenuItemType.servicesSubmenu]),
          ),
          PlatformMenuItemGroup(
            members: provided([
              PlatformProvidedMenuItemType.hide,
              PlatformProvidedMenuItemType.hideOtherApplications,
              PlatformProvidedMenuItemType.showAllApplications,
            ]),
          ),
          PlatformMenuItemGroup(
            members: provided([PlatformProvidedMenuItemType.quit]),
          ),
        ],
      ),
      _EditMenu.build(l10n),
      // 播放
      PlatformMenu(
        label: l10n.menuPlayback,
        menus: [
          PlatformMenuItemGroup(
            members: [
              // Space 不能作为原生菜单快捷键（输入框敲空格会被它吞掉），菜单里只保留点击入口
              PlatformMenuItem(
                label: l10n.shortcutPlayPause,
                onSelected: shell?.onTogglePlayPause,
              ),
              PlatformMenuItem(
                label: l10n.shortcutNext,
                shortcut: shortcut(AppShortcut.next),
                onSelected: playback?.next,
              ),
              PlatformMenuItem(
                label: l10n.shortcutPrevious,
                shortcut: shortcut(AppShortcut.previous),
                onSelected: playback?.previous,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: l10n.shortcutVolumeUp,
                shortcut: shortcut(AppShortcut.volumeUp),
                onSelected: playback?.volumeUp,
              ),
              PlatformMenuItem(
                label: l10n.shortcutVolumeDown,
                shortcut: shortcut(AppShortcut.volumeDown),
                onSelected: playback?.volumeDown,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: l10n.shortcutShuffle,
                shortcut: shortcut(AppShortcut.shuffle),
                onSelected: playback?.shuffle,
              ),
              PlatformMenuItem(
                label: l10n.shortcutRepeat,
                shortcut: shortcut(AppShortcut.repeat),
                onSelected: playback?.repeat,
              ),
            ],
          ),
        ],
      ),
      // 导航
      PlatformMenu(
        label: l10n.menuNavigate,
        menus: [
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: l10n.shortcutBack,
                shortcut: shortcut(AppShortcut.back),
                onSelected: shell?.onBack,
              ),
              PlatformMenuItem(
                label: l10n.shortcutForward,
                shortcut: shortcut(AppShortcut.forward),
                onSelected: shell?.onForward,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: l10n.shellHome,
                onSelected: shell?.onHome,
              ),
              PlatformMenuItem(
                label: l10n.shortcutSearch,
                shortcut: shortcut(AppShortcut.search),
                onSelected: shell == null
                    ? null
                    : () => _showWindowThen(shell.onSearch),
              ),
            ],
          ),
        ],
      ),
      // 窗口
      PlatformMenu(
        label: l10n.menuWindow,
        menus: [
          PlatformMenuItemGroup(
            members: provided([
              PlatformProvidedMenuItemType.minimizeWindow,
              PlatformProvidedMenuItemType.zoomWindow,
            ]),
          ),
          PlatformMenuItemGroup(
            members: [
              // 与红色关闭按钮同一条路：preventClose 拦截后只隐藏窗口（见 _CloseGuard）
              PlatformMenuItem(
                label: l10n.windowClose,
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyW,
                  meta: true,
                ),
                onSelected: () => unawaited(windowManager.close()),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              // 主窗口被红色按钮隐藏后，除了点 Dock 图标，也能从这里叫回来（macOS 惯例 ⌘0）
              PlatformMenuItem(
                label: 'Flutify',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.digit0,
                  meta: true,
                ),
                onSelected: () => _showWindowThen(() {}),
              ),
              PlatformMenuItem(
                label: l10n.shortcutImmersive,
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyF,
                  meta: true,
                  shift: true,
                ),
                onSelected: shell == null
                    ? null
                    : () => _showWindowThen(shell.onImmersive),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: provided([PlatformProvidedMenuItemType.toggleFullScreen]),
          ),
        ],
      ),
    ];
  }
}

/// 作用在主窗口上的菜单动作：窗口可能已被红色按钮隐藏，先显示并聚焦再执行。
void _showWindowThen(VoidCallback action) {
  unawaited(() async {
    await windowManager.show();
    await windowManager.focus();
    action();
  }());
}

/// 「编辑」菜单。
///
/// Flutter 的 [PlatformProvidedMenuItemType] 没有剪切 / 拷贝 / 粘贴，自己实现：
/// - 焦点在原生视图（登录页 WKWebView 等）时，经 `flutify/edit_menu` 通道把 `copy:` 这类
///   标准 selector 发给响应链（没有编辑菜单时 WebView 里 ⌘C / ⌘V 不生效）；
/// - 否则对 Flutter 当前焦点调用对应的文本编辑 Intent。
/// Flutter 输入框里按 ⌘C 等由引擎先交给 Flutter 处理，不会走到这里，不会双触发。
abstract final class _EditMenu {
  static const _channel = MethodChannel('flutify/edit_menu');

  static PlatformMenu build(AppLocalizations l10n) {
    PlatformMenuItem item(
      String label,
      LogicalKeyboardKey key,
      String selector,
      Intent intent, {
      bool shift = false,
    }) => PlatformMenuItem(
      label: label,
      shortcut: SingleActivator(key, meta: true, shift: shift),
      onSelected: () => unawaited(_perform(selector, intent)),
    );

    const cause = SelectionChangedCause.keyboard;
    return PlatformMenu(
      label: l10n.menuEdit,
      menus: [
        PlatformMenuItemGroup(
          members: [
            item(
              l10n.menuUndo,
              LogicalKeyboardKey.keyZ,
              'undo:',
              const UndoTextIntent(cause),
            ),
            item(
              l10n.menuRedo,
              LogicalKeyboardKey.keyZ,
              'redo:',
              const RedoTextIntent(cause),
              shift: true,
            ),
          ],
        ),
        PlatformMenuItemGroup(
          members: [
            item(
              l10n.menuCut,
              LogicalKeyboardKey.keyX,
              'cut:',
              const CopySelectionTextIntent.cut(cause),
            ),
            item(
              l10n.menuCopy,
              LogicalKeyboardKey.keyC,
              'copy:',
              CopySelectionTextIntent.copy,
            ),
            item(
              l10n.menuPaste,
              LogicalKeyboardKey.keyV,
              'paste:',
              const PasteTextIntent(cause),
            ),
            item(
              l10n.menuSelectAll,
              LogicalKeyboardKey.keyA,
              'selectAll:',
              const SelectAllTextIntent(cause),
            ),
          ],
        ),
      ],
    );
  }

  static Future<void> _perform(String selector, Intent intent) async {
    bool handledNatively = false;
    try {
      handledNatively =
          await _channel.invokeMethod<bool>('perform', selector) ?? false;
    } catch (_) {}
    if (handledNatively) return;
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus != null && focus.mounted) Actions.maybeInvoke(focus, intent);
  }
}
