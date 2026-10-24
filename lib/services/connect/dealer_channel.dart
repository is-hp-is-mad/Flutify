import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/rust_core.dart';
import '../../src/rust/api/network.dart' as rust_net;
import '../../src/rust/api/protocol.dart' as rust;
import '../network/direct_route.dart';

/// dealer 长连接的最小传输抽象：只收发文本帧，便于测试时替换成内存实现。
abstract class DealerChannel {
  /// 收到的文本帧；连接关闭时流结束，出错时流报错。
  Stream<String> get messages;

  void send(String text);

  Future<void> close();
}

/// 建立 dealer 连接：[uri] 已带 `access_token`，[headers] 只含 `User-Agent` 这类握手头。
typedef DealerConnector = Future<DealerChannel> Function(Uri uri, Map<String, String> headers);

/// 默认实现：dart:io WebSocket。
class WebSocketDealerChannel implements DealerChannel {
  final WebSocket _socket;

  WebSocketDealerChannel._(this._socket);

  static Future<DealerChannel> connect(Uri uri, Map<String, String> headers) async {
    final socket = await WebSocket.connect(uri.toString(), headers: headers);
    return WebSocketDealerChannel._(socket);
  }

  /// dealer 只发文本帧；万一收到二进制帧按 UTF-8 解成文本，交给上层 JSON 解析去判断。
  @override
  Stream<String> get messages => _socket.map((data) => data is String ? data : utf8.decode(data as List<int>));

  @override
  void send(String text) => _socket.add(text);

  @override
  Future<void> close() => _socket.close();
}

/// Rust WebSocket（tokio-tungstenite + rustls）。直连时使用；网关 / 代理，或 Rust 握手没连上
/// （建连 / TLS 失败）时退回 dart:io 的 [WebSocketDealerChannel]。服务端拒绝握手（如令牌过期）不重试。
class RustDealerChannel implements DealerChannel {
  final int _id;
  final Stream<String> _messages;
  final StreamSubscription<rust_net.WebSocketEvent> _subscription;
  final Completer<void> _closed;

  RustDealerChannel._(this._id, this._messages, this._subscription, this._closed);

  static int _nextId = 1;

  /// 握手超时（与 dart:io 默认的连接超时量级一致）。
  static const Duration handshakeTimeout = Duration(seconds: 30);

  static Future<DealerChannel> connect(Uri uri, Map<String, String> headers) async {
    if (!RustCore.ready || !await isDirectRoute(uri)) {
      return WebSocketDealerChannel.connect(uri, headers);
    }
    final id = _nextId++;
    final messages = StreamController<String>();
    final opened = Completer<void>();
    final closed = Completer<void>();
    void finish() {
      if (!messages.isClosed) unawaited(messages.close());
      if (!closed.isCompleted) closed.complete();
    }

    late final StreamSubscription<rust_net.WebSocketEvent> subscription;
    subscription = rust_net
        .websocketConnect(
          id: id,
          url: uri.toString(),
          headers: [
            for (final h in headers.entries)
              rust.HttpHeaderEntry(name: h.key, value: h.value),
          ],
        )
        .listen(
          (e) {
            switch (e.kind) {
              case 0: // 已连接
                if (!opened.isCompleted) opened.complete();
              case 1: // 文本帧
                if (!messages.isClosed) messages.add(e.text);
              case 2: // 已关闭
                finish();
              case 3: // 出错
                if (!opened.isCompleted) {
                  opened.completeError(_HandshakeError(e.text));
                } else {
                  if (!messages.isClosed) {
                    messages.addError(WebSocketException(e.text.replaceFirst(RegExp('^[a-z]+:'), '')));
                  }
                  finish();
                }
            }
          },
          onDone: () {
            if (!opened.isCompleted) {
              opened.completeError(const _HandshakeError('connect:连接意外结束'));
            }
            finish();
          },
        );
    try {
      await opened.future.timeout(handshakeTimeout);
    } catch (e) {
      await subscription.cancel();
      finish();
      if (e is _HandshakeError && !e.message.startsWith('connect:')) {
        throw WebSocketException(e.message.replaceFirst(RegExp('^[a-z]+:'), ''));
      }
      // 建连 / TLS / 超时：Rust 这条路没连上，改用 dart:io 再试一次
      return WebSocketDealerChannel.connect(uri, headers);
    }
    return RustDealerChannel._(id, messages.stream, subscription, closed);
  }

  @override
  Stream<String> get messages => _messages;

  @override
  void send(String text) {
    try {
      rust_net.websocketSend(id: _id, text: text);
    } catch (e) {
      throw const WebSocketException('WebSocket 已关闭');
    }
  }

  @override
  Future<void> close() async {
    rust_net.websocketClose(id: _id);
    // 等 Rust 端确认关闭；对端不回 Close 帧时不无限等待
    await _closed.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    await _subscription.cancel();
  }
}

class _HandshakeError implements Exception {
  final String message;
  const _HandshakeError(this.message);

  @override
  String toString() => message;
}
