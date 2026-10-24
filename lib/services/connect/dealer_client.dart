import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth_constants.dart';
import 'dealer_channel.dart';
import 'dealer_message.dart';

export 'dealer_channel.dart';
export 'dealer_message.dart';

/// dealer 连接状态。
enum DealerStatus {
  /// 未连接，也不会自动重连（尚未 [DealerClient.connect] 或已 [DealerClient.close]）。
  idle,

  /// 正在建立连接 / 等待连接 id。
  connecting,

  /// 已拿到连接 id，心跳正常。
  online,

  /// 连接失败或中断，等待自动重连。
  offline,
}

class DealerException implements Exception {
  final String message;

  /// 自动重连是否有意义（未登录这类问题重试也没用）。
  final bool retryable;

  const DealerException(this.message, {this.retryable = true});

  @override
  String toString() => message;
}

/// Spotify dealer 长连接（`wss://{dealer}/?access_token=…`）：连接 id、推送消息与心跳。
///
/// 约定：
/// - 接入点来自 apresolve，取第一个并去掉 `:443`；失败时用 [defaultDealerHost] / [defaultSpclientHost]。
///   [spclientHost] 一并带出，供 connect-state 请求使用。
/// - 连接后服务端先推一条 `hm://pusher/v1/connections/…`，其 `Spotify-Connection-Id` 头就是连接 id；
///   每次（重）连成功都会从 [connectionIds] 发出新 id，旧 id 随连接作废。
/// - 每 [pingInterval] 发 `{"type":"ping"}`，发出后 [pongTimeout] 内没收到 pong 就当作断线。
/// - 断线 / 出错后自动重连，退避 [initialBackoff] 起每次翻倍、上限 [maxBackoff]；每次重连前重新取 headers
///   （令牌可能已续期）。[close] 之后不再重连，但再次 [connect] 可重新启用。
/// - 令牌取自 headers 的 `Authorization: Bearer …`，没有令牌时不重试（见 [DealerException.retryable]）。
class DealerClient {
  static const String defaultDealerHost = 'dealer.spotify.com';
  static const String defaultSpclientHost = 'spclient.wg.spotify.com';
  static final Uri defaultApresolve = Uri.parse('https://apresolve.spotify.com/?type=dealer&type=spclient');
  static const String _defaultUserAgent = SpotifyAuthConstants.webUserAgent;

  final http.Client _client;
  final Future<Map<String, String>> Function() _headers;
  final DealerConnector _connector;
  final Uri _apresolve;

  final Duration pingInterval;
  final Duration pongTimeout;
  final Duration firstMessageTimeout;
  final Duration initialBackoff;
  final Duration maxBackoff;

  final _messages = StreamController<DealerMessage>.broadcast();
  final _connectionIds = StreamController<String>.broadcast();
  final _statusChanges = StreamController<DealerStatus>.broadcast();

  DealerStatus _status = DealerStatus.idle;
  String? _connectionId;
  String? _dealerHost;
  String? _spclientHost;
  _Session? _session;
  Future<void>? _connecting;
  Timer? _retryTimer;

  /// 是否需要保持连接；[connect] 置 true，[close] 置 false。
  bool _wanted = false;

  /// 每次 [connect] 尝试 / [close] 递增，用来丢弃已被取代的异步结果。
  int _epoch = 0;
  int _attempts = 0;

