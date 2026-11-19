import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/shell/desktop/library_sidebar.dart';
import 'package:flutify_app/ui/shell/desktop/library_sidebar_item.dart';
import 'package:flutify_app/ui/shell/desktop/now_playing_details.dart';
import 'package:flutify_app/ui/widgets/desktop_player_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_library_source.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';
import '../fixtures/sample_home.dart';

/// 回归（BUG-2b）：底部播放条是悬浮胶囊，盖在三栏内容之上——
/// 左栏（音乐库）与右栏（正在播放）滚动末尾要留出播放栏占位，最底部内容不能被遮住。
void main() {
  Future<WidgetTester> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ArtworkPalette.enabled = false;
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await storage.auth.markDesktopSession();
    await storage.auth.setRefreshToken('synthetic-refresh');
    await storage.auth.setUsername('synthetic-user');
    await storage.auth.setDisplayName('Synthetic User');
    await tester.pumpWidget(
      FlutifyApp(
        storageService: storage,
        audioEngine: FakeAudioPlayerService(),
        emePlayer: EmePlayer(),
        spotifyApiService: FakeSpotifyApiService(storage.auth,
          homeFeed: SampleHome.feed,
          librarySource: FakeLibrarySource(
            playlists: [
              for (var i = 0; i < 40; i++)
                SpotifyPlaylist(
                  id: 'p$i',
                  name: 'Playlist $i',
                  uri: 'spotify:playlist:p$i',
                ),
            ],
          ),
        ),
        trackAudioLoader: FakeTrackAudioSource(),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return tester;
  }

  Finder sidebarList() => find.descendant(
    of: find.byType(LibrarySidebar),
    matching: find.byWidgetPredicate(
      (w) => w is ListView && w.scrollDirection == Axis.vertical,
    ),
  );

  testWidgets('左栏滚到底：最后一行完整露出在播放胶囊上方', (tester) async {
    await pumpShell(tester);
    expect(sidebarList(), findsOneWidget);

    // 一路滚到底
    for (var i = 0; i < 12; i++) {
      await tester.drag(sidebarList(), const Offset(0, -2000));
      await tester.pump(const Duration(milliseconds: 60));
    }
    final items = find.byType(LibrarySidebarItem);
    expect(items, findsWidgets);
    final lastBottom = tester.getBottomLeft(items.last).dy;
    expect(
      lastBottom,
      lessThanOrEqualTo(700 - DesktopPlayerBar.reservedHeight + 1),
      reason: '左栏末尾行被底部播放胶囊遮住了（缺滚动末尾留白）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('右栏详情列表末尾留白随播放栏占位', (tester) async {
    await pumpShell(tester);
    final playback = Provider.of<PlaybackProvider>(
      tester.element(find.byType(MainShell)),
      listen: false,
    );
    await playback.playTrack(
      const SpotifyTrack(
        id: 'synthetic-1',
        name: 'Synthetic One',
        durationMs: 180000,
      ),
      contextQueue: const [
        SpotifyTrack(
          id: 'synthetic-1',
          name: 'Synthetic One',
          durationMs: 180000,
        ),
      ],
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(NowPlayingDetails), findsOneWidget);
    final list = tester.widget<ListView>(
      find.descendant(
        of: find.byType(NowPlayingDetails),
        matching: find.byType(ListView),
      ),
    );
    final bottom = list.padding!.resolve(TextDirection.ltr).bottom;
    expect(
      bottom,
      greaterThanOrEqualTo(DesktopPlayerBar.reservedHeight),
      reason: '右栏末尾留白至少要顶到播放胶囊顶部',
    );
    expect(tester.takeException(), isNull);
  });
}
