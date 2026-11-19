import 'package:flutter/material.dart';

import 'bootstrap/app_bootstrap.dart';
import 'core/render/frame_rate_binding.dart';
import 'core/utils/error_placeholder.dart';
import 'core/utils/file_log.dart';
import 'self_test/launch_args.dart';
import 'services/input/mouse_navigation_channel.dart';
import 'ui/navigation/app_routes.dart';
import 'ui/widgets/app_startup.dart';

export 'ui/flutify_app.dart';

Future<void> main(List<String> args) async {
  // 必须先于任何其他 binding 创建：帧率上限在帧调度入口生效
  FrameRateBinding.ensureInitialized();
  // 解码后位图缓存默认 1000 张 / 100 MiB。封面都按显示尺寸解码（见 CoverImage），
  // 400 张 / 64 MiB 足够，常驻内存上限直接降低约三分之一。
  PaintingBinding.instance.imageCache
    ..maximumSize = 400
    ..maximumSizeBytes = 64 << 20;
  installFileLog();
  installErrorPlaceholder();
  installMacOSMouseNavigation(
    onBack: () => AppRoutes.navigateBack?.call(),
    onForward: () => AppRoutes.navigateForward?.call(),
  );
  // 仅 self-test 版本会识别 --mock / --self-test-e2e；其他版本自动忽略，保持 LaunchArgs.none。
  final launchArgs = LaunchArgs.parse(args);
  runApp(
    AppStartup(
      initialize: (reportStage) => initializeFlutifyApp(reportStage, launchArgs),
    ),
  );
}
