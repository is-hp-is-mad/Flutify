import 'dart:convert';

import 'package:flutify_app/l10n/app_locale.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/models/track_credits.dart';
import 'package:flutify_app/services/pathfinder/credits_parser.dart';
import 'package:flutify_app/services/pathfinder/desktop_data_source.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/widgets/track_actions/track_credits_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 曲目菜单补全的两项：「查看制作人员」（Pathfinder 分组解析 + 弹窗）与「前往歌曲电台」（种子 → 电台歌单）。
/// 全部使用合成数据。
void main() {
  /// 合成的 queryTrackCreditsGroupedModal 响应：扁平的「人 × 角色」列表。
  Map<String, dynamic> creditsResponse() => {
    'data': {
      'trackUnion': {
        'name': 'Synthetic Song',
        'creditsTrait': {
          'contributors': {
            'items': [
              {
                'name': 'Singer A',
                'role': '主要艺人',
                'roleGroup': {'name': '艺人'},
                'uri': 'spotify:artist:aaa',
              },
              {
                'name': 'Writer B',
                'role': '作曲者',
                'roleGroup': {'name': '作曲和作词'},
                'uri': 'spotify:artist:bbb',
              },
              {
                'name': 'Writer B',
                'role': '作词者',
                'roleGroup': {'name': '作曲和作词'},
                'uri': 'spotify:artist:bbb',
              },
              {
                'name': 'Engineer C',
                'role': '混音工程师',
                'roleGroup': {'name': '制作兼工程'},
                'uri': '',
              },
              {
                'name': 'Singer A',
                'role': '制作人',
                'roleGroup': {'name': '制作兼工程'},
                'uri': 'spotify:artist:aaa',
              },
              {
                'name': '',
                'role': '空名字被忽略',
                'roleGroup': {'name': '制作兼工程'},
              },
            ],
          },
          'sources': {
            'items': [
              {'name': 'Synthetic Records'},
            ],
          },
        },
      },
    },
  };

  group('制作人员解析', () {
    test('按角色分组（保持顺序），同组同一人的角色合并，无艺人页的人不可点击', () {
      final credits = CreditsParser.parse(creditsResponse())!;
      expect(credits.trackName, 'Synthetic Song');
      expect(credits.groups.map((g) => g.name), ['艺人', '作曲和作词', '制作兼工程']);

      final writers = credits.groups[1].people;
      expect(writers, hasLength(1));
      expect(writers.single.roles, ['作曲者', '作词者']);
      expect(writers.single.artistId, 'bbb');

      final production = credits.groups[2].people;
      expect(production.map((p) => p.name), ['Engineer C', 'Singer A']);
      expect(production.first.hasArtistPage, isFalse);
      expect(credits.sources, ['Synthetic Records']);
    });

    test('兼容 PathfinderClient.query 已解包外层 data 的响应结构', () {
      final unwrapped = creditsResponse()['data'] as Map<String, dynamic>;
      final credits = CreditsParser.parse(unwrapped)!;
      expect(credits.trackName, 'Synthetic Song');
      expect(credits.groups.map((g) => g.name), ['艺人', '作曲和作词', '制作兼工程']);
      expect(credits.sources, ['Synthetic Records']);
    });

    test('结构不符时返回 null 或空', () {
      expect(CreditsParser.parse({'data': {}}), isNull);
      expect(
        CreditsParser.parse({
          'data': {
            'trackUnion': {'name': 'x'},
          },
        })!.isEmpty,
        isTrue,
      );
    });
  });

  group('歌曲电台', () {
    DesktopDataSource source(http.Response Function(http.Request) handler, List<Uri> seen) => DesktopDataSource(
      MockClient((request) async {
        seen.add(request.url);
        return handler(request);
      }),
      headers: () async => const {},
    );

    test('以曲目 URI 为种子取电台歌单 id；404 视为没有电台', () async {
      final seen = <Uri>[];
      final ok = source(
        (_) => http.Response(
          jsonEncode({
            'total': 1,
            'mediaItems': [
              {'uri': 'spotify:playlist:radio123'},
            ],
          }),
          200,
        ),
        seen,
      );
      expect(await ok.songRadioPlaylistId('track42'), 'radio123');
      expect(seen.single.path, '/inspiredby-mix/v2/seed_to_playlist/spotify:track:track42');

      final none = source((_) => http.Response('', 404), seen);
      expect(await none.songRadioPlaylistId('track42'), isNull);
    });
  });

  testWidgets('制作人员弹窗：分组标题、合并后的角色、来源', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _CreditsApi(await StorageService.init(), CreditsParser.parse(creditsResponse())!);
    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocale.supportedLocales,
        localizationsDelegates: AppLocale.delegates,
        home: Builder(
          builder: (context) {
            host = context;
            return const Scaffold();
          },
        ),
        builder: (context, child) => Provider<SpotifyApiService>.value(value: api, child: child!),
      ),
    );

    TrackCreditsView.show(host, const SpotifyTrack(id: 't1', name: 'Synthetic Song'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('制作人员'), findsOneWidget);
    expect(find.text('作曲和作词'), findsOneWidget);
    expect(find.text('作曲者、作词者'), findsOneWidget);
    expect(find.text('来源'), findsOneWidget);
    expect(find.text('Synthetic Records'), findsOneWidget);
  });
}

/// 只返回固定制作人员的数据服务。
class _CreditsApi extends SpotifyApiService {
  final TrackCredits credits;

  _CreditsApi(super.storage, this.credits);

  @override
  Future<TrackCredits> getTrackCredits(String trackId) async => credits;
}
