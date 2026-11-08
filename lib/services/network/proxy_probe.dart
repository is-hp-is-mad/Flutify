import 'package:http/http.dart' as http;

/// 设置页「测试连接」：按当前代理策略请求一次 Spotify 接入点目录，返回耗时。
///
/// 请求走全局 [HttpOverrides]，与 App 里其他请求完全同一条路径；失败时抛出原始异常。
class ProxyProbe {
  ProxyProbe._();

  static final Uri target = Uri.parse(
    'https://apresolve.spotify.com/?type=accesspoint',
  );

  static Future<Duration> run({
    http.Client? client,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final c = client ?? http.Client();
    final watch = Stopwatch()..start();
    try {
      final response = await c.get(target).timeout(timeout);
      if (response.statusCode >= 400)
        throw http.ClientException('HTTP ${response.statusCode}', target);
      return watch.elapsed;
    } finally {
      if (client == null) c.close();
    }
  }
}
