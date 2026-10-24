import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../core/rust_core.dart';
import '../../src/rust/api/network.dart' as rust_net;
import '../../src/rust/api/protocol.dart' as rust;
import '../network/direct_route.dart';

/// 多连接分段下载：把文件按 [segmentBytes] 切段，最多 [connections] 个 HTTP Range 请求并行拉取，
/// 写进同一个文件的对应偏移。
///
/// 规则：
/// - 首段先单独请求（`Range: bytes=0-…`），顺便从 `Content-Range` 拿到总长；
///   服务器不支持 Range（回 200）时退化为单连接顺序下载；
/// - 段按偏移从小到大分配给空闲连接，保证「从头开始的连续可用字节」尽快增长（HLS 按顺序取段）；
/// - [onContiguous] 报告从 0 开始已连续落盘的字节数，语义与单连接顺序下载一致；
/// - 单段失败时换下一个 CDN 地址重试，累计 [maxAttemptsPerSegment] 次仍失败则整体失败。
///
/// 直连时由 Rust（flutify_core `downloads::download_to_file`）完成同样的下载与写文件，CDN 支持
/// HTTP/2 时多段共用一条连接；Rust 建连失败（一个字节都没收到）时退回下面的 Dart 实现。
class SegmentedDownload {
  final http.Client client;
  final List<String> urls;
  final File dest;
  final Map<String, String> headers;
  final int segmentBytes;
  final int connections;
  final int maxAttemptsPerSegment;

  /// 连续可用字节数变化（每写入一块数据都可能调用）。
  final void Function(int contiguousBytes, int totalBytes) onContiguous;

  SegmentedDownload({
    required this.client,
    required this.urls,
    required this.dest,
    required this.onContiguous,
    this.headers = const {},
    this.segmentBytes = 512 * 1024,
    this.connections = 4,
    this.maxAttemptsPerSegment = 3,
  }) : assert(urls.isNotEmpty);

  late RandomAccessFile _raf;

  /// 文件写入串行化：RandomAccessFile 不允许并发操作。
  Future<void> _writeChain = Future.value();

  /// 各段已顺序写入的字节数（段内从段首连续增长）。
  late List<int> _segmentGot;
  late List<int> _segmentLen;
  int _total = 0;
  int _urlCursor = 0;

  /// 下载整个文件；完成时返回总字节数。
  Future<int> run() async {
    if (RustCore.ready && await _allDirect()) {
      final total = await _runRust();
      if (total != null) return total;
    }
    return _runDart();
  }

  Future<bool> _allDirect() async {
    for (final url in urls) {
      if (!await isDirectRoute(Uri.parse(url))) return false;
    }
    return true;
  }

  /// Rust 下载；建连失败（尚未写入任何数据）时返回 null，交给 Dart 实现重试。
  Future<int?> _runRust() async {
    var wrote = false;
    await for (final e in rust_net.audioDownloadToFile(
      urls: urls,
      headers: [
        for (final h in headers.entries)
          rust.HttpHeaderEntry(name: h.key, value: h.value),
      ],
      path: dest.path,
      segmentBytes: segmentBytes,
      connections: connections,
      maxAttemptsPerSegment: maxAttemptsPerSegment,
    )) {
      switch (e.kind) {
        case 0: // 元信息
          _total = e.total;
        case 2: // 连续可用字节
          wrote = true;
          _total = e.total;
          onContiguous(e.bytes, e.total);
        case 3: // 完成
          return _total = e.total;
        case 4: // 失败
          if (!wrote && e.message.startsWith('connect:')) return null;
          throw HttpException(e.message.replaceFirst(RegExp('^[a-z]+:'), ''));
      }
    }
    throw const HttpException('下载意外中断');
  }

  Future<int> _runDart() async {
    await dest.parent.create(recursive: true);
    _raf = await dest.open(mode: FileMode.write);
    try {
      final first = await _openRange(0, segmentBytes - 1);
      if (first.statusCode == 200) {
        // 不支持 Range：整份在这一个响应里顺序写完
        _total = first.contentLength ?? 0;
        _segmentLen = [_total];
        _segmentGot = [0];
        await _consume(first, 0);
        return _total = _segmentGot[0];
      }
      _total = _totalFromContentRange(first.headers['content-range']) ?? 0;
      if (_total <= 0) throw const HttpException('CDN 未返回 Content-Range 总长');

      final count = (_total + segmentBytes - 1) ~/ segmentBytes;
      _segmentLen = [
        for (var i = 0; i < count; i++) math.min(segmentBytes, _total - i * segmentBytes),
      ];
      _segmentGot = List.filled(count, 0);

      var next = 1;
      Future<void> worker() async {
        while (next < count) {
          final i = next++;
          await _fetchSegment(i);
        }
      }

      // 首段与其余连接同时进行
      await Future.wait([
        _consume(first, 0).catchError((Object _) => _fetchSegment(0)),
        for (var c = 0; c < math.max(1, connections - 1); c++) worker(),
      ]);
      await _writeChain;
      return _total;
    } finally {
      await _writeChain.catchError((Object _) {});
      await _raf.close();
    }
  }

  /// 拉取第 [i] 段；失败时从已收到的位置续传并轮换 CDN。
  Future<void> _fetchSegment(int i) async {
    Object? lastError;
    for (var attempt = 0; attempt < maxAttemptsPerSegment; attempt++) {
      final start = i * segmentBytes + _segmentGot[i];
      final end = i * segmentBytes + _segmentLen[i] - 1;
      if (start > end) return;
      try {
        final res = await _openRange(start, end);
        if (res.statusCode != 206) {
          await res.stream.drain<void>();
          throw HttpException('分段请求 HTTP ${res.statusCode}');
        }
        await _consume(res, i);
        if (_segmentGot[i] >= _segmentLen[i]) return;
        lastError = const HttpException('分段响应提前结束');
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? StateError('分段 $i 下载失败');
  }

  /// 把响应体顺序写到第 [i] 段的当前位置。
  Future<void> _consume(http.StreamedResponse res, int i) async {
    await for (final chunk in res.stream) {
      final offset = i * segmentBytes + _segmentGot[i];
      _segmentGot[i] += chunk.length;
      _writeChain = _writeChain.then((_) async {
        await _raf.setPosition(offset);
        await _raf.writeFrom(chunk);
      });
      await _writeChain;
      onContiguous(_contiguous(), _total);
    }
  }

  /// 从 0 开始连续写完的字节数：前面完整的段 + 第一个未完成段已写入的部分。
  int _contiguous() {
    var sum = 0;
    for (var i = 0; i < _segmentGot.length; i++) {
      sum += _segmentGot[i];
      if (_segmentGot[i] < _segmentLen[i]) break;
    }
    return sum;
  }

  Future<http.StreamedResponse> _openRange(int start, int end) {
    final url = urls[_urlCursor++ % urls.length];
    final req = http.Request('GET', Uri.parse(url))
      ..headers.addAll(headers)
      ..headers['Range'] = 'bytes=$start-$end';
    return client.send(req);
  }

  static int? _totalFromContentRange(String? range) {
    final slash = range?.lastIndexOf('/') ?? -1;
    if (range == null || slash < 0) return null;
    return int.tryParse(range.substring(slash + 1).trim());
  }
}
