import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/rust_core.dart';
import '../../src/rust/api/backend.dart' as rust;
import '../auth/client_profile.dart';
import '../auth/proto_codec.dart';
import '../network/proxy_tunnel.dart';
import '../rust_backend_bridge.dart';
import 'ap_codec.dart';
import 'ap_crypto.dart' as ap_crypto;
import 'ap_login_request.dart';

/// AP 包类型（librespot `packet.rs`）。
class ApPacketType {
  static const int ping = 0x04;
  static const int requestKey = 0x0c;
  static const int aesKey = 0x0d;
  static const int aesKeyError = 0x0e;
  static const int pong = 0x49;
  static const int pongAck = 0x4a;
  static const int login = 0xab;
  static const int apWelcome = 0xac;
  static const int authFailure = 0xad;

  /// Mercury 请求 / 响应（hm:// 内部接口，如 metadata/4/episode）。
  static const int mercuryReq = 0xb2;
}

/// AP 登录凭据（`authentication.proto` LoginCredentials）。
class ApCredentials {
  /// AUTHENTICATION_USER_PASS。
  static const int typeUserPass = 0;

  /// AUTHENTICATION_STORED_SPOTIFY_CREDENTIALS（可复用 blob 原样回传）。
  static const int typeStoredCredentials = 1;

  /// AUTHENTICATION_SPOTIFY_TOKEN（Login5/OAuth 的 access_token）。
  static const int typeSpotifyToken = 3;

  final String? username;
  final int authType;
  final Uint8List authData;

  const ApCredentials({
    this.username,
    required this.authType,
    required this.authData,
  });

  factory ApCredentials.accessToken(String token) => ApCredentials(
    authType: typeSpotifyToken,
    authData: Uint8List.fromList(token.codeUnits),
  );

  factory ApCredentials.password(String username, String password) =>
      ApCredentials(
        username: username,
        authType: typeUserPass,
        authData: Uint8List.fromList(password.codeUnits),
      );

  factory ApCredentials.storedBlob(String username, Uint8List blob) =>
      ApCredentials(
        username: username,
        authType: typeStoredCredentials,
        authData: blob,
      );
}

/// APWelcome 中的登录结果。
class ApWelcome {
  final String canonicalUsername;
  final int reusableAuthType;
  final Uint8List reusableAuth;

  const ApWelcome({
    required this.canonicalUsername,
    required this.reusableAuthType,
    required this.reusableAuth,
  });
}

/// AP 登录失败（AuthFailure / APLoginFailed）。
class ApLoginException implements Exception {
  final int errorCode;
  final String? description;

  const ApLoginException(this.errorCode, [this.description]);

  static const _messages = <int, String>{
    0x00: '协议错误',
    0x02: '该接入点不可用，请换一个（TryAnotherAP）',
    0x05: '连接 ID 无效',
    0x09: '地区限制',
    0x0b: '需要 Premium 账号',
    0x0c: '凭据无效',
    0x0d: '凭据无法验证',
    0x0e: '账号已存在',
    0x0f: '需要额外验证',
    0x10: 'App Key 无效',
    0x11: '应用已被封禁',
  };

  String get message => (description != null && description!.isNotEmpty)
      ? description!
      : (_messages[errorCode] ?? 'AP 登录失败（错误码 $errorCode）');

  @override
  String toString() => message;
}

/// Mercury 请求返回非 200 状态。
class ApMercuryException implements Exception {
  final int statusCode;
  const ApMercuryException(this.statusCode);

  @override
  String toString() => 'Mercury 请求失败（状态 $statusCode）';
}

/// 取音频密钥失败。
class ApKeyException implements Exception {
  final int code;

  /// 服务端原始错误负载（供诊断）。
  final Uint8List raw;
  ApKeyException(this.code, [Uint8List? raw]) : raw = raw ?? Uint8List(0);

  @override
  String toString() =>
      '获取音频密钥失败（错误码 $code${raw.isEmpty ? '' : ' raw=${raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'}）';
}

/// Spotify Access Point 会话：握手（DH + Shannon）→ 登录 → 取音频密钥。
///
/// 这是「完整曲目」链路里唯一必须走非 HTTP 协议的环节（音频密钥没有 REST 接口），
/// 其余（metadata / storage-resolve / CDN 下载）都是普通 HTTPS。对照 librespot
/// `connection/handshake.rs`、`session.rs`、`audio_key.rs` 与官方 `docs/connection.md`。
class SpotifyAccessPoint {
  final TunnelSocket? _socket;
  final bool _rustMode;
  final String? _rustProxy;
  BigInt? _rustSessionId;

