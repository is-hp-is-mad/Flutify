import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:hyper_glass/hyper_ui.dart' show Decelerate, hyperSpring;

import '../../core/theme/flutify_tokens.dart';
import 'hyper_surface.dart';

/// 全 App 统一的弹窗与底部弹层入口。
///
/// 材质为 MD3E 时与 Flutter 的 [showDialog] / [showModalBottomSheet] 完全一致；
/// 柔光玻璃时换成 HyperOS 的遮罩、动画和混色模糊表面。调用方不用分支。
Color _hyperBarrier(BuildContext context) => Colors.black.withValues(
  alpha: Theme.of(context).brightness == Brightness.dark ? 0.45 : 0.3,
);

/// 弹窗进场弹簧（PhoneDialogAnim：阻尼比 0.82，响应 0.3 s）。
class _DialogSpring extends Curve {
  const _DialogSpring();

  static const Duration duration = Duration(milliseconds: 420);
  static final SpringSimulation _spring = SpringSimulation(
    hyperSpring(0.82, 0.3),
    0,
    1,
    0,
  );

  @override
  double transformInternal(double t) =>
      _spring.x(t * duration.inMilliseconds / 1000);
}

/// 进场 420 ms（弹簧）、退场 200 ms（减速 1.5）：路由只有一个时长，退场放在动画的后半段。
const double _exitStart = 1 - 200 / 420;

/// 见文件头。参数与 [showDialog] 同名同义。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = true,
  bool barrierDismissible = true,
  Color? barrierColor,
}) {
  if (!context.tokens.hyperMaterial) {
    return showDialog<T>(
      context: context,
      builder: builder,
      useRootNavigator: useRootNavigator,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
    );
  }
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final still = context.reduceMotion;
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: _hyperBarrier(context),
    transitionDuration: still ? Duration.zero : _DialogSpring.duration,
    pageBuilder: (_, _, _) =>
        themes.wrap(SafeArea(child: Builder(builder: builder))),
    transitionBuilder: (_, animation, _, child) => AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (_, child) {
        final t = animation.value;
        final v = animation.status == AnimationStatus.reverse
            ? const Decelerate(
                1.5,
              ).transform(((t - _exitStart) / (1 - _exitStart)).clamp(0.0, 1.0))
            : const _DialogSpring().transform(t);
        return Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - v) * 120),
            child: child,
          ),
        );
      },
    ),
  );
}

/// 见文件头。参数与 [showModalBottomSheet] 同名同义。
/// 传了 [backgroundColor] 的弹层自带表面（歌词弹层），两种材质都原样显示。
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = false,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  bool? showDragHandle,
  Color? backgroundColor,
}) {
  if (!context.tokens.hyperMaterial || backgroundColor != null) {
    return showModalBottomSheet<T>(
      context: context,
      builder: builder,
      useRootNavigator: useRootNavigator,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      showDragHandle: showDragHandle,
      backgroundColor: backgroundColor,
    );
  }
  final handle =
      showDragHandle ??
      Theme.of(context).bottomSheetTheme.showDragHandle ??
      false;
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    showDragHandle: false, // 把手画在表面里，否则会悬空在透明底上
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: _hyperBarrier(context),
    builder: (sheetContext) =>
        _HyperSheetSurface(handle: handle, child: builder(sheetContext)),
  );
}

/// 底部弹层的混色模糊表面（弹窗材质，形状仍是弹层）。
class _HyperSheetSurface extends StatelessWidget {
  final bool handle;
  final Widget child;

  const _HyperSheetSurface({required this.handle, required this.child});

  @override
  Widget build(BuildContext context) {
    return HyperBlendSurface(
      material: HyperBlendSurface.dialog(context),
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(context.tokens.corner(32)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: !handle
            ? child
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withAlpha(100),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Flexible(child: child),
                ],
              ),
      ),
    );
  }
}

/// 不走 [FlutifyDialog]、自带内容的 [Dialog]：柔光玻璃时背景换成弹窗混色模糊。
class AppDialog extends StatelessWidget {
  final BorderRadius borderRadius;
  final Widget child;
  final Color? backgroundColor;
  final AlignmentGeometry? alignment;
  final EdgeInsets? insetPadding;

  const AppDialog({
    super.key,
    required this.borderRadius,
    required this.child,
    this.backgroundColor,
    this.alignment,
    this.insetPadding,
  });

  @override
  Widget build(BuildContext context) {
    final hyper = context.tokens.hyperMaterial;
    return Dialog(
      alignment: alignment,
      insetPadding: insetPadding,
      backgroundColor: hyper ? Colors.transparent : backgroundColor,
      elevation: hyper ? 0 : null,
      shape: RoundedRectangleBorder(borderRadius: borderRadius),
      clipBehavior: Clip.antiAlias,
      child: !hyper
          ? child
          : HyperBlendSurface(
              material: HyperBlendSurface.dialog(context),
              borderRadius: borderRadius,
              bloom: HyperBlendSurface.dialogBloom(context),
              child: child,
            ),
    );
  }
}
