import 'dart:io';

import 'package:flutter/foundation.dart';

/// 把 `debugPrint` 同时写进日志文件 `<系统临时目录>/flutify.log`
/// （Windows 为 `%TEMP%`，Android 为应用缓存目录）。双击 / 任务栏启动或在手机上运行时没有控制台，排查只能靠它。
///
/// 每次启动覆盖旧文件；超过 8 MB 后停止写入，避免长时间运行撑大文件。
void installFileLog() {
  final IOSink sink;
  try {
    sink = logFile.openWrite(mode: FileMode.write);
  } catch (_) {
    return;
  }
  _sink = sink;
  var failed = false;
  // openWrite reports filesystem failures asynchronously through done.
  // Logging must not turn a recoverable startup error into an unhandled error.
  sink.done.catchError((Object _) {
    failed = true;
    if (identical(_sink, sink)) _sink = null;
  });
  var written = 0;
  const maxBytes = 8 * 1024 * 1024;
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    original(message, wrapWidth: wrapWidth);
    if (message == null || written > maxBytes || failed) return;
    final now = DateTime.now();
    final line = '${now.toIso8601String().substring(11, 23)} $message\n';
    written += line.length;
    sink.write(line);
  };
}

IOSink? _sink;

/// 本次运行的日志文件。
File get logFile =>
    File('${Directory.systemTemp.path}${Platform.pathSeparator}flutify.log');

/// 读取日志末尾最多 [maxChars] 个字符（先把缓冲刷到磁盘），供「复制日志」使用；没有日志时返回空串。
Future<String> readLogTail({int maxChars = 200 * 1024}) async {
  try {
    await _sink?.flush();
    final text = await logFile.readAsString();
    return text.length <= maxChars
        ? text
        : text.substring(text.length - maxChars);
  } catch (_) {
    return '';
  }
}
