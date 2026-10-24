import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show CacheObject;
import 'package:path/path.dart' as p;

import '../../core/file_digest.dart';
import '../storage_service.dart';
import 'cache_directory_access.dart';

enum CacheCategory { audio, artwork, lyrics }

enum CachePreset { appData, application, custom }

class CacheSelection {
  final CachePreset preset;
  final String customPath;
  const CacheSelection(this.preset, [this.customPath = '']);
  Map<String, String> toJson() => {'preset': preset.name, 'path': customPath};
}

class CacheResult {
  int bytes = 0;
  int files = 0;
  int deferred = 0;
  int failed = 0;
  void add(CacheResult other) {
    bytes += other.bytes;
    files += other.files;
    deferred += other.deferred;
    failed += other.failed;
  }
}

/// Serializes maintenance with disk operations, without locking network waits.
class CacheLock {
  Future<void> _tail = Future.value();
  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}

/// Owns only disposable category directories, never their selected parent.
class CacheLocation extends ChangeNotifier {
  final StorageService storage;
  String _defaultRoot;
  String get defaultRoot => _defaultRoot;
  final String applicationRoot;
  String? _legacyArtworkDirectory;
  String? get legacyArtworkDirectory => _legacyArtworkDirectory;
  final Map<String, String> _platformRootAliases = {};
  final lock = CacheLock();
  final Map<CacheCategory, CacheSelection> _selections = {};
  final Map<CacheCategory, Set<String>> _old = {};
  bool Function(String path)? audioInUse;
  Future<CacheResult> Function(Future<CacheResult> Function())?
  artworkMaintenance;
  Future<void> Function()? prepareLegacyArtwork;
  bool _legacyArtworkPrepared = false;
  Timer? _pendingTimer;
  bool _disposed = false;

  CacheLocation(
    this.storage,
    String defaultRoot, {
    String? applicationRoot,
    String? legacyArtworkDirectory,
  }) : _defaultRoot = defaultRoot,
       _legacyArtworkDirectory = legacyArtworkDirectory,
       applicationRoot =
           applicationRoot ?? File(Platform.resolvedExecutable).parent.path;

  static String folder(CacheCategory category) => switch (category) {
    CacheCategory.audio => 'eme_audio',
    CacheCategory.artwork => 'images',
    CacheCategory.lyrics => 'lyrics_lrc',
  };

  CacheSelection selection(CacheCategory category) =>
      _selections[category] ?? const CacheSelection(CachePreset.appData);
  String rootFor(CacheCategory category) => _root(selection(category));
  String directory(CacheCategory category) =>
      p.join(rootFor(category), folder(category));
  String get audioPath => directory(CacheCategory.audio);
  Directory get lyricsDirectory => Directory(directory(CacheCategory.lyrics));
  Directory get imageDirectory => Directory(directory(CacheCategory.artwork));

  String _root(CacheSelection choice) =>
      _canonicalPlatformPath(switch (choice.preset) {
        CachePreset.appData => defaultRoot,
        CachePreset.application => p.join(applicationRoot, 'FlutifyCache'),
        CachePreset.custom => p.join(
          p.normalize(choice.customPath.trim()),
          'FlutifyCache',
        ),
      });

