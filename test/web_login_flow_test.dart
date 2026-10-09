import 'dart:async';
import 'dart:io';

import 'package:flutify_app/services/auth/web_login_flow.dart';
import 'package:flutify_app/services/auth/web_token_exception.dart';
import 'package:flutter_test/flutter_test.dart';

/// 统一登录流程：Web 登录 → 自动取凭据 → 后台无感完成桌面 OAuth。
void main() {
  /// 造一个可编排的流程：cookie / 保存 / 铸 token / 桌面授权都用桩。
  ({
    WebLoginFlow flow,
    List<String> saved,
    List<int> mintCalls,
    List<int> beginCalls,
    List<Uri> authorizeUrls,
    List<int> finished,
    void Function() setCookie,
    void Function() dropCookie,
  })
  build({
    bool desktopSignedIn = true,
    bool mintFails = false,
    bool beginFails = false,
    Future<String?> Function()? readCookie,
    Future<void> Function()? prepare,
    Future<Uri?> Function()? begin,
    Future<void> Function()? cancel,
  }) {
    final saved = <String>[];
    final mintCalls = <int>[];
    final beginCalls = <int>[];
    final authorizeUrls = <Uri>[];
    final finished = <int>[];
    var cookie = 'sp_dc-value';
    var signedIn = desktopSignedIn;

    final flow = WebLoginFlow(
      readSpDc: readCookie ?? () async => cookie.isEmpty ? null : cookie,
      saveSpDc: (v) async => saved.add(v),
      prepareWebToken: () async {
        mintCalls.add(1);
        if (prepare != null) return prepare();
        if (mintFails) throw StateError('铸造失败');
      },
      desktopSignedIn: () => signedIn,
      beginDesktopOAuth: () async {
        beginCalls.add(1);
        if (begin != null) return begin();
        if (beginFails) throw StateError('端口被占用');
        return Uri.parse(
          'https://accounts.spotify.com/authorize?client_id=abc&state=s1',
        );
      },
      cancelDesktopOAuth: cancel ?? () async {},
      onAuthorizeUrl: authorizeUrls.add,
      onFinished: (_) => finished.add(1),
    );
    return (
      flow: flow,
      saved: saved,
      mintCalls: mintCalls,
      beginCalls: beginCalls,
      authorizeUrls: authorizeUrls,
      finished: finished,
      setCookie: () => cookie = 'sp_dc-value',
      dropCookie: () => cookie = '',
    );
  }

  test('web session captured → token minted → desktop 已登录则直接完成', () async {
    final t = build(desktopSignedIn: true);
    await t.flow.poll();

    expect(t.flow.stage, WebLoginStage.done);
    expect(t.flow.webSignedIn, isTrue);
    expect(t.flow.desktopAuthorized, isTrue);
    expect(t.saved, ['sp_dc-value']);
    expect(t.mintCalls, [1]);
    expect(t.beginCalls, isEmpty, reason: '桌面已登录不应再发起授权');
    expect(t.finished, [1]);
  });

  test('桌面未登录 → 后台发起授权，回调完成后才收尾', () async {
    final t = build(desktopSignedIn: false);
    await t.flow.poll();

    expect(t.flow.stage, WebLoginStage.desktopAuthorize);
    expect(t.flow.waitingForDesktop, isTrue);
    expect(t.authorizeUrls, hasLength(1), reason: '授权页地址应交给 UI 装载');
    expect(t.finished, isEmpty, reason: '授权未完成不能提前收尾');

    t.flow.onDesktopAuthorized();
    expect(t.flow.stage, WebLoginStage.done);
    expect(t.flow.desktopAuthorized, isTrue);
    expect(t.finished, [1]);
  });

  test('读不到 sp_dc 就停在 webSignIn 继续等，不动后续步骤', () async {
    final t = build(desktopSignedIn: true);
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

  test('铸 token 失败只提示不阻断：sp_dc 已保存，继续后台授权', () async {
    final t = build(desktopSignedIn: true, mintFails: true);
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

  test('桌面授权失败进入 failed，可 retry 重发', () async {
    final t = build(desktopSignedIn: false);
    await t.flow.poll();
    t.flow.onDesktopFailed('你在授权页取消了授权');

    expect(t.flow.stage, WebLoginStage.failed);
    expect(t.flow.error, contains('取消'));
    expect(t.finished, isEmpty);

    await t.flow.retry();
    expect(t.flow.stage, WebLoginStage.desktopAuthorize);
    expect(t.beginCalls, hasLength(2), reason: 'retry 应重新发起授权');
    t.flow.onDesktopAuthorized();
    expect(t.flow.stage, WebLoginStage.done);
  });

  test('Web token 401 丢弃 Cookie 并停止桌面授权，重试从 Web 登录开始', () async {
    final t = build(
      desktopSignedIn: false,
      prepare: () async => throw WebTokenHttpException(401),
    );
    await t.flow.poll();
    expect(t.flow.stage, WebLoginStage.failed);
    expect(t.flow.webSignedIn, isFalse);
    expect(t.flow.error, contains('重新登录'));
    expect(t.beginCalls, isEmpty);
    expect(t.finished, isEmpty);
    await t.flow.retry();
    expect(t.flow.stage, WebLoginStage.webSignIn);
    expect(t.beginCalls, isEmpty);
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

  test('取消后迟到的 Web token 成功不能继续桌面授权', () async {
    final prepared = Completer<void>();
    final preparing = Completer<void>();
    final t = build(
      desktopSignedIn: false,
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
    expect(t.beginCalls, isEmpty);
    expect(t.finished, isEmpty);
  });

  test('会话清除后旧授权启动异常不能覆盖重新登录提示', () async {
    final authorization = Completer<Uri?>();
    final starting = Completer<void>();
    final t = build(
      desktopSignedIn: false,
      begin: () {
        starting.complete();
        return authorization.future;
      },
    );
    final poll = t.flow.poll();
    await starting.future;
    t.flow.invalidateSession();
    authorization.completeError(StateError('old OAuth failure'));
    await poll;
    expect(t.flow.error, contains('重新登录'));
    expect(t.authorizeUrls, isEmpty);
    expect(t.finished, isEmpty);
  });

  test('重试等待取消旧授权时若清除会话，不得重新发起授权', () async {
    final cancelled = Completer<void>();
    final t = build(desktopSignedIn: false, cancel: () => cancelled.future);
    await t.flow.poll();
    t.flow.onDesktopFailed('retry');
    final retry = t.flow.retry();
    t.flow.invalidateSession();
    cancelled.complete();
    await retry;
    expect(t.beginCalls, hasLength(1));
    expect(t.flow.stage, WebLoginStage.failed);
    expect(t.flow.webSignedIn, isFalse);
  });

  test('beginDesktopOAuth 抛错 / 返回 null 都进 failed', () async {
    final failing = build(desktopSignedIn: false, beginFails: true);
    await failing.flow.poll();
    expect(failing.flow.stage, WebLoginStage.failed);
    expect(failing.flow.error, contains('无法开始桌面授权'));
  });

  test('完成后迟到的回调被忽略，onFinished 只跑一次', () async {
    final t = build(desktopSignedIn: true);
    await t.flow.poll();
    t.flow.onDesktopAuthorized();
    t.flow.onDesktopFailed('late');
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

  test('isLoopbackRedirect：认 127.0.0.1 回环回调', () {
    expect(
      isLoopbackRedirect('http://127.0.0.1:8898/login?code=x&state=s'),
      isTrue,
    );
    expect(isLoopbackRedirect('http://localhost:8898/login?code=x'), isTrue);
    expect(isLoopbackRedirect('http://127.0.0.1:8898/other'), isFalse);
    expect(isLoopbackRedirect('https://127.0.0.1:8898/login'), isFalse);
    expect(isLoopbackRedirect('https://open.spotify.com/'), isFalse);
    expect(isLoopbackRedirect(null), isFalse);
  });

  test('同意页自动点击脚本只点确认类按钮，不点取消', () {
    expect(kConsentAutoApproveScript, contains('agree'));
    expect(kConsentAutoApproveScript, contains('同意'));
    expect(kConsentAutoApproveScript, isNot(contains("'cancel'")));
    expect(kConsentAutoApproveScript, isNot(contains('取消')));
  });
}
