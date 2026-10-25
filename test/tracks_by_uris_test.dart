import 'dart:convert';

import 'package:flutify_app/services/pathfinder/desktop_data_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final uris = [for (var i = 0; i < 120; i++) 'spotify:track:t$i'];

  /// 第 2 批（第 51–100 首）前 [failures] 次请求返回 500。
  DesktopDataSource source(int failures, List<int> calls) => DesktopDataSource(
    MockClient((request) async {
      final batch = (jsonDecode(request.body)['variables']['uris'] as List)
          .cast<String>();
      calls.add(uris.indexOf(batch.first));
      if (batch.first == uris[50] && failures-- > 0) {
        return http.Response('{}', 500);
      }
      return http.Response(
        jsonEncode({
          'data': {
            'tracks': [
              for (final uri in batch) {'uri': uri, 'name': uri},
            ],
          },
        }),
        200,
      );
    }),
    headers: () async => {},
    retryDelay: Duration.zero,
  );

  test('a failed batch is retried instead of dropped', () async {
    final calls = <int>[];
    final tracks = await source(2, calls).tracksByUris(uris, complete: true);
    expect(tracks, hasLength(120));
    expect(calls.where((c) => c == 50), hasLength(3));
  });

  test('complete throws when a batch keeps failing', () async {
    await expectLater(
      source(99, []).tracksByUris(uris, complete: true),
      throwsA(anything),
    );
  });

  test('without complete the remaining batches are still returned', () async {
    final tracks = await source(99, []).tracksByUris(uris);
    expect(tracks, hasLength(70));
  });
}
