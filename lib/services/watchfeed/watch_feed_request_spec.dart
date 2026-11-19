/// `spotify:watch-feed:…` URI → 请求参数（对齐官方 twa.java：第 2 段为 feed_id，剩余段数为奇数时
/// 下一段为 entity_id，其余成对的段与 query 全部进 parameters，值里的 `/` 还原为 `:`）。
class WatchFeedRequestSpec {
  final String feedId;
  final String? entityId;
  final Map<String, String> parameters;

  const WatchFeedRequestSpec({
    required this.feedId,
    this.entityId,
    this.parameters = const {},
  });

  static const _prefix = 'spotify:watch-feed:';

  /// 解析失败（不是 watch-feed URI）返回 null。
  static WatchFeedRequestSpec? fromUri(String uri) {
    if (!uri.startsWith(_prefix)) return null;
    final rest = uri.substring(_prefix.length);
    final q = rest.indexOf('?');
    final path = q < 0 ? rest : rest.substring(0, q);
    final query = q < 0 ? '' : rest.substring(q + 1);
    final segments = path.split(':').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null;
    final feedId = segments.first;
    final remaining = segments.sublist(1);
    String? entityId;
    var start = 0;
    if (remaining.length.isOdd) {
      entityId = remaining.first;
      start = 1;
    }
    final parameters = <String, String>{};
    for (var i = start; i + 1 < remaining.length; i += 2) {
      parameters[remaining[i]] = remaining[i + 1];
    }
    for (final pair in query.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      final key = _decode(eq < 0 ? pair : pair.substring(0, eq));
      final value = eq < 0
          ? ''
          : _decode(pair.substring(eq + 1)).replaceAll('/', ':');
      if (key.isEmpty || key == 'presentAsOverlay') continue;
      parameters[key] = value;
    }
    return WatchFeedRequestSpec(
      feedId: feedId,
      entityId: entityId,
      parameters: parameters,
    );
  }

  /// 百分号解码；编码不合法时原样返回。
  static String _decode(String value) {
    try {
      return Uri.decodeQueryComponent(value);
    } catch (_) {
      return value;
    }
  }
}
