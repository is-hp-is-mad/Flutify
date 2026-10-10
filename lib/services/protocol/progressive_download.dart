import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'audio_normalization.dart';
import 'decrypt/decrypt_backend.dart';
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

/// 已下载区间的集合（半开区间 [start, end)，保持有序、互不相交）。
///
/// 多连接并行下载时各段不按顺序完成，播放器却需要知道「某个字节有没有到」，
/// 单一的连续水位线已经不够用。
class _Intervals {
  final List<int> _s = <int>[];

  /// 已覆盖的字节总数（重叠部分只算一次）。
  int total = 0;

  /// 从 0 开始连续可用的字节数。
  int get prefix => _s.isNotEmpty && _s[0] == 0 ? _s[1] : 0;

  bool has(int pos) {
    for (var i = 0; i < _s.length; i += 2) {
      if (pos < _s[i]) return false;
      if (pos < _s[i + 1]) return true;
    }
    return false;
  }

  /// 包含 [pos] 的区间的结尾；[pos] 尚未下载时返回 [pos] 本身。
  int endOf(int pos) {
    for (var i = 0; i < _s.length; i += 2) {
      if (pos < _s[i]) return pos;
      if (pos < _s[i + 1]) return _s[i + 1];
    }
    return pos;
  }

  void add(int start, int end) {
    if (end <= start) return;
    var ns = start, ne = end;
    final out = <int>[];
    var inserted = false;
    for (var i = 0; i < _s.length; i += 2) {
      final s = _s[i], e = _s[i + 1];
      if (e < ns) {
        out.addAll([s, e]);
      } else if (s > ne) {
        if (!inserted) {
          out.addAll([ns, ne]);
          inserted = true;
        }
        out.addAll([s, e]);
      } else {
        ns = math.min(ns, s);
        ne = math.max(ne, e);
      }
    }
    if (!inserted) out.addAll([ns, ne]);
    _s
      ..clear()
      ..addAll(out);
    var sum = 0;
    for (var i = 0; i < _s.length; i += 2) {
      sum += _s[i + 1] - _s[i];
    }
    total = sum;
  }
}

/// 服务器对 Range 请求回了整份文件（200）：不支持分段，改回单连接。
class _RangeIgnored implements Exception {
  const _RangeIgnored();
}

/// 一次 CDN 下载：流式解密到内存缓冲区，同时可被播放器按区间读取。
///
/// 规则：
/// - 头部（[SpotifyAudioHeader.probeLength] 字节）到达后 [ready] 完成，此时即可开始播放；
/// - 首个连接从头顺序下载（起播最快）；一旦知道总长度且文件够大，其余部分切成 [segmentBytes] 一段，
///   由 [connections] - 1 条 HTTP Range 连接并行拉取，各段按自己的偏移独立解密（AES-CTR 可从任意位置解密）；
/// - 播放器拖到还没下载的位置时，该位置所在的段会插队优先下载；
/// - 中途断线时用 HTTP Range 从已收到的位置续传，依次轮换 CDN 地址，累计失败 [maxAttempts] 次才放弃；
/// - 服务器不支持 Range、或某一段重试用尽时，退回单连接顺序下载，不比原来更差；
/// - 服务器没给出总长度（无 Content-Length）时无法预分配缓冲区，退化为下载完成后才 [ready]。
class ProgressiveDownload implements ProgressiveAudio {
  final List<String> urls;

  /// 解密方式（当前为 AES-128-CTR，见 [AesCtrDecryptSpec]）。
  final DecryptSpec decrypt;

  /// 解密在哪里执行：生产环境为常驻后台 Isolate，测试默认在当前线程。
  final DecryptBackend backend;
  final AudioFileFormat format;
  final http.Client client;

  /// 单个地址失败后重试的总次数上限（含轮换到其他地址）。
  final int maxAttempts;

  /// 同时进行的 HTTP 连接数上限（含首个顺序连接）；1 表示不并行。
  final int connections;

