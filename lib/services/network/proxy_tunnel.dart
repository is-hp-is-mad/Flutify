import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'network_proxy.dart';
import 'proxy_endpoint.dart';
import 'proxy_mode.dart';

/// AP only needs byte writes/flush/close; its stream can be TCP or binary WS.
class TunnelSocket {
  final Socket? tcpSocket;
  final void Function(List<int>) add;
  final Future<void> Function() flush;
  final void Function() destroy;
  TunnelSocket({
    this.tcpSocket,
    required this.add,
    required this.flush,
    required this.destroy,
  });
  factory TunnelSocket.tcp(Socket socket) => TunnelSocket(
    tcpSocket: socket,
    add: socket.add,
    flush: socket.flush,
    destroy: socket.destroy,
  );
}

/// 经 [NetworkProxy] 建立原始 TCP 连接（接入点协议不是 HTTP，不能直接交给 HttpClient）。
///
/// 需要代理时向 HTTP 代理发 `CONNECT host:port`，收到 200 后这条连接就是到目标的透明隧道；
/// SOCKS5 代理则走自建握手（dart:io 不支持 SOCKS）。手动代理配了用户名 / 密码时
/// 会随 CONNECT 带上 `Proxy-Authorization: Basic …`。
/// 返回的 [input] 是隧道建立后的数据（代理响应头之后的字节）；直连时就是 socket 本身。
/// socket 是单订阅流，读响应头时已经订阅过，所以调用方必须改为读 [input]。
class ProxyTunnel {
  ProxyTunnel._();

  static Future<({TunnelSocket socket, Stream<Uint8List> input})> connect(
    String host,
    int port, {
    required Duration timeout,
    NetworkProxy? proxy,
    ProxyEndpoint? endpoint,
    bool useGateway = true,
  }) async {
    final net = proxy ?? NetworkProxy.instance;
    final gateway = net.gateway;
    if (useGateway && gateway.enabled) {
      // A dedicated client makes a timed-out handshake cancellable and uses
      // the same forward-proxy policy as all other requests.
      final client = HttpClient()..findProxy = net.findProxy;
      try {
        final ws = await WebSocket.connect(
          gateway.tunnel(host, port).toString(),
          headers: gateway.headers,
          customClient: client,
          compression: CompressionOptions.compressionOff,
        ).timeout(timeout);
        ws.pingInterval = const Duration(seconds: 30);
        return (
          socket: TunnelSocket(
            add: (bytes) => ws.add(Uint8List.fromList(bytes)),
            flush: () async {},
            destroy: () {
              unawaited(ws.close());
              client.close(force: true);
            },
          ),
          input: ws.map((frame) {
            if (frame is! List<int>)
              throw const ProxyTunnelException(
                'AP tunnel received a text frame',
              );
            return Uint8List.fromList(frame);
          }),
        );
      } catch (_) {
        client.close(force: true);
        rethrow;
      }
    }
    // 自动配置（PAC）也要能解析到这里的原始 TCP 连接（AP 协议不走 HttpClient）
    final resolved =
        endpoint ??
        await net.endpointForAsync(
          Uri(scheme: 'https', host: host, port: port),
        );
    if (resolved == null) {
      final socket = await Socket.connect(host, port, timeout: timeout);
      return (socket: TunnelSocket.tcp(socket), input: socket);
    }
    if (resolved.type == ProxyType.socks5) {
      return _socks5(host, port, resolved, timeout);
    }

    final socket = await Socket.connect(
      resolved.host,
      resolved.port,
      timeout: timeout,
    );
    final target = host.contains(':') ? '[$host]:$port' : '$host:$port';
    // 认证只在配置了手动代理凭据时带上（CONNECT 头是自己拼的，用户名 / 密码任意字符都安全）
    final auth = net.mode == ProxyMode.manual && net.manualHasCredentials
        ? 'Proxy-Authorization: Basic ${base64Encode(utf8.encode('${net.manualUsername}:${net.manualPassword}'))}\r\n'
        : '';
    socket.add(
      ascii.encode('CONNECT $target HTTP/1.1\r\nHost: $target\r\n$auth\r\n'),
    );

    final output = StreamController<Uint8List>();
    final established = Completer<void>();
    final header = BytesBuilder(copy: false);
    var open = false;

    socket.listen(
      (data) {
        if (open) {
          output.add(data);
          return;
        }
        header.add(data);
        final bytes = header.toBytes();
        final end = _headerEnd(bytes);
        if (end < 0) {
          if (bytes.length > 16 * 1024) {
            _fail(established, socket, const ProxyTunnelException('代理响应头过长'));
          }
          return;
        }
        final status = latin1.decode(bytes.sublist(0, end)).split('\r\n').first;
        if (RegExp(r'^HTTP/1\.[01] 407').hasMatch(status)) {
          // 凭据缺失或不对：单独说清楚，免得被当成「代理挂了」排查半天
          _fail(
            established,
            socket,
            ProxyTunnelException('代理认证失败（$status）：请检查用户名与密码'),
          );
          return;
        }
        if (!RegExp(r'^HTTP/1\.[01] 2\d\d').hasMatch(status)) {
          _fail(established, socket, ProxyTunnelException('代理拒绝连接：$status'));
          return;
        }
        open = true;
        established.complete();
        // 响应头后面紧跟的字节已属于目标服务器
        if (bytes.length > end + 4) {
          output.add(Uint8List.sublistView(bytes, end + 4));
        }
      },
      onError: (Object e) => established.isCompleted
          ? output.addError(e)
          : _fail(established, socket, e),
      onDone: () {
        if (!established.isCompleted) {
          _fail(established, socket, const ProxyTunnelException('代理关闭了连接'));
        }
        output.close();
      },
    );

    try {
      await established.future.timeout(timeout);
    } catch (_) {
      socket.destroy();
      rethrow;
    }
    return (socket: TunnelSocket.tcp(socket), input: output.stream);
  }

