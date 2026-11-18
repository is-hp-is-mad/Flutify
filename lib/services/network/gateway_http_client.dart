import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/spotify_gateway.dart';

/// Shared by package:http, cover images and WebSocket handshakes. Redirects
/// are resolved against the original URL, so gateway credentials never follow
/// an upstream Location to another server.
class GatewayHttpClient implements HttpClient {
  final HttpClient _inner;
  final SpotifyGateway Function() _gateway;
  GatewayHttpClient(this._inner, this._gateway);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    // Dart's WebSocket.connect converts an implicit ws/wss port to HTTP(S)
    // port 0. HttpClient treats 0 as the default; normalize before routing.
    if ((url.scheme == 'http' || url.scheme == 'https') && url.port == 0) {
      url = url.replace(port: url.scheme == 'https' ? 443 : 80);
    }
    final gateway = _gateway();
    final target = gateway.route(url);
    final request = await _inner.openUrl(method, target);
    request.followRedirects = false;
    if (target != url) gateway.headers.forEach(request.headers.set);
    return _GatewayRequest(this, request, url);
  }

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => openUrl(
    method,
    Uri(scheme: 'http', host: host, port: port).resolve(path),
  );
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);
  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;
  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;
  @override
  set authenticate(Future<bool> Function(Uri, String, String?)? f) =>
      _inner.authenticate = f;
  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addCredentials(_gateway().route(url), realm, credentials);
  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? f,
  ) => _inner.connectionFactory = f;
  @override
  set findProxy(String Function(Uri)? f) => _inner.findProxy = f;
  @override
  set authenticateProxy(
    Future<bool> Function(String, int, String, String?)? f,
  ) => _inner.authenticateProxy = f;
  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addProxyCredentials(host, port, realm, credentials);
  @override
  set badCertificateCallback(
    bool Function(X509Certificate, String, int)? callback,
  ) => _inner.badCertificateCallback = callback;
  @override
  set keyLog(Function(String)? callback) => _inner.keyLog = callback;
  @override
  void close({bool force = false}) => _inner.close(force: force);
}

class _GatewayRequest implements HttpClientRequest {
  final GatewayHttpClient _client;
  final HttpClientRequest _inner;
  @override
  final Uri uri;
  _GatewayRequest(this._client, this._inner, this.uri);
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  Future<HttpClientResponse>? _response;
  HttpClientRequest? _redirectRequest;
  bool _aborted = false;

  Future<HttpClientResponse> _finish() async {
    final response = await _inner.done;
    final location = response.headers.value(HttpHeaders.locationHeader);
    final redirectMethod = method == 'POST' && response.statusCode == 303
        ? 'GET'
        : method;
    if (!followRedirects ||
        !response.isRedirect ||
        location == null ||
        (redirectMethod != 'GET' && redirectMethod != 'HEAD'))
      return response;
    await response.drain<void>();
    if (_aborted) throw const HttpException('Request aborted');
    if (maxRedirects <= 0)
      throw RedirectException('Redirect limit exceeded', const []);
    final target = uri.resolve(location);
    // Never downgrade a redirected HTTPS request, including signed media URLs.
    if (uri.scheme == 'https' && target.scheme != 'https')
      throw const HttpException('Insecure redirect');
    final next = await _client.openUrl(redirectMethod, target);
    _redirectRequest = next;
    if (_aborted) {
      next.abort();
      throw const HttpException('Request aborted');
    }
    next.maxRedirects = maxRedirects - 1;
    final sameOrigin = uri.origin == target.origin;
    headers.forEach((name, values) {
      final key = name.toLowerCase();
      if (const {
        'host',
        'x-proxy-user',
        'x-proxy-pass',
        'content-length',
        'transfer-encoding',
      }.contains(key))
        return;
      if (!sameOrigin &&
          const {
            'authorization',
            'cookie',
            'www-authenticate',
            'proxy-authorization',
          }.contains(key))
        return;
      next.headers.set(name, values);
    });
    if (sameOrigin) next.cookies.addAll(cookies);
    return next.close();
  }

  @override
  Future<HttpClientResponse> get done => _response ??= _finish();
  @override
  Future<HttpClientResponse> close() {
    _inner.close();
    return done;
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    _aborted = true;
    _inner.abort(exception, stackTrace);
    _redirectRequest?.abort(exception, stackTrace);
  }

  @override
  String get method => _inner.method;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;
  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;
  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;
  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;
  @override
  void add(List<int> data) => _inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);
  @override
  Future<void> flush() => _inner.flush();
  @override
  void write(Object? object) => _inner.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
}