  Future<void> initialize() async {
    // path_provider can return OS aliases (e.g. Android /data/user/0 or
    // macOS /var). Resolve only the platform-owned roots, before appending
    // owned cache folders. Custom roots and cache children remain link-checked.
    _defaultRoot = await _resolvePlatformRoot(defaultRoot);
    final legacy = legacyArtworkDirectory;
    if (legacy != null) {
      _legacyArtworkDirectory = p.join(
        await _resolvePlatformRoot(p.dirname(legacy)),
        p.basename(legacy),
      );
    }
    try {
      final saved =
          jsonDecode(storage.cacheLocationsJson) as Map<String, dynamic>;
      for (final category in CacheCategory.values) {
        final data = saved[category.name] as Map<String, dynamic>?;
        if (data == null) continue;
        final preset = CachePreset.values.byName(data['preset'] as String);
        final choice = CacheSelection(preset, data['path'] as String? ?? '');
        if (preset == CachePreset.custom && !_valid(choice.customPath))
          continue;
        _selections[category] = choice;
        _old[category] = (data['old'] as List<dynamic>? ?? [])
            .whereType<String>()
            .map(_canonicalPlatformPath)
            .where(
              (path) =>
                  _valid(path) &&
                  (p.basename(path) == folder(category) ||
                      category == CacheCategory.audio &&
                          p.basename(path) == 'audio' ||
                      category == CacheCategory.artwork &&
                          p.equals(path, legacyArtworkDirectory ?? '')),
            )
            .toSet();
      }
    } catch (_) {
      _selections.clear();
      _old.clear();
      final legacy = storage.cacheDirectory ?? storage.audioCacheDirectory;
      if (_valid(legacy)) {
        for (final category in CacheCategory.values) {
          _selections[category] = CacheSelection(CachePreset.custom, legacy);
        }
        _old[CacheCategory.audio] = {
          p.join(legacy, 'FlutifyAudioCache', 'eme_audio'),
        };
      }
    }
    for (final category in CacheCategory.values) {
      final current = directory(category);
      final original = p.join(defaultRoot, folder(category));
      if (!p.equals(current, original)) (_old[category] ??= {}).add(original);
      if (category == CacheCategory.audio) {
        (_old[category] ??= {}).add(p.join(defaultRoot, 'audio'));
      }
      if (category == CacheCategory.artwork && legacyArtworkDirectory != null) {
        (_old[category] ??= {}).add(legacyArtworkDirectory!);
      }
      for (final root in storage.previousCacheRoots) {
        if (_valid(root) &&
            {'FlutifyCache', 'FlutifyAudioCache'}.contains(p.basename(root))) {
          final old = p.join(root, folder(category));
          if (!p.equals(current, old)) (_old[category] ??= {}).add(old);
        }
      }
      try {
        await prepare(current);
      } on FileSystemException {
        (_old[category] ??= {}).add(current);
        _selections.remove(category);
        await prepare(directory(category));
      }
    }
    await _save();
  }

  Future<String> _resolvePlatformRoot(String path) async {
    final directory = await Directory(path).create(recursive: true);
    final canonical = await directory.resolveSymbolicLinks();
    _platformRootAliases[p.normalize(path)] = canonical;
    return canonical;
  }

  String _canonicalPlatformPath(String path) {
    for (final alias in _platformRootAliases.entries) {
      if (p.equals(alias.key, path)) return alias.value;
      if (p.isWithin(alias.key, path)) {
        return p.join(alias.value, p.relative(path, from: alias.key));
      }
    }
    return _normalizeMacOSSystemPath(path);
  }

  static String _normalizeMacOSSystemPath(String path) {
    final normalized = p.normalize(path);
    if (Platform.isMacOS) {
      for (final alias in const ['/var', '/tmp']) {
        if (p.equals(alias, normalized) || p.isWithin(alias, normalized)) {
          return '/private$normalized';
        }
      }
    }
    return normalized;
  }

  static bool _valid(String path) =>
      path.isNotEmpty &&
      p.isAbsolute(path) &&
      !path.contains('\u0000') &&
      !path.startsWith('\\\\') &&
      !path.startsWith('//');

  static Future<void> prepare(String path) async {
    await _checkAncestors(path);
    final dir = await Directory(path).create(recursive: true);
    final probe = await dir.createTemp('.write-check-');
    try {
      await File(p.join(probe.path, 'probe')).writeAsBytes([0], flush: true);
    } finally {
      final file = File(p.join(probe.path, 'probe'));
      if (await file.exists()) await file.delete();
      await probe.delete();
    }
  }

  static Future<void> _checkAncestors(String path) async {
    var ancestor = _normalizeMacOSSystemPath(p.absolute(path));
    while (true) {
      if (await FileSystemEntity.type(ancestor, followLinks: false) ==
          FileSystemEntityType.link) {
        throw FileSystemException(
          'Cache directory cannot contain symbolic links',
          ancestor,
        );
      }
      final parent = p.dirname(ancestor);
      if (parent == ancestor) break;
      ancestor = parent;
    }
  }

  Future<void> _save() async {
    final data = {
      for (final category in CacheCategory.values)
        category.name: {
          ...selection(category).toJson(),
          'old': (_old[category] ?? {}).toList(),
        },
    };
    if (!await storage.setCacheLocationsJson(jsonEncode(data))) {
      throw const FileSystemException('Could not save cache locations');
    }
  }

