import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/services/updates/update_downloader.dart';
import 'package:flutify_app/services/updates/update_installer.dart';
import 'package:flutify_app/models/update_release.dart';
import 'package:flutify_app/services/updates/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _Installer implements UpdateInstaller {
  _Installer(this.root);
  final Directory root;
  int installs = 0;
  @override
  Future<Directory> downloadDirectory() async => root;
  @override
  Future<UpdateTarget> target() async =>
      const UpdateTarget(UpdatePlatform.windowsPortable, 'x64');
  @override
  Future<bool> install(File package, String checksum) async {
    installs++;
    expect(sha256.convert(await package.readAsBytes()).toString(), checksum);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late StorageService storage;
  late _Installer installer;
  final bytes = utf8.encode('verified update package');
  final digest = sha256.convert(bytes).toString();
  const name = 'Flutify-v0.07-beta-windows-x64.zip';
  const base =
      'https://github.com/is-hp-is-mad/Flutify/releases/download/v0.07-beta';
  final release = {
    'tag_name': 'v0.07-beta',
    'body': 'Release changes',
    'prerelease': true,
    'assets': [
      {
        'name': name,
        'size': bytes.length,
        'browser_download_url': '$base/$name',
      },
      {
        'name': 'SHA256SUMS.txt',
        'size': 120,
        'browser_download_url': '$base/SHA256SUMS.txt',
      },
    ],
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.init();
    temporary = await Directory.systemTemp.createTemp('flutify-update-test-');
    installer = _Installer(
      Directory(p.join(temporary.path, 'missing', 'updates')),
    );
  });

  tearDown(() async {
    expect(
      p.isWithin(Directory.systemTemp.absolute.path, temporary.absolute.path),
      isTrue,
    );
    await temporary.delete(recursive: true);
  });

  Future<http.Response> respond(http.Request request) async {
    if (request.url.host == 'api.github.com') {
      expect(request.url.path, '/repos/is-hp-is-mad/Flutify/releases');
      return http.Response(jsonEncode([release]), 200);
    }
    if (request.url.path.endsWith('/SHA256SUMS.txt')) {
      return http.Response('$digest  $name\n', 200);
    }
    return http.Response.bytes(bytes, 200);
  }

  UpdateService service({MockClient? client}) {
    final result = UpdateService(
      storage: storage.updates,
      installer: installer,
      currentTag: 'v0.06-beta',
      client: client ?? MockClient(respond),
      downloaderFactory: () =>
          UpdateDownloader(clientFactory: () => MockClient(respond)),
    );
    addTearDown(result.dispose);
    return result;
  }

  test(
    'first download creates absent cache and waits for explicit installation',
    () async {
      final updates = service();
      await updates.check(manual: true);
      expect(updates.release?.tag, 'v0.07-beta');
      expect(updates.release?.notes, 'Release changes');
      expect(await installer.root.exists(), isFalse);
      await updates.download();
      expect(updates.error, isNull);
      expect(updates.status, UpdateStatus.ready);
      expect(await updates.package!.readAsBytes(), bytes);
      expect(
        await File(p.join(installer.root.path, 'pending.json')).exists(),
        isTrue,
      );
      expect(installer.installs, 0);
      await updates.install();
      expect(installer.installs, 1);
    },
  );

  test('automatic download also waits for explicit installation', () async {
    await storage.updates.setUpdateMode('automatic');
    final updates = service();
    await updates.check();
    expect(updates.error, isNull);
    expect(updates.status, UpdateStatus.ready);
    expect(installer.installs, 0);
    expect(updates.notification, greaterThan(0));
  });

  test(
    'skip persists across sessions while manual check can find it again',
    () async {
      final updates = service();
      await updates.check(manual: true);
      await updates.skip();
      expect(storage.updates.skippedUpdate, 'v0.07-beta');
      await storage.updates.setLastUpdateCheck('');
      final restarted = service();
      await restarted.check();
      expect(restarted.release, isNull);
      await restarted.check(manual: true);
      expect(restarted.release?.tag, 'v0.07-beta');
    },
  );

  test('disabling checks ignores an already running response', () async {
    final response = Completer<http.Response>();
    final sent = Completer<void>();
    final updates = service(
      client: MockClient((_) {
        sent.complete();
        return response.future;
      }),
    );
    final check = updates.check();
    await sent.future;
    await updates.setMode(UpdateMode.disabled);
    response.complete(http.Response(jsonEncode([release]), 200));
    await check;
    expect(updates.status, UpdateStatus.idle);
    expect(updates.release, isNull);
    expect(storage.updates.updateMode, 'disabled');
  });

  test('cleanup removes leftovers of installed updates but keeps a pending package', () async {
    final stale = Directory(p.join(installer.root.path, 'download-old'));
    await stale.create(recursive: true);
    await File(p.join(stale.path, name)).writeAsBytes(bytes);
    await File(p.join(installer.root.path, 'pending.json')).writeAsString('{}');
    final fresh = Directory(p.join(installer.root.path, 'apply-fresh'));
    await fresh.create();
    final updates = service();
    await updates.cleanupInstalledUpdates();
    expect(await stale.exists(), isFalse);
    expect(await File(p.join(installer.root.path, 'pending.json')).exists(), isFalse);
    // Recent Windows helper work directories may still be in use.
    expect(await fresh.exists(), isTrue);
  });
}
