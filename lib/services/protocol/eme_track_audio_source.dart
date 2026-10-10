import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import '../../models/audio_playback_info.dart';

import '../audio/audio_engine.dart';
import '../auth/auth_constants.dart';
import '../cache/cache_location.dart';
import '../eme/fairplay.dart';
import '../eme/segmented_download.dart';
import '../eme/streaming_download.dart';
import 'audio_cache_store.dart';
import 'spotify_id.dart';
import 'storage_resolver.dart';
import 'track_audio_loader.dart';
import 'track_metadata.dart';
import 'track_playback_media.dart';
import 'http_range_audio.dart';

/// 流式下载句柄：[readyForPlayback] 在可起播字节数就绪时完成。
class _StreamingDownloadHandle {
  final Completer<void> _ready = Completer<void>();
  Future<void> get readyForPlayback => _ready.future;
  final Completer<void> _done = Completer<void>();
  Future<void> get done => _done.future;

  _StreamingDownloadHandle() {
    // 可能在可起播之前失败，此时还没有 LoadedAudio 的消费者监听完成信号。
    done.ignore();
  }
}

/// EME（Widevine）曲目音频来源：track-playback 取 MP4 → sneaktables 取 HLS 清单 →
/// storage-resolve 下载加密 m4a → 交给 EME 引擎（WebView2）解密播放。
///
/// 与 [TrackAudioLoader]（OGG/AP 链路）互补：那条路密钥被拒的 DRM 曲目走这里。
/// 产物（加密 m4a + 清单）缓存在 [cacheDirectory]/eme_audio，同一 file_id 复用。
class EmeTrackAudioSource implements TrackAudioSource, AudioCacheStore {
  final Future<String> Function() accessToken;
  final Future<String> Function()? clientToken;
  final String _cacheDirectory;
  final String Function()? cacheDirectoryProvider;
  final String? Function()? playingPath;
  final Set<String> _loadingPaths = {};
  final Map<String, DateTime> _recentPaths = {};
  final CacheLock _cacheLock;
  Timer? _trimTimer;
  Future<void>? _trimming;
  bool _trimRequested = false;
  bool _disposed = false;

  /// 仅保留下一首的已解析音源，切歌不再重复请求 track-playback / HLS。
  LoadedAudio? _prefetchedAudio;
  int _prefetchGeneration = 0;

  bool isCacheFileInUse(String path) {
    final audio = path.endsWith('.done')
        ? path.substring(0, path.length - 5)
        : path.endsWith('.part')
        ? path.substring(0, path.length - 5)
        : path;
    final current = playingPath?.call();
    _recentPaths.removeWhere((_, until) => until.isBefore(DateTime.now()));
    return (current != null && p.equals(audio, current)) ||
        (_prefetchedAudio != null && p.equals(audio, _prefetchedAudio!.path)) ||
        _loadingPaths.contains(audio) ||
        _recentPaths.containsKey(audio) ||
        StreamingDownloads.of(audio) != null;
  }

  String get cacheDirectory =>
      cacheDirectoryProvider?.call() ?? _cacheDirectory;
  final http.Client _client;

  /// Web 登录态（sp_dc）是否就绪；为 null 时不检查。
  /// EME 链路的 Widevine 真密钥依赖 Web token（sp_dc 铸造），缺 sp_dc 时
  /// 下载完整首也只会在 license 步骤失败，因此在下载前提前拦截。
  final bool Function()? webSessionReady;

  int _maxCacheBytes = 512 * 1024 * 1024;

  /// 进行中的加载（按曲目合并）。
  final Map<String, Future<LoadedAudio>> _inFlight = {};

  EmeTrackAudioSource({
    required this.accessToken,
    this.clientToken,
    required String cacheDirectory,
    this.cacheDirectoryProvider,
    this.playingPath,
    CacheLock? cacheLock,
    this.webSessionReady,
    http.Client? client,
  }) : _cacheDirectory = cacheDirectory,
       _cacheLock = cacheLock ?? CacheLock(),
       _client = client ?? http.Client();

