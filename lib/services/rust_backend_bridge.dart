import '../core/rust_core.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../models/image.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../models/track_credits.dart';
import '../models/watch_feed.dart';
import '../src/rust/api/backend.dart' as rust;
import 'library/collection_codec.dart';
import 'library/playlist_cover.dart';
import 'lyrics/lrclib_candidate.dart';
import 'lyrics/lrclib_client.dart';
import 'network/rust_route.dart';
import 'storage/auth_session_store.dart';

/// Dart 与 `flutify_core` Rust 后端之间的会话同步与 DTO 转换桥。
class RustBackendBridge {
  RustBackendBridge._();

  /// 返回 Rust 可直接使用的代理地址（`''` 为直连）；若需要走自定义网关或配置无效则返回 null（回退 Dart）。
  static Future<String?> proxyForUrl(String url) async {
    final route = await rustRouteFor(Uri.parse(url));
    if (route == null || route.viaGateway) return null;
    return route.proxy;
  }

  static void syncSession(AuthSessionStore auth, {String? deviceId}) {
    if (!RustCore.ready) return;
    rust.rustSessionConfigure(
      config: rust.RustSessionConfig(
        spDc: auth.spDc,
        accessToken: auth.accessToken,
        accessTokenExpiryMs: auth.accessTokenExpiry,
        clientToken: auth.clientToken,
        clientTokenExpiryMs: auth.clientTokenExpiry,
        deviceId: deviceId ?? auth.deviceId,
        proxy: '',
        epoch: BigInt.from(auth.sessionEpoch),
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

  static SpotifyPlaylist playlistSummaryFromDto(
    rust.RustPlaylistSummaryDto dto,
  ) => SpotifyPlaylist(
    id: dto.id,
    name: dto.name,
    uri: dto.uri,
    description: dto.description,
    ownerName: dto.ownerName,
    images: [for (final img in dto.images) imageFromDto(img)],
    totalTracks: dto.totalTracks,
  );

  static TrackCredits trackCreditsFromDto(rust.RustTrackCreditsDto dto) =>
      TrackCredits(
        trackName: dto.trackName,
        groups: [
          for (final g in dto.groups)
            CreditGroup(
              name: g.name,
              people: [
                for (final p in g.people)
                  CreditPerson(
                    name: p.name,
                    roles: List.unmodifiable(p.roles),
                    artistId: p.artistId,
                  ),
              ],
            ),
        ],
        sources: List.unmodifiable(dto.sources),
      );

  static WatchFeedEntry watchFeedEntryFromDto(rust.RustWatchFeedEntryDto dto) =>
      WatchFeedEntry(
        title: dto.title,
        subtitle: dto.subtitle,
        overline: dto.overline,
        feedUri: dto.feedUri,
        firstItemUri: dto.firstItemUri,
        thumbnailUrl: dto.thumbnailUrl,
        videoUrl: dto.videoUrl,
        coverUrl: dto.coverUrl,
        accessibilityText: dto.accessibilityText,
      );

  static WatchFeedShelf watchFeedShelfFromDto(rust.RustWatchFeedShelfDto dto) =>
      WatchFeedShelf(
        title: dto.title,
        entries: [for (final e in dto.entries) watchFeedEntryFromDto(e)],
      );

  static WatchFeedVisualKind _visualKind(int kind) => switch (kind) {
    0 => WatchFeedVisualKind.canvas,
    1 => WatchFeedVisualKind.trackPreview,
    2 => WatchFeedVisualKind.image,
    _ => WatchFeedVisualKind.gradient,
  };

  static WatchFeedPage watchFeedPageFromDto(rust.RustWatchFeedPageDto dto) =>
      WatchFeedPage(
        headerTitles: dto.headerTitles,
        items: [
          for (final item in dto.items)
            WatchFeedItem(
              id: item.id,
              uri: item.uri,
              visual: WatchFeedVisual(
                kind: _visualKind(item.visual.kind),
                videoUrl: item.visual.videoUrl,
                imageUrl: item.visual.imageUrl,
                animationUrl: item.visual.animationUrl,
                colors: item.visual.colors,
              ),
              audio: item.audio == null
                  ? null
                  : WatchFeedAudio(
                      url: item.audio!.url,
                      shouldLoop: item.audio!.shouldLoop,
                      fadeIn: item.audio!.fadeIn,
                    ),
              creator: item.creator == null
                  ? null
                  : WatchFeedCreator(
                      uri: item.creator!.uri,
                      name: item.creator!.name,
                      subtitle: item.creator!.subtitle,
                      imageUrl: item.creator!.imageUrl,
                      followUri: item.creator!.followUri,
                      followText: item.creator!.followText,
                      followingText: item.creator!.followingText,
                    ),
              hashtags: [
                for (final h in item.hashtags)
                  WatchFeedHashtag(
                    id: h.id,
                    title: h.title,
                    navigationUri: h.navigationUri,
                    seedItemUri: h.seedItemUri,
                  ),
              ],
              entityRow: item.entityRow == null
                  ? null
                  : WatchFeedEntityRow(
                      title: item.entityRow!.title,
                      subtitle: item.entityRow!.subtitle,
                      imageUrl: item.entityRow!.imageUrl,
                      playUri: item.entityRow!.playUri,
                      accessibilityText: item.entityRow!.accessibilityText,
                    ),
              texts: item.texts,
              track: item.track == null ? null : trackFromDto(item.track!),
              canShare: item.canShare,
              hasMenu: item.hasMenu,
              canSave: item.canSave,
              hasProgressBar: item.hasProgressBar,
            ),
        ],
        nextPageToken: dto.nextPageToken,
        associatedFeedUris: dto.associatedFeedUris,
        verticalOnboardingText: dto.verticalOnboardingText,
        associatedOnboardingText: dto.associatedOnboardingText,
      );

  static LrclibResponse lrclibResponseFromDto(rust.RustLrclibResponseDto dto) =>
      LrclibResponse([
        for (final c in dto.candidates)
          if (c.syncedLyrics.isNotEmpty || c.instrumental)
            LrclibCandidate(
              trackName: c.trackName,
              artistName: c.artistName,
              albumName: c.albumName,
              synced: c.syncedLyrics,
              duration: c.durationSec,
              instrumental: c.instrumental,
            ),
      ], networkError: dto.networkError);
}
