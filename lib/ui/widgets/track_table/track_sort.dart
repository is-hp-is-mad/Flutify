import 'package:flutter/foundation.dart';

import '../../../models/track.dart';

/// 曲目列表的排序字段；[custom] 为歌单原始顺序。
enum TrackSortKey { custom, title, artist, album, addedAt, duration }

/// 曲目列表的排序与筛选（歌单页「排序方式」菜单、列表头点击、歌单内搜索）。
///
/// 规则：
/// - 点列表头：首次按该列的自然方向（文字 A→Z、添加日期新→旧、时长短→长），再点反向，第三次回到自定义顺序；
/// - 排序稳定：相同值保持原始顺序（Dart 的 sort 不稳定，用下标兜底）；
/// - 文字比较忽略大小写；缺少添加日期的曲目总排在最后。
@immutable
class TrackSort {
  final TrackSortKey key;
  final bool descending;

  const TrackSort(this.key, {this.descending = false});

  static const TrackSort custom = TrackSort(TrackSortKey.custom);

  /// 该字段第一次被选中时的方向。
  static TrackSort initial(TrackSortKey key) => TrackSort(key, descending: key == TrackSortKey.addedAt);

  /// 点击列表头 [tapped] 后的排序。
  TrackSort tap(TrackSortKey tapped) {
    if (tapped != key) return initial(tapped);
    if (descending == initial(tapped).descending) return TrackSort(key, descending: !descending);
    return custom;
  }

  List<SpotifyTrack> apply(List<SpotifyTrack> tracks) {
    if (key == TrackSortKey.custom) return tracks;
    final indexed = [for (var i = 0; i < tracks.length; i++) (i, tracks[i])];
    indexed.sort((a, b) {
      final byKey = _compare(a.$2, b.$2);
      return byKey != 0 ? byKey : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  int _compare(SpotifyTrack a, SpotifyTrack b) {
    final sign = descending ? -1 : 1;
    switch (key) {
      case TrackSortKey.custom:
        return 0;
      case TrackSortKey.title:
        return sign * _text(a.name, b.name);
      case TrackSortKey.artist:
        return sign * _text(a.artistNames, b.artistNames);
      case TrackSortKey.album:
        return sign * _text(a.album?.name ?? '', b.album?.name ?? '');
      case TrackSortKey.duration:
        return sign * a.durationMs.compareTo(b.durationMs);
      case TrackSortKey.addedAt:
        final (x, y) = (a.addedAt, b.addedAt);
        if (x == null || y == null) return (x == null ? 1 : 0) - (y == null ? 1 : 0);
        return sign * x.compareTo(y);
    }
  }

  static int _text(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

  /// 歌单内搜索：歌名 / 艺人 / 专辑包含 [query]（忽略大小写与首尾空白）。
  static List<SpotifyTrack> filter(List<SpotifyTrack> tracks, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return tracks;
    return tracks
        .where(
          (t) =>
              t.name.toLowerCase().contains(q) ||
              t.artistNames.toLowerCase().contains(q) ||
              (t.album?.name.toLowerCase().contains(q) ?? false),
        )
        .toList();
  }

  @override
  bool operator ==(Object other) => other is TrackSort && other.key == key && other.descending == descending;

  @override
  int get hashCode => Object.hash(key, descending);
}
