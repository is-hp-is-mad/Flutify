import 'dart:io';

import 'package:flutify_app/services/network/proxy_endpoint.dart';
import 'package:flutify_app/services/network/system_proxy.dart';
import 'package:flutify_app/services/network/system_proxy_macos.dart';
import 'package:flutter_test/flutter_test.dart';

/// macOS 系统代理：原生通道地图（CFNetworkCopySystemProxySettings 快照）的解析。
void main() {
  group('systemProxySettingsFromMacOS', () {
    test('HTTP 代理单独开启时，HTTPS 回退到同一地址', () {
      final s = systemProxySettingsFromMacOS({
        'httpEnabled': true,
        'httpHost': '127.0.0.1',
        'httpPort': 7890,
      });
      expect(s.http, const ProxyEndpoint('127.0.0.1', 7890));
      expect(s.https, const ProxyEndpoint('127.0.0.1', 7890));
      expect(s.isEmpty, isFalse);
    });

    test('HTTP 与 HTTPS 分开配置时各用各的', () {
      final s = systemProxySettingsFromMacOS({
        'httpEnabled': true,
        'httpHost': 'proxy.lan',
        'httpPort': 8080,
        'httpsEnabled': true,
        'httpsHost': 'secure-proxy.lan',
        'httpsPort': 8443,
      });
      expect(s.http, const ProxyEndpoint('proxy.lan', 8080));
      expect(s.https, const ProxyEndpoint('secure-proxy.lan', 8443));
    });

    test('NSNumber 桥接成 Int 的开关也认（0/1）', () {
      final s = systemProxySettingsFromMacOS({
        'httpEnabled': 1,
        'httpHost': '10.0.0.2',
        'httpPort': 3128,
        'httpsEnabled': 0,
        'httpsHost': 'ignored',
        'httpsPort': 443,
      });
      expect(s.http, const ProxyEndpoint('10.0.0.2', 3128));
      // https 未开 → 回退 http
      expect(s.https, const ProxyEndpoint('10.0.0.2', 3128));
    });

    test('只开 SOCKS 时解析为 SOCKS5（由自建隧道使用）', () {
      final s = systemProxySettingsFromMacOS({
        'socksEnabled': true,
        'socksHost': '127.0.0.1',
        'socksPort': 1080,
      });
      expect(
        s.socks,
        const ProxyEndpoint('127.0.0.1', 1080, type: ProxyType.socks5),
      );
      expect(s.primary, s.socks);
      expect(s.isEmpty, isFalse);
    });

    test('只开 PAC 时按直连处理', () {
      final s = systemProxySettingsFromMacOS({
        'pacEnabled': true,
        'pacUrl': 'http://wpad.corp.example/proxy.pac',
      });
      expect(s.isEmpty, isTrue);
    });

    test('PAC 与 HTTP 并存时只用 HTTP（与 Windows 同取舍）', () {
      final s = systemProxySettingsFromMacOS({
        'pacEnabled': true,
        'pacUrl': 'http://wpad/proxy.pac',
        'httpEnabled': true,
        'httpHost': '127.0.0.1',
        'httpPort': 7890,
      });
      expect(s.primary, const ProxyEndpoint('127.0.0.1', 7890));
    });

    test('绕过清单与 excludeSimpleHostnames 映射为 <local>', () {
      final s = systemProxySettingsFromMacOS({
        'httpEnabled': true,
        'httpHost': '127.0.0.1',
        'httpPort': 7890,
        'exceptions': ['*.local', '  ', 'internal.example.com'],
        'excludeSimpleHostnames': true,
      });
      expect(s.bypasses('printer.local'), isTrue);
      expect(s.bypasses('internal.example.com'), isTrue);
      expect(s.bypasses('Nas'), isTrue, reason: '<local> = 不带点的主机名');
      expect(s.bypasses('api.spotify.com'), isFalse);
    });

    test('CIDR 网段例外（含 macOS 省略写法 169.254/16）按网段匹配', () {
      final s = systemProxySettingsFromMacOS({
        'httpEnabled': true,
        'httpHost': '127.0.0.1',
        'httpPort': 7890,
        'exceptions': [
          '192.168.0.0/16',
          '10.0.0.0/8',
          '172.16.0.0/12',
          '169.254/16',
          'bad/99',
        ],
      });
      expect(s.bypasses('192.168.1.20'), isTrue);
      expect(s.bypasses('10.255.0.1'), isTrue);
      expect(s.bypasses('172.31.255.255'), isTrue);
      expect(s.bypasses('172.32.0.1'), isFalse, reason: '/12 只到 172.31');
      expect(s.bypasses('169.254.3.4'), isTrue);
      expect(s.bypasses('169.255.0.1'), isFalse);
      expect(s.bypasses('192.169.0.1'), isFalse);
      expect(s.bypasses('api.spotify.com'), isFalse, reason: '域名不按网段匹配');
    });

    test('全部关闭 / 空 map / 无效端点都视为无代理', () {
      expect(systemProxySettingsFromMacOS({}).isEmpty, isTrue);
      expect(
        systemProxySettingsFromMacOS({
          'httpEnabled': false,
          'httpHost': '127.0.0.1',
          'httpPort': 7890,
        }).isEmpty,
        isTrue,
      );
      // 缺端口 / 端口越界 / 空主机名 → 该条忽略
      expect(
        systemProxySettingsFromMacOS({
          'httpEnabled': true,
          'httpHost': '127.0.0.1',
        }).isEmpty,
        isTrue,
      );
      expect(
        systemProxySettingsFromMacOS({
          'httpEnabled': true,
          'httpHost': '127.0.0.1',
          'httpPort': 70000,
        }).isEmpty,
        isTrue,
      );
      expect(
        systemProxySettingsFromMacOS({
          'httpsEnabled': true,
          'httpsHost': '   ',
          'httpsPort': 443,
        }).isEmpty,
        isTrue,
      );
    });

    test('ftpPassive 等额外键不影响解析', () {
      final s = systemProxySettingsFromMacOS({
        'ftpPassive': true,
        'httpsEnabled': true,
        'httpsHost': 'p.local',
        'httpsPort': 443,
      });
      expect(s.https, const ProxyEndpoint('p.local', 443));
    });
  });

  group('SystemProxyReader macOS 通道', () {
    tearDown(() => SystemProxyReader.macOSSettingsReader = null);

    test('通道有数据时优先用通道结果', () async {
      if (!Platform.isMacOS) return; // 分支只在 macOS 宿主上可达
      SystemProxyReader.macOSSettingsReader = () async => {
        'httpEnabled': true,
        'httpHost': '192.168.1.8',
        'httpPort': 8080,
      };
      final s = await SystemProxyReader.read();
      expect(s.https, const ProxyEndpoint('192.168.1.8', 8080));
    });

    test('通道失败 / 未接入时回退环境变量，不抛错', () async {
      if (!Platform.isMacOS) return;
      SystemProxyReader.macOSSettingsReader = () async =>
          throw StateError('channel gone');
      final a = await SystemProxyReader.read();
      SystemProxyReader.macOSSettingsReader = () async => null;
      final b = await SystemProxyReader.read();
      // 两个结果都来自宿主环境变量，彼此一致且可用即可（值随宿主而定，不断言具体地址）
      expect(a.http, b.http);
      expect(a.https, b.https);
    });
  });
}
