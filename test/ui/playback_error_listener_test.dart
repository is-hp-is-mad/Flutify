import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/auth/login_region_check.dart';
import 'package:flutify_app/services/playback/playback_region_gate.dart';
import 'package:flutify_app/services/protocol/track_playback_exception.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/navigation/app_routes.dart';
import 'package:flutify_app/ui/widgets/playback_error_listener.dart';
import 'package:flutify_app/ui/widgets/toast/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_track_audio_source.dart';
import '../fixtures/sample_catalog.dart';

/// 地区拦截提示（播放错误监听）：
/// - 全屏播放器盖在根 Navigator 上会遮住底部提示——弹提示前先退出播放器页面；
/// - 文案与按钮都较长：按钮放文字下方靠右（不走 SnackBar.action 的折行留白），文字铺满整行。
void main() {
  const track = SampleCatalog.track1;
  const ctx = PlaybackContext.playlist('Test', uri: 'spotify:playlist:test');

  var code = 'CN';
  late FakeTrackAudioSource loader;
  late PlaybackProvider playback;

  setUp(() async {
    LoginRegionCheck.resetForTest();
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    code = 'CN';
    loader = FakeTrackAudioSource();
    playback = PlaybackProvider(
      FakeAudioPlayerService(),
      storage,
      audioLoader: loader,
      regionGate: PlaybackRegionGate(probe: () async => LoginRegion(code)),
    );
  });

  tearDown(() {
    playback.dispose();
    LoginRegionCheck.resetForTest();
  });

  Future<BuildContext> pumpApp(WidgetTester tester) async {
    late BuildContext host;
    await tester.pumpWidget(
      ChangeNotifierProvider<PlaybackProvider>.value(
        value: playback,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PlaybackErrorListener(
            child: Scaffold(
              body: Builder(
                builder: (context) {
                  host = context;
                  return const Text('主页');
                },
              ),
            ),
          ),
        ),
      ),
    );
    return host;
  }

  Future<void> pushFullPlayer(BuildContext host, WidgetTester tester) async {
    Navigator.of(host).push(
      PageRouteBuilder<void>(
        settings: const RouteSettings(name: AppRoutes.fullPlayerRouteName),
        pageBuilder: (_, _, _) => const Scaffold(body: Text('播放器')),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('地区拦截：退出全屏播放器页面，文字铺满整行、按钮底部靠右', (tester) async {
    final host = await pumpApp(tester);
    await pushFullPlayer(host, tester);
    expect(find.text('播放器'), findsOneWidget);

    await playback.playTrack(track, contextQueue: [track], context: ctx);
    await tester.pumpAndSettle();

    expect(find.text('播放器'), findsNothing, reason: '先退出播放器页面，提示才看得见');
    expect(
      find.text('当前网络出口在中国大陆，Spotify 无法播放。请切换节点后重试'),
      findsOneWidget,
    );
    expect(find.text('跳过本次'), findsOneWidget);
    expect(
      tester.widget<ToastContent>(find.byType(ToastContent)).maxLines,
      3,
      reason: '文字铺满整行后 2~3 行即可显示完整',
    );
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).action,
      isNull,
      reason: '按钮放进内容区底部靠右，不再走 SnackBar.action（折行会挤掉四成文字宽度）',
    );
    expect(
      find.descendant(
        of: find.byType(ToastContent),
        matching: find.byWidgetPredicate(
          (w) => w is Align && w.alignment == AlignmentDirectional.centerEnd,
        ),
      ),
      findsOneWidget,
      reason: '按钮在文字下方靠右对齐',
    );

    await tester.tap(find.text('跳过本次'));
    await tester.pumpAndSettle();
    expect(
      LoginRegionCheck.skippedThisRun,
      isTrue,
      reason: '点按后跳过本次检测',
    );
    expect(find.text('跳过本次'), findsNothing, reason: '点按后提示收起');
  });

  testWidgets('普通播放错误：不动播放器页面，提示维持默认行数', (tester) async {
    final host = await pumpApp(tester);
    code = 'JP'; // 地区门控放行，才会走到加载失败的分支
    loader.failures[track.id] = const TrackPlaybackException(
      TrackPlaybackFailure.unavailable,
      '这首歌仅提供 DRM 加密格式',
    );
    await pushFullPlayer(host, tester);

    await playback.playTrack(track, contextQueue: [track], context: ctx);
    await tester.pumpAndSettle();

    expect(find.text('播放器'), findsOneWidget, reason: '非地区拦截的错误不退出播放器');
    expect(
      tester.widget<ToastContent>(find.byType(ToastContent)).maxLines,
      isNull,
    );
  });
}
