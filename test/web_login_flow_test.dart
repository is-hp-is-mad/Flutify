import 'dart:async';
import 'dart:io';

import 'package:flutify_app/services/auth/web_login_flow.dart';
import 'package:flutify_app/services/auth/web_token_exception.dart';
import 'package:flutter_test/flutter_test.dart';

/// 统一登录流程：Web 登录 → 自动取凭据（铸 Web token 并建立登录态）。
void main() {
  /// 造一个可编排的流程：cookie / 保存 / 铸 token 都用桩。
  ({
    WebLoginFlow flow,
    List<String> saved,
    List<int> mintCalls,
    List<int> finished,
    void Function() setCookie,
    void Function() dropCookie,
  })
  build({
    bool mintFails = false,
    Future<String?> Function()? readCookie,
    Future<void> Function()? prepare,
  }) {
    final saved = <String>[];
    final mintCalls = <int>[];
    final finished = <int>[];
    var cookie = 'sp_dc-value';

    final flow = WebLoginFlow(
      readSpDc: readCookie ?? () async => cookie.isEmpty ? null : cookie,
      saveSpDc: (v) async => saved.add(v),
      prepareWebToken: () async {
        mintCalls.add(1);
        if (prepare != null) return prepare();
        if (mintFails) throw StateError('铸造失败');
      },
      onFinished: (_) => finished.add(1),
    );
    return (
      flow: flow,
      saved: saved,
      mintCalls: mintCalls,
      finished: finished,
      setCookie: () => cookie = 'sp_dc-value',
      dropCookie: () => cookie = '',
    );
  }

  test('web session captured → token minted → 直接完成', () async {
    final t = build();
    await t.flow.poll();

    expect(t.flow.stage, WebLoginStage.done);
    expect(t.flow.webSignedIn, isTrue);
    expect(t.saved, ['sp_dc-value']);
    expect(t.mintCalls, [1]);
    expect(t.finished, [1]);
  });

  test('读不到 sp_dc 就停在 webSignIn 继续等，不动后续步骤', () async {
    final t = build();
    t.dropCookie();
    await t.flow.poll();

    expect(t.flow.stage, WebLoginStage.webSignIn);
    expect(t.flow.webSignedIn, isFalse);
    expect(t.saved, isEmpty);
    expect(t.mintCalls, isEmpty);

    t.setCookie();
    await t.flow.poll();
    expect(t.flow.stage, WebLoginStage.done);
  });

  test('铸 token 失败只提示不阻断：sp_dc 已保存，照常完成', () async {
    final t = build(mintFails: true);
    await t.flow.poll();

    expect(t.flow.stage, WebLoginStage.done);
    expect(t.flow.notice, contains('Web token'));
    expect(t.saved, ['sp_dc-value']);
  });

  test('TLS 证书错误提示指向代理 / 安全软件的 HTTPS 拦截', () {
    final notice = webTokenMintNotice(
      const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
    );
    expect(notice, contains('TLS'));
    expect(notice, contains('拦截 HTTPS'));
    expect(
      webTokenMintNotice(StateError('铸造失败')),
      contains('稍后会自动重试'),
    );
  });

  test('Web token 401 丢弃 Cookie，重试从 Web 登录开始', () async {
    final t = build(prepare: () async => throw WebTokenHttpException(401));
    await t.flow.poll();
    expect(t.flow.stage, WebLoginStage.failed);
    expect(t.flow.webSignedIn, isFalse);
    expect(t.flow.error, contains('重新登录'));
    expect(t.finished, isEmpty);
    await t.flow.retry();
    expect(t.flow.stage, WebLoginStage.webSignIn);
  });

  test('会话清除后迟到的 Cookie 读取不能保存旧 Cookie', () async {
    final cookie = Completer<String?>();
    final t = build(readCookie: () => cookie.future);
    final poll = t.flow.poll();
    t.flow.invalidateSession();
    cookie.complete('old-cookie');
    await poll;
    expect(t.saved, isEmpty);
    expect(t.flow.webSignedIn, isFalse);
    expect(t.flow.stage, WebLoginStage.failed);
  });

  test('取消后迟到的 Web token 成功不能收尾', () async {
    final prepared = Completer<void>();
    final preparing = Completer<void>();
    final t = build(
      prepare: () {
        preparing.complete();
        return prepared.future;
      },
    );
    final poll = t.flow.poll();
    await preparing.future;
    await t.flow.cancel();
    prepared.complete();
    await poll;
    expect(t.finished, isEmpty);
  });

  test('完成后再 poll 被忽略，onFinished 只跑一次', () async {
    final t = build();
    await t.flow.poll();
    await t.flow.poll();

    expect(t.flow.stage, WebLoginStage.done);
    expect(t.finished, [1]);
    expect(t.flow.error, isNull);
  });

  test('isConsentPageUrl：只认 accounts.spotify.com 的授权页', () {
    expect(
      isConsentPageUrl('https://accounts.spotify.com/authorize?client_id=1'),
      isTrue,
    );
    expect(
      isConsentPageUrl(
        'https://accounts.spotify.com/zh-hans/authorize?client_id=1',
      ),
      isTrue,
    );
    expect(
      isConsentPageUrl('https://accounts.spotify.com/login?continue=x'),
      isFalse,
    );
    expect(
      isConsentPageUrl('https://accounts.spotify.com/login?client_id=1'),
      isFalse,
    );
    expect(isConsentPageUrl('http://accounts.spotify.com/authorize'), isFalse);
    expect(
      isConsentPageUrl('https://accounts.spotify.com:8443/authorize'),
      isFalse,
    );
    expect(
      isSpotifyAccountsPageUrl('https://accounts.spotify.com/en/status'),
      isTrue,
    );
    expect(
      isSpotifyAccountsPageUrl(
        'https://accounts.spotify.com.evil.test/authorize',
      ),
      isFalse,
    );
    expect(
      isConsentPageUrl('https://accounts.spotify.com/authorize-other'),
      isFalse,
    );
    expect(
      isConsentPageUrl('https://open.spotify.com/authorize?client_id=1'),
      isFalse,
    );
    expect(isConsentPageUrl(null), isFalse);
  });

  test('同意页自动点击脚本只点确认类按钮，不点取消', () {
    expect(kConsentAutoApproveScript, contains('agree'));
    expect(kConsentAutoApproveScript, contains('同意'));
    expect(kConsentAutoApproveScript, isNot(contains("'cancel'")));
    expect(kConsentAutoApproveScript, isNot(contains('取消')));
  });
}