  /// 单订阅 socket 的常驻接收：握手期收明文帧，之后喂给 [ApCodec]。
  final BytesBuilder _preCodecBuffer = BytesBuilder();
  final List<Completer<({Uint8List payload, Uint8List raw})>> _handshakeFrames =
      [];
  ApCodec? _codec;

  final Map<int, Completer<Uint8List>> _pendingKeys = {};
  int _keySeq = 0;

  /// 进行中的 Mercury 请求（seq → 结果）。
  final Map<int, Completer<Uint8List>> _pendingMercury = {};
  int _mercurySeq = 0;

  Completer<ApWelcome>? _loginWaiter;
  Timer? _pongTimer;
  bool _closed = false;

  /// 连接是否已关闭（服务端断开 / 出错 / 主动关闭），关闭后需重新 connect。
  bool get isClosed => _closed;

  /// 登录成功后的用户名（canonical）。
  String? canonicalUsername;

  /// 可复用凭据（APWelcome 返回，可持久化后免密重登）。
  ({int type, Uint8List blob})? reusableCredentials;

  /// [input] 为经代理隧道建立的连接上的数据流（见 [ProxyTunnel]）；直连时就是 socket 本身。
  SpotifyAccessPoint._(this._socket, Stream<Uint8List> input)
    : _rustMode = false,
      _rustProxy = null {
    input.listen(
      (data) => _onBytes(Uint8List.fromList(data)),
      onError: _abort,
      onDone: () => _abort(StateError('AP 连接已关闭')),
      cancelOnError: true,
    );
  }

  SpotifyAccessPoint._rust(this._rustProxy)
    : _socket = null,
      _rustMode = true;

  // -------------------------------------------------------------------------
  // 连接与握手
  // -------------------------------------------------------------------------

  /// 解析接入点，返回单个随机候选（兼容旧调用）。
  static Future<({String host, int port})> resolveAccessPoint({
    http.Client? client,
  }) async => (await resolveAccessPoints(client: client)).first;

  /// 解析全部接入点（`https://apresolve.spotify.com/?type=accesspoint`）。
  ///
  /// 排序规则：端口 4070 → 443 → 80（部分代理 / TUN 环境会丢弃 :80 的非 HTTP 流量），
  /// 同端口内随机打散，分摊负载。
  static Future<List<({String host, int port})>> resolveAccessPoints({
    http.Client? client,
  }) async {
    final c = client ?? http.Client();
    try {
      final res = await c
          .get(
            Uri.parse('https://apresolve.spotify.com/?type=accesspoint'),
            headers: {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 10));
      final match = RegExp(
        r'"accesspoint"\s*:\s*\[([^\]]*)\]',
      ).firstMatch(res.body);
      final entries = RegExp(r'"([^"]+)"')
          .allMatches(match?.group(1) ?? '')
          .map((m) => m.group(1)!)
          .where((s) => s.contains(':'))
          .toList();
      if (entries.isEmpty) throw StateError('apresolve 未返回接入点');
      int rank(int port) => switch (port) {
        4070 => 0,
        443 => 1,
        _ => 2,
      };
      final parsed = [
        for (final e in entries)
          (host: e.split(':')[0], port: int.parse(e.split(':')[1])),
      ]..shuffle(Random.secure());
      parsed.sort((a, b) => rank(a.port).compareTo(rank(b.port)));
      return parsed;
    } finally {
      if (client == null) c.close();
    }
  }

