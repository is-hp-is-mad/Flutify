import 'package:flutter/foundation.dart';

import '../../models/app_preferences.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';

/// 歌单备份服务所需的本地媒体库读写端口（解耦 `services/backup` 对 `LibraryProvider` 的依赖）。
abstract interface class BackupLibraryPort implements Listenable {
  static const String likedSongsId = 'liked_songs_collection';

  /// 合并两张重合的歌单（同 ID 或同名）：保留主歌单的 ID 与封面元数据，曲目按 ID / URI 去重合并。
  static SpotifyPlaylist mergePlaylists(
    SpotifyPlaylist base,
    SpotifyPlaylist incoming,
  ) {
    final seen = <String>{};
    final mergedTracks = <SpotifyTrack>[];
    for (final t in [...base.tracks, ...incoming.tracks]) {
      final key = t.id.isNotEmpty ? t.id : t.uri;
      if (key.isEmpty || seen.add(key)) {
        mergedTracks.add(t);
      }
    }
    final maxTotal = [
      mergedTracks.length,
      base.totalTracks,
      incoming.totalTracks,
    ].reduce((a, b) => a > b ? a : b);
    return base.copyWith(
      name: base.name.isNotEmpty ? base.name : incoming.name,
      description: base.description.isNotEmpty
          ? base.description
          : incoming.description,
      images: base.images.isNotEmpty ? base.images : incoming.images,
      tracks: mergedTracks,
      totalTracks: mergedTracks.isNotEmpty ? mergedTracks.length : maxTotal,
    );
  }

  bool get isLoading;
  String? get loadError;
  List<SpotifyTrack> get likedTracks;
  List<SpotifyPlaylist> get playlists;

  int likeTracks(List<SpotifyTrack> tracks);
  void upsertLocalPlaylists(List<SpotifyPlaylist> playlists);
}

/// 歌单备份服务所需的偏好读取端口（解耦 `services/backup` 对 `PreferencesProvider` 的依赖）。
abstract interface class BackupPreferencesPort implements Listenable {
  AppPreferences get prefs;
}
