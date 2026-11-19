import 'dart:async';

import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/navigation/app_routes.dart';
import 'package:flutify_app/ui/screens/detail/playlist_detail_screen.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';

/// 分页加载的长歌单：标题的歌曲数是歌单总数，没加载完时旁边注明已加载多少，加载完才显示总时长。
void main() {
  SpotifyTrack track(int i) => SpotifyTrack(
    id: 'synthetic${i.toString().padLeft(11, '0')}',
    name: 'Synthetic Track $i',
    durationMs: 60000,
  );

  final card = SpotifyPlaylist(
    id: 'synthetic-long-playlist',
    name: 'Synthetic Long Playlist',
    ownerName: 'Tester',
    totalTracks: 1200,
  );

  late StreamController<SpotifyPlaylist> pages;

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ArtworkPalette.enabled = false;

    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    pages = StreamController<SpotifyPlaylist>();
    addTearDown(pages.close);
    await tester.pumpWidget(
      FlutifyApp(
        storageService: storage,
        audioEngine: FakeAudioPlayerService(),
        emePlayer: EmePlayer(),
        spotifyApiService: _PagedApiService(storage.auth, pages.stream),
      ),
    );
    await settle(tester);
    AppRoutes.openPlaylist(tester.element(find.byType(MainShell)), card);
    await settle(tester);
    expect(find.byType(PlaylistDetailScreen), findsOneWidget);
  }

  testWidgets('没加载完：显示总数与已加载数，不显示部分时长', (tester) async {
    await pumpApp(tester);
    pages.add(card.copyWith(tracks: [for (var i = 0; i < 3; i++) track(i)], totalTracks: 1200));
    await settle(tester);

    expect(find.textContaining('1200 首歌曲 · 已加载 3 首'), findsWidgets);
    expect(find.textContaining('3 首歌曲'), findsNothing);
    expect(find.textContaining('3 分钟'), findsNothing);
  });

  testWidgets('加载完：只显示总数与总时长', (tester) async {
    await pumpApp(tester);
    pages.add(card.copyWith(tracks: [track(0), track(1)], totalTracks: 2));
    await settle(tester);

    expect(find.textContaining('2 首歌曲'), findsWidgets);
    expect(find.textContaining('已加载'), findsNothing);
  });
}

/// 只替换歌单拉取：按测试推送的分页快照返回，其余沿用真实实现（未登录，不发网络请求）。
class _PagedApiService extends SpotifyApiService {
  _PagedApiService(super.storage, this._pages);

  final Stream<SpotifyPlaylist> _pages;

  @override
  Stream<SpotifyPlaylist> watchPlaylist(String id) => _pages;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