  /// 并行下载时每段的字节数。文件小于两段时不并行。
  final int segmentBytes;

  ProgressiveDownload({
    required this.urls,
    required this.decrypt,
    required this.format,
    required this.client,
    this.backend = const InlineDecryptBackend(),
    this.maxAttempts = 4,
    this.connections = 4,
    this.segmentBytes = 512 * 1024,
  }) : assert(connections >= 1),
       assert(segmentBytes > 0);

  /// 解密后的完整文件（含私有头）；总长度未知时下载期间为 null。
  Uint8List? _buffer;
  final _Intervals _filled = _Intervals();

  /// 从 0 开始连续可用的字节数。
  int _received = 0;
  int _skip = 0;
  Uint8List? _normalizationBytes;
  Object? _error;
  bool _started = false;

  final Completer<void> _ready = Completer<void>();
  final Completer<void> _done = Completer<void>();
  final List<({int pos, Completer<void> completer})> _waiters = [];
  final List<void Function(double progress)> _progressListeners = [];

  // ---- 并行分段状态 ----
  bool _parallelStarted = false;
  bool _parallelStopped = false;
  Object? _parallelError;

  /// 首个顺序连接负责 [0, _handoff)，之后交给分段连接；并行停止后恢复为整个文件。
  int _handoff = 1 << 62;

