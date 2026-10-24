import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../../../core/rust_core.dart';
import 'audio_decryptor.dart';

export 'audio_decryptor.dart';

/// 一路解密流：按顺序提交数据块，按相同顺序拿回明文。
abstract class ChunkDecryptor {
  /// 解密一个数据块。调用方需等上一块完成后再提交下一块（ProgressiveDownload 即如此）。
  /// [data] 的所有权交给解密器（后台实现会把它转移到另一个 Isolate），调用后不要再使用。
  Future<Uint8List> process(Uint8List data);

  /// 结束这一路（释放后台资源）。
  void close();
}

/// 解密在哪里执行。
abstract class DecryptBackend {
  ChunkDecryptor open(DecryptSpec spec, {int offset = 0});
}

/// 在当前 Isolate 里同步解密（测试、或后台 Isolate 不可用时兜底）。
class InlineDecryptBackend implements DecryptBackend {
  const InlineDecryptBackend();

  @override
  ChunkDecryptor open(DecryptSpec spec, {int offset = 0}) => _InlineChunkDecryptor(spec.create(offset));
}

class _InlineChunkDecryptor implements ChunkDecryptor {
  final AudioDecryptor _decryptor;

  _InlineChunkDecryptor(this._decryptor);

  @override
  Future<Uint8List> process(Uint8List data) {
    _decryptor.process(data);
    return Future.value(data);
  }

  @override
  void close() {}
}

/// 常驻后台 Isolate 解密：下载线程（主 Isolate）只收发数据，逐字节运算不占 UI 线程。
///
/// - Isolate 在第一次使用（或 [warmUp]）时启动，之后一直保留，供所有曲目共用；
/// - 数据块用 [TransferableTypedData] 传递（每个方向只拷贝一次，不经过消息序列化）；
/// - 后台 Isolate 意外退出时，进行中的请求以错误结束（下载会按偏移续传重试），下次使用时自动重建。
class IsolateDecryptBackend implements DecryptBackend {
  Future<_DecryptWorker>? _worker;
  int _nextSession = 0;

  /// 提前启动后台 Isolate（App 启动时调用，第一次播放不必等它启动）。
  Future<void> warmUp() => _ensureWorker().then((_) {}, onError: (Object _) {});

  Future<_DecryptWorker> _ensureWorker() {
    final existing = _worker;
    if (existing != null) return existing;
    late final Future<_DecryptWorker> spawned;
    void forget() {
      if (identical(_worker, spawned)) _worker = null;
    }

    spawned = _DecryptWorker.spawn(onExit: forget).catchError((Object e) {
      forget();
      throw e;
    });
    return _worker = spawned;
  }

  @override
  ChunkDecryptor open(DecryptSpec spec, {int offset = 0}) {
    final id = _nextSession++;
    final opened = _ensureWorker().then((worker) {
      worker.openSession(id, spec, offset);
      return worker;
    });
    opened.ignore(); // 错误在 process 时抛出
    return _IsolateChunkDecryptor(id, opened);
  }

  /// 关闭后台 Isolate。
  Future<void> dispose() async {
    final worker = _worker;
    _worker = null;
    if (worker == null) return;
    try {
      (await worker).kill();
    } catch (_) {}
  }
}

class _IsolateChunkDecryptor implements ChunkDecryptor {
  final int _session;
  final Future<_DecryptWorker> _worker;
  bool _closed = false;

  _IsolateChunkDecryptor(this._session, this._worker);

  @override
  Future<Uint8List> process(Uint8List data) async {
    if (_closed) throw StateError('解密流已关闭');
    final worker = await _worker;
    return worker.process(_session, data);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _worker.then((w) => w.closeSession(_session), onError: (Object _) {});
  }
}

/// 后台 Isolate 的主线程一侧。
class _DecryptWorker {
  final Isolate _isolate;
  final SendPort _send;
  final ReceivePort _receive;
  final Map<int, Completer<Uint8List>> _pending = {};
  int _nextRequest = 0;
  bool _dead = false;

  _DecryptWorker._(this._isolate, this._send, this._receive);

  static Future<_DecryptWorker> spawn({required void Function() onExit}) async {
    final receive = ReceivePort('flutify-decrypt');
    final exit = ReceivePort('flutify-decrypt-exit');
    final isolate = await Isolate.spawn(
      _workerMain,
      (receive.sendPort, RustCore.ready),
      debugName: 'flutify-decrypt',
      onExit: exit.sendPort,
      onError: exit.sendPort,
      errorsAreFatal: true,
    );
    final messages = receive.asBroadcastStream();
    final send = await messages.first as SendPort;
    final worker = _DecryptWorker._(isolate, send, receive);
    messages.listen(worker._onMessage);
    // onError 发来 [错误, 堆栈]，onExit 发来 null；两者都意味着这个 Isolate 不再可用
    exit.listen((message) {
      worker._die(StateError('后台解密线程已退出：$message'));
      if (message == null) {
        exit.close();
        onExit();
      }
    });
    return worker;
  }

  void openSession(int session, DecryptSpec spec, int offset) => _send.send(['open', session, spec, offset]);

  void closeSession(int session) {
    if (!_dead) _send.send(['close', session]);
  }

  Future<Uint8List> process(int session, Uint8List data) {
    if (_dead) return Future.error(StateError('后台解密线程已退出'));
    final request = _nextRequest++;
    final completer = Completer<Uint8List>();
    _pending[request] = completer;
    _send.send(['data', session, request, TransferableTypedData.fromList([data])]);
    return completer.future;
  }

  void _onMessage(Object? message) {
    if (message is! List || message.length != 2) return;
    final completer = _pending.remove(message[0]);
    if (completer == null) return;
    final payload = message[1];
    if (payload is TransferableTypedData) {
      completer.complete(payload.materialize().asUint8List());
    } else {
      completer.completeError(StateError('解密失败：$payload'));
    }
  }

  void _die(Object error) {
    if (_dead) return;
    _dead = true;
    for (final c in _pending.values) {
      c.completeError(error);
    }
    _pending.clear();
    _receive.close();
  }

  void kill() {
    _die(StateError('后台解密线程已关闭'));
    _isolate.kill(priority: Isolate.immediate);
  }
}

/// 后台 Isolate 入口：维护每一路的解密器，按收到的顺序处理并原路返回。
Future<void> _workerMain((SendPort, bool) args) async {
  final (toMain, useRust) = args;
  // Isolate 的静态状态各自独立：主 Isolate 加载过 Rust 核心，这里仍需单独加载，
  // 否则 AesCtr 永远走纯 Dart 实现。先加载再交出端口，保证每路解密从头到尾用同一实现。
  if (useRust) await RustCore.initialize(exitOnFailure: false);
  final port = ReceivePort();
  toMain.send(port.sendPort);
  final sessions = <int, AudioDecryptor>{};
  port.listen((message) {
    if (message is! List) return;
    switch (message[0]) {
      case 'open':
        final spec = message[2] as DecryptSpec;
        sessions[message[1] as int] = spec.create(message[3] as int);
      case 'data':
        final request = message[2] as int;
        final data = (message[3] as TransferableTypedData).materialize().asUint8List();
        final decryptor = sessions[message[1] as int];
        if (decryptor == null) {
          toMain.send([request, '解密流不存在']);
          return;
        }
        try {
          decryptor.process(data);
          toMain.send([request, TransferableTypedData.fromList([data])]);
        } catch (e) {
          toMain.send([request, '$e']);
        }
      case 'close':
        sessions.remove(message[1] as int);
    }
  });
}
