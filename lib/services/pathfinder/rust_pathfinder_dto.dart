import 'dart:ui';

import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/catalog_page.dart';
import '../../models/category.dart';
import '../../models/home_feed.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../../src/rust/api/pathfinder.dart' as rust;
import '../rust_backend_bridge.dart';
import 'pathfinder_parsers.dart';

/// Rust Pathfinder 解析结果（`api/pathfinder.rs`）→ 内存模型。
abstract final class RustPathfinderDto {
  static HomeFeed homeFeed(rust.RustHomeFeedDto dto) => HomeFeed(
    greeting: dto.greeting,
    chips: [for (final c in dto.chips) _chip(c)],
    shortcuts: [for (final i in dto.shortcuts) ?_item(i)],
    sections: [for (final s in dto.sections) ?homeSection(s)],
  );

  static HomeChip _chip(rust.RustHomeChipDto dto) => HomeChip(
    id: dto.id,
    label: dto.label,
    subChips: [for (final c in dto.subChips) _chip(c)],
  );

  static HomeSection? homeSection(rust.RustHomeSectionDto dto) {
    if (dto.kind < 0 || dto.kind >= HomeSectionKind.values.length) return null;
    return HomeSection(
      uri: dto.uri,
      kind: HomeSectionKind.values[dto.kind],
      title: dto.title,
      subtitle: dto.subtitle,
      headerArtist: dto.headerArtist == null
          ? null
          : RustBackendBridge.artistFromDto(dto.headerArtist!),
      items: [for (final i in dto.items) ?_item(i)],
      totalCount: dto.totalCount,
    );
  }

  static HomeItem? _item(rust.RustHomeItemDto dto) {
    if (dto.kind < 0 || dto.kind >= HomeItemKind.values.length) return null;
    return HomeItem(
      kind: HomeItemKind.values[dto.kind],
      uri: dto.uri,
      title: dto.title,
      subtitle: dto.subtitle,
      images: [for (final i in dto.images) RustBackendBridge.imageFromDto(i)],
      reason: dto.reason,
      reasonArtist: dto.reasonArtist == null
          ? null
          : RustBackendBridge.artistFromDto(dto.reasonArtist!),
      playlist: dto.playlist == null
          ? null
          : RustBackendBridge.playlistSummaryFromDto(dto.playlist!),
      album: dto.album == null ? null : RustBackendBridge.albumFromDto(dto.album!),
      artist: dto.artist == null ? null : RustBackendBridge.artistFromDto(dto.artist!),
      parentUri: dto.parentUri,
    );
  }

  /// 默认色与 Dart `PathfinderParsers.categories` 一致。
  static SpotifyCategory category(rust.RustCategoryDto dto) => SpotifyCategory(
    id: dto.id,
    name: dto.name,
    iconUrl: dto.iconUrl,
    color:
        PathfinderParsers.hexColor(dto.colorHex.isEmpty ? null : dto.colorHex) ??
        const Color(0xFF1DB954),
  );

  static CatalogPage<SpotifyTrack> trackPage(rust.RustTrackCatalogPageDto dto) =>
      CatalogPage(
        items: List.unmodifiable([
          for (final t in dto.items) RustBackendBridge.trackFromDto(t),
        ]),
        offset: dto.offset,
        total: dto.total,
        nextOffset: dto.nextOffset,
      );

  static CatalogPage<SpotifyArtist> artistPage(
    rust.RustArtistCatalogPageDto dto,
  ) => CatalogPage(
    items: List.unmodifiable([
      for (final a in dto.items) RustBackendBridge.artistFromDto(a),
    ]),
    offset: dto.offset,
    total: dto.total,
    nextOffset: dto.nextOffset,
  );

  static CatalogPage<SpotifyPlaylist> playlistPage(
    rust.RustPlaylistCatalogPageDto dto,
  ) => CatalogPage(
    items: List.unmodifiable([
      for (final p in dto.items) RustBackendBridge.playlistSummaryFromDto(p),
    ]),
    offset: dto.offset,
    total: dto.total,
    nextOffset: dto.nextOffset,
  );

  static CatalogPage<SpotifyAlbum> albumPage(rust.RustAlbumCatalogPageDto dto) =>
      CatalogPage(
        items: List.unmodifiable([
          for (final a in dto.items) RustBackendBridge.albumFromDto(a),
        ]),
        offset: dto.offset,
        total: dto.total,
        nextOffset: dto.nextOffset,
      );

  static SearchPage searchPage(rust.RustSearchPageDto dto) => SearchPage(
    tracks: trackPage(dto.tracks),
    artists: artistPage(dto.artists),
    playlists: playlistPage(dto.playlists),
  );

  /// 专辑信息 + 首屏曲目；专辑缺失时为 null（与 `PathfinderParsers.albumPage` 一致）。
  static ({SpotifyAlbum album, List<SpotifyTrack> tracks})? album(
    rust.RustAlbumQueryDto dto,
  ) {
    final album = dto.album;
    if (album == null) return null;
    return (
      album: RustBackendBridge.albumFromDto(album),
      tracks: [for (final t in dto.tracks) RustBackendBridge.trackFromDto(t)],
    );
  }

  /// 专辑曲目一页；分页解析失败时抛 [FormatException]（与 `PathfinderParsers.albumTracksPage` 一致）。
  static CatalogPage<SpotifyTrack> albumTracks(
    rust.RustAlbumQueryDto dto,
    int offset,
  ) {
    final error = dto.pageError;
    if (error != null) {
      throw FormatException(error.replaceFirst(RegExp(r'^format:'), ''));
    }
    return CatalogPage(
      items: List.unmodifiable([
        for (final t in dto.tracks) RustBackendBridge.trackFromDto(t),
      ]),
      offset: offset,
      total: dto.total,
      nextOffset: dto.nextOffset,
    );
  }

  static ({SpotifyArtist artist, List<SpotifyTrack> topTracks})? artist(
    rust.RustArtistOverviewDto? dto,
  ) {
    if (dto == null) return null;
    return (
      artist: RustBackendBridge.artistFromDto(dto.artist),
      topTracks: [
        for (final t in dto.topTracks) RustBackendBridge.trackFromDto(t),
      ],
    );
  }

  static ({List<SpotifyTrack> items, int totalCount}) libraryTracks(
    rust.RustLibraryTracksPageDto dto,
  ) => (
    items: [
      for (final i in dto.items)
        RustBackendBridge.trackFromDto(
          i.track,
        ).copyWith(addedAt: SpotifyTrack.parseAddedAt(i.addedAtIso)),
    ],
    totalCount: dto.totalCount,
  );
}
