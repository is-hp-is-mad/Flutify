import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../src/rust/api/audio_stream.dart' as rust_stream;
import '../../src/rust/api/network.dart' show AudioDownloadEvent;
import '../../src/rust/api/protocol.dart' as rust;
import '../network/rust_route.dart';
import 'audio_normalization.dart';
import 'track_metadata.dart';
/// Spotify 音频文件头的处理规则（落盘与边下边播共用）。
///
/// Spotify 的 Ogg 文件以 0xa7 字节的私有头页开头（librespot `SPOTIFY_OGG_HEADER_END`），
/// 标准解码器不认识，需要跳过；跳过后必须紧跟 `OggS`，否则说明不是这种结构，按原样播放。
/// 私有头里偏移 144 起是响度数据（音量均衡用）。
class SpotifyAudioHeader {
  SpotifyAudioHeader._();

  static const int oggHeaderEnd = 0xa7;

  /// 判断需要跳过多少字节所需的最少数据量。
  static const int probeLength = oggHeaderEnd + 4;

  /// 解密后的文件开头 [head]（至少 [probeLength] 字节，不足时按不跳过处理）应跳过的字节数。
  static int skipFor(Uint8List head, AudioFileFormat format) {
    if (format.extension != 'ogg' || head.length < probeLength) return 0;
    final magic = String.fromCharCodes(head.sublist(oggHeaderEnd, oggHeaderEnd + 4));
    return magic == 'OggS' ? oggHeaderEnd : 0;
  }

  /// 私有头里的响度原始数据（16 字节，写 `.norm` 旁路文件用）；没有私有头或数据不合理时为 null。
  static Uint8List? normalizationBytesIn(Uint8List head, int skip) {
    if (skip == 0) return null;
    const start = AudioNormalization.headerOffset;
    if (head.length < start + AudioNormalization.byteLength) return null;
    final bytes = Uint8List.fromList(head.sublist(start, start + AudioNormalization.byteLength));
    return AudioNormalization.parse(bytes) == null ? null : bytes;
  }
}

/// 下载因没有使用者而被取消（见 [ProgressiveDownload.retain]）。
class DownloadCancelledException implements Exception {
  const DownloadCancelledException();

  @override
  String toString() => '下载已取消';
}

/// 可边下载边播放的音频（已解密、已去掉私有头的字节流）。
///
/// 播放器通过 [read] 按字节区间取数据：区间内尚未下载到的部分会等待下载推进。
abstract class ProgressiveAudio {
  /// 可播放部分的总字节数（不含私有头）。
  int get length;

  /// MIME 类型（`audio/ogg` / `audio/mpeg`）。
  String get contentType;

  /// 已下载比例（0~1）。
  double get progress;

  /// 下载完成（成功）或失败（抛出原始错误）。
  Future<void> get done;

  /// 读取 `[start, end)`（可播放坐标，end 为空表示到结尾）。
  Stream<List<int>> read(int start, [int? end]);
}

/// 一次边下边播下载的事件来源：按顺序推送 [AudioDownloadEvent]（语义见 Rust
/// `api::audio_stream::audio_progressive_download`）；取消订阅即停止下载。
typedef ProgressiveFetch =
    Stream<AudioDownloadEvent> Function(
      List<String> urls,
      Uint8List key,
      Uint8List iv,
      int maxAttempts,
    );

/// 生产实现：下载、AES-128-CTR 解密、Range 续传、CDN 轮换与重试全部在 Rust 里完成。
/// 这里只为每个 CDN 地址选好路线（代理 / 网关，见 [rustRouteFor]）。
Stream<AudioDownloadEvent> rustProgressiveFetch(
  List<String> urls,
  Uint8List key,
  Uint8List iv,
  int maxAttempts,
) async* {
  final targets = <rust_stream.AudioDownloadTarget>[];
  for (final url in urls) {
    final route = await rustRouteFor(Uri.parse(url));
    if (route == null) throw StateError('网关配置无效，无法下载音频');
    targets.add(
      rust_stream.AudioDownloadTarget(
        proxy: route.proxy,
        url: route.url.toString(),
        headers: [
          for (final h in route.headers.entries)
            rust.HttpHeaderEntry(name: h.key, value: h.value),
        ],
      ),
    );
  }
  yield* rust_stream.audioProgressiveDownload(
    targets: targets,
    key: key,
    iv: iv,
    maxAttempts: maxAttempts,
  );
}

/// 一次 CDN 下载：Rust 流式下载并解密，明文按文件偏移写进内存缓冲区，同时可被播放器按区间读取。
///
/// 规则：
/// - 头部（[SpotifyAudioHeader.probeLength] 字节）到达后 [ready] 完成，此时即可开始播放；
/// - 中途断线时由 Rust 用 HTTP Range 从已收到的位置续传，依次轮换 CDN 地址，累计失败 [maxAttempts] 次才放弃；
/// - 服务器没给出总长度（无 Content-Length）时无法预分配缓冲区，退化为下载完成后才 [ready]。
class ProgressiveDownload implements ProgressiveAudio {
  final List<String> urls;

