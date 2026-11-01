/// 当前播放来源（歌单 / 专辑 / 艺人 / 搜索 / 媒体库）。
/// 对应 Spotify player state 中的 `context` 字段，用于全屏播放器顶部
/// 「正在播放歌单」以及队列页「接下来播放：…」的展示（文案见 l10n/model_labels.dart）。
class PlaybackContext {
  final String type;
  final String name;
  final String uri;

  const PlaybackContext({required this.type, required this.name, this.uri = ''});

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

  const PlaybackContext.playlist(this.name, {this.uri = ''}) : type = 'playlist';
  const PlaybackContext.album(this.name, {this.uri = ''}) : type = 'album';
  const PlaybackContext.artist(this.name, {this.uri = ''}) : type = 'artist';
  const PlaybackContext.search(this.name) : type = 'search', uri = 'spotify:search';
  const PlaybackContext.collection(this.name, {this.uri = ''}) : type = 'collection';

  bool get isNone => type == 'none';
}
