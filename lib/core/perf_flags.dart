/// 性能诊断开关，只用于定位掉帧来源，默认全部关闭，正常构建行为不变。
///
/// 用 `--dart-define` 打开，例如：
///   flutter build apk --release --dart-define=FLUTIFY_PERF_NO_BACKDROP=true
///
/// 每个开关只去掉一种开销，真机上逐个打开对比就能看出哪一项是主因。
abstract final class PerfFlags {
  /// 所有 [LiquidGlass] 不再做 BackdropFilter（每帧复制并模糊下方画面）。
  static const noBackdrop = bool.fromEnvironment('FLUTIFY_PERF_NO_BACKDROP');

  /// 歌词列表去掉上下边缘渐隐的整块离屏遮罩（ShaderMask）。
  static const noLyricsMask = bool.fromEnvironment('FLUTIFY_PERF_NO_LYRICS_MASK');

  /// Android 原生流动背景停在静态帧，不再持续出帧。
  static const staticBackground = bool.fromEnvironment('FLUTIFY_PERF_STATIC_BG');

  /// 显示 Flutter 自带的 GPU / UI 帧耗时叠加层（release 构建也有效）。
  static const overlay = bool.fromEnvironment('FLUTIFY_PERF_OVERLAY');
}