  /// AES-128-CTR 音频密钥与 IV（[key] 为空表示数据本身是明文）。
  final Uint8List key;
  final Uint8List iv;
  final AudioFileFormat format;

  /// 下载事件来源：生产为 [rustProgressiveFetch]，测试可注入假实现。
  final ProgressiveFetch fetch;

  /// 失败后重试的总次数上限（含轮换到其他地址）。
  final int maxAttempts;

  ProgressiveDownload({
    required this.urls,
    required this.key,
    required this.iv,
    required this.format,
    this.maxAttempts = 4,
    ProgressiveFetch? fetch,
  }) : fetch = fetch ?? rustProgressiveFetch;

  /// 解密后的完整文件（含私有头）；总长度未知时下载期间为 null。
  Uint8List? _buffer;
  int _received = 0;
  int _skip = 0;
  Uint8List? _normalizationBytes;
  Object? _error;
  bool _started = false;
  StreamSubscription<AudioDownloadEvent>? _subscription;

  /// 总长度未知时收集中的数据（完成后整体放入 [_buffer]）。
  BytesBuilder? _pending;

  /// 使用者计数：见 [retain]。
  int _holders = 0;
  bool _cancelled = false;
  Timer? _cancelTimer;

  /// 没有使用者后等这么久再取消：切歌后马上又点回来 / 同一首重新加载时可以接着用。
  static const Duration cancelGrace = Duration(seconds: 2);

  /// 已被取消（没有使用者超过 [cancelGrace]）。
  bool get isCancelled => _cancelled;

