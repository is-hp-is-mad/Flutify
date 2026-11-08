import 'dart:async';

/// 流式下载的进度登记：EME 播放器按 BYTERANGE 取段时，若要的区间还没下完就等它。
///
/// 数据源（EmeTrackAudioSource）写入进度；播放器（EmePlayer 的本地 HTTP 服务）按需等待。
/// 键 = 缓存文件路径。
class StreamingDownload {
  /// 已落盘字节数（从 0 顺序增长）。
  int available = 0;

  /// 下载完成（或失败）标记。
  bool done = false;

  /// 失败原因（done=true 且 error 非空）。
  Object? error;

  /// 预计总字节数（未知为 0）。
  int expectedTotal = 0;

  final _progress = StreamController<void>.broadcast();

  /// 报告进度（每写一个数据块调用）。
  void report(int availableBytes) {
    available = availableBytes;
    if (!_progress.hasListener) return;
    _progress.add(null);
  }

  /// 标记完成（[err] 非空表示失败）。
  void finish([Object? err]) {
    done = true;
    error = err;
    if (_progress.hasListener) _progress.add(null);
  }

  /// 等待至少有 [bytes] 字节可用（或下载结束）。超时 30s 视为失败。
  Future<void> waitFor(int bytes) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (available < bytes && !done) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('流式下载等待超时（需要 $bytes，现有 $available）');
      }
      await _progress.stream.first
          .timeout(const Duration(seconds: 5), onTimeout: () {});
    }
    if (available < bytes && done && error != null) {
      throw StateError('流式下载失败：$error');
    }
  }

  void dispose() {
    _progress.close();
  }
}

/// 进行中的流式下载（按文件路径登记）。
class StreamingDownloads {
  StreamingDownloads._();

  static final Map<String, StreamingDownload> _active = {};

  static StreamingDownload begin(String path) {
    final d = StreamingDownload();
    _active[path] = d;
    return d;
  }

  /// 读取（无登记返回 null = 非流式 / 已完成）。
  static StreamingDownload? of(String path) => _active[path];

  static void end(String path) {
    _active.remove(path)?.dispose();
  }
}