  /// SOCKS5（RFC 1928，免认证 + 域名寻址）：CONNECT 到 [host]:[port]，
  /// 与 HTTP CONNECT 一样把握手之后的字节交给调用方。
  static Future<({TunnelSocket socket, Stream<Uint8List> input})> _socks5(
    String host,
    int port,
    ProxyEndpoint endpoint,
    Duration timeout,
  ) async {
    final socket = await Socket.connect(
      endpoint.host,
      endpoint.port,
      timeout: timeout,
    );
    final output = StreamController<Uint8List>();
    final established = Completer<void>();
    final pending = <int>[];
    final hostBytes = utf8.encode(host);
    var phase = 0; // 0 = 等问候响应，1 = 等 CONNECT 响应
    var done = false;

    void fail(Object error) {
      if (!established.isCompleted) established.completeError(error);
      socket.destroy();
    }

    void process() {
      while (!done) {
        if (phase == 0) {
          if (pending.length < 2) return;
          if (pending[0] != 5 || pending[1] != 0) {
            fail(const ProxyTunnelException('SOCKS5 代理不支持免认证连接'));
            return;
          }
          pending.removeRange(0, 2);
          socket.add([
            5,
            1,
            0,
            3,
            hostBytes.length,
            ...hostBytes,
            (port >> 8) & 0xff,
            port & 0xff,
          ]);
          phase = 1;
          continue;
        }
        if (pending.length < 4) return;
        if (pending[0] != 5) {
          fail(const ProxyTunnelException('SOCKS5 代理响应格式错误'));
          return;
        }
        if (pending[1] != 0) {
          fail(
            ProxyTunnelException('SOCKS5 代理拒绝连接：${_socksReply(pending[1])}'),
          );
          return;
        }
        final atyp = pending[3];
        int addressLength;
        if (atyp == 1) {
          addressLength = 4;
        } else if (atyp == 4) {
          addressLength = 16;
        } else if (atyp == 3) {
          if (pending.length < 5) return;
          addressLength = pending[4];
        } else {
          fail(const ProxyTunnelException('SOCKS5 代理返回未知地址类型'));
          return;
        }
        // VER + REP + RSV + ATYP + ADDR + PORT
        final replyLength = 4 + addressLength + 2 + (atyp == 3 ? 1 : 0);
        if (pending.length < replyLength) return;
        pending.removeRange(0, replyLength);
        done = true;
      }
    }

    socket.listen(
      (data) {
        if (done) {
          output.add(data);
          return;
        }
        pending.addAll(data);
        process();
        if (done && !established.isCompleted) established.complete();
        if (done && pending.isNotEmpty) {
          output.add(Uint8List.fromList(pending));
          pending.clear();
        }
      },
      onError: (Object e) => established.isCompleted
          ? output.addError(e)
          : fail(e),
      onDone: () {
        if (!established.isCompleted) {
          fail(const ProxyTunnelException('代理关闭了连接'));
        }
        output.close();
      },
    );
    socket.add([5, 1, 0]); // VER=5, NMETHODS=1, NO AUTH
    try {
      await established.future.timeout(timeout);
    } catch (_) {
      socket.destroy();
      rethrow;
    }
    return (socket: TunnelSocket.tcp(socket), input: output.stream);
  }

  /// SOCKS5 应答码的可读说明（RFC 1928 §6）。
  static String _socksReply(int code) => switch (code) {
    1 => 'general failure',
    2 => 'connection not allowed',
    3 => 'network unreachable',
    4 => 'host unreachable',
    5 => 'connection refused',
    6 => 'TTL expired',
    7 => 'command not supported',
    8 => 'address type not supported',
    _ => 'code $code',
  };

  static void _fail(Completer<void> established, Socket socket, Object error) {
    if (!established.isCompleted) established.completeError(error);
    socket.destroy();
  }

  /// `\r\n\r\n` 的位置；没有时返回 -1。
  static int _headerEnd(Uint8List b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }
}

class ProxyTunnelException implements Exception {
  final String message;
  const ProxyTunnelException(this.message);

  @override
  String toString() => message;
}