  Future<Map<String, String>> _headers() async {
    final token = await accessToken();
    final h = <String, String>{
      'Authorization': 'Bearer $token',
      // 桌面端身份（track-playback / sneaktables 用这个）
      'User-Agent': SpotifyAuthConstants.desktopUserAgent,
      'app-platform': SpotifyAuthConstants.desktopPlatform,
      'spotify-app-version': SpotifyAuthConstants.desktopVersion,
    };
    if (clientToken != null) h['client-token'] = await clientToken!();
    return h;
  }

  Directory get _dir =>
      Directory('$cacheDirectory${Platform.pathSeparator}eme_audio');

  File _cacheFile(String fileIdHex) =>
      File('${_dir.path}${Platform.pathSeparator}$fileIdHex.m4a');

  @override
  Future<LoadedAudio> open(
    String trackIdOrUri, {
    void Function(double progress)? progress,
  }) => _loadUri(trackIdOrUri, progress, streaming: true);

  @override
  Future<LoadedAudio> load(
    String trackIdOrUri, {
    void Function(double progress)? progress,
  }) async {
    final audio = await _loadUri(trackIdOrUri, progress, streaming: false);
    await audio.downloadComplete;
    return audio;
  }

  Future<LoadedAudio> _loadUri(
    String trackIdOrUri,
    void Function(double)? progress, {
    required bool streaming,
  }) {
    final id = SpotifyId.fromUri(trackIdOrUri);
    final episode =
        trackIdOrUri.startsWith('spotify:episode:') ||
        trackIdOrUri.contains('/episode/');
    // 复用预取 / 进行中的下载前，仍检查已有的 Web 登录前提。
    if (!episode && webSessionReady?.call() == false) {
      return Future.error(
        const TrackPlaybackException(
          TrackPlaybackFailure.webSignInRequired,
          '全曲播放需要先完成 Web 登录',
        ),
      );
    }
    final key =
        '${_dir.path}:eme:${episode ? 'episode' : 'track'}:${id.toBase62()}:${episode && streaming}';
    final prepared = _prefetchedAudio;
    if (!episode && prepared?.trackId == id.toBase62()) {
      final download = StreamingDownloads.of(prepared!.path);
      if (p.equals(p.dirname(prepared.path), _dir.path) &&
          prepared.file.existsSync() &&
          prepared.file.lengthSync() > 0 &&
          ((download != null && download.error == null) ||
              File('${prepared.path}.done').existsSync())) {
        progress?.call(1);
        return Future.value(prepared);
      }
      _prefetchedAudio = null;
    }
    return _inFlight.putIfAbsent(key, () async {
      LoadedAudio? audio;
      try {
        audio = await _load(
          id,
          progress,
          episode: episode,
          streaming: streaming,
        );
        // 首段就绪不代表下载结束：继续合并点播与预取，避免重开并截断同一文件。
        audio.downloadComplete?.then<void>(
          (_) {
            _inFlight.remove(key);
          },
          onError: (Object _) {
            _inFlight.remove(key);
          },
        );
        return audio;
      } finally {
        if (audio?.downloadComplete == null) _inFlight.remove(key);
      }
    });
  }