  DealerClient({
    required this._client,
    required this._headers,
    DealerConnector? connector,
    Uri? apresolve,
    this.pingInterval = const Duration(seconds: 30),
    this.pongTimeout = const Duration(seconds: 10),
    this.firstMessageTimeout = const Duration(seconds: 10),
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 60),
  }) : _connector = connector ?? RustDealerChannel.connect,
       _apresolve = apresolve ?? defaultApresolve;

  /// 除连接握手消息外的全部推送（广播）。
  Stream<DealerMessage> get messages => _messages.stream;

  /// 每次（重）连成功拿到新连接 id 时发出。
  Stream<String> get connectionIds => _connectionIds.stream;

  Stream<DealerStatus> get statusChanges => _statusChanges.stream;

  DealerStatus get status => _status;

  /// 当前连接 id；未在线时为 null。
  String? get connectionId => _connectionId;

  /// apresolve 解析出的 spclient 接入点；第一次连接尝试结束前为 null。
  String? get spclientHost => _spclientHost;

  /// 建立连接并等到连接 id；幂等（已在线直接返回，正在连接则复用同一次尝试）。
  ///
  /// 首次尝试失败时抛出，同时后台仍会按退避自动重连（未登录除外）。
  Future<void> connect() {
    _wanted = true;
    if (_status == DealerStatus.online) return Future.value();
    final pending = _connecting;
    if (pending != null) return pending;

    // 手动重试：不等退避计时
    _retryTimer?.cancel();
    _retryTimer = null;
    final attempt = _open();
    _connecting = attempt;
    attempt.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_connecting, attempt)) _connecting = null;
    });
    return attempt;
  }

  /// 主动断开并停止重连。
  Future<void> close() async {
    _wanted = false;
    _epoch++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _connecting = null;
    _connectionId = null;
    final session = _session;
    _session = null;
    _setStatus(DealerStatus.idle);
    await session?.dispose();
  }

  /// 释放流控制器；之后不可再用。
  Future<void> dispose() async {
    await close();
    await _messages.close();
    await _connectionIds.close();
    await _statusChanges.close();
  }

  Future<void> _open() async {
    final epoch = ++_epoch;
    _setStatus(DealerStatus.connecting);
    _Session? session;
    try {
      final headers = await _headers();
      final token = _bearerToken(headers);
      if (token == null) throw const DealerException('未登录，无法连接 dealer', retryable: false);
      await _resolveHosts();
      _ensureCurrent(epoch);

      final uri = Uri(
        scheme: 'wss',
        host: _dealerHost ?? defaultDealerHost,
        path: '/',
        queryParameters: {'access_token': token},
      );
      final channel = await _connector(uri, {'User-Agent': _headerValue(headers, 'user-agent') ?? _defaultUserAgent});
      if (epoch != _epoch) {
        unawaited(channel.close().catchError((Object _) {}));
        throw const DealerException('连接已取消', retryable: false);
      }

      final s = _Session(channel);
      session = s;
      _session = s;
      s.sub = channel.messages.listen(
        (text) => _onText(s, text),
        onError: (Object _) => _onLost(s),
        onDone: () => _onLost(s),
        cancelOnError: true,
      );

      final id = await s.idCompleter.future.timeout(
        firstMessageTimeout,
        onTimeout: () => throw const DealerException('等待 dealer 连接 id 超时'),
      );
      _ensureCurrent(epoch);

      _attempts = 0;
      _connectionId = id;
      _setStatus(DealerStatus.online);
      _connectionIds.add(id);
      _startHeartbeat(s);
    } catch (e) {
      if (session != null) {
        if (identical(_session, session)) _session = null;
        unawaited(session.dispose());
      }
      // 被 close() / 新一轮尝试取代时，状态已由对方负责
      if (epoch == _epoch) {
        _connectionId = null;
        _setStatus(DealerStatus.offline);
        if (_wanted && !(e is DealerException && !e.retryable)) _scheduleReconnect();
      }
      rethrow;
    }
  }

  /// 抛出表示本次尝试已被 [close] 取代。
  void _ensureCurrent(int epoch) {
    if (epoch != _epoch) throw const DealerException('连接已取消', retryable: false);
  }

  /// apresolve 取接入点；失败保留上一次的结果，仍没有就用默认域名。
  Future<void> _resolveHosts() async {
    try {
      final res = await _client.get(_apresolve).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final json = jsonDecode(utf8.decode(res.bodyBytes));
        if (json is Map) {
          _dealerHost = _firstHost(json['dealer']) ?? _dealerHost;
          _spclientHost = _firstHost(json['spclient']) ?? _spclientHost;
        }
      }
    } catch (_) {}
    _dealerHost ??= defaultDealerHost;
    _spclientHost ??= defaultSpclientHost;
  }

  static String? _firstHost(Object? list) {
    if (list is! List || list.isEmpty || list.first is! String) return null;
    final host = (list.first as String).replaceAll(':443', '');
    return host.isEmpty ? null : host;
  }

  void _onText(_Session s, String text) {
    if (s.lost) return;
    final Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (json is! Map<String, dynamic>) return;

    switch (json['type']) {
      case 'pong':
        s.pongTimer?.cancel();
        s.pongTimer = null;
      case 'message':
        final message = DealerMessage.fromJson(json);
        final id = message.uri.startsWith('hm://pusher/v1/connections/')
            ? message.header('Spotify-Connection-Id')
            : null;
        if (id != null && id.isNotEmpty) {
          _onConnectionId(s, id);
        } else {
          _messages.add(message);
        }
    }
  }

  /// 连接握手消息：首次交给 [_open]；同一连接上之后换了 id 就直接更新并通知。
  void _onConnectionId(_Session s, String id) {
    if (!s.idCompleter.isCompleted) {
      s.idCompleter.complete(id);
    } else if (identical(s, _session) && id != _connectionId) {
      _connectionId = id;
      _connectionIds.add(id);
    }
  }

  void _startHeartbeat(_Session s) {
    s.pingTimer = Timer.periodic(pingInterval, (_) {
      if (s.lost) return;
      try {
        s.channel.send(jsonEncode({'type': 'ping'}));
      } catch (_) {
        _onLost(s);
        return;
      }
      // 上一个 ping 还没等到 pong 时沿用旧的计时，不重置
      s.pongTimer ??= Timer(pongTimeout, () => _onLost(s));
    });
  }

  /// 连接中断（流结束 / 出错 / pong 超时）。
  void _onLost(_Session s) {
    if (s.lost) return;
    final connecting = !s.idCompleter.isCompleted;
    unawaited(s.dispose());
    // 还在等连接 id：由 _open 的 catch 统一处理
    if (connecting || !identical(s, _session)) return;
    _session = null;
    _connectionId = null;
    _setStatus(DealerStatus.offline);
    if (_wanted) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_retryTimer != null) return;
    var delay = initialBackoff * (1 << (_attempts < 20 ? _attempts : 20));
    if (delay > maxBackoff) delay = maxBackoff;
    _attempts++;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (_wanted) connect().ignore();
    });
  }

  void _setStatus(DealerStatus status) {
    if (_status == status) return;
    _status = status;
    if (!_statusChanges.isClosed) _statusChanges.add(status);
  }

  static String? _headerValue(Map<String, String> headers, String lowerName) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lowerName) return entry.value;
    }
    return null;
  }

  static String? _bearerToken(Map<String, String> headers) {
    final auth = _headerValue(headers, 'authorization');
    if (auth == null) return null;
    final token = auth.replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '').trim();
    return token.isEmpty ? null : token;
  }
}

/// 一次 WebSocket 连接的运行时状态：通道、订阅与心跳计时器。
class _Session {
  final DealerChannel channel;
  final Completer<String> idCompleter = Completer<String>();
  StreamSubscription<String>? sub;
  Timer? pingTimer;
  Timer? pongTimer;
  bool lost = false;

  _Session(this.channel) {
    // 失败由 _open 的 await 处理；这里避免没人等待时报未处理异常
    idCompleter.future.ignore();
  }

  Future<void> dispose() async {
    if (lost) return;
    lost = true;
    pingTimer?.cancel();
    pongTimer?.cancel();
    if (!idCompleter.isCompleted) idCompleter.completeError(const DealerException('dealer 连接已关闭'));
    try {
      await sub?.cancel();
      await channel.close().timeout(const Duration(seconds: 2), onTimeout: () {});
    } catch (_) {}
  }
}
