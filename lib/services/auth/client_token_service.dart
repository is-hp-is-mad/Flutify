import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'auth_constants.dart';
import 'client_profile.dart';
import 'hashcash.dart';
import 'proto_codec.dart';

/// 申请 client-token（`clienttoken.spotify.com/v1/clienttoken`）。
///
/// 流程（对齐 librespot spclient.rs）：
/// 1. 发送 ClientTokenRequest{request_type=CLIENT_DATA, client_data=ClientDataRequest{...}}；
/// 2. 若返回 GRANTED_TOKEN，直接得到 token；
/// 3. 若返回 CHALLENGES（hashcash），求解后用 CHALLENGE_ANSWERS 再次提交。
///
/// client-token 与 access_token 是两套令牌：前者是设备/客户端态，spclient 内部接口普遍要求携带。
class ClientTokenService {
  final http.Client _client;

  ClientTokenService(this._client);

  /// 以 [profile] 的客户端身份申请 client-token。失败抛异常。
  Future<GrantedClientToken> request(String deviceId, [SpotifyClientProfile profile = SpotifyClientProfile.desktop]) async {
    if (profile == SpotifyClientProfile.web) return _requestWeb(deviceId, profile);
    final body = _buildClientDataRequest(deviceId, profile);
    var response = await _post(body, profile);

    for (var attempt = 0; attempt < 3; attempt++) {
      final parsed = _parseResponse(response);

      if (parsed.token != null) return parsed.token!;

      final challenge = parsed.hashcashChallenge;
      if (challenge == null) {
        throw StateError('client-token 申请失败：未返回令牌，也无可解挑战');
      }

      // client-token 的 hashcash：ctx 为空，prefix 是十六进制字符串（需先解码），答案 suffix 以大写十六进制回传
      final prefixBytes = _hexDecode(challenge.prefixHex);
      final suffix = await Hashcash.solveAsync(const [], prefixBytes, challenge.length);
      final suffixHex = _hexEncodeUpper(suffix);

      response = await _post(_buildChallengeAnswer(parsed.state, suffixHex), profile);
    }

    throw StateError('client-token 申请失败：多次挑战应答均未通过');
  }

  /// Web 播放器的申请方式（对齐 open.spotify.com 前端）：JSON 请求体
  /// `{client_data:{client_version, client_id, js_sdk_data:{…}}}`，响应取 `granted_token`。
  /// Web 前端不处理挑战，这里也一样：没拿到令牌即失败。
  Future<GrantedClientToken> _requestWeb(String deviceId, SpotifyClientProfile profile) async {
    final res = await _client.post(
      Uri.parse(SpotifyAuthConstants.clientTokenEndpoint),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'User-Agent': profile.userAgent,
      },
      body: jsonEncode({
        'client_data': {
          'client_version': profile.clientVersion,
          'client_id': profile.clientId,
          'js_sdk_data': profile.jsSdkData(deviceId),
        },
      }),
    );
    if (res.statusCode != 200) {
      throw StateError('client-token HTTP ${res.statusCode}');
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    final granted = body is Map ? body['granted_token'] : null;
    final token = granted is Map ? granted['token'] : null;
    if (token is! String || token.isEmpty) {
      throw StateError('client-token 申请失败：未返回令牌（${body is Map ? body['response_type'] : 'invalid'}）');
    }
    int seconds(Object? v, int fallback) => v is num ? v.toInt() : fallback;
    final refreshAfter = seconds(granted['refresh_after_seconds'], 1209600);
    return GrantedClientToken(
      token: token,
      expiresAfterSeconds: seconds(granted['expires_after_seconds'], refreshAfter),
      refreshAfterSeconds: refreshAfter,
    );
  }

  Future<Uint8List> _post(Uint8List body, SpotifyClientProfile profile) async {
    final res = await _client.post(
      Uri.parse(SpotifyAuthConstants.clientTokenEndpoint),
      headers: {
        'Accept': 'application/x-protobuf',
        'Content-Type': 'application/x-protobuf',
        'User-Agent': profile.userAgent,
      },
      body: body,
    );
    if (res.statusCode != 200) {
      throw StateError('client-token HTTP ${res.statusCode}: ${res.body}');
    }
    return res.bodyBytes;
  }

  // --- 请求构造 ---

  /// ClientTokenRequest{ request_type=1(CLIENT_DATA), client_data=2 }
  Uint8List _buildClientDataRequest(String deviceId, SpotifyClientProfile profile) {
    // ConnectivitySdkData{ platform_specific_data=1{ desktop_windows=4 }, device_id=2 }
    final connectivity = ProtoWriter()
      ..message(1, profile.platformData()) // platform_specific_data=1
      ..string(2, deviceId); // device_id=2

    final clientData = ProtoWriter()
      ..string(1, profile.clientVersion) // client_version=1
      ..string(2, profile.clientId) // client_id=2
      ..message(3, connectivity); // connectivity_sdk_data=3 (oneof data)

    final request = ProtoWriter()
      ..enumValue(1, 1) // request_type=1 => REQUEST_CLIENT_DATA_REQUEST
      ..message(2, clientData); // client_data=2 (oneof request)

    return request.toBytes();
  }