  Future<LoadedAudio> _load(
    SpotifyId id,
    void Function(double progress)? progress, {
    required bool episode,
    required bool streaming,
  }) async {
    debugPrint('[eme-src] 开始加载 ${id.toBase62()}');
    // 1) track-playback 取 MP4 文件清单
    progress?.call(0.05);
    final TrackPlaybackMedia media;
    try {
      media = await fetchTrackPlaybackMedia(
        'spotify:${episode ? 'episode' : 'track'}:${id.toBase62()}',
        headers: _headers,
        client: _client,
      );
      debugPrint(
        '[eme-src] track-playback OK，MP4 文件 ${media.mp4Files.length} 个',
      );
    } catch (e) {
      debugPrint('[eme-src] track-playback 失败: $e');
      throw TrackPlaybackException(
        TrackPlaybackFailure.network,
        '获取曲目播放信息失败',
        e,
      );
    }
    if (episode && media.externalUrls.isNotEmpty) {
      Object? lastError;
      for (final url in media.externalUrls) {
        try {
          final audio = await HttpRangeAudio.open(_client, url);
          final dest = File(
            '${_dir.path}${Platform.pathSeparator}episode-${id.toBase62()}.mp3',
          );
          if (!streaming) {
            _loadingPaths.add(dest.path);
            final part = File('${dest.path}.part');
            try {
              await dest.parent.create(recursive: true);
              if (!dest.existsSync() || dest.lengthSync() != audio.length) {
                final sink = part.openWrite();
                try {
                  await sink.addStream(audio.read(0));
                } finally {
                  await sink.close();
                }
                if (dest.existsSync()) dest.deleteSync();
                await part.rename(dest.path);
              }
              await dest.setLastModified(DateTime.now());
              _recentPaths[dest.path] = DateTime.now().add(
                const Duration(minutes: 2),
              );
            } finally {
              if (part.existsSync()) part.deleteSync();
              _loadingPaths.remove(dest.path);
              unawaited(trimCache());
            }
          }
          progress?.call(1);
          return LoadedAudio(
            file: dest,
            playbackInfo: const AudioPlaybackInfo(format: 'file_urls_external'),
            source: TrackAudioFile(
              fileId: Uint8List(0),
              format: AudioFileFormat.mp3_160,
            ),
            durationMs: media.durationMs,
            trackId: id.toBase62(),
            stream: streaming ? audio : null,
          );
        } catch (error) {
          lastError = error;
        }
      }
      if (media.mp4Files.isEmpty)
        throw TrackPlaybackException(
          TrackPlaybackFailure.network,
          '播客音频加载失败',
          lastError,
        );
    }
    if (episode && webSessionReady?.call() == false) {
      throw const TrackPlaybackException(
        TrackPlaybackFailure.webSignInRequired,
        '此播客需要先完成 Web 登录',
      );
    }
    final file = useFairPlay
        ? media.selectCbcsForFairPlay()
        : media.selectForFree();
    if (file == null) {
      throw TrackPlaybackException(
        TrackPlaybackFailure.unavailable,
        episode ? '这集播客没有可用的音频文件' : '这首歌没有可用的 DRM 音频文件',
      );
    }
    debugPrint(
      '[eme-src] 选定 file_id=${file.fileIdHex.substring(0, 16)}… br=${file.bitrate} group=${file.formatKey}',
    );

    // 2) sneaktables 取 HLS 清单，同时 storage-resolve 取 CDN 地址（两者互不依赖，并行省一个往返）
    progress?.call(0.15);
    final dest = _cacheFile(file.fileIdHex);
    _loadingPaths.add(dest.path);
    var handedOff = false;
    try {
      final doneMarker = File('${dest.path}.done');
      final complete =
          dest.existsSync() && doneMarker.existsSync() && dest.lengthSync() > 0;
      final cdnUrls = complete
          ? null
          : resolveAudioStorage(
              fileIdHex: file.fileIdHex,
              headers: _headers,
              client: _client,
            ).then((r) => r.cdnUrls);
      cdnUrls?.ignore(); // 清单失败时没人等它，避免未处理异常
      final String m3u8;
      try {
        m3u8 = await fetchHlsManifest(
          file.fileIdHex,
          headers: _headers,
          client: _client,
        );
        debugPrint('[eme-src] HLS 清单 OK（${m3u8.length} 字符）');
      } catch (e) {
        debugPrint('[eme-src] HLS 清单失败: $e');
        throw TrackPlaybackException(
          TrackPlaybackFailure.network,
          '获取播放清单失败',
          e,
        );
      }

      // 3) 下载加密 m4a：完整缓存命中直接用；否则后台下载、init 段就绪即返回（流式起播）
      Future<void>? downloadComplete;
      if (cdnUrls != null) {
        progress?.call(0.25);
        // 后台下载；init 段 + 首段就绪即返回，剩余边下边播
        final dl = _startStreamingDownload(cdnUrls, dest, doneMarker, progress);
        downloadComplete = dl.done;
        await dl.readyForPlayback; // 等到可起播的字节数
        debugPrint('[eme-src] init 段就绪，流式起播（后台继续下载）');
      } else {
        debugPrint('[eme-src] 缓存命中 ${dest.path}');
        // 修改时间记录最近播放，而不是最初下载，供 LRU 淘汰使用。
        try {
          await dest.setLastModified(DateTime.now());
        } catch (_) {}
      }
      progress?.call(1.0);

      handedOff = true;
      return LoadedAudio(
        playbackInfo: AudioPlaybackInfo(
          bitrate: file.bitrate > 0 ? file.bitrate : null,
          format: file.format > 0 ? file.format : null,
        ),
        file: dest,
        source: TrackAudioFile(
          fileId: _hexToBytes(file.fileIdHex),
          format: AudioFileFormat.aac48,
        ),
        durationMs: media.durationMs > 0 ? media.durationMs : null,
        trackId: id.toBase62(),
        downloadComplete: downloadComplete,
        emeContent: EmeTrackContent(
          m4aPath: dest.path,
          m3u8: m3u8,
          fileIdHex: file.fileIdHex,
        ),
      );
    } finally {
      _loadingPaths.remove(dest.path);
      // Covers the handoff between loader completion and engine adoption.
      if (handedOff)
        _recentPaths[dest.path] = DateTime.now().add(
          const Duration(minutes: 2),
        );
      unawaited(trimCache());
    }
  }

