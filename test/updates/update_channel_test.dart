import 'dart:convert';
import 'dart:io';

import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/services/updates/update_installer.dart';
import 'package:flutify_app/services/updates/update_release.dart';
import 'package:flutify_app/services/updates/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Installer implements UpdateInstaller {
  _Installer(this.root);
  final Directory root;
  @override
  Future<Directory> downloadDirectory() async => root;
  @override
  Future<UpdateTarget> target() async =>
      const UpdateTarget(UpdatePlatform.windowsPortable, 'x64');
  @override
  Future<bool> install(File package, String checksum) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late StorageService storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.init();
    temporary = await Directory.systemTemp.createTemp('flutify-channel-test-');
  });
  tearDown(() => temporary.delete(recursive: true));

  UpdateService service(String current, List<String> tags) {
    final result = UpdateService(
      storage: storage,
      installer: _Installer(temporary),
      currentTag: current,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode([
            for (final tag in tags) {'tag_name': tag, 'body': '', 'assets': []},
          ]),
          200,
        ),
      ),
    );
    addTearDown(result.dispose);
    return result;
  }

  UpdateVersion v(String tag) => UpdateVersion.parse(tag)!;

  /// 切换通道后服务会自己在后台重新检查一次，等它结束。
  Future<void> settle(UpdateService updates) async {
    for (var i = 0; i < 200 && updates.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  group('标签里的通道与实质版本号', () {
    test('三种通道的标签都能解析', () {
      expect(v('v0.18.151').channel, UpdateChannel.release);
      expect(v('v0.18.151').build, 151);
      expect(v('v0.18.140-beta').channel, UpdateChannel.beta);
      expect(v('v0.18.140-beta').build, 140);
      expect(v('v0.18.135-selftest').channel, UpdateChannel.selfTest);
      expect(v('v0.18.135-selftest').build, 135);
      // 旧标签：没有实质版本号
      expect(v('v0.18').build, 0);
      expect(v('v0.14-beta').channel, UpdateChannel.beta);
    });

    test('只能从低的实质版本号更新到高的，跨通道也一样', () {
      expect(v('v0.18.151').isUpgradeFrom(v('v0.18.140-beta')), isTrue);
      expect(v('v0.18.160-selftest').isUpgradeFrom(v('v0.18.151')), isTrue);
      // 正式版的号更低：不降级
      expect(v('v0.18.151').isUpgradeFrom(v('v0.18.160-selftest')), isFalse);
      expect(v('v0.18.151').isUpgradeFrom(v('v0.18.151')), isFalse);
      // 现有的旧版本（v0.18）能更新到带实质版本号的新版本
      expect(v('v0.18.135').isUpgradeFrom(v('v0.18')), isTrue);
      // 基础版本更低的不算更新，哪怕第三段更大
      expect(v('v0.17.1').isUpgradeFrom(v('v0.18')), isFalse);
      // 旧标签之间沿用原来的比较
      expect(v('v0.14').isUpgradeFrom(v('v0.14-beta')), isTrue);
      expect(v('v0.14-beta').isUpgradeFrom(v('v0.14')), isFalse);
    });
  });

  group('按通道接收更新', () {
    const tags = [
      'v0.18.160-selftest',
      'v0.18.150-beta',
      'v0.18.140',
      'v0.18.120-selftest',
      'v0.18',
    ];

    test('默认跟随已安装版本的通道', () {
      expect(service('v0.18', tags).channel, UpdateChannel.release);
      expect(service('v0.18.130-beta', tags).channel, UpdateChannel.beta);
      expect(
        service('v0.18.130-selftest', tags).channel,
        UpdateChannel.selfTest,
      );
    });

    test('正式版只收正式版，测试版多收测试版，自测版全收', () async {
      final updates = service('v0.18', tags);
      await updates.check(manual: true);
      expect(updates.release?.tag, 'v0.18.140');

      await updates.setChannel(UpdateChannel.beta);
      await settle(updates);
      expect(updates.release?.tag, 'v0.18.150-beta');

      await updates.setChannel(UpdateChannel.selfTest);
      await settle(updates);
      expect(updates.release?.tag, 'v0.18.160-selftest');
      expect(storage.updateChannel, 'selfTest');
    });

    test('切回正式版不会降级：更高的自测版留在原地，找到的自测版更新被丢弃', () async {
      final updates = service('v0.18.155-selftest', tags);
      await updates.check(manual: true);
      expect(updates.release?.tag, 'v0.18.160-selftest');

      await updates.setChannel(UpdateChannel.release);
      expect(updates.release, isNull);
      await settle(updates);
      // 正式版 140 < 当前 155：不更新
      expect(updates.release, isNull);
      expect(updates.status, UpdateStatus.idle);
    });

    test('选过的通道下次启动仍然生效', () async {
      await service('v0.18', tags).setChannel(UpdateChannel.beta);
      expect(service('v0.18', tags).channel, UpdateChannel.beta);
    });
  });
}
