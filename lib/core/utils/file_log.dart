import 'dart:io';

import 'package:flutter/foundation.dart';

/// 把 `debugPrint` 与全局未捕获异常同时写进日志文件 `<系统临时目录>/flutify.log`
/// （Windows 为 `%TEMP%`，Android 为应用缓存目录）。双击 / 任务栏启动或在手机上运行时没有控制台，排查只能靠它。
///
/// 每次启动把上一次的日志轮转到 `flutify.prev.log`，再新建 `flutify.log`；
/// 单次运行超过 8 MB 后停止写入，避免长时间运行撑大文件。
void installFileLog() {
  _rotatePreviousLog();
  final IOSink sink;
  try {
    sink = logFile.openWrite(mode: FileMode.write);
  } catch (_) {
    return;
  }
  _sink = sink;
  _failed = false;
  _written = 0;
  // openWrite reports filesystem failures asynchronously through done.
  // Logging must not turn a recoverable startup error into an unhandled error.
  sink.done.catchError((Object _) {
    _failed = true;
    if (identical(_sink, sink)) _sink = null;
  });

  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    original(message, wrapWidth: wrapWidth);
    if (message == null) return;
    _appendLogLine('LOG', message);

    // 如果消息包含常见错误关键词，记录堆栈信息以提高排查效率
    if (message.contains('失败') ||
        message.contains('错误') ||
        message.contains('异常') ||
        message.toLowerCase().contains('error') ||
        message.toLowerCase().contains('fail')) {
      _appendLogLine('STACK', StackTrace.current.toString());
    }
  };

  _installGlobalErrorHooks();
}

IOSink? _sink;
bool _failed = false;
int _written = 0;
bool _errorHooksInstalled = false;
const int _maxLogBytes = 8 * 1024 * 1024;

void _rotatePreviousLog() {
  try {
    final current = logFile;
    if (!current.existsSync() || current.lengthSync() <= 0) return;
    final prev = previousLogFile;
    if (prev.existsSync()) prev.deleteSync();
    current.renameSync(prev.path);
  } catch (_) {}
}

void _appendLogLine(String level, String message) {
  final sink = _sink;
  if (sink == null || _written > _maxLogBytes || _failed) return;
  final now = DateTime.now().toIso8601String();
  final line = '$now [$level] $message\n';
  _written += line.length;
  sink.write(line);
}

void _installGlobalErrorHooks() {
  if (_errorHooksInstalled) return;
  _errorHooksInstalled = true;

  final prevFlutterError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    _appendLogLine(
      'FlutterError',
      '${details.exceptionAsString()}\n${details.stack ?? StackTrace.empty}',
    );
    prevFlutterError?.call(details);
  };

  final prevPlatformError = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    _appendLogLine('UncaughtError', '$error\n$stack');
    if (prevPlatformError != null) {
      return prevPlatformError(error, stack);
    }
    return false;
  };
}

/// 本次运行的日志文件。
File get logFile =>
    File('${Directory.systemTemp.path}${Platform.pathSeparator}flutify.log');

/// 上一次运行的日志文件（用于崩溃重启后仍能回溯现场）。
File get previousLogFile =>
    File('${Directory.systemTemp.path}${Platform.pathSeparator}flutify.prev.log');

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

/// 读取完整日志内容（包含上一次运行残留的 `flutify.prev.log` 与本次运行日志），供导出文件使用。
Future<String> readFullLog({bool includePrevious = true}) async {
  try {
    await _sink?.flush();
  } catch (_) {}
  final buffer = StringBuffer();
  if (includePrevious) {
    try {
      if (await previousLogFile.exists()) {
        final prev = await previousLogFile.readAsString();
        if (prev.trim().isNotEmpty) {
          buffer.writeln('===== Previous Session (flutify.prev.log) =====');
          buffer.writeln(prev.trimRight());
          buffer.writeln();
        }
      }
    } catch (_) {}
  }
  try {
    if (await logFile.exists()) {
      final current = await logFile.readAsString();
      if (current.trim().isNotEmpty) {
        if (buffer.isNotEmpty) {
          buffer.writeln('===== Current Session (flutify.log) =====');
        }
        buffer.writeln(current.trimRight());
      }
    }
  } catch (_) {}
  return buffer.toString();
}