  /// 启动流式下载：后台顺序写入 [dest]，init 段 + 首段就绪后 [readyForPlayback] 完成。
  /// 进度登记到 [StreamingDownloads]，供 EME 播放器的本地服务按区间等待。
  _StreamingDownloadHandle _startStreamingDownload(
    Future<List<String>> cdnUrls,
    File dest,
    File doneMarker,
    void Function(double)? progress,
  ) {
    final handle = _StreamingDownloadHandle();
    final registration = StreamingDownloads.begin(dest.path);
    () async {
      try {
        final urls = await cdnUrls;
        debugPrint('[eme-src] storage-resolve 得 ${urls.length} 个 CDN');
        if (urls.isEmpty) throw StateError('无可用 CDN');
        // 多连接分段：按偏移顺序分配，从头连续可用的字节增长最快；报告语义与顺序下载一致
        await SegmentedDownload(
          client: _client,
          urls: urls,
          dest: dest,
          headers: const {
            'User-Agent': SpotifyAuthConstants.desktopUserAgent,
          },
          // 首段小一点：起播只需 init 段 + 首个媒体段
          segmentBytes: _kMinBytesToPlay,
          connections: 2,
          onContiguous: (got, total) {
            registration.expectedTotal = total;
            registration.report(got);
            if (!handle._ready.isCompleted && got >= _kMinBytesToPlay) {
              handle._ready.complete();
            }
            if (total > 0) progress?.call(0.25 + 0.75 * got / total);
            _scheduleTrim(const Duration(seconds: 1));
          },
        ).run();
        // 完成：写 .done 标记
        await doneMarker.writeAsString('${dest.lengthSync()}');
        if (!handle._ready.isCompleted) handle._ready.complete();
        registration.finish();
        handle._done.complete();
        debugPrint('[eme-src] 下载完成 ${dest.lengthSync()}B');
      } catch (e) {
        debugPrint('[eme-src] 流式下载失败: $e');
        registration.finish(e);
        handle._done.completeError(e);
        if (!handle._ready.isCompleted) {
          handle._ready.completeError(
            TrackPlaybackException(
              TrackPlaybackFailure.network,
              '音频下载失败，请检查网络后重试',
              e,
            ),
          );
        }
      } finally {
        StreamingDownloads.end(dest.path);
        unawaited(trimCache());
      }
    }();
    return handle;
  }

