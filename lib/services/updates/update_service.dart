import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../core/constants/app_info.dart';
import '../storage_service.dart';
import 'update_downloader.dart';
import 'update_installer.dart';
import 'update_release.dart';

enum UpdateStatus { idle, checking, available, downloading, ready, installing, failed }

class UpdateService extends ChangeNotifier {
  final StorageService storage;
  final UpdateInstaller installer;
  final http.Client client;
  final UpdateDownloader Function() downloaderFactory;
  final String currentTag;
  UpdateMode mode;

  /// 接收哪个通道的更新；默认跟随已安装版本所属的通道。
  UpdateChannel channel;
  UpdateStatus status = UpdateStatus.idle;
  UpdateRelease? release;
  UpdateTarget? target;
  File? package;
  String? checksum;
  String? error;
  bool needsInstallPermission = false;
  int received = 0;
  int total = 0;
  int notification = 0;
  String? _skipped;
  DateTime? _lastCheck;
  Timer? _timer;
  UpdateDownloader? _downloader;
  bool _disposed = false;
  int _generation = 0;
  Future<void>? _restoreFuture;
  String? _notifiedTag;

  UpdateService({
    required this.storage,
    required this.installer,
    http.Client? client,
    UpdateDownloader Function()? downloaderFactory,
    this.currentTag = AppInfo.releaseTag,
  }) : client = client ?? http.Client(),
       downloaderFactory = downloaderFactory ?? UpdateDownloader.new,
       mode = UpdateMode.values.firstWhere((m) => m.name == storage.updateMode, orElse: () => UpdateMode.manual),
       channel = UpdateChannel.values.firstWhere(
         (c) => c.name == storage.updateChannel,
         orElse: () => UpdateVersion.parse(currentTag)?.channel ?? UpdateChannel.release,
       ) {
    _skipped = storage.skippedUpdate;
    _lastCheck = DateTime.tryParse(storage.lastUpdateCheck);
  }

  UpdateVersion get currentVersion => UpdateVersion.parse(currentTag)!;

  /// [version] 是否是当前通道会收到、且比已安装版本新的版本。
  bool _accepts(UpdateVersion version) =>
      version.channel.index <= channel.index && version.isUpgradeFrom(currentVersion);

  /// 切换通道。只影响以后收到哪些版本：已经装上的更高版本不会被换回去（只升不降），
  /// 从自测版切回正式版后，要等正式版的实质版本号超过当前版本才会再收到更新。
  Future<void> setChannel(UpdateChannel value) async {
    if (value == channel) return;
    channel = value;
    await storage.setUpdateChannel(value.name);
    if (_disposed) return;
    final selected = release;
    if (selected != null && !_accepts(selected.version) && status != UpdateStatus.installing) {
      // 已找到 / 已下载的版本不属于新通道：丢掉，不让它被装上
      _generation++;
      _downloader?.cancel();
      release = null;
      package = null;
      checksum = null;
      status = UpdateStatus.idle;
      try {
        final root = await installer.downloadDirectory();
        final state = File(p.join(root.path, 'pending.json'));
        if (await state.exists()) await state.delete();
      } catch (_) {}
      if (_disposed) return;
    }
    _lastCheck = null;
    _notify();
    if (mode != UpdateMode.disabled) unawaited(check());
  }

  bool get busy => const [UpdateStatus.checking, UpdateStatus.downloading, UpdateStatus.installing].contains(status);
  bool get canDownload => release?.assetFor(target ?? const UpdateTarget(UpdatePlatform.unsupported, '')) != null && release?.checksums != null;
  double? get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
  void _notify() { if (!_disposed) notifyListeners(); }

  void start() {
    _timer?.cancel();
    if (mode == UpdateMode.disabled) return;
    unawaited(_start());
    _timer = Timer.periodic(const Duration(hours: 1), (_) => unawaited(check()));
  }

  Future<void> _start() async {
    await (_restoreFuture ??= _restoreReady());
    await check();
  }

