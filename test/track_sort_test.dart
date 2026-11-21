import 'package:flutify_app/core/utils/added_date_format.dart';
import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutify_app/models/album.dart';
import 'package:flutify_app/models/artist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/ui/widgets/track_table/track_sort.dart';
import 'package:flutify_app/ui/widgets/track_table/track_table_columns.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

SpotifyTrack _t(String name, {String artist = 'A', String album = 'X', int ms = 1000, DateTime? added}) =>
    SpotifyTrack(
      id: name,
      name: name,
      artists: [SpotifyArtist(id: artist, name: artist)],
      album: SpotifyAlbum(id: album, name: album),
      durationMs: ms,
      addedAt: added,
    );

void main() {
  group('TrackSort', () {
    final tracks = [
      _t('charlie', artist: 'Zed', album: 'b', ms: 300, added: DateTime(2026, 1, 2)),
      _t('Alpha', artist: 'yan', album: 'C', ms: 100),
      _t('bravo', artist: 'Xu', album: 'a', ms: 300, added: DateTime(2026, 3, 1)),
    ];
    List<String> names(List<SpotifyTrack> list) => list.map((t) => t.name).toList();

    test('custom keeps the playlist order (same list instance)', () {
      expect(identical(TrackSort.custom.apply(tracks), tracks), isTrue);
    });

    test('text columns ignore case; equal keys keep their original order', () {
      expect(names(const TrackSort(TrackSortKey.title).apply(tracks)), ['Alpha', 'bravo', 'charlie']);
      expect(names(const TrackSort(TrackSortKey.album).apply(tracks)), ['bravo', 'charlie', 'Alpha']);
      expect(names(const TrackSort(TrackSortKey.duration).apply(tracks)), ['Alpha', 'charlie', 'bravo']);
      expect(names(const TrackSort(TrackSortKey.duration, descending: true).apply(tracks)), [
        'charlie',
        'bravo',
        'Alpha',
      ]);
    });

    test('date added: newest first, tracks without a date always last', () {
      final initial = TrackSort.initial(TrackSortKey.addedAt);
      expect(initial.descending, isTrue);
      expect(names(initial.apply(tracks)), ['bravo', 'charlie', 'Alpha']);
      expect(names(TrackSort(TrackSortKey.addedAt).apply(tracks)), ['charlie', 'bravo', 'Alpha']);
    });

    test('header taps cycle natural → reversed → custom', () {
      var sort = TrackSort.custom.tap(TrackSortKey.title);
      expect(sort, const TrackSort(TrackSortKey.title));
      sort = sort.tap(TrackSortKey.title);
      expect(sort, const TrackSort(TrackSortKey.title, descending: true));
      expect(sort.tap(TrackSortKey.title), TrackSort.custom);
      // 换列：从新列的自然方向开始
      expect(sort.tap(TrackSortKey.addedAt), const TrackSort(TrackSortKey.addedAt, descending: true));
    });

    test('filter matches title, artist or album, case-insensitively', () {
      expect(names(TrackSort.filter(tracks, '  ALP ')), ['Alpha']);
      expect(names(TrackSort.filter(tracks, 'zed')), ['charlie']);
      expect(names(TrackSort.filter(tracks, 'c')), ['charlie', 'Alpha']); // 专辑 C
      expect(identical(TrackSort.filter(tracks, ' '), tracks), isTrue);
    });
  });

  group('TrackTableColumns', () {
    test('columns collapse right-to-left as the content narrows', () {
      final wide = TrackTableColumns.forWidth(1000, compact: false, hasAddedAt: true);
      expect((wide.album, wide.addedAt, wide.artist), (true, true, false));
      final mid = TrackTableColumns.forWidth(700, compact: false, hasAddedAt: true);
      expect((mid.album, mid.addedAt), (true, false));
      final narrow = TrackTableColumns.forWidth(600, compact: true, hasAddedAt: true);
      expect((narrow.album, narrow.addedAt, narrow.artist), (false, false, true));
      expect(TrackTableColumns.forWidth(1000, compact: false, hasAddedAt: false).addedAt, isFalse);
    });
  });

  group('AddedDateFormat', () {
    final zh = lookupAppLocalizations(const Locale('zh'));
    final en = lookupAppLocalizations(const Locale('en'));
    final now = DateTime(2026, 10, 1, 9);

    // App 里由 Material 本地化代理加载；纯单元测试需手动加载日期格式数据
    setUpAll(initializeDateFormatting);

    test('relative within a month, then a full date', () {
      expect(AddedDateFormat.format(zh, DateTime(2026, 10, 1, 0, 5), now: now), '今日');
      // 昨晚加入：按自然日算 1 天前
      expect(AddedDateFormat.format(zh, DateTime(2026, 9, 30, 23), now: now), '1 天前');
      expect(AddedDateFormat.format(en, DateTime(2026, 9, 28), now: now), '3 days ago');
      expect(AddedDateFormat.format(en, DateTime(2026, 9, 24), now: now), '1 week ago');
      expect(AddedDateFormat.format(zh, DateTime(2026, 9, 10), now: now), '3 周前');
      expect(AddedDateFormat.format(en, DateTime(2025, 9, 1), now: now), 'Sep 1, 2025');
      expect(AddedDateFormat.format(zh, DateTime(2025, 9, 1), now: now), '2025年9月1日');
    });
  });
}
