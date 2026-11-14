/// 当前账号可以往里加歌的歌单（「添加到歌单」菜单的一项）。
class EditablePlaylist {
  /// `spotify:playlist:<id>`。
  final String uri;
  final String name;
  final String coverUrl;

  /// 查询时给出的那首歌是否已经在这张歌单里。
  final bool containsTrack;

  const EditablePlaylist({
    required this.uri,
    required this.name,
    this.coverUrl = '',
    this.containsTrack = false,
  });

  String get id => uri.split(':').last;
}
