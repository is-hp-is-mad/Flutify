import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../navigation/content_history.dart';
import '../../widgets/keyboard_shortcuts.dart';
import '../../widgets/user_avatar.dart';
import 'desktop_window.dart';
import 'window_caption_buttons.dart';

/// 桌面端顶栏（与窗口标题栏合一，高 56）。
///
/// 布局：`‹ ›` 后退 / 前进 ─── [⌂] [ 🔍 你想听什么？  Ctrl K ] ─── 头像 · （窗口按钮位）
/// - 空白处可拖动窗口、双击最大化（[WindowDragArea]）；
/// - 搜索框居中，输入即切到搜索页；`Ctrl K`（macOS 为 `⌘K`）聚焦；
/// - 头像打开设置（账号卡片在设置页顶部）；
/// - 后退 / 前进、主页、搜索框、头像统一 40px 高，与原生交通灯在同一中线上。
///
/// macOS：原生交通灯浮在窗口左上角，原生端把它们对齐到 20pt 留白（上下 = 左侧）并与
/// 40px 控件中线对齐（见 macos/Runner/TrafficLightAligner.swift），
/// 顶栏左侧为它留白 [DesktopWindow.macTrafficLightsInset]；
/// 右上角不再为自绘窗口按钮占位（macOS 不渲染自绘按钮）。
class DesktopTopBar extends StatelessWidget {
  final ContentHistory history;
  final bool homeSelected;
  final VoidCallback onHome;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onSearchSubmitted;
  final VoidCallback onSearchActivated;
  final VoidCallback onOpenSettings;

  const DesktopTopBar({
    super.key,
    required this.history,
    required this.homeSelected,
    required this.onHome,
    required this.searchController,
    required this.searchFocus,
    required this.onSearchChanged,
    required this.onSearchSubmitted,
    required this.onSearchActivated,
    required this.onOpenSettings,
  });

  static const double height = 56;

  /// 顶栏交互控件统一高度（后退 / 前进、主页、搜索框、头像）。
  static const double controlSize = 40;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final macButtons = DesktopWindow.macNativeWindow;
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          // 拖窗只接收空白处事件，不能作为输入框的祖先参与文字选择的手势竞争。
          const Positioned.fill(
            child: WindowDragArea(child: SizedBox.expand()),
          ),
          Row(
            children: [
              // macOS 原生交通灯浮在左上角，顶栏内容为它留白
              SizedBox(
                width: macButtons ? DesktopWindow.macTrafficLightsInset : 16,
              ),
              ListenableBuilder(
                listenable: history,
                builder: (context, _) => Row(
                  children: [
                    _RoundIconButton(
                      icon: Icons.chevron_left_rounded,
                      tooltip: l10n.shellBack,
                      onPressed: history.canGoBack ? history.back : null,
                    ),
                    const SizedBox(width: 8),
                    _RoundIconButton(
                      icon: Icons.chevron_right_rounded,
                      tooltip: l10n.shellForward,
                      onPressed: history.canGoForward ? history.forward : null,
                    ),
                  ],
                ),
              ),
              // 中间区域：主页按钮 + 搜索框整体居中，两侧留白都是拖动区
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          _HomeButton(
                            selected: homeSelected,
                            onPressed: onHome,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _SearchField(
                              controller: searchController,
                              focusNode: searchFocus,
                              onChanged: onSearchChanged,
                              onSubmitted: onSearchSubmitted,
                              onActivated: onSearchActivated,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _AccountButton(onPressed: onOpenSettings),
              // 窗口按钮由 WindowFrame 浮在右上角（所有页面都可见），这里只留出位置；
              // macOS 用原生交通灯，无自绘按钮不占位
              SizedBox(
                width: DesktopWindow.enabled && !macButtons
                    ? 8 + WindowCaptionButtons.width
                    : 16,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 40px 圆形图标按钮（后退 / 前进）；禁用时降低不透明度。
class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(icon, size: 22),
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(DesktopTopBar.controlSize),
        minimumSize: const Size.square(DesktopTopBar.controlSize),
        padding: EdgeInsets.zero,
        backgroundColor: colorScheme.surfaceContainerHigh,
        foregroundColor: colorScheme.onSurface,
        disabledBackgroundColor: colorScheme.surfaceContainerHigh.withAlpha(
          140,
        ),
        disabledForegroundColor: colorScheme.onSurfaceVariant.withAlpha(110),
      ),
    );
  }
}

/// 40px 主页按钮：选中时实心图标。
class _HomeButton extends StatelessWidget {
  final bool selected;
  final VoidCallback onPressed;

  const _HomeButton({required this.selected, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(selected ? Icons.home_filled : Icons.home_outlined, size: 22),
      tooltip: context.l10n.shellHome,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(DesktopTopBar.controlSize),
        backgroundColor: colorScheme.surfaceContainerHigh,
        foregroundColor: selected
            ? colorScheme.onSurface
            : colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// 胶囊搜索框：悬停 / 聚焦时底色提亮并出现描边；未输入且未聚焦时显示快捷键提示。
class _SearchField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onActivated;

  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
    required this.onActivated,
  });

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
    widget.controller.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    widget.controller.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  void _onFocus() {
    if (widget.focusNode.hasFocus) widget.onActivated();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    final focused = widget.focusNode.hasFocus;
    final hasText = widget.controller.text.isNotEmpty;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: DesktopTopBar.controlSize,
        decoration: ShapeDecoration(
          color: _hover || focused
              ? colorScheme.surfaceContainerHighest
              : colorScheme.surfaceContainerHigh,
          shape: StadiumBorder(
            side: BorderSide(
              color: focused
                  ? colorScheme.onSurface
                  : (_hover ? colorScheme.outlineVariant : Colors.transparent),
              width: focused ? 2 : 1,
            ),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(
              Icons.search_rounded,
              size: 22,
              color: focused
                  ? colorScheme.onSurface
                  : colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                textInputAction: TextInputAction.search,
                onChanged: widget.onChanged,
                onSubmitted: widget.onSubmitted,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  hintText: l10n.searchHint,
                  filled: false,
                  isCollapsed: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            if (hasText)
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 20),
                tooltip: l10n.commonClear,
                color: colorScheme.onSurfaceVariant,
                onPressed: () {
                  widget.controller.clear();
                  widget.onChanged('');
                  widget.focusNode.requestFocus();
                },
              )
            else if (!focused)
              Container(
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  border: Border.all(color: colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  // macOS 显示 ⌘K（见 PlatformShortcuts），其余平台 Ctrl K
                  PlatformShortcuts.hintText(l10n.shellSearchShortcut),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            if (hasText) const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

/// 右上角头像：已登录显示账号头像（无头像时显示昵称首字），未登录显示人形图标。
class _AccountButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _AccountButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (signedIn, name) = context.select<AuthProvider, (bool, String)>(
      (a) => (a.isSignedIn, a.displayName),
    );

    return Tooltip(
      message: signedIn && name.isNotEmpty
          ? name
          : context.l10n.shellAccountMenu,
      child: IconButton(
        onPressed: onPressed,
        icon: const UserAvatar(size: 28),
        style: IconButton.styleFrom(
          fixedSize: const Size.square(DesktopTopBar.controlSize),
          backgroundColor: colorScheme.surfaceContainerHigh,
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }
}
