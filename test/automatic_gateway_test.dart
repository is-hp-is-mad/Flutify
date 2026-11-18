import 'dart:async';

import 'package:flutify_app/services/network/network_proxy.dart';
import 'package:flutify_app/models/proxy_mode.dart';
import 'package:flutify_app/models/spotify_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

const settings = SpotifyGateway(
  automatic: true,
  baseUrl: 'https://gateway.example/assets-test',
  username: 'user',
  password: 'pass',
);

void main() {
  test('default and allowlist country policies round-trip', () {
    expect(settings.enabledForCountry('CN'), isTrue);
    expect(settings.enabledForCountry('US'), isFalse);
    final custom = settings.copyWith(directCountries: 'us jp，hk US');
    expect(
      SpotifyGateway.normalizeCountries(custom.directCountries),
      'HK, JP, US',
    );
    for (final country in ['US', 'JP', 'HK']) {
      expect(custom.enabledForCountry(country), isFalse);
    }
    for (final country in ['CN', 'DE', 'GB']) {
      expect(custom.enabledForCountry(country), isTrue);
    }
    expect(SpotifyGateway.fromJson(custom.toJson()), custom);
    expect(SpotifyGateway.fromJson({'enabled': true}).automatic, isFalse);
    expect(
      () => SpotifyGateway.normalizeCountries('USA'),
      throwsFormatException,
    );
  });

  test(
    'trace parsing rejects malformed, absent, duplicate and unknown location',
    () {
      expect(NetworkProxy.countryFromTrace('fl=1\nloc=CN\nip=1\n'), 'CN');
      expect(NetworkProxy.countryFromTrace('loc=JP\r\n'), 'JP');
      for (final trace in [
        'ip=1',
        'loc=XX',
        'loc=cn',
        'loc=USA',
        'loc=CN\nloc=US',
        '<html>loc=CN</html>',
      ]) {
        expect(
          () => NetworkProxy.countryFromTrace(trace),
          throwsFormatException,
        );
      }
      expect(
        settings.route(Uri.parse('https://cloudflare.com/cdn-cgi/trace')).host,
        'cloudflare.com',
      );
    },
  );

  test(
    'CN enables routing, failures retain it, and a later success disables it',
    () async {
      var country = 'CN';
      var fail = false;
      var reads = 0;
      final proxy = NetworkProxy(
        countryReader: () {
          reads++;
          if (fail) throw StateError('offline');
          return Future.value(country);
        },
      );
      await proxy.configure(mode: ProxyMode.none, gateway: settings);
      final target = Uri.parse('https://api.spotify.com/v1/me');
      expect(proxy.gateway.route(target).host, 'gateway.example');
      fail = true;
      await proxy.refreshGatewayCountry();
      expect(proxy.gateway.enabled, isTrue);
      expect(proxy.gatewayLookupFailed, isTrue);
      fail = false;
      country = 'US';
      await proxy.refreshGatewayCountry();
      expect(reads, 3);
      expect(proxy.gateway.route(target), target);
      expect(proxy.gatewayLookupFailed, isFalse);
      expect(
        settings.enabled,
        isFalse,
        reason: 'automatic state does not mutate preferences',
      );
    },
  );

  test(
    'concurrent checks merge; manual selection wins over an old lookup',
    () async {
      final pending = Completer<String>();
      var reads = 0;
      final proxy = NetworkProxy(
        countryReader: () {
          reads++;
          return pending.future;
        },
      );
      final first = proxy.configure(mode: ProxyMode.none, gateway: settings);
      final second = proxy.refreshGatewayCountry();
      await Future<void>.delayed(Duration.zero);
      expect(reads, 1);
      await proxy.configure(
        mode: ProxyMode.none,
        gateway: settings.copyWith(automatic: false),
      );
      pending.complete('CN');
      await Future.wait([first, second]);
      expect(proxy.gateway.enabled, isFalse);
      expect(proxy.gatewayChecking, isFalse);
    },
  );

  test(
    'network changes discard late results from the previous network',
    () async {
      final old = Completer<String>();
      var reads = 0;
      final proxy = NetworkProxy(
        countryReader: () => ++reads == 1 ? old.future : Future.value('US'),
      );
      final first = proxy.configure(mode: ProxyMode.none, gateway: settings);
      await Future<void>.delayed(Duration.zero);
      await proxy.refreshGatewayCountry(networkChanged: true);
      old.complete('CN');
      await first;
      expect(proxy.gatewayCountry, 'US');
      expect(proxy.gateway.enabled, isFalse);
    },
  );

  test('allowlist edits apply and invalid configs do not query', () async {
    var reads = 0;
    final proxy = NetworkProxy(
      countryReader: () async {
        reads++;
        return 'JP';
      },
    );
    await proxy.configure(
      mode: ProxyMode.none,
      gateway: settings.copyWith(directCountries: 'US'),
    );
    expect(proxy.gateway.enabled, isTrue);
    await proxy.configure(
      mode: ProxyMode.none,
      gateway: settings.copyWith(directCountries: 'JP'),
    );
    expect(proxy.gateway.enabled, isFalse);
    await proxy.configure(
      mode: ProxyMode.none,
      gateway: const SpotifyGateway(automatic: true),
    );
    expect(reads, 2);
  });

  test('first failed lookup preserves configured fallback', () async {
    final proxy = NetworkProxy(
      countryReader: () => Future.error(StateError('offline')),
    );
    await proxy.configure(
      mode: ProxyMode.none,
      gateway: settings.copyWith(enabled: true),
    );
    expect(proxy.gateway.enabled, isTrue);
    expect(proxy.gatewayLookupFailed, isTrue);
  });
}
