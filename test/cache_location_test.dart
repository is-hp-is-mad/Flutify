import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutify_app/services/cache/artwork_cache.dart';
import 'package:flutify_app/services/cache/cache_location.dart';
import 'package:flutify_app/services/lyrics/lyrics_disk_cache.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory sandbox;
  late StorageService storage;
  late CacheLocation location;
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.flutify/cache_directories'),
          (call) async => null,
        );
    sandbox = await Directory.systemTemp.createTemp('flutify-cache-test-');
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.init();
    location = CacheLocation(storage.cache,
      p.join(sandbox.path, 'support'),
      applicationRoot: p.join(sandbox.path, 'portable'),
    );
    await location.initialize();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.flutify/cache_directories'),
          null,
        );
    location.dispose();
    await sandbox.delete(recursive: true);
  });

  Future<File> seed(String dir, String name, List<int> data) async {
    await Directory(dir).create(recursive: true);
    return File(p.join(dir, name)).writeAsBytes(data, flush: true);
  }

  Future<void> linkDirectory(String target, String alias) async {
    if (Platform.isWindows) {
      // Junctions do not require Windows Developer Mode or symlink privileges.
      final result = await Process.run('cmd.exe', [
        '/c',
        'mklink',
        '/J',
        alias,
        target,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    } else {
      await Link(alias).create(target);
    }
    expect(
      await FileSystemEntity.type(alias, followLinks: false),
      FileSystemEntityType.link,
    );
  }

  test(
    'system directory aliases allow startup and legacy cache migration',
    () async {
      final real = await Directory(p.join(sandbox.path, 'real')).create();
      final alias = p.join(sandbox.path, 'system-alias');
      await linkDirectory(real.path, alias);
      try {
        final support = p.join(alias, 'files');
        final legacy = p.join(alias, 'cache', 'libCachedImageData');
        await seed(p.join(support, 'audio'), 'old.mp4', [1, 2]);
        await seed(legacy, 'cover.png', [3, 4]);
        await storage.cache.setCacheLocationsJson(
          jsonEncode({
            'artwork': {
              'preset': 'appData',
              'old': [legacy],
            },
          }),
        );
        location.dispose();
        location = CacheLocation(storage.cache,
          support,
          legacyArtworkDirectory: legacy,
        );
        await location.initialize();
        expect((await location.resumeMigrations()).failed, 0);
        expect(
          await File(p.join(location.audioPath, 'old.mp4')).readAsBytes(),
          [1, 2],
        );
        expect(
          await File(
            p.join(location.imageDirectory.path, 'cover.png'),
          ).readAsBytes(),
          [3, 4],
        );
        expect((await location.clearCategory(CacheCategory.audio)).failed, 0);
        expect(
          await File(p.join(location.audioPath, 'old.mp4')).exists(),
          false,
        );
      } finally {
        await Link(alias).delete();
      }
    },
  );

  test('macOS system aliases are valid cache ancestors', () async {
    await CacheLocation.prepare(p.join(sandbox.path, 'alias-cache'));
  }, skip: !Platform.isMacOS);

  test(
    'macOS system aliases do not bypass cache containment checks',
    () async {
      final alias = location.audioPath.replaceFirst('/private/var/', '/var/');
      expect(alias, startsWith('/var/'));
      await expectLater(
        location.change(
          CacheCategory.audio,
          CacheSelection(CachePreset.custom, alias),
        ),
        throwsA(isA<FormatException>()),
      );
    },
    skip: !Platform.isMacOS,
  );

  test('cache child links and custom root links remain rejected', () async {
    final outside = await Directory(p.join(sandbox.path, 'outside')).create();
    final sentinel = await seed(outside.path, 'keep', [9]);
    final child = p.join(location.defaultRoot, 'linked-cache');
    await linkDirectory(outside.path, child);
    try {
      await expectLater(
        CacheLocation.prepare(child),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        location.change(
          CacheCategory.audio,
          CacheSelection(CachePreset.custom, child),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect((await CacheLocation.clearDirectory(child)).failed, 1);
      expect(await sentinel.readAsBytes(), [9]);
    } finally {
      await Link(child).delete();
    }
  });

  test(
    'category selection migrates bytes, removes originals and persists',
    () async {
      final original = await seed(location.audioPath, 'track.mp4', [1, 2, 3]);
      final lyrics = await seed(location.lyricsDirectory.path, 'track.lrc', [
        4,
      ]);
      final result = await location.change(
        CacheCategory.audio,
        const CacheSelection(CachePreset.application),
      );
      expect(result.failed, 0);
      expect(result.bytes, 3);
      expect(await original.exists(), false);
      expect(
        await File(p.join(location.audioPath, 'track.mp4')).readAsBytes(),
        [1, 2, 3],
      );
      expect(await lyrics.exists(), true);
      final restored = CacheLocation(storage.cache,
        location.defaultRoot,
        applicationRoot: location.applicationRoot,
      );
      await restored.initialize();
      expect(restored.audioPath, location.audioPath);
      restored.dispose();
    },
  );

  test(
    'playing audio and completion marker defer together and resume after restart',
    () async {
      final file = await seed(location.audioPath, 'active.mp4', [1, 2]);
      final marker = await seed(location.audioPath, 'active.mp4.done', []);
      location.audioInUse = (path) => path == file.path || path == marker.path;
      final result = await location.change(
        CacheCategory.audio,
        CacheSelection(CachePreset.custom, p.join(sandbox.path, 'custom')),
      );
      expect(result.deferred, 2);
      expect(await file.exists(), true);
      location.dispose();
      location = CacheLocation(storage.cache, location.defaultRoot);
      await location.initialize();
      final resumed = await location.resumeMigrations();
      expect(resumed.failed, 0);
      expect(resumed.deferred, 0);
      expect(await file.exists(), false);
      expect(await marker.exists(), false);
      expect(
        await File(p.join(location.audioPath, 'active.mp4.done')).exists(),
        true,
      );
    },
  );

  test(
    'different destination content keeps both originals and reports failure',
    () async {
      final source = p.join(sandbox.path, 'source');
      final target = p.join(sandbox.path, 'target');
      final old = await seed(source, 'same', [1]);
      final current = await seed(target, 'same', [2]);
      final result = await CacheLocation.transferDirectory(source, target);
      expect(result.failed, 1);
      expect(result.bytes, 0);
      expect(await old.readAsBytes(), [1]);
      expect(await current.readAsBytes(), [2]);
    },
  );

  test(
    'failed legacy artwork export preserves originals and retries migration',
    () async {
      final legacy = p.join(sandbox.path, 'legacy-artwork');
      final image = await seed(legacy, 'cover.png', [1, 2, 3]);
      location.dispose();
      location = CacheLocation(storage.cache,
        p.join(sandbox.path, 'support'),
        legacyArtworkDirectory: legacy,
      );
      await location.initialize();
      location.prepareLegacyArtwork = () async =>
          throw const FileSystemException('busy');
      expect((await location.resumeMigrations()).failed, 1);
      expect(await image.exists(), true);
      expect(
        await File(p.join(location.imageDirectory.path, 'cover.png')).exists(),
        false,
      );
      location.prepareLegacyArtwork = () async {};
      expect((await location.resumeMigrations()).failed, 0);
      expect(await image.exists(), false);
      expect(
        await File(
          p.join(location.imageDirectory.path, 'cover.png'),
        ).readAsBytes(),
        [1, 2, 3],
      );
    },
  );

  test(
    'clear removes owned caches including legacy audio, preserving state and active files',
    () async {
      final state = await seed(location.defaultRoot, 'session.json', [7, 8]);
      final playing = await seed(location.audioPath, 'playing.mp4', [1, 2]);
      await seed(location.audioPath, 'other.mp4', [1, 2, 3]);
      await seed(p.join(location.defaultRoot, 'audio'), 'legacy.ogg', [4, 5]);
      location.audioInUse = (path) => path == playing.path;
      final result = await location.clearCategory(CacheCategory.audio);
      expect(result.bytes, 5);
      expect(result.deferred, 1);
      expect(result.failed, 0);
      expect(await playing.exists(), true);
      expect(await state.readAsBytes(), [7, 8]);
    },
  );

  test('late lyrics writes cannot repopulate a cleared cache', () async {
    final cache = LyricsDiskCache(
      location.lyricsDirectory,
      directoryProvider: () => location.lyricsDirectory,
      lock: location.lock,
    );
    await cache.write('track', 'old');
    final generation = cache.generation;
    final result = await cache.clear(
      clearFiles: () => location.clearCategory(CacheCategory.lyrics),
    );
    expect(result.bytes, 3);
    await cache.write('track', 'late', expectedGeneration: generation);
    expect(await cache.read('track'), isNull);
  });

  test(
    'artwork migration merges populated indexes and keeps cached URLs usable',
    () async {
      final cache = ArtworkCache(location);
      location.artworkMaintenance = cache.maintain;
      try {
        final first = await cache.putFile(
          'https://example.test/one',
          Uint8List.fromList([1, 2, 3]),
        );
        final firstRoot = location.imageDirectory.path;
        expect(
          (await location.change(
            CacheCategory.artwork,
            const CacheSelection(CachePreset.application),
          )).failed,
          0,
        );
        expect(await first.exists(), false);
        expect(
          await (await cache.getFileFromCache(
            'https://example.test/one',
          ))!.file.readAsBytes(),
          [1, 2, 3],
        );
        await cache.putFile(
          'https://example.test/two',
          Uint8List.fromList([4, 5]),
        );
        // Populate the retired root independently, as after a previous partial move.
        final otherLocation = CacheLocation(storage.cache, location.defaultRoot);
        final other = ArtworkCache(otherLocation);
        await other.putFile(
          'https://example.test/three',
          Uint8List.fromList([6]),
        );
        await other.dispose();
        otherLocation.dispose();
        expect(
          (await location.change(
            CacheCategory.artwork,
            const CacheSelection(CachePreset.appData),
          )).failed,
          0,
        );
        expect(location.imageDirectory.path, firstRoot);
        for (final key in ['one', 'two', 'three']) {
          expect(
            await cache.getFileFromCache('https://example.test/$key'),
            isNotNull,
          );
        }
        expect((await location.clearCategory(CacheCategory.artwork)).failed, 0);
        expect(
          await cache.getFileFromCache('https://example.test/one'),
          isNull,
        );
        await cache.putFile(
          'https://example.test/new',
          Uint8List.fromList([9]),
        );
        expect(
          await cache.getFileFromCache('https://example.test/new'),
          isNotNull,
        );
      } finally {
        await cache.dispose();
      }
    },
  );

  test(
    'artwork downloads remain concurrent while migration drains pending writes',
    () async {
      final cache = ArtworkCache(location);
      location.artworkMaintenance = cache.maintain;
      final source = StreamController<List<int>>();
      try {
        final slow = cache.putFileStream(
          'https://example.test/slow',
          source.stream,
        );
        final fast = await cache
            .putFile('https://example.test/fast', Uint8List.fromList([2]))
            .timeout(const Duration(seconds: 5));
        expect(await fast.exists(), true);
        var migrated = false;
        final pending = location
            .change(
              CacheCategory.artwork,
              const CacheSelection(CachePreset.application),
            )
            .then((result) {
              migrated = true;
              return result;
            });
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(migrated, false);
        source.add([1]);
        await source.close();
        await slow;
        expect((await pending).failed, 0);
        expect(
          await cache.getFileFromCache('https://example.test/slow'),
          isNotNull,
        );
      } finally {
        await cache.dispose();
      }
    },
  );
}
