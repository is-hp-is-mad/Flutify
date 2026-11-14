// 开发工具：用 App 已保存的桌面版会话探测 Pathfinder / spclient 接口，记录入参是否被接受与响应结构。
//
// 用途：逆向新的 persisted query 时确认入参与响应结构（需本机已登录桌面版会话）。
// 用法（在 app 目录）：dart run tool/pathfinder_probe.dart [操作名 ...]
// 响应完整写入 tool/probe_out/<操作名>.json（已 gitignore，含账号数据）；终端只打印状态码与字段结构，
// 不打印任何令牌。
import 'dart:convert';
import 'dart:io';

// 业务请求统一用 Web 播放器身份（见 lib/services/auth/client_profile.dart）
const _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36';
const _appVersion = '1.3.8.509.g26b6eac7300d';

// 探测用样本实体
const _album = 'spotify:album:4yP0hdKOZPNshxUOjY0cZj'; // After Hours
const _artist = 'spotify:artist:1Xyo4u8uXC1ZmMpatF05PJ'; // The Weeknd
const _playlistId = '37i9dQZF1DXcBWIGoYBM5M'; // Today's Top Hits
const _track = 'spotify:track:0VjIjW4GlUZAMYd2vXMi3b'; // Blinding Lights
const _show = 'spotify:show:4rOoJ6Egrf8K2IrywzwOMk'; // The Joe Rogan Experience
const _episode =
    'spotify:episode:4ar2L3XOkq9IT8ezkHd8vP'; // 来自 searchEpisodes 探测结果

final Map<String, _Op> _ops = {
  'home':
      _Op('76243c78b0e20ecdbe41b794dec8cbe73f75e585b0a7201b8d2e84578412847a', {
        'homeEndUserIntegration': 'INTEGRATION_DESKTOP',
        'timeZone': 'Asia/Shanghai',
        'sp_t': '',
        'facet': '',
        'sectionItemsLimit': 10,
        'includeEpisodeContentRatingsV2': false,
      }),
  'browseAll': _Op(
    'dbd8b55e09a58afc52eab438bc228ba28fd72ac2f2148c6c26354980e4579001',
    {
      'pagePagination': {'offset': 0, 'limit': 10},
      'sectionPagination': {'offset': 0, 'limit': 99},
      'browseEndUserIntegration': 'INTEGRATION_DESKTOP',
    },
  ),
  'getAlbum': _Op(
    '6a74b456cd1735c9193d9e8ec8cc5184cad7ce13572210315229db3975964361',
    {'uri': _album, 'locale': '', 'offset': 0, 'limit': 50},
  ),
  'queryArtistOverview': _Op(
    '7bdc7185c219898c7a2b659cfff2f8ce066dd2d9a97f8b7c4bde92ccfec28310',
    {'uri': _artist, 'locale': '', 'preReleaseV2': false},
  ),
  'queryArtistDiscographyAll': _Op(
    '5e07d323febb57b4a56a42abbf781490e58764aa45feb6e3dc0591564fc56599',
    {'uri': _artist, 'offset': 0, 'limit': 20, 'order': 'DATE_DESC'},
  ),
  'searchDesktop':
      _Op('db61238974d27839a136c9dc02bfdbe3fab7635f21cf85976ebff9a1ee281345', {
        'searchTerm': 'weeknd',
        'offset': 0,
        'limit': 10,
        'numberOfTopResults': 5,
        'includeAudiobooks': false,
        'includeArtistHasConcertsField': false,
        'includePreReleases': false,
        'includeLocalConcertsField': false,
        'includeAuthors': false,
      }),
  // 右栏「正在播放」（NPV）：艺人卡 / 提供者 / 巡演
  'queryNpvArtist':
      _Op('604b3771fc8c748bd344d8db8eb1bf2d9cb4f381556cdc0879ddb17a97c80546', {
        'artistUri': _artist,
        'trackUri': _track,
        'contributorsLimit': 10,
        'contributorsOffset': 0,
        'enableRelatedVideos': true,
        'enableRelatedAudioTracks': true,
      }),
  'npvV2TrackSupplementalSections': _Op(
    '3268e307f08330b620de5c161a03b48acf66ec57164eac446e0653694a485764',
    {'trackUri': _track},
  ),
  'queryTrackCreditsGroupedModal': _Op(
    'f135fb9be58a72d041ab5d214d817021a272405d883860468e2627afb01a3ca9',
    {'trackUri': _track, 'contributorsLimit': 50, 'contributorsOffset': 0},
  ),
  'ArtistConcerts': _Op(
    'ef53c43b865496b9890b7167eab1dc614a8949ef9451b3c41184ea888de8bd2b',
    {'artistId': _artist},
  ),
  // ---- 播客 ----
  'searchPodcasts':
      _Op('0195d9f61b43606d490bca64c3456e3593528cea6cc05c7e822c7c42beed0f4e', {
        'searchTerm': 'podcast',
        'offset': 0,
        'limit': 5,
        'numberOfTopResults': 5,
        'includeAudiobooks': false,
        'includeArtistHasConcertsField': false,
        'includePreReleases': false,
        'includeLocalConcertsField': false,
        'includeAuthors': false,
      }),
  'searchEpisodes':
      _Op('c9ee277c533bd3f191f9f09bee04f8e4e81bdc48f4d2fadbf67e504c75dc3fe1', {
        'searchTerm': 'podcast',
        'offset': 0,
        'limit': 5,
        'numberOfTopResults': 5,
        'includeAudiobooks': false,
        'includeArtistHasConcertsField': false,
        'includePreReleases': false,
        'includeLocalConcertsField': false,
        'includeAuthors': false,
      }),
  // 节目名称（顺带验证播客实体查询的入参形式）
  'getPodcastOrBookName': _Op(
    '631676b4cf1eb7c93d1133e3f1f17e5bfe8d6a5e2fb9560148bac61f1531f267',
    {'uri': _show},
  ),
  // 子实体列表（猜：节目的单集列表）
  'lookupChildEntities': _Op(
    '91ce02e32b19123de231dc8de91fe4b9ab84eca087d4c015549308d77fbb6d10',
    {
      'uris': [_show],
    },
  ),
  // 单集元数据（与 decorateContextTracks 同一文档，喂 episode URI）
  'decorateContextEpisodesOrChapters': _Op(
    '383de00240775c39a6afe0b1055dc562b2a3930894201f9762f3fc32a74971c7',
    {
      'uris': [_episode],
    },
  ),
  // 单集播放状态（猜入参为节目 uri + 分页）
  'showItemsPlayedState': _Op(
    '4a070b9bfab2e8537a5271e6839bc3ef51501dcac8170b5fb69a98f967c5fb60',
    {'uri': _show, 'offset': 0, 'limit': 10},
  ),
  // NPV 单集信息
  'queryNpvEpisode': _Op(
    'b1cb5ba81403b81628bd4b73e4b15cabde1898a2ed63667b30bfd053f82a281f',
    {'uri': _episode},
  ),
  // 「添加到歌单」可选的歌单（当前账号可编辑的）；哈希取自 open.spotify.com web-player.632a438d.js
  'editablePlaylists': _Op(
    'd5c4b8096437dcc2ac9528c91dfcd299e35b747cda2f8f75d28f41f49c5092ba',
    {
      'offset': 0,
      'limit': 50,
      'textFilter': '',
      'folderUri': null,
      'uris': [_track],
    },
  ),
  // 播客实体配图与提取色
  'fetchExtractedColorAndImageForPodcastEntity': _Op(
    'b2d6d99fb6237952dfa6638385f9c6085f1b1fb9d0468753ca6ad98ff45adc6f',
    {'uri': _show},
  ),
};

