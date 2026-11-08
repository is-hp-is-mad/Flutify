import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/playback_session.dart';

/// 上次播放会话的持久化。PlaybackProvider 只依赖这个接口，测试可用内存实现。
abstract class PlaybackSessionStore {
  /// 启动时同步读取（在第一帧之前还原播放栏，避免闪一下空状态）。
  PlaybackSession? read();

  Future<void> write(PlaybackSession session);

  Future<void> clear();
}

/// 存成应用数据目录下的一个 JSON 文件。
///
/// 不放进 SharedPreferences：它在桌面端每次写入都会重写整个偏好文件（含媒体库缓存），
/// 而播放进度需要定期保存。写入先落到 `.tmp` 再改名，进程中途被杀也不会留下半截文件；
/// 连续多次写入只保留最新一次（前一次写完后再写最新内容）。
class FilePlaybackSessionStore implements PlaybackSessionStore {
  final File file;

  FilePlaybackSessionStore(this.file);

  Future<void>? _writing;
  PlaybackSession? _pending;

  @override
  PlaybackSession? read() {
    try {
      if (!file.existsSync()) return null;
      return PlaybackSession.fromJson(jsonDecode(file.readAsStringSync()));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(PlaybackSession session) {
    _pending = session;
    return _writing ??= _drain().whenComplete(() => _writing = null);
  }

  Future<void> _drain() async {
    while (_pending != null) {
      final session = _pending!;
      _pending = null;
      try {
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(jsonEncode(session.toJson()), flush: true);
        if (file.existsSync()) await file.delete(); // Windows 上 rename 不覆盖已有文件
        await tmp.rename(file.path);
      } catch (_) {
        // 写失败（磁盘满 / 被占用）只影响下次启动能否还原，不打断播放
      }
    }
  }

  @override
  Future<void> clear() async {
    _pending = null;
    await _writing;
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }
}

/// 内存实现（测试 / 未提供存储目录时）。
class MemoryPlaybackSessionStore implements PlaybackSessionStore {
  PlaybackSession? session;

  MemoryPlaybackSessionStore([this.session]);

  @override
  PlaybackSession? read() => session;

  @override
  Future<void> write(PlaybackSession session) async => this.session = session;

  @override
  Future<void> clear() async => session = null;
}