  /// 每段状态：0 待下载，1 下载中，2 已完成（或由首个连接负责）。
  List<int> _segState = const [];
  List<int> _segPos = const [];
  int _segCursor = 0;
  int _activeWorkers = 0;
  Completer<void>? _parallelDone;

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
    return total > 0 ? (_filled.total / total).clamp(0.0, 1.0) : 0.0;
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
    unawaited(_run());
  }

  Future<void> _run() async {
    if (urls.isEmpty) {
      _fail(StateError('没有可用的 CDN 地址'));
      return;
    }
    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final url = urls[attempt % urls.length];
      try {
        await _fetch(url);
        _complete();
        return;
      } catch (e) {
        lastError = e;
      }
    }
    _fail(StateError('所有 CDN 地址下载失败：$lastError'));
  }

  /// 首个连接：从连续可用的位置（续传时带 Range）顺序下载；
  /// 并行开启后只负责到 [_handoff]，随后等分段连接补齐其余部分。
  Future<void> _fetch(String url) async {
    final from = _received;
    final resume = from > 0 && _buffer != null;
    if (resume && _filled.total >= _buffer!.length) return; // 其余部分已由分段连接补齐
    final request = http.Request('GET', Uri.parse(url));
    if (resume) request.headers['Range'] = 'bytes=$from-';
    final response = await client.send(request);
    final status = response.statusCode;
    if (status != 200 && status != 206) {
      await response.stream.drain<void>().catchError((_) {});
      throw StateError('CDN 返回 HTTP $status');
    }

    // 服务器忽略 Range 时从头重新写（内容相同，已交给播放器的数据不受影响）
    var pos = status == 206 ? from : 0;
    if (_buffer == null) {
      final total = _totalLength(response);
      if (total != null && total > 0) _buffer = Uint8List(total);
    }
    final buffer = _buffer;
    if (buffer != null) _maybeStartParallel(buffer.length, pos);
    final decryptor = backend.open(decrypt, offset: pos);
    // 总长度未知：先收集，结束后再整体放入缓冲区
    final pending = buffer == null ? BytesBuilder(copy: false) : null;

    try {
      // 逐块等解密结果再读下一块：顺序天然保证，网络读取也随之形成背压
      await for (final chunk in response.stream) {
        final data = await decryptor.process(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
        if (buffer != null) {
          final limit = math.min(_handoff, buffer.length);
          if (pos + data.length > buffer.length) throw StateError('CDN 返回的数据超出声明长度');
          final end = math.min(pos + data.length, limit);
          if (end > pos) {
            buffer.setRange(pos, end, data);
            _filled.add(pos, end);
            pos = end;
            _afterFill();
          }
          if (pos >= limit) break; // 后面的部分交给分段连接（取消本连接）
        } else {
          pending!.add(data);
        }
      }
    } finally {
      decryptor.close();
    }

    if (pending != null) {
      final bytes = pending.takeBytes();
      if (bytes.isEmpty) throw StateError('CDN 返回空文件');
      _buffer = bytes;
      _filled.add(0, bytes.length);
      _afterFill();
      return;
    }
    if (pos < math.min(_handoff, buffer!.length)) {
      throw StateError('下载中断（$pos/${buffer.length}）');
    }
    if (_parallelStarted) {
      // 首个连接的区间已经下完，补上一条连接继续拉后面的段，并等它们全部完成
      _spawnWorkerIfNeeded();
      await _parallelDone!.future;
    }
    if (_filled.total < buffer.length) {
      throw StateError('下载中断（${_filled.total}/${buffer.length}${_parallelError == null ? '' : '，$_parallelError'}）');
    }
  }

  // ---------------------------------------------------------------- 并行分段

  /// 总长度已知、文件够大时，把 [首连接边界, 结尾) 切成段交给并行连接。
  void _maybeStartParallel(int total, int lanePos) {
    if (_parallelStarted || _parallelStopped || connections < 2) return;
    if (total < segmentBytes * 2) return;
    final handoff = ((lanePos ~/ segmentBytes) + 1) * segmentBytes;
    if (handoff >= total) return;
    final count = (total + segmentBytes - 1) ~/ segmentBytes;
    final firstSegment = handoff ~/ segmentBytes;
    _segState = [for (var i = 0; i < count; i++) i < firstSegment ? 2 : 0];
    _segPos = [for (var i = 0; i < count; i++) i * segmentBytes];
    _segCursor = firstSegment;
    _handoff = handoff;
    _parallelStarted = true;
    _parallelDone = Completer<void>();
    for (var k = 0; k < math.max(1, connections - 1); k++) {
      _spawnWorkerIfNeeded();
    }
  }

  bool get _parallelActive => _parallelStarted && !_parallelStopped && _error == null;

  bool get _hasPendingSegment => _segState.contains(0);

  void _spawnWorkerIfNeeded() {
    if (!_parallelActive || _activeWorkers >= connections || !_hasPendingSegment) {
      _finishParallelIfIdle();
      return;
    }
    unawaited(_worker());
  }

  Future<void> _worker() async {
    _activeWorkers++;
    try {
      while (_parallelActive) {
        final i = _claimSegment();
        if (i == null) break;
        await _fetchSegment(i);
      }
    } on _RangeIgnored {
      _stopParallel(); // 服务器不支持 Range：首个连接接管剩余部分
    } catch (e) {
      _parallelError ??= e;
      _stopParallel();
    } finally {
      _activeWorkers--;
      _finishParallelIfIdle();
    }
  }

  void _stopParallel() {
    _parallelStopped = true;
    _handoff = 1 << 62; // 首个连接（若还在跑）一直读到文件结尾
  }

  void _finishParallelIfIdle() {
    final done = _parallelDone;
    if (done == null || done.isCompleted || _activeWorkers > 0) return;
    if (_parallelActive && _hasPendingSegment) return; // 还有段没人领，等首个连接补位
    done.complete();
  }

  /// 领一段：优先从 [_segCursor]（播放位置附近）往后找，没有再从头找。
  int? _claimSegment() {
    final n = _segState.length;
    for (var k = 0; k < n; k++) {
      final i = (_segCursor + k) % n;
      if (_segState[i] == 0) {
        _segState[i] = 1;
        _segCursor = (i + 1) % n;
        return i;
      }
    }
    return null;
  }

  /// 播放器等着 [pos]：它所在的段还没人领的话，插队到最前。
  void _prioritize(int pos) {
    if (_segState.isEmpty) return;
    final i = pos ~/ segmentBytes;
    if (i < _segState.length && _segState[i] == 0) _segCursor = i;
  }

  Future<void> _fetchSegment(int i) async {
    final buffer = _buffer!;
    final segStart = i * segmentBytes;
    final segEnd = math.min(segStart + segmentBytes, buffer.length);
    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (!_parallelActive) {
        _segState[i] = 0;
        return;
      }
      var pos = _segPos[i];
      if (pos >= segEnd) {
        _segState[i] = 2;
        return;
      }
      try {
        final request = http.Request('GET', Uri.parse(urls[(i + attempt) % urls.length]))
          ..headers['Range'] = 'bytes=$pos-${segEnd - 1}';
        final response = await client.send(request);
        final status = response.statusCode;
        if (status == 200) {
          await response.stream.listen(null).cancel();
          throw const _RangeIgnored();
        }
        if (status != 206) {
          await response.stream.drain<void>().catchError((_) {});
          throw StateError('CDN 返回 HTTP $status');
        }
        final range = response.headers['content-range'];
        if (range != null && !range.startsWith('bytes $pos-')) {
          await response.stream.listen(null).cancel();
          throw StateError('CDN 返回的区间不符（$range）');
        }
        final decryptor = backend.open(decrypt, offset: pos);
        try {
          await for (final chunk in response.stream) {
            var data = await decryptor.process(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
            if (pos + data.length > segEnd) data = Uint8List.sublistView(data, 0, segEnd - pos);
            if (data.isEmpty) break;
            buffer.setRange(pos, pos + data.length, data);
            _filled.add(pos, pos + data.length);
            pos += data.length;
            _segPos[i] = pos;
            _afterFill();
            if (pos >= segEnd) break;
          }
        } finally {
          decryptor.close();
        }
        if (pos >= segEnd) {
          _segState[i] = 2;
          return;
        }
        lastError = StateError('分段 $i 提前结束（$pos/$segEnd）');
      } on _RangeIgnored {
        rethrow;
      } catch (e) {
        lastError = e;
      }
    }
    _segState[i] = 0;
    throw lastError ?? StateError('分段 $i 下载失败');
  }

  /// 总长度：200 取 Content-Length；206 取 Content-Range 的 `/total`。
  static int? _totalLength(http.StreamedResponse response) {
    if (response.statusCode == 206) {
      final range = response.headers['content-range'];
      final slash = range?.lastIndexOf('/') ?? -1;
      if (range != null && slash >= 0) return int.tryParse(range.substring(slash + 1).trim());
      return null;
    }
    return response.contentLength;
  }

  /// 有新数据写入缓冲区之后：刷新连续水位、判断可起播、通知进度与等待者。
  void _afterFill() {
    _received = _filled.prefix;
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
      if (!_filled.has(w.pos)) return false;
      w.completer.complete();
      return true;
    });
  }

  void _complete() {
    if (!_ready.isCompleted) _ready.complete();
    _done.complete();
    for (final listener in _progressListeners) {
      listener(1.0);
    }
    _progressListeners.clear();
    _releaseWaiters();
  }

  void _fail(Object error) {
    _error = error;
    if (!_ready.isCompleted) _ready.completeError(error);
    _done.completeError(error);
    _progressListeners.clear();
    _releaseWaiters();
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

  /// 等到字节 [pos]（文件坐标）可用。下载失败时抛错；下载已结束仍不够时直接返回。
  Future<void> _waitFor(int pos) {
    if (_filled.has(pos) || isComplete) return Future.value();
    if (_error != null) return Future.error(_error!);
    final completer = Completer<void>();
    _waiters.add((pos: pos, completer: completer));
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
      if (!_filled.has(pos)) {
        _prioritize(pos);
        await _waitFor(pos);
        if (!_filled.has(pos)) break; // 下载已结束但数据不够（不应发生）
      }
      final chunkEnd = math.min(math.min(_filled.endOf(pos), stop), pos + maxChunk);
      yield Uint8List.sublistView(buffer, pos, chunkEnd);
      pos = chunkEnd;
    }
  }
}