  /// 登记一个使用者，返回释放函数（可重复调用，只生效一次）。
  /// 所有使用者都释放、且下载尚未完成时，宽限期后取消下载，不再占用带宽。
  void Function() retain() {
    _holders++;
    _cancelTimer?.cancel();
    _cancelTimer = null;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _holders--;
      if (_holders > 0 || _done.isCompleted || _cancelled) return;
      _cancelTimer?.cancel();
      _cancelTimer = Timer(cancelGrace, () {
        _cancelTimer = null;
        if (_holders == 0 && !_done.isCompleted) cancel();
      });
    };
  }

  /// 立即取消下载（取消 Rust 事件流，连接随之关闭）：[ready] / [done] 以
  /// [DownloadCancelledException] 结束，不写缓存。
  void cancel() {
    if (_cancelled || _done.isCompleted) return;
    _cancelled = true;
    _cancelTimer?.cancel();
    _cancelTimer = null;
    _fail(const DownloadCancelledException());
  }

  final Completer<void> _ready = Completer<void>();
  final Completer<void> _done = Completer<void>();
  final List<({int bytes, Completer<void> completer})> _waiters = [];
  final List<void Function(double progress)> _progressListeners = [];

  /// 可以开始播放（头部已到达）；下载在此之前失败时抛出错误。
  Future<void> get ready => _ready.future;

  @override
  Future<void> get done => _done.future;

  bool get isComplete => _done.isCompleted && _error == null;

  @override
  int get length => (_buffer?.length ?? 0) - _skip;

  @override
  String get contentType => format.extension == 'ogg' ? 'audio/ogg' : 'audio/mpeg';

  @override
  double get progress {
    final total = _buffer?.length ?? 0;
    return total > 0 ? (_received / total).clamp(0.0, 1.0) : 0.0;
  }

  /// 文件私有头里的响度数据（[ready] 之后可用）。
  AudioNormalization? get normalization {
    final bytes = _normalizationBytes;
    return bytes == null ? null : AudioNormalization.parse(bytes);
  }

  /// 响度原始数据（16 字节），落盘时写入 `.norm` 旁路文件。
  Uint8List? get normalizationBytes => _normalizationBytes;

  /// 去掉私有头之后的完整音频（仅下载完成后可用），用于写入缓存。
  Uint8List get playableBytes => Uint8List.sublistView(_buffer!, _skip);

  /// 下载进度回调（0~1）。完成后添加的监听器立即收到 1.0。
  void addProgressListener(void Function(double progress) listener) {
    if (isComplete) {
      listener(1.0);
      return;
    }
    _progressListeners.add(listener);
  }

  /// 开始下载（重复调用无效）。
  void start() {
    if (_started) return;
    _started = true;
    // 结果通过 ready / done 观察；未被监听的错误不应成为未捕获异常
    _ready.future.catchError((Object _) {});
    _done.future.catchError((Object _) {});
    if (urls.isEmpty) {
      _fail(StateError('没有可用的 CDN 地址'));
      return;
    }
    if (_done.isCompleted) return; // 开始前已被取消
    _subscription = fetch(urls, key, iv, maxAttempts).listen(
      (event) {
        try {
          _onEvent(event);
        } catch (e) {
          _fail(e);
        }
      },
      onError: (Object e) => _fail(e is StateError ? e : StateError('$e')),
      onDone: () => _fail(StateError('下载意外中断')),
      cancelOnError: true,
    );
  }

  // 事件类型（与 Rust downloads::EVENT_* 一致）
  static const int _eventMeta = 0;
  static const int _eventData = 1;
  static const int _eventDone = 3;
  static const int _eventError = 4;

  void _onEvent(AudioDownloadEvent e) {
    if (_done.isCompleted) return;
    switch (e.kind) {
      case _eventMeta:
        // 每次请求（含重试）一条：总长第一次已知时分配缓冲区；仍未知时 Rust 从头重下，丢弃已收集的数据
        if (_buffer == null && e.total > 0) _buffer = Uint8List(e.total);
        _pending = _buffer == null ? BytesBuilder(copy: false) : null;
      case _eventData:
        final data = e.data;
        final buffer = _buffer;
        if (buffer == null) {
          _pending?.add(data);
          return;
        }
        // 服务器忽略 Range 时 Rust 从头重新推送（内容相同），按偏移覆盖写不影响已交给播放器的数据
        final start = e.bytes;
        final end = start + data.length;
        if (start < 0 || end > buffer.length) throw StateError('CDN 返回的数据超出声明长度');
        buffer.setRange(start, end, data);
        if (end > _received) _advance(end);
      case _eventDone:
        if (_buffer == null) {
          final bytes = _pending?.takeBytes() ?? Uint8List(0);
          _pending = null;
          if (bytes.isEmpty) throw StateError('CDN 返回空文件');
          _buffer = bytes;
          _advance(bytes.length);
        } else if (_received < _buffer!.length) {
          throw StateError('下载中断（$_received/${_buffer!.length}）');
        }
        _complete();
      case _eventError:
        throw StateError(e.message.replaceFirst(RegExp('^[a-z]+:'), ''));
    }
  }

  void _advance(int received) {
    _received = received;
    final buffer = _buffer!;
    if (!_ready.isCompleted && (_received >= SpotifyAudioHeader.probeLength || _received >= buffer.length)) {
      final head = Uint8List.sublistView(buffer, 0, math.min(_received, SpotifyAudioHeader.probeLength));
      _skip = SpotifyAudioHeader.skipFor(head, format);
      _normalizationBytes = SpotifyAudioHeader.normalizationBytesIn(head, _skip);
      _ready.complete();
    }
    final p = progress;
    for (final listener in _progressListeners) {
      listener(p);
    }
    _waiters.removeWhere((w) {
      if (_received < w.bytes) return false;
      w.completer.complete();
      return true;
    });
  }

  void _complete() {
    _stopFetch();
    if (!_ready.isCompleted) _ready.complete();
    _done.complete();
    for (final listener in _progressListeners) {
      listener(1.0);
    }
    _progressListeners.clear();
    _releaseWaiters();
  }

  void _fail(Object error) {
    if (_done.isCompleted) return;
    _stopFetch();
    _error = error;
    if (!_ready.isCompleted) _ready.completeError(error);
    _done.completeError(error);
    _progressListeners.clear();
    _releaseWaiters();
  }

  void _stopFetch() {
    final subscription = _subscription;
    _subscription = null;
    _pending = null;
    subscription?.cancel().ignore();
  }

  void _releaseWaiters() {
    for (final w in _waiters) {
      if (_error != null) {
        w.completer.completeError(_error!);
      } else {
        w.completer.complete();
      }
    }
    _waiters.clear();
  }

  /// 等到至少收到 [bytes] 字节（文件坐标）。下载失败时抛错；下载已结束仍不够时直接返回。
  Future<void> _waitFor(int bytes) {
    if (_received >= bytes || isComplete) return Future.value();
    if (_error != null) return Future.error(_error!);
    final completer = Completer<void>();
    _waiters.add((bytes: bytes, completer: completer));
    return completer.future;
  }

  @override
  Stream<List<int>> read(int start, [int? end]) async* {
    await ready;
    final buffer = _buffer!;
    var pos = start + _skip;
    final stop = math.min((end ?? length) + _skip, buffer.length);
    const maxChunk = 64 * 1024;
    while (pos < stop) {
      await _waitFor(pos + 1);
      final available = math.min(_received, stop);
      if (available <= pos) break; // 下载已结束但数据不够（不应发生）
      final chunkEnd = math.min(available, pos + maxChunk);
      yield Uint8List.sublistView(buffer, pos, chunkEnd);
      pos = chunkEnd;
    }
  }
}