Future<void> main(List<String> args) async {
  // 当前版本的设置在 %APPDATA%\Flutify\Flutify；旧版本在 com.flutify.music\flutify_app
  final appData = Platform.environment['APPDATA'];
  final prefsFile = [
    File('$appData\\Flutify\\Flutify\\shared_preferences.json'),
    File('$appData\\com.flutify.music\\flutify_app\\shared_preferences.json'),
  ].firstWhere((f) => f.existsSync());
  final prefs =
      jsonDecode(prefsFile.readAsStringSync()) as Map<String, dynamic>;
  final token = prefs['flutter.sp_access_token'] as String;
  final clientToken = prefs['flutter.sp_client_token'] as String? ?? '';
  final expiry = prefs['flutter.sp_access_token_expiry'] as int? ?? 0;
  if (expiry < DateTime.now().millisecondsSinceEpoch) {
    stdout.writeln('access_token 已过期，请先打开 App 让它续期');
    exit(1);
  }

  final headers = {
    'authorization': 'Bearer $token',
    'client-token': clientToken,
    'user-agent': _ua,
    'app-platform': 'WebPlayer',
    'spotify-app-version': _appVersion,
    'origin': 'https://open.spotify.com',
    'referer': 'https://open.spotify.com/',
    'accept': 'application/json',
    'accept-language': Platform.environment['PROBE_LANG'] ?? 'zh-CN',
  };
  final out = Directory('tool/probe_out')..createSync(recursive: true);
  final client = HttpClient();

  // 用歌单探测结果中的曲目 URI 批量补全曲目信息
  final playlistDump = File('${out.path}/playlist.json');
  if (playlistDump.existsSync()) {
    final items =
        (jsonDecode(playlistDump.readAsStringSync())['contents']['items']
                as List)
            .take(3);
    _ops['decorateContextTracks'] = _Op(
      '383de00240775c39a6afe0b1055dc562b2a3930894201f9762f3fc32a74971c7',
      {
        'uris': [for (final i in items) i['uri']],
      },
    );
  }

  final names = args.isEmpty ? [..._ops.keys, 'playlist'] : args;
  for (final name in names) {
    // playlist:<id>：取任意歌单（例如 daylist 等动态歌单）
    if (name.startsWith('playlist:')) {
      final id = name.substring(9);
      await _get(
        client,
        'playlist_$id',
        Uri.parse(
          'https://spclient.wg.spotify.com/playlist/v2/playlist/$id?decorate=attributes,length,owner&from=0&length=100',
        ),
        headers,
        out,
      );
      continue;
    }
    // 歌曲电台：种子曲目 → 电台歌单
    if (name == 'radio') {
      await _get(
        client,
        'radio',
        Uri.parse(
          'https://spclient.wg.spotify.com/inspiredby-mix/v2/seed_to_playlist/$_track?response-format=json',
        ),
        headers,
        out,
      );
      continue;
    }
    // 移动端的节目详情（cosmos sp:// 对应的 spclient REST 路径，探测 HTTPS 是否可用）
    if (name == 'coreshow') {
      await _get(
        client,
        'coreshow',
        Uri.parse(
          'https://spclient.wg.spotify.com/core-show/v1/shows/4zmKf7s1X6WY1rF2GdyHSy?market=from_token',
        ),
        headers,
        out,
      );
      continue;
    }
    // 制作人员（REST 版本）
    if (name == 'credits_rest') {
      await _get(
        client,
        'credits_rest',
        Uri.parse(
          'https://spclient.wg.spotify.com/track-credits-view/v0/experimental/${_track.split(':').last}/credits',
        ),
        headers,
        out,
      );
      continue;
    }
    if (name == 'playlist') {
      await _get(
        client,
        'playlist',
        Uri.parse(
          'https://spclient.wg.spotify.com/playlist/v2/playlist/$_playlistId?decorate=attributes,length,owner',
        ),
        headers,
        out,
      );
      continue;
    }
    final op = _ops[name];
    if (op == null) continue;
    // 先试 v2（POST JSON），失败再试 v1（GET 查询参数）
    final body = jsonEncode({
      'variables': op.variables,
      'operationName': name,
      'extensions': {
        'persistedQuery': {'version': 1, 'sha256Hash': op.hash},
      },
    });
    final ok = await _post(
      client,
      '$name.v2',
      Uri.parse('https://api-partner.spotify.com/pathfinder/v2/query'),
      body,
      headers,
      out,
    );
    if (!ok) {
      await _get(
        client,
        '$name.v1',
        Uri.parse(
          'https://api-partner.spotify.com/pathfinder/v1/query',
        ).replace(
          queryParameters: {
            'operationName': name,
            'variables': jsonEncode(op.variables),
            'extensions': jsonEncode({
              'persistedQuery': {'version': 1, 'sha256Hash': op.hash},
            }),
          },
        ),
        headers,
        out,
      );
    }
  }
  client.close();
}