  /// ClientTokenRequest{ request_type=2(CHALLENGE_ANSWERS), challenge_answers=3 }
  Uint8List _buildChallengeAnswer(String state, String suffixHexUpper) {
    // HashCashAnswer{ suffix=1 }
    final hashAnswer = ProtoWriter()..string(1, suffixHexUpper);
    // ChallengeAnswer{ ChallengeType=1(=3 HASH_CASH), hash_cash=4 }
    final answer = ProtoWriter()
      ..enumValue(1, 3) // CHALLENGE_HASH_CASH
      ..message(4, hashAnswer); // hash_cash=4 (oneof answer)
    // ChallengeAnswersRequest{ state=1, answers=2 repeated }
    final answers = ProtoWriter()
      ..string(1, state)
      ..message(2, answer);

    final request = ProtoWriter()
      ..enumValue(1, 2) // request_type=2 => REQUEST_CHALLENGE_ANSWERS_REQUEST
      ..message(3, answers); // challenge_answers=3

    return request.toBytes();
  }

  // --- 响应解析 ---

  _ClientTokenParsed _parseResponse(Uint8List data) {
    GrantedClientToken? token;
    _HashcashParams? challenge;
    var state = '';

    ProtoReader(data).forEach((f) {
      switch (f.number) {
        case 2: // granted_token (oneof)
          token = _parseGranted(f.asMessage);
          break;
        case 3: // challenges (oneof)
          final parsed = _parseChallenges(f.asMessage);
          state = parsed.state;
          challenge = parsed.hashcash;
          break;
      }
    });

    return _ClientTokenParsed(token: token, hashcashChallenge: challenge, state: state);
  }

  /// GrantedTokenResponse{ token=1, expires_after_seconds=2, refresh_after_seconds=3 }
  GrantedClientToken _parseGranted(ProtoReader r) {
    var token = '';
    var expiresAfter = 0;
    var refreshAfter = 0;
    r.forEach((f) {
      switch (f.number) {
        case 1:
          token = f.asString;
          break;
        case 2:
          expiresAfter = f.varintValue;
          break;
        case 3:
          refreshAfter = f.varintValue;
          break;
      }
    });
    return GrantedClientToken(token: token, expiresAfterSeconds: expiresAfter, refreshAfterSeconds: refreshAfter);
  }

  /// ChallengesResponse{ state=1, challenges=2 repeated Challenge }
  ({String state, _HashcashParams? hashcash}) _parseChallenges(ProtoReader r) {
    var state = '';
    _HashcashParams? hashcash;
    r.forEach((f) {
      if (f.number == 1) {
        state = f.asString;
      } else if (f.number == 2) {
        // Challenge{ type=1, evaluate_hashcash_parameters=4 }
        f.asMessage.forEach((c) {
          if (c.number == 4) {
            hashcash = _parseHashcashParams(c.asMessage);
          }
        });
      }
    });
    return (state: state, hashcash: hashcash);
  }

  /// HashCashParameters{ length=1, prefix=2 }
  _HashcashParams _parseHashcashParams(ProtoReader r) {
    var length = 0;
    var prefixHex = '';
    r.forEach((f) {
      if (f.number == 1) {
        length = f.varintValue;
      } else if (f.number == 2) {
        prefixHex = f.asString;
      }
    });
    return _HashcashParams(length: length, prefixHex: prefixHex);
  }

  // --- 十六进制辅助 ---

  static Uint8List _hexDecode(String hex) {
    final clean = hex.trim();
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _hexEncodeUpper(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
}

/// 申请成功的 client-token 及其有效期。
class GrantedClientToken {
  final String token;
  final int expiresAfterSeconds;
  final int refreshAfterSeconds;

  GrantedClientToken({
    required this.token,
    required this.expiresAfterSeconds,
    required this.refreshAfterSeconds,
  });

  /// 到期时间戳（毫秒）。
  int expiryEpochMs(DateTime now) => now.add(Duration(seconds: expiresAfterSeconds)).millisecondsSinceEpoch;
}

class _ClientTokenParsed {
  final GrantedClientToken? token;
  final _HashcashParams? hashcashChallenge;
  final String state;
  _ClientTokenParsed({this.token, this.hashcashChallenge, required this.state});
}

class _HashcashParams {
  final int length;
  final String prefixHex;
  _HashcashParams({required this.length, required this.prefixHex});
}
