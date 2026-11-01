import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../hyper_surface.dart';

/// 提示的语气：决定左侧图标容器的表现力形状与强调色。
enum ToastTone {
  /// 一般说明（设置已更改、链接已复制…）。
  info(M3EShapeKind.cookie6Sided),

  /// 操作完成（已登录、已清除、已添加…）。
  success(M3EShapeKind.cookie9Sided),

  /// 需要留意但不是错误（暂不支持、设备不支持音量…）。
  warning(M3EShapeKind.pentagon),

  /// 失败（播放出错、网络问题…）。
  error(M3EShapeKind.softBurst);

  final M3EShapeKind shape;
  const ToastTone(this.shape);
}

/// 全 App 统一的底部提示（Material 3 Expressive）。
///
/// - 外观：反色悬浮胶囊（见 `md3e_theme.dart` 的 snackBarTheme），左侧为按语气区分形状的
///   表现力图标块（入场时弹簧缩放 + 回转），文字最多两行，操作按钮为浅色调胶囊；
/// - 位置与宽度交给当前外壳：桌面端播放栏上方、水平居中限宽（DesktopShell），手机端底部铺满；
/// - 新提示默认替换正在显示的那条，不排队刷屏；带操作按钮的停留更久，且到时自动收起。
///
/// 所有提示都应走这里，不要直接 `showSnackBar(SnackBar(...))`。
class AppToast {
  AppToast._();

  /// 纯提示的停留时长；带按钮的多给几秒，留出点按的时间。
  static const Duration duration = Duration(seconds: 4);
  static const Duration durationWithAction = Duration(seconds: 7);

  /// 在 [context] 最近的 ScaffoldMessenger 上显示。
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? show(
    BuildContext context,
    String message, {
    IconData? icon,
    ToastTone tone = ToastTone.info,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) {
    return showOn(
      ScaffoldMessenger.maybeOf(context),
      message,
      icon: icon,
      tone: tone,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
  }

  /// 在已取得的 [messenger] 上显示（异步操作完成时 context 可能已失效，先取 messenger 再 await）。
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showOn(
    ScaffoldMessengerState? messenger,
    String message, {
    IconData? icon,
    ToastTone tone = ToastTone.info,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) {
    if (messenger == null) return null;
    final hasAction = actionLabel != null && onAction != null;
    messenger.hideCurrentSnackBar();
    if (messenger.context.tokens.hyperMaterial) {
      return messenger.showSnackBar(
        SnackBar(
          content: _HyperToast(
            message: message,
            icon: icon ?? _defaultIcon(tone),
            tone: tone,
            actionLabel: hasAction ? actionLabel : null,
            onAction: hasAction
                ? () {
                    messenger.hideCurrentSnackBar();
                    onAction();
                  }
                : null,
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          padding: EdgeInsets.zero,
          persist: false,
          duration:
              duration ?? (hasAction ? durationWithAction : AppToast.duration),
        ),
      );
    }
    return messenger.showSnackBar(
      SnackBar(
        content: ToastContent(
          message: message,
          icon: icon ?? _defaultIcon(tone),
          tone: tone,
        ),
        action: hasAction
            ? SnackBarAction(label: actionLabel, onPressed: onAction)
            : null,
        // 带按钮的提示在新版 Flutter 默认常驻不消失，这里显式设为到时自动收起
        persist: false,
        duration:
            duration ?? (hasAction ? durationWithAction : AppToast.duration),
        padding: const EdgeInsetsDirectional.fromSTEB(10, 10, 12, 10),
      ),
    );
  }

  /// 一句话提示：柔光玻璃时走 [show]；MD3E 时是原来的纯文字 SnackBar，样式不变。
  static void plain(BuildContext context, String message) {
    if (context.tokens.hyperMaterial) {
      show(context, message);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  static IconData _defaultIcon(ToastTone tone) => switch (tone) {
    ToastTone.info => Icons.info_rounded,
    ToastTone.success => Icons.check_rounded,
    ToastTone.warning => Icons.priority_high_rounded,
    ToastTone.error => Icons.error_rounded,
  };
}

/// 柔光玻璃的提示：浮动控件材质的胶囊，文字用表面色（不再是反色），按钮放在胶囊里面。
class _HyperToast extends StatelessWidget {
  final String message;
  final IconData icon;
  final ToastTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _HyperToast({
    required this.message,
    required this.icon,
    required this.tone,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = tone == ToastTone.error ? scheme.error : scheme.primary;
    return HyperBlendSurface(
      material: HyperBlendSurface.bar(context),
      borderRadius: context.tokens.radius(28),
      bloom: HyperBlendSurface.barBloom(context),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 12, 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (actionLabel != null) ...[
              const SizedBox(width: 8),
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 提示内容：表现力形状的图标块 + 文字。公开以便测试按类型查找。
class ToastContent extends StatelessWidget {
  final String message;
  final IconData icon;
  final ToastTone tone;

  const ToastContent({
    super.key,
    required this.message,
    required this.icon,
    required this.tone,
  });

  /// 可用宽度低于此值时收起图标，把空间全部留给文字（兜底，正常布局不会触发）。
  static const double _iconMinWidth = 160;
  static const double _badgeSize = 38;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 提示底色是反色表面：浅色主题下为深色，强调色需取对应的「深色方案」取值才够亮
    final darkSurface =
        ThemeData.estimateBrightnessForColor(colorScheme.inverseSurface) ==
        Brightness.dark;
    final accent = tone == ToastTone.error
        ? (darkSurface ? const Color(0xFFFFB4AB) : colorScheme.error)
        : colorScheme.inversePrimary;

    final text = Text(message, maxLines: 2, overflow: TextOverflow.ellipsis);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _iconMinWidth) return text;
        return Row(
          children: [
            _SpringIn(
              child: M3EShapeContainer(
                kind: tone.shape,
                width: _badgeSize,
                height: _badgeSize,
                color: accent.withAlpha(46),
                child: Icon(icon, size: 20, color: accent),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: text),
          ],
        );
      },
    );
  }
}

/// 图标块入场：从 0.5 倍弹簧放大、带一点回转，呼应 MD3E 的形状动效。减弱动效时直接显示。
class _SpringIn extends StatelessWidget {
  final Widget child;

  const _SpringIn({required this.child});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 650),
      curve: Curves.elasticOut,
      builder: (context, t, child) => Transform.rotate(
        angle: (1 - t) * -0.5,
        child: Transform.scale(scale: 0.5 + 0.5 * t, child: child),
      ),
      child: child,
    );
  }
}