  /// 连接接入点并完成握手（明文阶段：ClientHello → APResponse → ClientResponsePlaintext）。
  static Future<SpotifyAccessPoint> connect({
    String? host,
    int? port,
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
    bool useRustBackend = false,
  }) async {
    if (useRustBackend && host == null && port == null && RustCore.ready) {
      final proxy = await RustBackendBridge.proxyForUrl(
        'https://apresolve.spotify.com/?type=accesspoint',
      );
      return SpotifyAccessPoint._rust(proxy);
    }
    if (host != null && port != null) {
      return _connectTo(host, port, timeout);
    }
    // 依次尝试候选：单个接入点不可达 / 被网络环境重置（部分地区只有个别接入点可达）
    // 不应让整条播放链路失败。上次连通的接入点排在最前，其后最多再试 [_maxAttempts] 个。
    final resolved = await resolveAccessPoints(client: client);
    final last = _lastGood;
    final candidates = <({String host, int port})>[
      ?last,
      ...resolved.where((c) => c != last),
    ];
    Object? lastError;
    for (final c in candidates.take(_maxAttempts)) {
      try {
        final ap = await _connectTo(c.host, c.port, timeout);
        _lastGood = c;
        return ap;
      } catch (e) {
        // 服务端明确拒绝（TryAnotherAP 除外），换接入点无意义
        if (e is ApLoginException && e.errorCode != 0x02) rethrow;
        if (c == _lastGood) _lastGood = null; // 曾经连通的接入点也可能失效
        lastError = e;
      }
    }
    throw lastError ?? StateError('没有可用的接入点');
  }

  /// 最近一次握手成功的接入点（进程内记忆，下次优先使用）。
  static ({String host, int port})? _lastGood;

  /// 单次 [connect] 最多尝试的接入点个数。
  static const int _maxAttempts = 6;

  /// 对单个接入点完成握手。
  static Future<SpotifyAccessPoint> _connectTo(
    String host,
    int port,
    Duration timeout,
  ) async {
    final connection = await ProxyTunnel.connect(host, port, timeout: timeout);
    return _handshake(
      SpotifyAccessPoint._(connection.socket, connection.input),
      connection.socket,
      timeout,
    );
  }

  /// 直连接入点并完成握手（探针 / 命令行工具用：不走代理隧道，避免引入 Flutter 侧依赖）。
  static Future<SpotifyAccessPoint> connectDirect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    final transport = TunnelSocket.tcp(socket);
    return _handshake(
      SpotifyAccessPoint._(transport, socket),
      transport,
      timeout,
    );
  }

  /// ClientHello → APResponse → ClientResponsePlaintext 握手（含 DH 签名验证与密钥安装）。
  static Future<SpotifyAccessPoint> _handshake(
    SpotifyAccessPoint ap,
    TunnelSocket socket,
    Duration timeout,
  ) async {
    try {
      // 1) ClientHello：[0x00,0x04] + u32be(6+len) + payload
      final dh = ap_crypto.DhLocalKeys.random();
      final nonce = Uint8List(16);
      Random.secure().nextBytes(nonce);

      final buildInfo = SpotifyClientProfile.desktop.apBuildInfo();
      final dhHello = ProtoWriter()
        ..bytes(10, dh.publicKey)
        ..varintAlways(20, 1); // server_keys_known
      final loginCryptoHello = ProtoWriter()..message(10, dhHello);
      final hello = ProtoWriter()
        ..message(10, buildInfo)
        ..varintAlways(30, 0) // cryptosuites_supported = CRYPTO_SUITE_SHANNON
        ..message(50, loginCryptoHello)
        ..bytes(60, nonce)
        ..bytes(70, Uint8List.fromList([0x1e]));
      final helloBytes = hello.toBytes();
      final helloFrame = Uint8List.fromList([
        0x00,
        0x04,
        ..._u32be(6 + helloBytes.length),
        ...helloBytes,
      ]);
      socket.add(helloFrame);

      // 2) APResponseMessage：u32be(整包长) + payload
      final respFrame = await ap._readHandshakeFrame(timeout);
      final resp = ProtoReader(respFrame.payload);

      Uint8List? gs;
      Uint8List? gsSignature;
      int? errorCode;
      resp.forEach((f) {
        if (f.number == 10 && f.wireType == 2) {
          // APChallenge
          f.asMessage.forEach((cf) {
            if (cf.number == 10 && cf.wireType == 2) {
              // LoginCryptoChallengeUnion
              cf.asMessage.forEach((df) {
                if (df.number == 10 && df.wireType == 2) {
                  df.asMessage.forEach((dd) {
                    if (dd.number == 10 && dd.wireType == 2) gs = dd.bytesValue;
                    if (dd.number == 30 && dd.wireType == 2)
                      gsSignature = dd.bytesValue;
                  });
                }
              });
            }
          });
        }
        if (f.number == 30 && f.wireType == 2) {
          // APLoginFailed
          f.asMessage.forEach((lf) {
            if (lf.number == 10) errorCode = lf.varintValue;
          });
        }
      });
      if (errorCode != null) throw ApLoginException(errorCode!);
      final gsBytes = gs;
      final gsSigBytes = gsSignature;
      if (gsBytes == null || gsSigBytes == null) {
        throw StateError('APResponse 缺少 DH 挑战');
      }

      // 防中间人：验证服务端对 gs 的 RSA 签名
      if (!ap_crypto.rsaVerifyPkcs1Sha1(
        modulus: ap_crypto.apServerKey,
        signature: gsSigBytes,
        message: gsBytes,
      )) {
        throw StateError('AP 服务端签名验证失败');
      }

      // 3) 密钥推导（accumulated = ClientHello 帧 + APResponse 帧，均含帧头）
      final shared = dh.sharedSecret(gsBytes);
      final accumulated = Uint8List.fromList([...helloFrame, ...respFrame.raw]);
      final keys = ap_crypto.apComputeKeys(shared, accumulated);

      // 4) ClientResponsePlaintext：u32be(4+len) + payload
      final dhResp = ProtoWriter()..bytes(10, keys.challenge);
      final loginCryptoResp = ProtoWriter()..message(10, dhResp);
      final plain = ProtoWriter()
        ..message(10, loginCryptoResp)
        ..message(20, ProtoWriter()) // pow_response（空）
        ..message(30, ProtoWriter()); // crypto_response（空）
      final plainBytes = plain.toBytes();
      socket.add([..._u32be(4 + plainBytes.length), ...plainBytes]);
      await socket.flush();

      ap._installCodec(keys.sendKey, keys.recvKey);
      return ap;
    } catch (e) {
      ap.close();
      rethrow;
    }
  }

