import '../constants/app_info.dart';

/// 自测版（self-test）专用启动参数。
///
/// 非 self-test 版本（如正式版 / beta 版）会自动忽略所有测试参数，
/// 确保用户即使在桌面端或 Android Intent 传入 `--mock` 也不会误入 Mock 模式。
class LaunchArgs {
  /// 进入免登录 Mock 模式，可随意浏览与操作除真音频流外的全部功能。
  final bool mockMode;

  /// 当传入 `--self-test-e2e=<dir>` 时自动运行全功能 UI + 性能 E2E 测试套件。
  final String? e2eOutputDir;

  const LaunchArgs({
    this.mockMode = false,
    this.e2eOutputDir,
  });

  static const LaunchArgs none = LaunchArgs();

  /// 解析命令行参数（或 Android Intent 转换而来的入口参数）。
  ///
  /// [isSelfTest] 默认读取编译期通道 `AppInfo.isSelfTest`（可通过单元测试覆盖）。
  factory LaunchArgs.parse(
    List<String> args, {
    bool? isSelfTest,
  }) {
    final allowed = isSelfTest ?? AppInfo.isSelfTest;
    if (!allowed || args.isEmpty) return LaunchArgs.none;

    var mock = false;
    String? e2eDir;

    for (var i = 0; i < args.length; i++) {
      final raw = args[i].trim();
      if (raw.isEmpty) continue;
      // macOS Finder / Xcode 注入的无关系统参数，忽略之
      if (raw.startsWith('-psn_') || raw == '-NSDocumentRevisionsDebugMode') {
        continue;
      }
      if (raw == '--mock' || raw == '--mock=true' || raw == '--flutify-mock') {
        mock = true;
      } else if (raw.startsWith('--self-test-e2e=')) {
        final value = raw.substring('--self-test-e2e='.length).trim();
        if (value.isNotEmpty) {
          e2eDir = value;
          mock = true;
        }
      } else if (raw == '--self-test-e2e' && i + 1 < args.length) {
        final next = args[++i].trim();
        if (next.isNotEmpty) {
          e2eDir = next;
          mock = true;
        }
      }
    }

    if (!mock && e2eDir == null) return LaunchArgs.none;
    return LaunchArgs(mockMode: mock, e2eOutputDir: e2eDir);
  }
}