  /// 起播所需的最少字节（init 段 1338B + 首个媒体段）。HLS.js 按 BYTERANGE 顺序取段，
  /// 这个量足够它解出 init 并开始第一段的解密播放。
  static const int _kMinBytesToPlay = 256 * 1024;

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  @override
  Future<void> prefetch(String trackIdOrUri) async {
    // Long episodes are read on demand; do not download the next whole episode.
    if (_disposed ||
        trackIdOrUri.contains(':episode:') ||
        trackIdOrUri.contains('/episode/')) {
      return;
    }
    final generation = ++_prefetchGeneration;
    try {
      final audio = await open(trackIdOrUri);
      if (!_disposed && generation == _prefetchGeneration) {
        _prefetchedAudio = audio;
      }
      await audio.downloadComplete;
    } catch (_) {
      if (generation == _prefetchGeneration) _prefetchedAudio = null;
    }
  }

  // ---------------------------------------------------------------------------
  // AudioCacheStore（设置页「存储」分组）
  // ---------------------------------------------------------------------------

  @override
  int get maxCacheBytes => _maxCacheBytes;

  @override
  set maxCacheBytes(int value) {
    _maxCacheBytes = value < 0 ? 0 : value;
    unawaited(trimCache());
  }

  List<File> _files() {
    final dir = _dir;
    if (!dir.existsSync()) return const [];
    return dir.listSync(followLinks: false).whereType<File>().toList();
  }

  @override
  Future<int> sizeBytes() async {
    await trimCache();
    try {
      var total = 0;
      await for (final e in _dir.list(followLinks: false)) {
        if (e is File) total += await e.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<int> clear() async {
    var freed = 0;
    try {
      for (final f in _files()) {
        if (isCacheFileInUse(f.path)) continue;
        try {
          final size = f.lengthSync();
          f.deleteSync();
          freed += size;
        } catch (_) {}
      }
    } catch (_) {}
    return freed;
  }

  void _scheduleTrim(Duration delay) {
    if (_disposed || _trimTimer != null) return;
    _trimTimer = Timer(delay, () {
      _trimTimer = null;
      unawaited(trimCache());
    });
  }

  /// 下载、缓存命中、启动与修改上限都会触发；占用导致暂时超额时继续重试。
  Future<void> trimCache() {
    if (_disposed) return Future.value();
    _trimRequested = true;
    return _trimming ??= _cacheLock
        .run(() async {
          do {
            _trimRequested = false;
            var total = 0;
            try {
              final files = <({File file, int size, DateTime used})>[];
              if (!await _dir.exists()) return;
              await for (final entry in _dir.list(followLinks: false)) {
                if (entry is! File) continue;
                try {
                  final stat = await entry.stat();
                  total += stat.size;
                  files.add((
                    file: entry,
                    size: stat.size,
                    used: stat.modified,
                  ));
                } catch (_) {}
              }
              files.sort((a, b) => a.used.compareTo(b.used));
              for (final item in files) {
                if (total <= _maxCacheBytes) break;
                if (isCacheFileInUse(item.file.path)) continue;
                try {
                  // Do not yield between the in-use check and unlink: a loader may
                  // otherwise adopt this path while the async delete is pending.
                  item.file.deleteSync();
                  total -= item.size;
                } catch (_) {}
              }
            } catch (error) {
              debugPrint('[eme-src] 缓存淘汰失败: $error');
            } finally {
              if (total > _maxCacheBytes)
                _scheduleTrim(const Duration(seconds: 15));
            }
          } while (_trimRequested && !_disposed);
        })
        .whenComplete(() {
          _trimming = null;
        });
  }

  void dispose() {
    _disposed = true;
    ++_prefetchGeneration;
    _prefetchedAudio = null;
    _trimTimer?.cancel();
    _client.close();
  }
}