  Future<CacheResult> change(CacheCategory category, CacheSelection choice) =>
      lock.run(() async {
        if (choice.preset == CachePreset.custom &&
            !_valid(choice.customPath.trim())) {
          throw const FormatException(
            'An absolute local directory is required',
          );
        }
        final target = p.join(_root(choice), folder(category));
        final old = directory(category);
        if (p.isWithin(old, target) || p.isWithin(target, old)) {
          throw const FormatException(
            'Cache directories cannot contain one another',
          );
        }
        await prepare(target);
        if (choice.preset == CachePreset.custom) {
          await CacheDirectoryAccess.remember(choice.customPath.trim());
        }
        if (p.equals(old, target)) return _migrate(category);
        final previous = selection(category);
        final previousOld = {...?_old[category]};
        (_old[category] ??= {}).add(old);
        _old[category]!.removeWhere((path) => p.equals(path, target));
        _selections[category] = choice;
        try {
          await _save();
        } catch (_) {
          _selections[category] = previous;
          _old[category] = previousOld;
          rethrow;
        }
        final result = await _migrate(category);
        notifyListeners();
        return result;
      });

  Future<CacheResult> resumeMigrations() => lock.run(() async {
    final result = CacheResult();
    for (final category in CacheCategory.values) {
      result.add(await _migrate(category));
    }
    return result;
  });

  Future<CacheResult> _migrate(CacheCategory category) async {
    if (category == CacheCategory.artwork && artworkMaintenance != null) {
      return artworkMaintenance!(() => _migrateFiles(category));
    }
    return _migrateFiles(category);
  }

  Future<CacheResult> _migrateFiles(CacheCategory category) async {
    final result = CacheResult();
    final sources = _old[category] ?? {};
    if (sources.isEmpty) return result;
    for (final source in sources.toList()) {
      if (p.equals(source, directory(category))) {
        sources.remove(source);
        continue;
      }
      if (category == CacheCategory.artwork &&
          p.equals(source, legacyArtworkDirectory ?? '') &&
          !_legacyArtworkPrepared &&
          prepareLegacyArtwork != null) {
        try {
          await prepareLegacyArtwork!();
          _legacyArtworkPrepared = true;
        } catch (_) {
          // Keep both the old metadata and image bytes for a later retry.
          result.failed++;
          continue;
        }
      }
      result.add(
        category == CacheCategory.artwork
            ? await transferArtwork(source, directory(category))
            : await transferDirectory(
                source,
                directory(category),
                protected: category == CacheCategory.audio ? audioInUse : null,
              ),
      );
      if (!await Directory(source).exists()) sources.remove(source);
    }
    await _save();
    if (result.deferred > 0) {
      _pendingTimer?.cancel();
      _pendingTimer = Timer(const Duration(seconds: 15), () {
        if (!_disposed)
          unawaited(resumeMigrations().catchError((Object _) => CacheResult()));
      });
    }
    return result;
  }

  Future<CacheResult> clearCategory(CacheCategory category) =>
      lock.run(() async {
        if (category == CacheCategory.artwork && artworkMaintenance != null) {
          return artworkMaintenance!(() => _clearFiles(category));
        }
        return _clearFiles(category);
      });

  Future<CacheResult> _clearFiles(CacheCategory category) async {
    final result = CacheResult();
    for (final path in {directory(category), ...?_old[category]}) {
      result.add(
        await clearDirectory(
          path,
          protected: category == CacheCategory.audio ? audioInUse : null,
        ),
      );
    }
    return result;
  }

  /// Copy, verify, rename, then delete. Different destination files are retained.
  static Future<CacheResult> transferDirectory(
    String source,
    String target, {
    bool Function(String)? protected,
    Set<String> skipNames = const {},
  }) async {
    final result = CacheResult();
    if (p.equals(source, target)) return result;
    try {
      await _checkAncestors(source);
      await prepare(target);
      final dir = Directory(source);
      if (!await dir.exists()) return result;
      await for (final entry in dir.list(followLinks: false)) {
        if (skipNames.contains(p.basename(entry.path))) continue;
        if (entry is! File) {
          result.failed++;
          continue;
        }
        if (protected?.call(entry.path) == true) {
          result.deferred++;
          continue;
        }
        final dest = File(p.join(target, p.basename(entry.path)));
        Directory? temp;
        try {
          final size = await entry.length();
          final digest = await sha256OfFile(entry);
          if (await FileSystemEntity.type(dest.path, followLinks: false) ==
              FileSystemEntityType.link) {
            throw FileSystemException('Destination is a link', dest.path);
          }
          if (await dest.exists()) {
            if (await dest.length() != size ||
                await sha256OfFile(dest) != digest) {
              throw FileSystemException(
                'Destination differs; original retained',
                dest.path,
              );
            }
          } else {
            temp = await Directory(target).createTemp('.migrate-');
            final copy = await entry.copy(p.join(temp.path, 'data'));
            if (await copy.length() != size ||
                await sha256OfFile(copy) != digest) {
              throw FileSystemException(
                'Cache copy verification failed',
                entry.path,
              );
            }
            await copy.rename(dest.path);
          }
          if (protected?.call(entry.path) == true) {
            result.deferred++;
            continue;
          }
          entry.deleteSync();
          result.bytes += size;
          result.files++;
        } on FileSystemException {
          result.failed++;
        } finally {
          if (temp != null) {
            final data = File(p.join(temp.path, 'data'));
            if (await data.exists()) await data.delete();
            await temp.delete();
          }
        }
      }
      if (await dir.list(followLinks: false).isEmpty) await dir.delete();
    } on FileSystemException {
      result.failed++;
    }
    return result;
  }

