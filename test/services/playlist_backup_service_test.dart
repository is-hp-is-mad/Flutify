import 'dart:io';

import 'package:flutify_app/l10n/l10n.dart';
import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/providers/preferences_provider.dart';
import 'package:flutify_app/services/backup/playlist_backup_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/auth/backup_account_login_screen.dart';
import 'package:flutify_app/ui/screens/settings/sections/backup_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fixtures/sample_catalog.dart';

void main() {
  const track1 = SampleCatalog.track1;
  const track2 = SampleCatalog.track2;
  const track3 = SampleCatalog.track3;

  late StorageService storage;
  late LibraryProvider library;
  late PreferencesProvider preferences;
  late Directory tempDir;
  late File diskFile;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'sp_auth_method': 'desktop',
      'sp_dc': 'local-sp-dc',
      'lib_account': 'local_user',
      'sp_username': 'local_user',
      'sp_display_name': 'Local User',
    });
    storage = await StorageService.init();
    library = LibraryProvider(storage);
    preferences = PreferencesProvider(storage);
    tempDir = Directory.systemTemp.createTempSync('flutify_backup_test_');
    diskFile = File('${tempDir.path}/playlist_backups.json');
  });

  tearDown(() {
    library.dispose();
    preferences.dispose();
    // 后台落盘可能仍占用文件：清理失败不影响结果，交给系统临时目录回收
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException catch (_) {}
  });

  test('备份频率强制不低于 20 分钟以防限流，支持 20min/1h/2h/12h/1d', () {
    expect(
      PlaylistBackupService.intervalOptionsMinutes,
      [20, 60, 120, 720, 1440],
    );
    final decoded = AppPreferences.fromJson(const {'backupIntervalMinutes': 5});
    expect(decoded.backupIntervalMinutes, 20);

    final service = PlaylistBackupService(
      storage,
      library: library,
      preferences: preferences,
      diskFile: diskFile,
    );
    addTearDown(service.dispose);

    service.configure(enabled: true, intervalMinutes: 1);
    expect(service.intervalMinutes, 20);
    expect(service.effectiveInterval, const Duration(minutes: 20));
  });

  test('本机已登录账号自动备份，且收藏更改立即落盘（不等轮询）', () async {
    final service = PlaylistBackupService(
      storage,
      library: library,
      preferences: preferences,
      diskFile: diskFile,
    );
    addTearDown(service.dispose);

    preferences.update(
      preferences.prefs.copyWith(
        backupEnabled: true,
        backupAutoCurrentAccount: true,
      ),
    );
    expect(service.accounts, hasLength(1));
    expect(service.accounts.first.isCurrentAccount, isTrue);
    expect(service.accounts.first.likedTracks, isEmpty);

    // 点赞歌曲后立即落盘，无需等待定时轮询
    library.toggleLike(track1);
    expect(service.accounts.first.likedTracks.map((t) => t.id), [track1.id]);
    await service.pendingPersist;
    expect(diskFile.existsSync(), isTrue);

    // 新建歌单并加歌同样立即落盘
    final created = library.createPlaylist('My Favs');
    library.addTrackToPlaylist(created.id, track2);
    expect(service.accounts.first.playlists.map((p) => p.name), ['My Favs']);
    expect(
      service.accounts.first.playlists.first.tracks.map((t) => t.id),
      [track2.id],
    );

    await service.pendingPersist;

    // 重新实例化的服务直接从磁盘恢复备份，不发任何网络请求
    var remoteCalls = 0;
    final reloaded = PlaylistBackupService(
      storage,
      diskFile: diskFile,
      remoteFetcher: (_) async {
        remoteCalls++;
        throw StateError('should not fetch from cloud on disk reload');
      },
    );
    addTearDown(reloaded.dispose);
    expect(remoteCalls, 0);
    expect(reloaded.accounts, hasLength(1));
    expect(reloaded.accounts.first.likedTracks.map((t) => t.id), [track1.id]);
    expect(
      reloaded.accounts.first.playlists.first.tracks.map((t) => t.id),
      [track2.id],
    );
  });

  test('添加多个外部备份账号（即使昵称相同也按唯一识别符邮箱/ID 区分），已收藏歌曲合并且歌单保留真实 ID', () async {
    final snapshots = <String, BackupAccountSnapshot>{
      'sp_dc_acct_a': const BackupAccountSnapshot(
        id: '31aaa',
        email: 'alice@example.com',
        displayName: 'Same Nickname',
        likedTracks: [track1, track2],
        playlists: [
          SpotifyPlaylist(
            id: '37i9dQZF1DXa1',
            name: 'Synthwave',
            ownerName: 'Same Nickname',
            tracks: [track1, track2],
            totalTracks: 2,
          ),
        ],
      ),
      'sp_dc_acct_b': const BackupAccountSnapshot(
        id: '31bbb',
        email: 'bob@example.com',
        displayName: 'Same Nickname',
        likedTracks: [track2, track3],
        playlists: [
          SpotifyPlaylist(
            id: '37i9dQZF1DXb1',
            name: 'Synthwave',
            ownerName: 'Same Nickname',
            tracks: [track2, track3],
            totalTracks: 2,
          ),
          SpotifyPlaylist(
            id: '37i9dQZF1DXb2',
            name: 'Chill',
            ownerName: 'Same Nickname',
            tracks: [track3],
            totalTracks: 1,
          ),
        ],
      ),
    };

    final service = PlaylistBackupService(
      storage,
      library: library,
      preferences: preferences,
      diskFile: diskFile,
      remoteFetcher: (spDc) async => snapshots[spDc]!,
    );
    addTearDown(service.dispose);
    service.configure(enabled: true, autoCurrentAccount: true);

    await service.addAccountWithSpDc('sp_dc_acct_a', profileDir: 'prof_a');
    await service.addAccountWithSpDc('sp_dc_acct_b', profileDir: 'prof_b');

    expect(
      service.accounts.map((a) => a.uniqueId),
      ['local_user', 'alice@example.com', 'bob@example.com'],
    );
    expect(
      service.accounts.map((a) => a.title),
      [
        'local_user（Local User）',
        'alice@example.com（Same Nickname）',
        'bob@example.com（Same Nickname）',
      ],
    );

    // 各账号拥有独立的「已点赞的歌曲」条目，而两个账号重合的「Synthwave」歌单曲目自动去重合并
    expect(
      service.allBackedUpPlaylists.map((p) => p.id),
      containsAll([
        'backup_liked_alice@example.com',
        'backup_liked_bob@example.com',
        '37i9dQZF1DXa1',
        '37i9dQZF1DXb2',
      ]),
    );
    final mergedSynthwave = service.allBackedUpPlaylists.firstWhere(
      (p) => p.name == 'Synthwave',
    );
    expect(
      mergedSynthwave.tracks.map((t) => t.id),
      [track1.id, track2.id, track3.id],
    );

    // 支持仅选择其中一部分备份歌曲一键合并导入到本账号「已点赞的歌曲」
    final addedPartial = await service.importSelectedTracksToLiked([track1]);
    expect(addedPartial, 1);
    expect(library.likedTracks.map((t) => t.id), [track1.id]);

    // 支持仅选择其中一部分备份歌单一键导入到本账号
    final partialPlaylistResult = await service.importSelectedPlaylists([
      service.allBackedUpPlaylists.firstWhere((p) => p.id == '37i9dQZF1DXa1'),
    ]);
    expect(partialPlaylistResult.syncedPlaylists, 1);
    expect(library.playlists.map((p) => p.id), ['37i9dQZF1DXa1']);

    // 一键同步全部：已收藏歌曲合并进本账号 Liked Songs，重合歌单合并去重曲目且不产生重复条目
    final result = await service.syncToCurrentAccount();
    expect(result.addedLikedTracks, 2);
    expect(
      library.likedTracks.map((t) => t.id),
      containsAll([track1.id, track2.id, track3.id]),
    );
    expect(
      library.playlists.where((p) => p.name == 'Synthwave'),
      hasLength(1),
    );
    expect(
      library.playlists
          .firstWhere((p) => p.name == 'Synthwave')
          .tracks
          .map((t) => t.id),
      [track1.id, track2.id, track3.id],
    );
    expect(
      library.playlists.any((p) => p.id.startsWith('backup_liked_')),
      isFalse,
      reason: '已点赞歌曲应当合并到 Liked Songs，而不是生成多份假歌单',
    );
  });

  testWidgets('BackupSection 支持开关、添加多账号、展示各账号已点赞歌曲与部分勾选导入', (
    tester,
  ) async {
    final service = PlaylistBackupService(
      storage,
      library: library,
      preferences: preferences,
      diskFile: diskFile,
      remoteFetcher: (spDc) async => const BackupAccountSnapshot(
        id: 'vault_user',
        email: 'vault@example.com',
        displayName: 'Vault User',
        likedTracks: [track1],
        playlists: [
          SpotifyPlaylist(
            id: 'pl_v1',
            name: 'Vault Favorites',
            ownerName: 'Vault User',
            tracks: [track1, track2],
            totalTracks: 2,
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PreferencesProvider>.value(value: preferences),
          ChangeNotifierProvider<LibraryProvider>.value(value: library),
          ChangeNotifierProvider<PlaylistBackupService>(create: (_) => service),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            body: SingleChildScrollView(
              child: BackupSection(
                loginExternalAccount: (_) async => const BackupLoginResult(
                  spDc: 'sp_dc_vault',
                  profileDir: 'isolated_profile_1',
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // 默认未开启
    expect(find.text('启用歌单备份'), findsOneWidget);
    expect(find.text('添加要同步歌单的账号'), findsNothing);

    // 打开总开关
    await tester.tap(find.text('启用歌单备份'));
    await tester.pumpAndSettle();

    expect(find.text('自动备份本机已登录的账号'), findsOneWidget);
    expect(find.text('添加要同步歌单的账号'), findsOneWidget);
    expect(find.text('一键同步已备份的歌单到本账号'), findsOneWidget);

    // 点击添加备份账号
    await tester.tap(find.text('添加要同步歌单的账号'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('vault@example.com（Vault User）（外部备份账号）'),
      findsOneWidget,
    );
    expect(find.text('vault@example.com（Vault User） · 已点赞的歌曲'), findsOneWidget);
    expect(find.text('Vault Favorites'), findsOneWidget);

    // 点击一键同步到本账号
    await tester.tap(find.text('一键同步已备份的歌单到本账号'));
    await tester.pumpAndSettle();

    expect(library.isLiked(track1.id), isTrue);
    expect(
      library.playlists.any((p) => p.name == 'Vault Favorites'),
      isTrue,
    );
  });

  group('当前账号备份的边界情况', () {
    PlaylistBackupService autoService() {
      final service = PlaylistBackupService(
        storage,
        library: library,
        preferences: preferences,
        diskFile: diskFile,
      );
      preferences.update(
        preferences.prefs.copyWith(
          backupEnabled: true,
          backupAutoCurrentAccount: true,
        ),
      );
      return service;
    }

    Future<void> switchTo(String user) async {
      await storage.setUsername(user);
      await storage.setLibraryAccount(user);
    }

    test('换号后旧账号备份保留为「以前登录的账号」并在设置里显示，当前账号隐藏', () async {
      final service = autoService();
      addTearDown(service.dispose);
      library.toggleLike(track1);
      expect(service.visibleAccounts, isEmpty);

      await switchTo('other_user');
      library.toggleLike(track2);

      final ids = service.accounts.map((a) => a.id).toList();
      expect(ids, ['other_user', 'local_user']);
      final old = service.accounts.last;
      expect(old.isCurrentAccount, isFalse);
      expect(old.likedTracks.map((t) => t.id), [track1.id]);
      expect(service.visibleAccounts.map((a) => a.id), ['local_user']);
      await service.pendingPersist;
    });

    test('关闭自动备份时换号：旧账号备份立即可见，不会一直被隐藏', () async {
      final service = autoService();
      addTearDown(service.dispose);
      library.toggleLike(track1);
      preferences.update(
        preferences.prefs.copyWith(backupAutoCurrentAccount: false),
      );

      await switchTo('other_user');
      expect(service.visibleAccounts.map((a) => a.id), ['local_user']);
      await service.pendingPersist;
    });

    test('媒体库数据不属于当前账号（换号后尚未加载完）时不备份，不把旧数据记到新账号名下', () async {
      final service = autoService();
      addTearDown(service.dispose);
      library.toggleLike(track1);

      await storage.setUsername('other_user'); // 媒体库仍是 local_user 的数据
      library.toggleLike(track2);

      expect(service.accounts.map((a) => a.id), ['local_user']);
      expect(service.accounts.single.likedTracks.map((t) => t.id), [track1.id]);
      await service.pendingPersist;
    });

    test('一键同步不把当前账号自己的歌单再导入一遍（不产生重复副本）', () async {
      final service = autoService();
      addTearDown(service.dispose);
      final created = library.createPlaylist('Mine');
      library.addTrackToPlaylist(created.id, track1);
      final before = library.playlists.length;

      final result = await service.syncToCurrentAccount();
      expect(result.syncedPlaylists, 0);
      expect(library.playlists.length, before);
      await service.pendingPersist;
    });

    test('主文件缺失时从写好的临时文件恢复', () async {
      final tmp = File('${diskFile.path}.tmp');
      tmp.writeAsStringSync(
        '[{"id":"tmp_user","displayName":"Tmp","likedTracks":[],"playlists":[]}]',
      );
      final service = PlaylistBackupService(storage, diskFile: diskFile);
      addTearDown(service.dispose);
      expect(service.accounts.map((a) => a.id), ['tmp_user']);
      await service.pendingPersist;
      expect(diskFile.existsSync(), isTrue);
    });

    test('主文件损坏时保留一份 .corrupt 副本', () async {
      diskFile.writeAsStringSync('{broken');
      final service = PlaylistBackupService(storage, diskFile: diskFile);
      addTearDown(service.dispose);
      expect(File('${diskFile.path}.corrupt').readAsStringSync(), '{broken');
    });
  });
}
