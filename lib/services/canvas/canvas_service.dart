import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/rust_core.dart';
import '../../src/rust/api/backend.dart' as rust;
import '../pathfinder/pathfinder_client.dart';
import '../pathfinder/pathfinder_operations.dart';
import '../rust_backend_bridge.dart';

class SpotifyCanvas {
  final Uri url;
  final bool isVideo;
  const SpotifyCanvas(this.url, {required this.isVideo});

  static SpotifyCanvas? fromData(Map<String, dynamic> data) {
    final track = data['trackUnion'];
    if (track is! Map || track['__typename'] != 'Track') return null;
    final canvas = track['canvas'];
    if (canvas is! Map) return null;
    final url = Uri.tryParse(canvas['url'] as String? ?? '');
    if (url == null || url.scheme != 'https' || url.host.isEmpty) return null;
    final type = canvas['type'];
    if (![
      'VIDEO',
      'VIDEO_LOOPING',
      'VIDEO_LOOPING_RANDOM',
      'IMAGE',
      'GIF',
    ].contains(type))
      return null;
    return SpotifyCanvas(url, isVideo: type != 'IMAGE' && type != 'GIF');
  }
}

class CanvasMedia {
  final SpotifyCanvas canvas;
  final Uint8List bytes;
  const CanvasMedia(this.canvas, this.bytes);
}

/// Official Pathfinder Canvas metadata. Media bytes use the app's HTTP routing,
/// keeping WebView requests independent of platform proxy configuration.
class CanvasService {
  final http.Client client;
  final PathfinderClient pathfinder;
  final Map<String, ({DateTime until, CanvasMedia? media})> _cache = {};
  final Map<String, Future<CanvasMedia?>> _pending = {};
  CanvasService(
    this.client, {
    required Future<Map<String, String>> Function() headers,
  }) : pathfinder = PathfinderClient(client, headers: headers);

  Future<CanvasMedia?> get(String uri) async {
    if (!RegExp(r'^spotify:track:[a-zA-Z0-9]{22}$').hasMatch(uri)) return null;
    final cached = _cache[uri];
    if (cached != null && cached.until.isAfter(DateTime.now()))
      return cached.media;
    return _pending.putIfAbsent(uri, () async {
      CanvasMedia? media;
      try {
        if (RustCore.ready) {
          final proxy = await RustBackendBridge.proxyForUrl(
            'https://api-partner.spotify.com/pathfinder/v2/query',
          );
          if (proxy != null) {
            try {
              final dto = await rust.rustFetchCanvas(
                hash: PathfinderOperation.canvas.sha256Hash,
                trackUri: uri,
                proxy: proxy,
              );
              if (dto != null) {
                final parsed = Uri.tryParse(dto.url);
                if (parsed != null) {
                  media = CanvasMedia(
                    SpotifyCanvas(parsed, isVideo: dto.isVideo),
                    dto.bytes,
                  );
                }
              }
            } catch (_) {}
          }
        }
        if (media == null) {
          final data = await pathfinder
              .query(PathfinderOperation.canvas, {'trackUri': uri})
              .timeout(const Duration(seconds: 12));
          final canvas = SpotifyCanvas.fromData(data);
          if (canvas != null) {
            final response = await client
                .send(http.Request('GET', canvas.url))
                .timeout(const Duration(seconds: 12));
            if (response.statusCode != 200) {
              await response.stream.listen(null).cancel();
              throw StateError('Canvas HTTP ${response.statusCode}');
            }
            const limit = 12 * 1024 * 1024;
            if ((response.contentLength ?? 0) > limit) {
              await response.stream.listen(null).cancel();
              throw StateError('Canvas exceeds size limit');
            }
            final bytes = BytesBuilder(copy: false);
            await for (final chunk in response.stream.timeout(
              const Duration(seconds: 12),
            )) {
              if (bytes.length + chunk.length > limit)
                throw StateError('Canvas exceeds size limit');
              bytes.add(chunk);
            }
            if (bytes.isNotEmpty) media = CanvasMedia(canvas, bytes.takeBytes());
          }
        }
      } catch (_) {
        // Canvas is optional: a failed request must not affect audio playback.
      } finally {
        _pending.remove(uri);
      }
      if (_cache.length >= 3) _cache.remove(_cache.keys.first);
      _cache[uri] = (
        until: DateTime.now().add(Duration(minutes: media == null ? 1 : 10)),
        media: media,
      );
      return media;
    });
  }
}
