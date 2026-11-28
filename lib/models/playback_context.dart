/// 当前播放来源（歌单 / 专辑 / 艺人 / 搜索 / 媒体库）。
/// 对应 Spotify player state 中的 `context` 字段，用于全屏播放器顶部
/// 「正在播放歌单」以及队列页「接下来播放：…」的展示（文案见 l10n/model_labels.dart）。
class PlaybackContext {
  final String type;
  final String name;
  final String uri;

  /// 曲目是按用户在歌单页选的排序排过的，与服务端展开 [uri] 得到的原顺序不同。
  /// Connect 点歌时据此改为带上整个列表（见 `ConnectPlayRequest.from`），远程设备 / 本机播放端才会按这个顺序播。
  final bool reordered;

  const PlaybackContext({
    required this.type,
    required this.name,
    this.uri = '',
    this.reordered = false,
  });

  /// 复制一份并设置 [reordered]。
  PlaybackContext withReordered(bool reordered) => reordered == this.reordered
      ? this
      : PlaybackContext(type: type, name: name, uri: uri, reordered: reordered);

  /// 只知道 URI 时（Connect 服务端的上下文）按 URI 推断类型。
  factory PlaybackContext.fromUri(String uri, {String name = ''}) {
    final type = switch (uri) {
      _ when uri.startsWith('spotify:album:') => 'album',
      _ when uri.startsWith('spotify:artist:') => 'artist',
      _ when uri.endsWith(':collection') => 'collection',
      _ => 'playlist',
    };
    return PlaybackContext(type: type, name: name, uri: uri);
  }

  static const none = PlaybackContext(type: 'none', name: '');

  const PlaybackContext.playlist(this.name, {this.uri = ''})
    : type = 'playlist',
      reordered = false;
  const PlaybackContext.album(this.name, {this.uri = ''})
    : type = 'album',
      reordered = false;
  const PlaybackContext.artist(this.name, {this.uri = ''})
    : type = 'artist',
      reordered = false;
  const PlaybackContext.search(this.name)
    : type = 'search',
      uri = 'spotify:search',
      reordered = false;
  const PlaybackContext.collection(this.name, {this.uri = ''})
    : type = 'collection',
      reordered = false;

  bool get isNone => type == 'none';
}
