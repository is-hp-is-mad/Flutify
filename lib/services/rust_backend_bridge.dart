import '../core/rust_core.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../models/image.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../src/rust/api/backend.dart' as rust;
import 'library/collection_codec.dart';
import 'library/playlist_cover.dart';
import 'network/rust_route.dart';
import 'storage_service.dart';

/// Dart 与 `flutify_core` Rust 后端之间的会话同步与 DTO 转换桥。
class RustBackendBridge {
  RustBackendBridge._();

  /// 返回 Rust 可直接使用的代理地址（`''` 为直连）；若需要走自定义网关或配置无效则返回 null（回退 Dart）。
  static Future<String?> proxyForUrl(String url) async {
    final route = await rustRouteFor(Uri.parse(url));
    if (route == null || route.viaGateway) return null;
    return route.proxy;
  }

  static void syncSession(StorageService storage, {String? deviceId}) {
    if (!RustCore.ready) return;
    rust.rustSessionConfigure(
      config: rust.RustSessionConfig(
        spDc: storage.spDc,
        accessToken: storage.accessToken,
        accessTokenExpiryMs: storage.accessTokenExpiry,
        clientToken: storage.clientToken,
        clientTokenExpiryMs: storage.clientTokenExpiry,
        deviceId: deviceId ?? storage.deviceId,
        proxy: '',
        epoch: BigInt.from(storage.sessionEpoch),
      ),
    );
  }

  static void clearSession() {
    if (!RustCore.ready) return;
    rust.rustSessionClear();
  }

  static SpotifyImage imageFromDto(rust.RustImageDto dto) =>
      SpotifyImage(url: dto.url, width: dto.width, height: dto.height);

  static SpotifyArtist artistFromDto(rust.RustArtistDto dto) => SpotifyArtist(
    id: dto.id,
    name: dto.name,
    uri: dto.uri,
    images: [for (final img in dto.images) imageFromDto(img)],
    followers: dto.followers?.toInt(),
  );

  static SpotifyAlbum albumFromDto(rust.RustAlbumDto dto) => SpotifyAlbum(
    id: dto.id,
    name: dto.name,
    uri: dto.uri,
    images: [for (final img in dto.images) imageFromDto(img)],
  );

  static SpotifyTrack trackFromDto(rust.RustTrackDto dto) => SpotifyTrack(
    id: dto.id,
    name: dto.name,
    uri: dto.uri,
    artists: [for (final a in dto.artists) artistFromDto(a)],
    album: dto.album == null ? null : albumFromDto(dto.album!),
    durationMs: dto.durationMs,
    explicit: dto.explicit,
    isPlayable: dto.isPlayable,
    addedAt: dto.addedAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(dto.addedAtMs!.toInt()),
  );

  static SpotifyPlaylist playlistFromDto(rust.RustPlaylistDto dto) {
    final tracks = [for (final t in dto.tracks) trackFromDto(t)];
    final baseImages = [for (final img in dto.images) imageFromDto(img)];
    final images = baseImages.isNotEmpty
        ? baseImages
        : PlaylistCover.fromAlbumCovers(
            tracks.take(12).map((t) => t.album?.images ?? const <SpotifyImage>[]),
          );
    return SpotifyPlaylist(
      id: dto.id,
      name: dto.name,
      uri: dto.uri,
      description: dto.description,
      ownerName: dto.ownerName,
      images: images,
      totalTracks: dto.totalTracks,
      tracks: tracks,
    );
  }

  static CollectionEntry collectionEntryFromDto(
    rust.RustCollectionEntryDto dto,
  ) => CollectionEntry(uri: dto.uri, addedAt: dto.addedAtSec.toInt());
}