Future<bool> _post(
  HttpClient c,
  String label,
  Uri uri,
  String body,
  Map<String, String> h,
  Directory out,
) async {
  final req = await c.postUrl(uri);
  h.forEach(req.headers.set);
  req.headers.contentType = ContentType.json;
  req.write(body);
  return _report(label, await req.close(), out);
}

Future<bool> _get(
  HttpClient c,
  String label,
  Uri uri,
  Map<String, String> h,
  Directory out,
) async {
  final req = await c.getUrl(uri);
  h.forEach(req.headers.set);
  return _report(label, await req.close(), out);
}

Future<bool> _report(
  String label,
  HttpClientResponse res,
  Directory out,
) async {
  final text = await res.transform(utf8.decoder).join();
  File('${out.path}/$label.json').writeAsStringSync(text);
  dynamic json;
  try {
    json = jsonDecode(text);
  } catch (_) {}
  final hasErrors = json is Map && json['errors'] != null;
  stdout.writeln(
    '[$label] HTTP ${res.statusCode}${hasErrors ? '  errors: ${_short(jsonEncode(json['errors']))}' : ''}',
  );
  if (json != null) stdout.writeln(_shape(json, 0, 4));
  return res.statusCode == 200 && !hasErrors;
}

String _short(String s) => s.length > 300 ? '${s.substring(0, 300)}…' : s;

/// 打印 JSON 结构（键名与类型），数组只展开第一个元素。
String _shape(dynamic v, int depth, int maxDepth) {
  final pad = '  ' * (depth + 1);
  if (v is Map) {
    if (depth >= maxDepth) return '{…${v.length} keys}';
    return v.entries
        .map((e) => '\n$pad${e.key}: ${_shape(e.value, depth + 1, maxDepth)}')
        .join();
  }
  if (v is List) {
    if (v.isEmpty) return '[]';
    return '[${v.length}] ${_shape(v.first, depth + 1, maxDepth)}';
  }
  if (v is String)
    return 'str(${v.length > 40 ? '${v.substring(0, 40)}…' : v})';
  return v.runtimeType.toString();
}

class _Op {
  final String hash;
  final Map<String, Object?> variables;
  const _Op(this.hash, this.variables);
}