  /// 握手期读取一个明文帧：u32be(整包长) + payload（返回值含原始帧字节）。
  Future<({Uint8List payload, Uint8List raw})> _readHandshakeFrame(
    Duration timeout,
  ) {
    final completer = Completer<({Uint8List payload, Uint8List raw})>();
    _handshakeFrames.add(completer);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _handshakeFrames.remove(completer);
        throw TimeoutException('等待 AP 握手响应超时');
      },
    );
  }

  void _installCodec(Uint8List sendKey, Uint8List recvKey) {
    _codec = ApCodec(sendKey, recvKey);
    final leftover = _preCodecBuffer.takeBytes();
    if (leftover.isNotEmpty) _codec!.addIncoming(leftover);
    _drainCodec();
  }

  // -------------------------------------------------------------------------
  // 登录
  // -------------------------------------------------------------------------

  /// 在加密通道上登录（cmd 0xab），成功返回 [ApWelcome]。
  Future<ApWelcome> authenticate(
    ApCredentials credentials, {
    String? deviceId,
  }) async {
    if (_rustMode) {
      try {
        final w = await rust.rustApConnectAndLogin(
          authType: credentials.authType,
          authData: credentials.authData,
          username: credentials.username ?? '',
          deviceId: deviceId ?? '',
          proxy: _rustProxy ?? '',
        );
        _rustSessionId = w.sessionId;
        canonicalUsername = w.canonicalUsername;
        reusableCredentials = (
          type: w.reusableAuthType,
          blob: w.reusableAuth,
        );
        return ApWelcome(
          canonicalUsername: w.canonicalUsername,
          reusableAuthType: w.reusableAuthType,
          reusableAuth: w.reusableAuth,
        );
      } catch (e) {
        final msg = e.toString();
        final m = RegExp(r'ap_auth_failure:(-?\d+):?(.*)').firstMatch(msg);
        if (m != null) {
          throw ApLoginException(
            int.parse(m.group(1)!),
            m.group(2)?.trim().isEmpty == true ? null : m.group(2)?.trim(),
          );
        }
        rethrow;
      }
    }
    final packet = encodeApLoginRequest(
      username: credentials.username,
      authType: credentials.authType,
      authData: credentials.authData,
      deviceId: deviceId,
    );

    final waiter = Completer<ApWelcome>();
    _loginWaiter = waiter;
    _send(ApPacketType.login, packet);

    try {
      final welcome = await waiter.future.timeout(const Duration(seconds: 15));
      canonicalUsername = welcome.canonicalUsername;
      reusableCredentials = (
        type: welcome.reusableAuthType,
        blob: welcome.reusableAuth,
      );
      return welcome;
    } finally {
      if (identical(_loginWaiter, waiter)) _loginWaiter = null;
    }
  }

  // -------------------------------------------------------------------------
  // 音频密钥
  // -------------------------------------------------------------------------

  /// 请求曲目音频密钥（cmd 0x0c → 0x0d）。
  ///
  /// 请求 payload = `file_id(20) + gid(16) + seq(4 BE) + 0x0000(2)`；
  /// 响应 payload = `seq(4) + key(16)`。
  Future<Uint8List> requestAudioKey(
    Uint8List fileId,
    Uint8List trackGid,
  ) async {
    if (fileId.length != 20) throw ArgumentError('fileId must be 20 bytes');
    if (trackGid.length != 16) throw ArgumentError('gid must be 16 bytes');

    if (_rustMode) {
      final sid = _rustSessionId;
      if (sid == null || _closed) throw StateError('AP 会话已关闭');
      try {
        return await rust.rustApRequestAudioKey(
          sessionId: sid,
          fileId: fileId,
          trackGid: trackGid,
        );
      } catch (e) {
        final msg = e.toString();
        final m = RegExp(r'ap_audio_key_error:(-?\d+)').firstMatch(msg);
        if (m != null) {
          throw ApKeyException(int.parse(m.group(1)!));
        }
        if (msg.contains('ap:closed') || msg.contains('ap_session_not_found')) {
          _closed = true;
        }
        rethrow;
      }
    }

    final seq = _keySeq++;
    final completer = Completer<Uint8List>();
    _pendingKeys[seq] = completer;

    final payload = Uint8List(20 + 16 + 4 + 2)
      ..setRange(0, 20, fileId)
      ..setRange(20, 36, trackGid)
      ..setRange(36, 40, _u32be(seq))
      ..setRange(40, 42, const [0, 0]);
    _send(ApPacketType.requestKey, payload);

    try {
      return await completer.future.timeout(const Duration(seconds: 10));
    } finally {
      _pendingKeys.remove(seq);
    }
  }

  // -------------------------------------------------------------------------
  // Mercury（hm:// 内部接口）
  // -------------------------------------------------------------------------

  /// 发送 Mercury GET 请求（如 `hm://metadata/4/episode/{gid}`），返回响应体。
  ///
  /// 协议（对照 librespot `mercury/mod.rs` + `mercury/types.rs` + `mercury.proto`）：
  /// 请求与响应都是 cmd 0xb2，负载 = `seq_len(2 BE) + seq(8 BE) + flags(1) + count(2 BE)
  /// + [len(2 BE) + part]…`；首个 part 是 `mercury.Header`（uri=1 / method=3 字符串 /
  /// status_code=4 sint32），其余为响应体分片。非 200 状态抛 [ApMercuryException]。
  Future<Uint8List> requestMercury(
    String uri, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_rustMode) {
      final sid = _rustSessionId;
      if (sid == null || _closed) throw StateError('AP 会话已关闭');
      try {
        return await rust.rustApMercuryGet(sessionId: sid, uri: uri);
      } catch (e) {
        final msg = e.toString();
        final m = RegExp(r'ap_mercury_http:(\d+)').firstMatch(msg);
        if (m != null) {
          throw ApMercuryException(int.parse(m.group(1)!));
        }
        if (msg.contains('ap:closed') || msg.contains('ap_session_not_found')) {
          _closed = true;
        }
        rethrow;
      }
    }
    final seq = _mercurySeq++;
    final completer = Completer<Uint8List>();
    _pendingMercury[seq] = completer;

    // mercury.Header：uri=1，method=3（字符串 "GET"）
    final header = ProtoWriter()
      ..string(1, uri)
      ..string(3, 'GET');
    final headerBytes = header.toBytes();

    final out = BytesBuilder()
      ..add(_u16be(8)) // seq 长度前缀
      ..add(_u64be(seq))
      ..addByte(1) // flags：FINAL
      ..add(_u16be(1)) // 只有 header 一个 part（GET 无请求体）
      ..add(_u16be(headerBytes.length))
      ..add(headerBytes);
    _send(ApPacketType.mercuryReq, out.toBytes());

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pendingMercury.remove(seq);
        throw TimeoutException('Mercury 请求超时：$uri');
      },
    );
  }

  /// 解析 Mercury 响应包并完成对应请求。
  void _onMercuryReply(Uint8List payload) {
    if (payload.length < 4) return;
    final seqLen = (payload[0] << 8) | payload[1];
    if (payload.length < 2 + seqLen + 3) return;
    final seq = _u64beAt(payload, 2);
    var offset = 2 + seqLen;
    final flags = payload[offset++]; // 1=FINAL（0x2 表示末个 part 未完，待续包）
    if (flags != 1) return; // 分片续传：本 App 的用途（metadata）响应都很小，不实现拼包
    final count = (payload[offset] << 8) | payload[offset + 1];
    offset += 2;
    final parts = <Uint8List>[];
    for (var i = 0; i < count && offset + 2 <= payload.length; i++) {
      final len = (payload[offset] << 8) | payload[offset + 1];
      offset += 2;
      if (offset + len > payload.length) return;
      parts.add(Uint8List.sublistView(payload, offset, offset + len));
      offset += len;
    }
    if (parts.isEmpty) return;

    // 首个 part 是 mercury.Header：status_code = 字段 4（sint32，zigzag 编码）
    var status = 200;
    ProtoReader(parts.first).forEach((f) {
      if (f.number == 4 && f.wireType == 0) {
        final v = f.varintValue;
        status = (v >> 1) ^ -(v & 1);
      }
    });

    final completer = _pendingMercury.remove(seq);
    if (completer == null || completer.isCompleted) return;
    if (status != 200) {
      completer.completeError(ApMercuryException(status));
    } else {
      final body = BytesBuilder();
      for (final part in parts.skip(1)) {
        body.add(part);
      }
      completer.complete(body.toBytes());
    }
  }

  // -------------------------------------------------------------------------
  // 收发
  // -------------------------------------------------------------------------

  void _send(int cmd, Uint8List payload) {
    if (_closed) throw StateError('AP 会话已关闭');
    final codec = _codec;
    if (codec == null) throw StateError('AP 握手尚未完成');
    _socket?.add(codec.encode(cmd, payload));
  }

  void _onBytes(Uint8List data) {
    final codec = _codec;
    if (codec == null) {
      // 握手阶段：明文帧 u32be(整包长) + payload
      _preCodecBuffer.add(data);
      final all = _preCodecBuffer.takeBytes();
      var offset = 0;
      while (all.length - offset >= 4) {
        final size =
            (all[offset] << 24) |
            (all[offset + 1] << 16) |
            (all[offset + 2] << 8) |
            all[offset + 3];
        if (all.length - offset < size) break;
        final raw = Uint8List.fromList(all.sublist(offset, offset + size));
        final payload = Uint8List.sublistView(raw, 4, size);
        offset += size;
        if (_handshakeFrames.isNotEmpty) {
          _handshakeFrames.removeAt(0).complete((payload: payload, raw: raw));
        }
      }
      if (offset < all.length)
        _preCodecBuffer.add(Uint8List.sublistView(all, offset));
      return;
    }

    codec.addIncoming(data);
    _drainCodec();
  }

  void _drainCodec() {
    final codec = _codec;
    if (codec == null) return;
    try {
      ApPacket? packet;
      while ((packet = codec.nextPacket()) != null) {
        _dispatch(packet!);
      }
    } catch (e, s) {
      _abort(e, s);
    }
  }

  void _dispatch(ApPacket packet) {
    switch (packet.cmd) {
      case ApPacketType.aesKey:
        final seq = _u32beAt(packet.payload, 0);
        final key = Uint8List.fromList(packet.payload.sublist(4, 20));
        _pendingKeys.remove(seq)?.complete(key);
        break;
      case ApPacketType.aesKeyError:
        final seq = _u32beAt(packet.payload, 0);
        final code = packet.payload.length > 4 ? packet.payload[4] : -1;
        _pendingKeys
            .remove(seq)
            ?.completeError(ApKeyException(code, packet.payload));
        break;
      case ApPacketType.ping:
        // 对照 librespot：延迟 60s 回 4 字节零负载 Pong（服务端随后回 PongAck）
        _pongTimer?.cancel();
        _pongTimer = Timer(const Duration(seconds: 60), () {
          try {
            _send(ApPacketType.pong, Uint8List(4));
          } catch (_) {}
        });
        break;
      case ApPacketType.apWelcome:
        final reader = ProtoReader(packet.payload);
        var username = '';
        var reusableType = -1;
        var reusable = Uint8List(0);
        reader.forEach((f) {
          if (f.number == 10 && f.wireType == 2) username = f.asString;
          if (f.number == 30 && f.wireType == 0) reusableType = f.varintValue;
          if (f.number == 40 && f.wireType == 2) reusable = f.bytesValue;
        });
        final waiter = _loginWaiter;
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete(
            ApWelcome(
              canonicalUsername: username,
              reusableAuthType: reusableType,
              reusableAuth: reusable,
            ),
          );
        }
        break;
      case ApPacketType.mercuryReq:
        _onMercuryReply(packet.payload);
        break;
      case ApPacketType.authFailure:
        final reader = ProtoReader(packet.payload);
        var code = -1;
        String? desc;
        reader.forEach((f) {
          if (f.number == 10 && f.wireType == 0) code = f.varintValue;
          if (f.number == 40 && f.wireType == 2) desc = f.asString;
        });
        final waiter = _loginWaiter;
        if (waiter != null && !waiter.isCompleted) {
          waiter.completeError(ApLoginException(code, desc));
        }
        break;
      default:
        // CountryCode / ProductInfo / PongAck 等：与取密钥无关，忽略
        break;
    }
  }

  /// 调试钩子：连接异常断开时回调真实原因（探针用，默认空）。
  static void Function(Object error)? onAbort;

  void _abort(Object error, [StackTrace? st]) {
    if (_closed) return;
    _closed = true;
    onAbort?.call(error);
    _pongTimer?.cancel();
    for (final waiter in _pendingKeys.values) {
      if (!waiter.isCompleted) waiter.completeError(error, st);
    }
    _pendingKeys.clear();
    for (final waiter in _pendingMercury.values) {
      if (!waiter.isCompleted) waiter.completeError(error, st);
    }
    _pendingMercury.clear();
    final login = _loginWaiter;
    if (login != null && !login.isCompleted) login.completeError(error, st);
    for (final frame in _handshakeFrames) {
      if (!frame.isCompleted) frame.completeError(error, st);
    }
    _handshakeFrames.clear();
    try {
      _socket?.destroy();
    } catch (_) {}
  }

  /// 关闭会话。
  void close() {
    if (_closed) return;
    _closed = true;
    final sid = _rustSessionId;
    _rustSessionId = null;
    if (sid != null) {
      unawaited(rust.rustApClose(sessionId: sid).catchError((_) {}));
    }
    _pongTimer?.cancel();
    for (final waiter in _pendingKeys.values) {
      if (!waiter.isCompleted) waiter.completeError(StateError('AP 会话已关闭'));
    }
    _pendingKeys.clear();
    for (final waiter in _pendingMercury.values) {
      if (!waiter.isCompleted) waiter.completeError(StateError('AP 会话已关闭'));
    }
    _pendingMercury.clear();
    final login = _loginWaiter;
    if (login != null && !login.isCompleted) {
      login.completeError(StateError('AP 会话已关闭'));
    }
    for (final frame in _handshakeFrames) {
      if (!frame.isCompleted) frame.completeError(StateError('AP 会话已关闭'));
    }
    _handshakeFrames.clear();
    try {
      _socket?.destroy();
    } catch (_) {}
  }

  static List<int> _u32be(int v) => [
    (v >> 24) & 0xff,
    (v >> 16) & 0xff,
    (v >> 8) & 0xff,
    v & 0xff,
  ];

  static List<int> _u16be(int v) => [(v >> 8) & 0xff, v & 0xff];

  static List<int> _u64be(int v) => [
    for (var i = 7; i >= 0; i--) (v >> (i * 8)) & 0xff,
  ];

  static int _u64beAt(Uint8List data, int offset) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | data[offset + i];
    }
    return v;
  }

  static int _u32beAt(Uint8List data, int offset) =>
      (data[offset] << 24) |
      (data[offset + 1] << 16) |
      (data[offset + 2] << 8) |
      data[offset + 3];
}

extension on Random {
  void nextBytes(Uint8List out) {
    for (var i = 0; i < out.length; i++) {
      out[i] = nextInt(256);
    }
  }
}
