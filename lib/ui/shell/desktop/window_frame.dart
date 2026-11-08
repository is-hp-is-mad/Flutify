import 'package:flutter/material.dart';

import '../shell_breakpoints.dart';
import 'desktop_window.dart';
import 'window_caption_buttons.dart';

/// 桌面窗口外框：保证任何页面（设置、登录、全屏对话框……）都能移动、缩放、关闭窗口。
/// macOS 显示原生交通灯（见 DesktopWindow.init 的 windowButtonVisibility），
/// 外框不再叠加 Windows 风格的自绘窗口按钮。
///
/// 放在 `MaterialApp.builder` 中，位于所有路由之上：
/// - 宽窗口（桌面布局）：窗口按钮浮在右上角，顶栏只为它留出空位，并负责拖动；
///   macOS 用系统原生交通灯（左上角），不渲染自绘按钮；
/// - 窄窗口（移动端布局）：顶部加一条 32px 标题条（拖动区 + 窗口按钮），内容整体下移，
///   相当于在桌面上模拟手机屏幕；macOS 标题条加高、应用名居中，避让原生交通灯；
/// - 系统全屏（沉浸式歌词）时两者都隐藏；沉浸式歌词仅铺满窗口时只浮深色窗口按钮；
/// - 未启用自绘标题栏（测试、移动端）时原样返回子组件。
///
/// 自带一层 [Overlay]：Builder 位于 Navigator 之外，窗口按钮的 Tooltip 需要它。
class WindowFrame extends StatefulWidget {
  final Widget child;

  const WindowFrame({super.key, required this.child});

  /// 窄窗口标题条高度。
  static const double captionHeight = 32;

  /// macOS 窄窗口标题条高度：与 [DesktopTopBar.height] 一致，
  /// 原生交通灯（原生端下移到该高度的中线）在宽窄布局切换时不会跳动。
  static const double captionHeightMac = 56;

  @override
  State<WindowFrame> createState() => _WindowFrameState();
}

class _WindowFrameState extends State<WindowFrame> {
  // 只创建一次；子组件变化时让入口重建，而不是重建整个 Overlay
  late final OverlayEntry _entry = OverlayEntry(
    builder: (_) => _FrameBody(child: widget.child),
  );

  @override
  void didUpdateWidget(WindowFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child) _entry.markNeedsBuild();
  }

  // 外框与应用同生命周期，入口随 Overlay 一起销毁，无需手动 remove

  @override
  Widget build(BuildContext context) {
    if (!DesktopWindow.enabled) return widget.child;
    return Overlay(initialEntries: [_entry]);
  }
}

class _FrameBody extends StatelessWidget {
  final Widget child;

  const _FrameBody({required this.child});

  @override
  Widget build(BuildContext context) {
    // macOS：原生交通灯浮在左上角，任何页面形态都不叠加自绘窗口按钮
    final macButtons = DesktopWindow.macNativeWindow;
    final wide = ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width);
    return ListenableBuilder(
      listenable: Listenable.merge([
        DesktopWindow.fullScreen,
        DesktopWindow.immersiveWindow,
      ]),
      child: child,
      builder: (context, child) {
        if (DesktopWindow.fullScreen.value) return child!;
        // 沉浸式歌词铺满窗口：任何宽度都只浮窗口按钮，深色样式贴合深色背景；macOS 靠原生交通灯
        if (DesktopWindow.immersiveWindow.value) {
          if (macButtons) return child!;
          return Stack(
            children: [
              Positioned.fill(child: child!),
              Positioned(
                top: 0,
                right: 0,
                child: Theme(
                  data: ThemeData(
                    brightness: Brightness.dark,
                    colorScheme: const ColorScheme.dark(),
                  ),
                  child: const WindowCaptionButtons(),
                ),
              ),
            ],
          );
        }
        if (wide) {
          if (macButtons) return child!;
          return Stack(
            children: [
              Positioned.fill(child: child!),
              const Positioned(top: 0, right: 0, child: WindowCaptionButtons()),
            ],
          );
        }
        // 标题条之下才是「手机屏幕」：MediaQuery 尺寸同步减去标题条高度
        final media = MediaQuery.of(context);
        final stripHeight = macButtons
            ? WindowFrame.captionHeightMac
            : WindowFrame.captionHeight;
        final screen = Size(media.size.width, media.size.height - stripHeight);
        return Column(
          children: [
            _CaptionStrip(mac: macButtons),
            Expanded(
              child: MediaQuery(
                data: media.copyWith(size: screen, padding: EdgeInsets.zero),
                child: child!,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 窄窗口标题条：左侧应用名，其余为拖动区，右侧窗口按钮。
/// macOS 分支：原生交通灯浮在左上角，去掉自绘按钮，应用名居中、整条可拖动。
class _CaptionStrip extends StatelessWidget {
  /// macOS 原生交通灯：应用名居中，避让左侧交通灯。
  final bool mac;

  const _CaptionStrip({required this.mac});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = Text(
      'Flutify',
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    );
    if (mac) {
      return Material(
        color: theme.scaffoldBackgroundColor,
        child: SizedBox(
          height: WindowFrame.captionHeightMac,
          child: WindowDragArea(child: Center(child: title)),
        ),
      );
    }
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SizedBox(
        height: WindowFrame.captionHeight,
        child: Row(
          children: [
            Expanded(
              child: WindowDragArea(
                child: Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Align(alignment: Alignment.centerLeft, child: title),
                ),
              ),
            ),
            const WindowCaptionButtons(height: WindowFrame.captionHeight),
          ],
        ),
      ),
    );
  }
}