  Future<void> _restoreReady() async {
    try {
      final root = await installer.downloadDirectory();
      final state = File(p.join(root.path, 'pending.json'));
      if (!await state.exists()) return;
      final json = jsonDecode(await state.readAsString()) as Map<String, dynamic>;
      final saved = UpdateRelease.fromJson(json['release'] as Map<String, dynamic>);
      final file = File(p.normalize(p.join(root.path, json['file'] as String)));
      final digest = json['checksum'] as String;
      if (saved == null || !_accepts(saved.version) ||
          saved.tag == _skipped || !p.isWithin(root.path, file.path) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) || !await file.exists()) return;
      target ??= await installer.target();
      if (saved.assetFor(target!)?.name != p.basename(file.path)) return;
      if (_disposed || busy || mode == UpdateMode.disabled) return;
      release = saved;
      package = file;
      checksum = digest;
      status = UpdateStatus.ready;
      notification++;
      _notify();
    } catch (_) {
      // Cache eviction or invalid state simply requires another download.
    }
  }

  Future<void> _saveReady(UpdateRelease selected, File file, String digest) async {
    final root = await installer.downloadDirectory();
    final state = File(p.join(root.path, 'pending.json'));
    final temp = File('${state.path}.tmp');
    await temp.writeAsString(jsonEncode({
      'file': p.relative(file.path, from: root.path),
      'checksum': digest,
      'release': {
        'tag_name': selected.tag,
        'body': selected.notes,
        'assets': [for (final a in selected.assets) {
          'name': a.name, 'size': a.size, 'browser_download_url': a.url.toString(),
        }],
      },
    }), flush: true);
    await temp.rename(state.path);
  }

  Future<void> setMode(UpdateMode value) async {
    mode = value;
    await storage.setUpdateMode(value.name);
    if (_disposed) return;
    if (value == UpdateMode.disabled) {
      _generation++;
      _timer?.cancel();
      cancelDownload();
      if (status == UpdateStatus.checking) status = UpdateStatus.idle;
    } else {
      start();
      if (value == UpdateMode.automatic && status == UpdateStatus.available && canDownload) {
        unawaited(download());
      }
    }
    _notify();
  }

  Future<void> skip() async {
    final tag = release?.tag;
    if (tag == null || status == UpdateStatus.installing) return;
    _skipped = tag;
    await storage.setSkippedUpdate(tag);
    cancelDownload();
    release = null;
    final oldPackage = package;
    package = null;
    status = UpdateStatus.idle;
    _notify();
    try {
      final root = await installer.downloadDirectory();
      final state = File(p.join(root.path, 'pending.json'));
      if (await state.exists()) await state.delete();
      if (oldPackage != null && p.isWithin(root.path, oldPackage.path) && await oldPackage.exists()) {
        await oldPackage.delete();
      }
    } catch (_) {}
  }

  Future<void> check({bool manual = false}) async {
    if (_disposed || busy || status == UpdateStatus.ready) return;
    if (!manual && (mode == UpdateMode.disabled ||
        (_lastCheck != null && DateTime.now().difference(_lastCheck!) < const Duration(hours: 6)))) return;
    final generation = _generation;
    status = UpdateStatus.checking;
    error = null;
    _notify();
    try {
      target ??= await installer.target();
      // /latest excludes every beta / self-test release. Sort parsed versions,
      // rather than relying on publication order (old tags can be republished).
      final response = await client.get(Uri.https('api.github.com',
          '/repos/is-hp-is-mad/Flutify/releases', {'per_page': '100'}), headers: {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Flutify-Updater',
      }).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw HttpException('GitHub HTTP ${response.statusCode}');
      final decoded = jsonDecode(response.body);
      if (decoded is! List) throw const FormatException('Invalid releases response');
      final candidates = <UpdateRelease>[
        for (final item in decoded)
          if (item is Map<String, dynamic>)
            if (UpdateRelease.fromJson(item) case final r?)
              if (_accepts(r.version)) r,
      ]..sort((a, b) {
        // 实质版本号最高的优先；旧标签（没有实质版本号）之间按版本比较
        final byBuild = b.version.build.compareTo(a.version.build);
        return byBuild != 0 ? byBuild : b.version.compareTo(a.version);
      });
      if (_disposed || generation != _generation) return;
      _lastCheck = DateTime.now();
      await storage.setLastUpdateCheck(_lastCheck!.toIso8601String());
      if (_disposed || generation != _generation) return;
      final latest = candidates.firstOrNull;
      release = latest != null && (manual || latest.tag != _skipped) ? latest : null;
      status = release == null ? UpdateStatus.idle : UpdateStatus.available;
      if (release != null && !manual && _notifiedTag != release!.tag) {
        _notifiedTag = release!.tag;
        notification++;
      }
      _notify();
      if (release != null && mode == UpdateMode.automatic && canDownload) await download();
    } catch (e) {
      if (_disposed || generation != _generation) return;
      status = UpdateStatus.failed;
      error = e.toString();
      _notify();
    }
  }

  Future<void> download() async {
    if (busy || status == UpdateStatus.ready || !canDownload || _disposed) return;
    final selected = release!;
    final asset = selected.assetFor(target!)!;
    final generation = ++_generation;
    status = UpdateStatus.downloading;
    error = null;
    received = 0;
    total = asset.size;
    final downloader = downloaderFactory();
    _downloader = downloader;
    _notify();
    try {
      final sums = await client.get(selected.checksums!.url).timeout(const Duration(seconds: 30));
      if (sums.statusCode != 200 || sums.bodyBytes.length > 1024 * 1024) {
        throw const FormatException('Missing update checksums');
      }
      final matches = RegExp(r'^([a-fA-F0-9]{64}) [ *](.+)$', multiLine: true)
          .allMatches(sums.body.replaceAll('\r', ''))
          .where((m) => m[2] == asset.name).toList();
      if (matches.length != 1) throw const FormatException('Missing or duplicate update checksum');
      final digest = matches.single[1]!.toLowerCase();
      if (_disposed || generation != _generation) return;
      final root = await installer.downloadDirectory();
      await root.create(recursive: true);
      final directory = await root.createTemp('download-');
      final file = File(p.join(directory.path, asset.name));
      var lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
      await downloader.download(url: asset.url, size: asset.size, sha256Hex: digest, destination: file,
        onProgress: (bytes, size) {
          if (_disposed || generation != _generation) return;
          received = bytes;
          total = size;
          if (DateTime.now().difference(lastNotify).inMilliseconds >= 100) {
            lastNotify = DateTime.now();
            _notify();
          }
        });
      if (_disposed || generation != _generation) {
        if (await file.exists()) await file.delete();
        return;
      }
      await _saveReady(selected, file, digest);
      if (_disposed || generation != _generation) return;
      package = file;
      checksum = digest;
      status = UpdateStatus.ready;
      notification++;
      _notify();
    } on UpdateCancelled {
      // Cancellation changes the state synchronously in cancelDownload().
    } catch (e) {
      if (_disposed || generation != _generation) return;
      status = UpdateStatus.failed;
      error = e.toString();
      _notify();
    } finally {
      if (identical(_downloader, downloader)) _downloader = null;
    }
  }

  void cancelDownload() {
    if (status != UpdateStatus.downloading) return;
    _generation++;
    _downloader?.cancel();
    status = release == null ? UpdateStatus.idle : UpdateStatus.available;
    _notify();
  }

  Future<void> install() async {
    if (package == null || checksum == null || status != UpdateStatus.ready) return;
    status = UpdateStatus.installing;
    error = null;
    needsInstallPermission = false;
    _notify();
    try {
      final opened = await installer.install(package!, checksum!);
      needsInstallPermission = !opened;
      // Keep APK ready if the user cancels the system installer or grants permission.
      status = UpdateStatus.ready;
    } catch (e) {
      status = UpdateStatus.ready;
      error = e.toString();
      debugPrint('[Updates] Installation failed: $e');
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _downloader?.cancel();
    client.close();
    super.dispose();
  }
}
