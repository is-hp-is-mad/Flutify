import 'dart:convert';

import 'package:http/http.dart' as http;

/// `track-playback/v1/media` 返回的一个音频文件（file_id + 格式 + 码率）。
class PlaybackFile {
  final String fileIdHex;
  final int format;
  final int bitrate;

  /// 该条目出自的 manifest 分组（`file_ids_mp4` / `file_ids_mp4_cbcs`）。
  /// macOS FairPlay 只认 cbcs 分组的加密形态（schm=cbcs）。
  final String formatKey;

  /// cbcs 分组的 audio 记录可能携带 `encoding_id`（FairPlay 的 assetId）。
  final String? encodingId;

  const PlaybackFile({
    required this.fileIdHex,
    required this.format,
    required this.bitrate,
    this.formatKey = '',
    this.encodingId,
  });
}

/// 曲目播放媒体信息（名称 / 时长 / 可选 MP4 文件列表）。
class TrackPlaybackMedia {
  final String name;
  final int durationMs;
  final List<PlaybackFile> mp4Files;
  final List<String> externalUrls;

  const TrackPlaybackMedia({
    required this.name,
    required this.durationMs,
    required this.mp4Files,
    this.externalUrls = const [],
  });

  /// 是否有 MP4 文件（不表示所有 DRM 后端都支持其加密格式）。
  bool get hasMp4 => mp4Files.isNotEmpty;

  /// Widevine 路径只选 CENC 分组中的最低码率。
  /// CBCS 即使码率更低或排列在前，也不能交给仅支持 CENC 的原生后端。
  PlaybackFile? selectForFree() {
    final sorted = mp4Files
        .where((f) => f.formatKey == 'file_ids_mp4')
        .toList()
      ..sort((a, b) => a.bitrate.compareTo(b.bitrate));
    return sorted.isEmpty ? null : sorted.first;
  }

  /// 选 FairPlay 用的 cbcs 文件：只从 `file_ids_mp4_cbcs` 分组取、取最低码率；
  /// 无 cbcs 条目返回 null（该曲目对 macOS 解密不可用，调用方报「不可用」）。
  /// 对齐 Spotify Web 播放器的行为：keySystem 为 FairPlay 时只向 manifest 请求
  /// file_ids_mp4_cbcs（见 vendor 播放器 FILE_IDS_CBCS 分支）。
  PlaybackFile? selectCbcsForFairPlay() {
    final cbcs = mp4Files
        .where((f) => f.formatKey == 'file_ids_mp4_cbcs')
        .toList();
    if (cbcs.isEmpty) return null;
    cbcs.sort((a, b) => a.bitrate.compareTo(b.bitrate));
    return cbcs.first;
  }
}

/// 宽松转 int（服务端有时把 format/bitrate 给成字符串）。
int _toInt(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

/// 取出可播放的 item。出口地区和曲目原编号不一致时，Spotify 会把同一首歌
/// 放在另一个 `spotify:track:` 键下，原编号在 `media` 里不出现。
Map<String, dynamic>? _mediaItem(Object? media, String uri) {
  if (media is! Map) return null;
  Map<String, dynamic>? itemOf(Object? entry) {
    if (entry is! Map) return null;
    final item = entry['item'];
    if (item is Map<String, dynamic>) return item;
    if (item is Map) return Map<String, dynamic>.from(item);
    return null;
  }

  final direct = itemOf(media[uri]);
  if (direct != null) return direct;
  for (final entry in media.values) {
    final item = itemOf(entry);
    if (item != null) return item;
  }
  return null;
}

/// 拉取 `track-playback/v1/media`（桌面端身份），取 CENC MP4 文件列表。
///
/// 这是 Widevine/EME 链路的文件清单来源（与 metadata.proto 的 OGG/MP3 列表不同）。
Future<TrackPlaybackMedia> fetchTrackPlaybackMedia(
  String trackIdOrUri, {
  required Future<Map<String, String>> Function() headers,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final id = trackIdOrUri.split(':').last.split('?').first.split('/').last;
    final isEpisode =
        trackIdOrUri.startsWith('spotify:episode:') ||
        trackIdOrUri.contains('/episode/');
    final uri = 'spotify:${isEpisode ? 'episode' : 'track'}:$id';
    final url = Uri.parse(
      'https://spclient.wg.spotify.com/track-playback/v1/media/$uri'
      '?manifestFileFormat=file_ids_mp4&manifestFileFormat=file_ids_mp4_cbcs'
      '${isEpisode ? '&manifestFileFormat=file_urls_external&manifestFileFormat=file_urls_mp3' : ''}',
    );
    final h = await headers();
    final res = await c.get(url, headers: {...h, 'Accept': 'application/json'});
    if (res.statusCode != 200) {
      throw StateError('track-playback 失败：HTTP ${res.statusCode}');
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final item = _mediaItem(body['media'], uri);
    if (item == null) throw StateError('track-playback 响应缺 item');
    final metadata = item['metadata'] as Map<String, dynamic>? ?? {};
    final manifest = item['manifest'] as Map<String, dynamic>? ?? {};

    final files = <PlaybackFile>[];
    final externalUrls = <String>[];
    for (final entry in manifest.entries) {
      if (entry.key == 'file_urls_external' || entry.key == 'file_urls_mp3') {
        for (final file in entry.value as List? ?? []) {
          final url = file is Map ? file['file_url'] : null;
          final parsed = url is String ? Uri.tryParse(url) : null;
          if (parsed?.scheme == 'https' && parsed!.host.isNotEmpty)
            externalUrls.add(url as String);
        }
      }
      if (!entry.key.startsWith('file_ids_mp4')) continue;
      for (final f in (entry.value as List? ?? [])) {
        final m = f as Map<String, dynamic>;
        // 非字符串的 file_id 无法当十六进制 id 用：跳过这一项，不让整首歌解析失败
        final fid = m['file_id'];
        if (fid is! String) continue;
        files.add(
          PlaybackFile(
            fileIdHex: fid,
            format: _toInt(m['format']),
            bitrate: _toInt(m['bitrate']),
            formatKey: entry.key,
            encodingId: m['encoding_id']?.toString(),
          ),
        );
      }
    }
    return TrackPlaybackMedia(
      name: metadata['name'] as String? ?? '',
      durationMs: _toInt(metadata['duration']),
      mp4Files: files,
      externalUrls: externalUrls,
    );
  } finally {
    if (client == null) c.close();
  }
}

/// 拉取 sneaktables policy=1 的 HLS 清单（含 EXT-X-KEY 的 PSSH + EXT-X-MAP/BYTERANGE）。
///
/// 该清单是 EME 的 initData（PSSH）来源，也是 HLS.js 喂段的结构依据。
Future<String> fetchHlsManifest(
  String fileIdHex, {
  required Future<Map<String, String>> Function() headers,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final url = Uri.parse(
      'https://spclient.wg.spotify.com/sneaktables/v2/hls/1/$fileIdHex/audio.m3u8',
    );
    final h = await headers();
    final res = await c.get(
      url,
      headers: {...h, 'Accept': 'application/vnd.apple.mpegurl'},
    );
    if (res.statusCode != 200) {
      throw StateError('sneaktables HLS 清单失败：HTTP ${res.statusCode}');
    }
    return res.body;
  } finally {
    if (client == null) c.close();
  }
}
