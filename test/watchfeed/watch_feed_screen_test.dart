import 'dart:typed_data';

import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/l10n/app_locale.dart';
import 'package:flutify_app/models/watch_feed.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/preferences_provider.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/services/watchfeed/preview_player.dart';
import 'package:flutify_app/ui/screens/detail/album_detail_screen.dart';
import 'package:flutify_app/ui/screens/watchfeed/watch_feed_screen.dart';
import 'package:flutify_app/ui/shell/shell_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import 'watch_feed_fixtures.dart';

/// 记录调用的试听播放器替身（测试环境没有音频平台实现）。
class FakePreviewPlayer extends ChangeNotifier
    implements WatchFeedPreviewPlayer {
  final List<String> played = [];
  int pauses = 0;
  bool _playing = false;
  String? _url;
  bool _muted = false;

  @override
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);

  @override
  Duration get duration => const Duration(seconds: 30);
  @override
  String? get currentUrl => _url;
  @override
  bool get muted => _muted;
  @override
  bool get isPlaying => _playing;
  @override
  bool get isLoading => false;

  @override
  Future<void> play(WatchFeedAudio audio) async {
    played.add(audio.url);
    _url = audio.url;
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    pauses++;
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> resume() async {
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> toggle() => _playing ? pause() : resume();

  @override
  Future<void> seek(Duration to) async {}

  double baseVolume = 1;

  @override
  void setBaseVolume(double value) => baseVolume = value;

  @override
  void setMuted(bool value) {
    _muted = value;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _url = null;
    _playing = false;
    notifyListeners();
  }
}

/// 主播放器替身：只关心「是否在播」，便于模拟用户在专辑页里点了播放。
class _MainPlayback extends PlaybackProvider {
  _MainPlayback(super.audio, super.storage);

  bool playing = false;

  @override
  bool get isPlaying => playing;
  @override
  bool get isPlaybackActive => playing;

  @override
  Future<void> pause() async {
    playing = false;
    notifyListeners();
  }
}

void main() {
  setUp(() => ArtworkPalette.enabled = false);
  tearDown(() => ArtworkPalette.enabled = true);

  /// 主 feed 两条（无视频，避免测试里创建 WebView）+ 一个关联 feed；#标签 feed 一条。
  Future<
    ({
      FakePreviewPlayer player,
      StorageService storage,
      List<String> feeds,
      _MainPlayback playback,
    })
  >
  pump(WidgetTester tester, {bool onboardingShown = true}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 860);
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'sp_access_token': 'token',
      'watch_feed_onboarding_shown': onboardingShown,
      'watch_feed_pivot_hint_shown': true,
    });
    final storage = await StorageService.init();
    final feeds = <String>[];
    final api = SpotifyApiService(
      storage,
      MockClient((request) async {
        final spec = request.bodyBytes;
        final body = String.fromCharCodes(spec);
        feeds.add(body);
        final Uint8List bytes;
        if (body.contains('h3')) {
          bytes = feedResponse(items: [previewItem('n1', name: 'Nested')]);
        } else if (body.contains('assoc')) {
          bytes = feedResponse(items: [previewItem('s1', name: 'Side')]);
        } else {
          bytes = feedResponse(
            items: [
              previewItem('t1', name: 'First', withAlbum: true),
              previewItem('t2', name: 'Second'),
            ],
            headerTitles: ['Similar to First', '#folk'],
            associated: ['spotify:watch-feed:discovery-feed:assoc'],
          );
        }
        return http.Response.bytes(bytes, 200);
      }),
    );
    final prefs = PreferencesProvider(storage);
    final library = LibraryProvider(storage);
    final player = FakePreviewPlayer();
    final audio = FakeAudioPlayerService();
    final playback = _MainPlayback(audio, storage);
    addTearDown(() {
      prefs.dispose();
      library.dispose();
      player.dispose();
      playback.dispose();
      audio.dispose();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<SpotifyApiService>.value(value: api),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider.value(value: library),
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocale.supportedLocales,
          localizationsDelegates: AppLocale.delegates,
          home: WatchFeedScreen(
            feedUri: 'spotify:watch-feed:discovery-feed:main',
            title: '#entry',
            player: player,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return (player: player, storage: storage, feeds: feeds, playback: playback);
  }

  /// 叠加组件依次入场（200ms × 序号 + 400ms）。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('加载首页：显示曲目行与 #标签，播放首条试听，顶栏换成服务端标题', (tester) async {
    final env = await pump(tester);
    await settle(tester);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('#autumn'), findsWidgets);
    expect(env.player.played, ['https://p.scdn.co/mp3-preview/pt1']);
    expect(find.text('Similar to First'), findsOneWidget);
  });

  testWidgets('上滑到下一条：切换试听', (tester) async {
    final env = await pump(tester);
    await settle(tester);
    await tester.fling(find.text('First'), const Offset(0, -500), 2000);
    await settle(tester);
    expect(env.player.played.last, 'https://p.scdn.co/mp3-preview/pt2');
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('轻点画面暂停 / 继续', (tester) async {
    final env = await pump(tester);
    await settle(tester);
    await tester.tap(find.byKey(const Key('watch-feed-gesture-layer')).first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(env.player.isPlaying, isFalse);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    await tester.tap(find.byKey(const Key('watch-feed-gesture-layer')).first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(env.player.isPlaying, isTrue);
  });

  testWidgets('左右滑到关联 feed：标题换成对应 #标签', (tester) async {
    await pump(tester);
    await settle(tester);
    await tester.fling(
      find.byType(PageView).first,
      const Offset(-400, 0),
      2000,
    );
    await settle(tester);
    expect(find.text('#folk'), findsOneWidget);
    expect(find.text('Side'), findsOneWidget);
  });

  testWidgets('点 #标签进入该标签的 feed，上一层试听暂停', (tester) async {
    final env = await pump(tester);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('watch-feed-hashtag-h3')).first);
    await settle(tester);
    expect(env.player.pauses, greaterThan(0));
    // 被压住的上一层在 offstage 里。
    expect(find.byType(WatchFeedScreen, skipOffstage: false), findsNWidgets(2));
    expect(find.text('Nested'), findsOneWidget);
  });

  testWidgets('首次进入显示竖滑引导，点击后消失并记住', (tester) async {
    final env = await pump(tester, onboardingShown: false);
    await settle(tester);
    final hint = find.byKey(const Key('watch-feed-vertical-hint'));
    expect(hint, findsOneWidget);
    expect(find.text('Swipe up to see more'), findsOneWidget);
    await tester.tap(hint);
    await tester.pump();
    expect(hint, findsNothing);
    expect(env.storage.watchFeedOnboardingShown, isTrue);
  });

  testWidgets('切到后台暂停试听，回到前台继续', (tester) async {
    final env = await pump(tester);
    await settle(tester);
    expect(env.player.isPlaying, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(env.player.isPlaying, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(env.player.isPlaying, isTrue);
  });

  testWidgets('手动暂停后切到后台再回来，保持暂停', (tester) async {
    final env = await pump(tester);
    await settle(tester);
    await tester.tap(find.byKey(const Key('watch-feed-gesture-layer')).first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(env.player.isPlaying, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(env.player.isPlaying, isFalse);
  });

  testWidgets('点左下角曲目行：进入所在专辑并定位到这首，试听暂停', (tester) async {
    final env = await pump(tester);
    await settle(tester);
    await tester.tap(find.byKey(const Key('watch-feed-entity-row')).first);
    await settle(tester);
    final album = tester.widget<AlbumDetailScreen>(
      find.byType(AlbumDetailScreen),
    );
    expect(album.album.id, 'albt1');
    expect(album.album.name, 'Album of First');
    expect(album.focusTrack?.id, 't1');
    expect(env.player.isPlaying, isFalse);
    // 专辑页上方没有发现流了：撤回「隐藏底部导航」请求。
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(ShellChrome.instance.hiddenFor(navigator), isFalse);

    // 返回 feed：试听恢复。
    await tester.pageBack();
    await settle(tester);
    expect(find.byType(AlbumDetailScreen), findsNothing);
    expect(env.player.isPlaying, isTrue);
    expect(ShellChrome.instance.hiddenFor(navigator), isTrue);
  });

  testWidgets('发现流是当前页时请求隐藏底部导航，离开后撤回', (tester) async {
    await pump(tester);
    await settle(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(ShellChrome.instance.hiddenFor(navigator), isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(ShellChrome.instance.hiddenFor(navigator), isFalse);
  });

  testWidgets('在专辑页点了播放再返回：试听不打断主播放，上滑到下一首才接管', (tester) async {
    final env = await pump(tester);
    await settle(tester);
    await tester.tap(find.byKey(const Key('watch-feed-entity-row')).first);
    await settle(tester);
    // 用户在专辑页开始播放。
    env.playback.playing = true;

    await tester.pageBack();
    await settle(tester);
    expect(env.playback.playing, isTrue, reason: '主播放不被暂停');
    expect(env.player.isPlaying, isFalse, reason: '试听保持暂停');
    expect(env.player.played, ['https://p.scdn.co/mp3-preview/pt1']);

    await tester.fling(find.text('First'), const Offset(0, -500), 2000);
    await settle(tester);
    expect(env.playback.playing, isFalse, reason: '翻到下一首后 feed 接管');
    expect(env.player.isPlaying, isTrue);
    expect(env.player.played.last, 'https://p.scdn.co/mp3-preview/pt2');
  });
}
