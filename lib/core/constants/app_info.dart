/// 应用信息（设置页「关于」、开源许可页使用）。
///
/// 版本号必须与 pubspec.yaml 的 `version` 一致，`test/core/app_info_test.dart` 会校验。
class AppInfo {
  AppInfo._();

  static const String name = 'Flutify';
  static const String version = '0.0.22';
  static const int build = 22;
  static const String _buildReleaseTag = String.fromEnvironment(
    'FLUTIFY_RELEASE_TAG', defaultValue: 'v0.18',
  );
  static const String releaseTag = _buildReleaseTag == '' ? 'v0.18' : _buildReleaseTag;

  /// 「0.0.18 (18)」
  static String get displayVersion => '$version ($build)';
}
