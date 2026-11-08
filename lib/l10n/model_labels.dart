import '../models/album.dart';
import '../models/playback_context.dart';
import 'app_localizations.dart';

/// 数据模型 → 界面标签的本地化映射。
///
/// 模型只保存 Spotify 原始字段（album_type、context type 等），
/// 展示文案统一在这里转换，模型层不包含任何界面语言。
extension ModelLabels on AppLocalizations {
  /// 专辑类型：album / single / compilation → 专辑 / 单曲 / 合辑。
  String albumType(SpotifyAlbum album) => switch (album.albumType) {
        'single' => typeSingle,
        'compilation' => typeCompilation,
        _ => typeAlbum,
      };

  /// 全屏播放器顶部的播放来源小标题。
  String playingFrom(PlaybackContext context) => switch (context.type) {
        'playlist' => playingFromPlaylist,
        'album' => playingFromAlbum,
        'artist' => playingFromArtist,
        'search' => playingFromSearch,
        'collection' => playingFromLibrary,
        _ => nowPlaying,
      };
}
