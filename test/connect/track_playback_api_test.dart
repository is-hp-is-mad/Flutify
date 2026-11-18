import 'dart:async';
import 'dart:convert';

import 'package:flutify_app/models/audio_playback_info.dart';
import 'package:flutify_app/services/connect/receiver/track_playback_api.dart';
import 'package:flutify_app/services/connect/receiver/connect_receiver.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  http.Response token(String value, {int? refresh, int? expires}) =>
      http.Response(
        jsonEncode({
          'granted_token': {
            'token': value,
            'refresh_after_seconds': ?refresh,
            'expires_after_seconds': ?expires,
          },
        }),
        200,
      );

  for (final status in [401, 403]) {
    test(
      'HTTP $status only invalidates client-token for explicit authentication failure',
      () async {
        var tokens = 0;
        var commands = 0;
        final api = TrackPlaybackApi(
          deviceId: 'test',
          webToken: () async => 'web',
          client: MockClient((r) async {
            if (r.url.host == 'clienttoken.spotify.com')
              return token('token-${++tokens}');
            commands++;
            return http.Response('rejected', status);
          }),
        );
        await expectLater(api.putVolume(50), throwsStateError);
        expect(commands, 1, reason: 'a rejected command is not replayed');
        final headers = await api.headers();
        expect(tokens, status == 401 ? 2 : 1);
        expect(headers['client-token'], 'token-$tokens');
      },
    );
  }

  test(
    'concurrent token requests share one request and short TTL expires',
    () async {
      var now = DateTime.utc(2026, 10, 5);
      var calls = 0;
      final response = Completer<http.Response>();
      final api = TrackPlaybackApi(
        deviceId: 'test',
        webToken: () async => 'web',
        now: () => now,
        client: MockClient((_) {
          calls++;
          return calls == 1 ? response.future : Future.value(token('second'));
        }),
      );
      final requests = [for (var i = 0; i < 8; i++) api.headers()];
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      response.complete(token('first', refresh: 100, expires: 20));
      expect(
        (await Future.wait(requests)).map((h) => h['client-token']),
        everyElement('first'),
      );
      now = now.add(const Duration(seconds: 17));
      expect((await api.headers())['client-token'], 'first');
      expect(calls, 1);
      now = now.add(const Duration(seconds: 1));
      expect((await api.headers())['client-token'], 'second');
      expect(calls, 2);
    },
  );

  test(
    'invalidation during refresh cannot restore the obsolete token',
    () async {
      final responses = <Completer<http.Response>>[];
      final api = TrackPlaybackApi(
        deviceId: 'test',
        webToken: () async => 'web',
        client: MockClient((_) {
          final pending = Completer<http.Response>();
          responses.add(pending);
          return pending.future;
        }),
      );
      final old = api.headers();
      await Future<void>.delayed(Duration.zero);
      api.invalidate();
      final fresh = api.headers();
      await Future<void>.delayed(Duration.zero);
      expect(responses, hasLength(2));
      responses[0].complete(token('obsolete'));
      await Future<void>.delayed(Duration.zero);
      final concurrent = api.headers();
      await Future<void>.delayed(Duration.zero);
      expect(responses, hasLength(2));
      responses[1].complete(token('current'));
      expect(
        (await Future.wait([
          old,
          fresh,
          concurrent,
        ])).map((h) => h['client-token']),
        everyElement('current'),
      );
      expect((await api.headers())['client-token'], 'current');
      expect(responses, hasLength(2));
    },
  );

  test(
    'HTTP failure is not cached, missing TTL gets a bounded cache',
    () async {
      var now = DateTime.utc(2026, 10, 5);
      var calls = 0;
      final api = TrackPlaybackApi(
        deviceId: 'test',
        webToken: () async => 'web',
        now: () => now,
        client: MockClient(
          (_) async => ++calls == 1
              ? http.Response('unavailable', 503)
              : token('token-$calls'),
        ),
      );
      await expectLater(api.headers(), throwsStateError);
      expect((await api.headers())['client-token'], 'token-2');
      now = now.add(const Duration(minutes: 5));
      expect((await api.headers())['client-token'], 'token-3');
    },
  );

  test(
    'registration and state follow discovered hosts and preserve chosen name',
    () async {
      String? host;
      final sent = <http.Request>[];
      final api = TrackPlaybackApi(
        deviceId: 'test',
        webToken: () async => 'web',
        spclientHostProvider: () => host,
        client: MockClient((r) async {
          if (r.url.host == 'clienttoken.spotify.com') return token('test');
          sent.add(r);
          return http.Response('{}', 200);
        }),
      );
      expect(api.spclientHost, 'gae2-spclient.spotify.com');
      host = 'gew1-spclient.spotify.com';
      await api.register(
        connectionId: 'c1',
        name: ConnectReceiver.defaultDeviceName,
        volume: 5,
      );
      expect(sent.last.url.host, host);
      expect(jsonDecode(sent.last.body)['device']['name'], 'Web Player');
      host = 'guc3-spclient.spotify.com';
      await api.register(connectionId: 'c2', name: 'Living room', volume: 5);
      expect(jsonDecode(sent.last.body)['device']['name'], 'Living room');
      await api.putState(debugSource: 'resume');
      expect(sent.last.url.host, host);
    },
  );

  test(
    'state reports real format, omits unknown quality, decodes UTF-8 titles',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final api = TrackPlaybackApi(
        deviceId: 'test',
        webToken: () async => 'test',
        client: MockClient((r) async {
          if (r.url.host == 'clienttoken.spotify.com')
            return http.Response('{"granted_token":{"token":"test"}}', 200);
          bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
          return http.Response.bytes(
            utf8.encode('{"name":"中文・日本語 🎵"}'),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final response = await api.putState(
        debugSource: 'resume',
        audio: const AudioPlaybackInfo(bitrate: 256000, format: 11),
      );
      expect(response!['name'], '中文・日本語 🎵');
      expect(bodies.last['sub_state']['bitrate'], 256000);
      expect(bodies.last['sub_state']['format'], 11);
      expect(bodies.last['sub_state'].containsKey('audio_quality'), isFalse);
      await api.putState(debugSource: 'before_track_load');
      expect(bodies.last['sub_state'].containsKey('bitrate'), isFalse);
      expect(bodies.last['sub_state'].containsKey('format'), isFalse);
    },
  );

  test(
    'receiver installation ID persists across restarts and logout',
    () async {
      SharedPreferences.setMockInitialValues({});
      final first = await StorageService.init();
      final id = first.auth.receiverDeviceId;
      expect(id, matches(RegExp(r'^[a-f0-9]{40}$')));
      await first.auth.clearLogin();
      expect((await StorageService.init()).auth.receiverDeviceId, id);
      SharedPreferences.setMockInitialValues({});
      expect((await StorageService.init()).auth.receiverDeviceId, isNot(id));
    },
  );
}