  /// Preserve URL → filename metadata when switching back to a populated root.
  /// Source metadata remains until the merged destination index is durable, so
  /// an interrupted transfer can finish using files already copied previously.
  static Future<CacheResult> transferArtwork(
    String source,
    String target,
  ) async {
    final result = CacheResult();
    if (p.equals(source, target) || !await Directory(source).exists())
      return result;
    final sourceIndex = File(p.join(source, 'index.json'));
    final targetIndex = File(p.join(target, 'index.json'));
    try {
      await _checkAncestors(sourceIndex.path);
      await _checkAncestors(targetIndex.path);
      final original = await readArtworkIndex(sourceIndex);
      final merged = {
        for (final item in await readArtworkIndex(targetIndex)) item.key: item,
      };
      result.add(
        await transferDirectory(source, target, skipNames: {'index.json'}),
      );
      final retained = <CacheObject>[];
      for (final item in original) {
        final name = item.relativePath;
        if (p.basename(name) != name || name == '.' || name == '..') {
          retained.add(item);
          result.failed++;
          continue;
        }
        if (await File(p.join(source, name)).exists()) {
          retained.add(item);
        } else if (await File(p.join(target, name)).exists()) {
          merged.putIfAbsent(item.key, () => item);
        }
      }
      if (original.isNotEmpty)
        await writeArtworkIndex(targetIndex, merged.values);
      if (await sourceIndex.exists()) {
        if (retained.isEmpty) {
          final bytes = await sourceIndex.length();
          await sourceIndex.delete();
          result.bytes += bytes;
          result.files++;
        } else {
          await writeArtworkIndex(sourceIndex, retained);
        }
      }
      final dir = Directory(source);
      if (await dir.exists() && await dir.list(followLinks: false).isEmpty)
        await dir.delete();
    } catch (_) {
      result.failed++;
    }
    return result;
  }

  static Future<List<CacheObject>> readArtworkIndex(File file) async {
    if (!await file.exists()) return [];
    return (jsonDecode(await file.readAsString()) as List<dynamic>)
        .map((entry) => CacheObject.fromMap(entry as Map<String, dynamic>))
        .toList();
  }

  static Future<void> writeArtworkIndex(
    File file,
    Iterable<CacheObject> items,
  ) async {
    await prepare(file.parent.path);
    var id = 0;
    final data = [
      for (final item in items)
        item.copyWith(id: ++id).toMap(setTouchedToNow: false),
    ];
    final staging = await file.parent.createTemp('.index-');
    try {
      await (await File(
        p.join(staging.path, 'index'),
      ).writeAsString(jsonEncode(data), flush: true)).rename(file.path);
    } finally {
      final temp = File(p.join(staging.path, 'index'));
      if (await temp.exists()) await temp.delete();
      await staging.delete();
    }
  }

  static Future<CacheResult> clearDirectory(
    String path, {
    bool Function(String)? protected,
  }) async {
    final result = CacheResult();
    try {
      await _checkAncestors(path);
      final dir = Directory(path);
      if (!await dir.exists()) return result;
      await for (final file in dir.list(followLinks: false)) {
        if (file is! File) {
          result.failed++;
          continue;
        }
        if (protected?.call(file.path) == true) {
          result.deferred++;
          continue;
        }
        try {
          final size = await file.length();
          if (protected?.call(file.path) == true) {
            result.deferred++;
            continue;
          }
          file.deleteSync();
          result.bytes += size;
          result.files++;
        } on FileSystemException {
          result.failed++;
        }
      }
    } on FileSystemException {
      result.failed++;
    }
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    _pendingTimer?.cancel();
    super.dispose();
  }
}
