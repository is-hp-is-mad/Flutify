import 'dart:io';

import 'package:flutify_app/services/deep_link/spotify_link_handler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 系统 spotify: 链接：启动参数、运行中转发、界面未就绪时暂存。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutify/protocol');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  String initialLink = '';
  setUp(() {
    initialLink = '';
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'initialLink':
          final link = initialLink;
          initialLink = '';
          return link;
        case 'status':
          return {'isDefault': false, 'otherHandler': 'Spotify.exe'};
        case 'setDefault':
          return call.arguments == true ? 'userChoice' : 'ok';
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// 模拟原生侧推送转发来的链接。
  Future<void> push(String link) => messenger.handlePlatformMessage(
    channel.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall('openLink', link)),
    (_) {},
  );

  test('启动参数里的链接在 attach 时投递，且只投递一次', () async {
    if (!Platform.isWindows) return;
    initialLink = 'spotify:track:4uLU6hMCjMI75M1A2tKUQC';
    final got = <String>[];
    void onLink(String l) => got.add(l);
    await SpotifyLinkHandler.attach(onLink);
    await SpotifyLinkHandler.attach(onLink);
    expect(got, ['spotify:track:4uLU6hMCjMI75M1A2tKUQC']);
    SpotifyLinkHandler.detach(onLink);
  });

  test('运行中转发来的链接直接交给当前界面', () async {
    if (!Platform.isWindows) return;
    final got = <String>[];
    void onLink(String l) => got.add(l);
    await SpotifyLinkHandler.attach(onLink);
    await push('spotify:album:1DFixLWuPkv3KT3TnV35m3');
    expect(got, ['spotify:album:1DFixLWuPkv3KT3TnV35m3']);
    SpotifyLinkHandler.detach(onLink);
  });

  test('界面不在（如退出登录）时到达的链接暂存，下次 attach 补发', () async {
    if (!Platform.isWindows) return;
    final first = <String>[];
    void onFirst(String l) => first.add(l);
    await SpotifyLinkHandler.attach(onFirst);
    SpotifyLinkHandler.detach(onFirst);

    await push('spotify:playlist:37i9dQZF1DXcBWIGoYBM5M');
    expect(first, isEmpty);

    final second = <String>[];
    void onSecond(String l) => second.add(l);
    await SpotifyLinkHandler.attach(onSecond);
    expect(second, ['spotify:playlist:37i9dQZF1DXcBWIGoYBM5M']);
    SpotifyLinkHandler.detach(onSecond);
  });

  test('旧界面 detach 不会清掉新界面的回调', () async {
    if (!Platform.isWindows) return;
    final got = <String>[];
    void onOld(String l) {}
    void onNew(String l) => got.add(l);
    await SpotifyLinkHandler.attach(onOld);
    await SpotifyLinkHandler.attach(onNew);
    SpotifyLinkHandler.detach(onOld);
    await push('spotify:artist:0OdUWJ0sBjDrqHygGUXeCF');
    expect(got, ['spotify:artist:0OdUWJ0sBjDrqHygGUXeCF']);
    SpotifyLinkHandler.detach(onNew);
  });

  test('状态与设为默认的结果映射', () async {
    if (!Platform.isWindows) return;
    final status = await SpotifyLinkHandler.status();
    expect(status?.isDefault, isFalse);
    expect(status?.otherHandler, 'Spotify.exe');
    expect(
      await SpotifyLinkHandler.setDefault(true),
      SpotifyLinkSetResult.needsSystemSettings,
    );
    expect(await SpotifyLinkHandler.setDefault(false), SpotifyLinkSetResult.ok);
  });
}
