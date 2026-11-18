import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/rust_core.dart';
import '../../models/app_preferences.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../../src/rust/api/backend.dart' as rust;
import '../spotify_api_service.dart';
import '../storage/auth_session_store.dart';
import '../storage/library_cache_store.dart';
import '../storage/preferences_store.dart';
import 'backup_models.dart';
import 'backup_ports.dart';
import 'sp_dc_backup_fetcher.dart';

export 'backup_models.dart';
export 'sp_dc_backup_fetcher.dart';

/// 歌单备份服务：
/// - 支持展示各个备份账号各自的「已点赞的歌曲」（`backup_liked_<uniqueId>`）与收藏歌单；
/// - 导入 / 同步「已点赞的歌曲」时，将歌曲**合并**进当前账号的 Liked Songs；
/// - 无论是备份的歌曲还是歌单，均支持勾选其中一部分一键导入到当前账号。
class PlaylistBackupService extends ChangeNotifier {
  static const int minIntervalMinutes = AppPreferences.minBackupIntervalMinutes;
  static const int defaultIntervalMinutes =
      AppPreferences.defaultBackupIntervalMinutes;
  static const List<int> intervalOptionsMinutes =
      AppPreferences.backupIntervalOptions;

  final AuthSessionStore _auth;
  final PreferencesStore _prefsStore;
  final LibraryCacheStore _libraryCache;
  final BackupLibraryPort? _library;
  final BackupPreferencesPort? _preferences;
  final SpotifyApiService? _apiService;
  final BackupRemoteFetcher? _customRemoteFetcher;
  final SpDcBackupFetcher _sessionFetcher;
  final File? _diskFile;

  /// 生产环境的备份文件（应用数据目录，由 main 在启动时设置）；测试不设置时只用 SharedPreferences。
  static File? defaultDiskFile;
  final DateTime Function() _now;
  final bool _enablePeriodicTimer;

  List<BackupAccount> _accounts = const [];
  bool _enabled = false;
  bool _autoCurrentAccount = true;
  int _intervalMinutes = defaultIntervalMinutes;
  bool _isBackingUp = false;
  String? _lastError;
  Timer? _timer;
  bool _disposed = false;

  /// 记录上次已落盘的本机收藏引用，仅在真正变化时立即重写落盘。
  List<SpotifyTrack>? _lastLocalLiked;
  List<SpotifyPlaylist>? _lastLocalPlaylists;

  PlaylistBackupService(
    this._auth,
    this._prefsStore,
    this._libraryCache, {
    BackupLibraryPort? library,
    BackupPreferencesPort? preferences,
    SpotifyApiService? apiService,
    BackupRemoteFetcher? remoteFetcher,
    SpDcBackupFetcher? sessionFetcher,
    File? diskFile,
    DateTime Function()? now,
    bool? enablePeriodicTimer,
  }) : _library = library,
       _preferences = preferences,
       _apiService = apiService,
       _customRemoteFetcher = remoteFetcher,
       _sessionFetcher =
           sessionFetcher ?? SpDcBackupFetcher(apiService: apiService),
       _diskFile = diskFile ?? defaultDiskFile,
       _now = now ?? DateTime.now,
       _enablePeriodicTimer =
           enablePeriodicTimer ??
           !Platform.environment.containsKey('FLUTTER_TEST') {
    _loadFromDisk();
    final prefs =
        _preferences?.prefs ?? AppPreferences.decode(_prefsStore.preferencesJson);
    _enabled = prefs.backupEnabled;
    _autoCurrentAccount = prefs.backupAutoCurrentAccount;
    _intervalMinutes = max(minIntervalMinutes, prefs.backupIntervalMinutes);

    _library?.addListener(_onLibraryChanged);
    _preferences?.addListener(_onPreferencesChanged);
    _rescheduleTimer();
    if (_enabled && _autoCurrentAccount) {
      _backupCurrentAccountImmediate();
    }
    if (_enabled && _apiService != null) {
      unawaited(_hydrateIncompleteAccounts());
    }
  }

  List<BackupAccount> get accounts => _accounts;
  bool get enabled => _enabled;
  bool get autoCurrentAccount => _autoCurrentAccount;
  int get intervalMinutes => _intervalMinutes;
  Duration get effectiveInterval =>
      Duration(minutes: max(minIntervalMinutes, _intervalMinutes));
  bool get isBackingUp => _isBackingUp;
  String? get lastError => _lastError;

  /// 所有备份账号合并后的「已点赞的歌曲」（按曲目 ID 去重）。
  List<SpotifyTrack> get mergedLikedTracks {
    final seen = <String>{};
    final merged = <SpotifyTrack>[];
    for (final account in _accounts) {
      for (final track in account.likedTracks) {
        final key = track.id.isNotEmpty ? track.id : track.uri;
        if (key.isEmpty || seen.add(key)) {
          merged.add(track);
        }
      }
    }
    return merged;
  }

  /// 判断指定歌单 ID 是否为「外部备份账号的已点赞歌曲」虚拟歌单（排除本机当前账号）。
  bool isExternalBackupLikedPlaylist(String playlistId) {
    if (!playlistId.startsWith(BackupAccount.backupLikedPrefix)) return false;
    final uid = playlistId.substring(BackupAccount.backupLikedPrefix.length);
    return _accounts.any((a) => !a.isCurrentAccount && a.uniqueId == uid);
  }

  /// 已落盘的备份歌单汇总：
  /// - 包含每个账号各自的「已点赞的歌曲」（`backup_liked_<uniqueId>`，点击可查看该账号自己的已点赞歌曲）；
  /// - 包含各账号的收藏歌单（不同账号间若有同 ID 或同名重合歌单，自动合并其曲目）。
  List<SpotifyPlaylist> get allBackedUpPlaylists {
    final likedPlaylists = <SpotifyPlaylist>[];
    final seenLikedIds = <String>{};
    final mergedPlaylists = <SpotifyPlaylist>[];

    // 当前登录账号自己的歌单本来就在媒体库里，导入给自己没有意义
    for (final account in visibleAccounts) {
      if (account.likedTracks.isNotEmpty) {
        final likedPl = account.likedSongsPlaylist;
        if (seenLikedIds.add(likedPl.id)) {
          likedPlaylists.add(likedPl);
        }
      }
      for (final p in account.playlists) {
        if (p.id.isEmpty) continue;
        final normalized = p.copyWith(
          ownerName: p.ownerName.isNotEmpty && p.ownerName != 'Spotify'
              ? p.ownerName
              : account.title,
          totalTracks: p.tracks.isNotEmpty ? p.tracks.length : p.totalTracks,
        );
        final existingIdx = mergedPlaylists.indexWhere(
          (existing) =>
              existing.id == normalized.id ||
              (normalized.name.trim().isNotEmpty &&
                  existing.name.trim().toLowerCase() ==
                      normalized.name.trim().toLowerCase()),
        );
        if (existingIdx >= 0) {
          mergedPlaylists[existingIdx] = BackupLibraryPort.mergePlaylists(
            mergedPlaylists[existingIdx],
            normalized,
          );
        } else {
          mergedPlaylists.add(normalized);
        }
      }
    }
    return [...likedPlaylists, ...mergedPlaylists];
  }

  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    _notify();
  }

  /// 更新备份开关与频率配置（测试或未挂 PreferencesProvider 时也可直接调用）。
  void configure({
    bool? enabled,
    bool? autoCurrentAccount,
    int? intervalMinutes,
  }) {
    final prevEnabled = _enabled;
    final prevAuto = _autoCurrentAccount;
    final prevInterval = _intervalMinutes;

    if (enabled != null) _enabled = enabled;
    if (autoCurrentAccount != null) _autoCurrentAccount = autoCurrentAccount;
    if (intervalMinutes != null) {
      _intervalMinutes = max(minIntervalMinutes, intervalMinutes);
    }

    if (prevEnabled != _enabled || prevInterval != _intervalMinutes) {
      _rescheduleTimer();
    }
    if (_enabled && _autoCurrentAccount && (!prevEnabled || !prevAuto)) {
      _backupCurrentAccountImmediate();
    } else {
      _notify();
    }
  }

  void _onPreferencesChanged() {
    final prefs = _preferences?.prefs;
    if (prefs == null) return;
    configure(
      enabled: prefs.backupEnabled,
      autoCurrentAccount: prefs.backupAutoCurrentAccount,
      intervalMinutes: prefs.backupIntervalMinutes,
    );
  }

  /// 本机账号的收藏歌曲或歌单发生任何增删改时，立即落盘，不等定时轮询。
  void _onLibraryChanged() {
    if (!_enabled || !_autoCurrentAccount) return;
    final library = _library;
    if (library == null) return;
    if (identical(library.likedTracks, _lastLocalLiked) &&
        identical(library.playlists, _lastLocalPlaylists)) {
      return;
    }
    _backupCurrentAccountImmediate();
  }

  void _backupCurrentAccountImmediate() {
    final library = _library;
    if (library == null) return;
    // 只在「确实是这个账号、且媒体库已加载完」时落盘：
    // - 未登录 / 刚退出：媒体库被清空，不能拿空数据覆盖备份；
    // - 加载中 / 用户名还没解析出来：可能是上一个账号的残留或半截数据。
    if (!_auth.isLoggedIn || library.isLoading) return;
    final id = _auth.username.trim();
    if (id.isEmpty) return;
    // 媒体库数据必须属于这个账号：换号时媒体库先清空、拉完新数据才标记归属，
    // 中间任何时刻（定时器、设置变化）触发都不能把空数据或上一个账号的数据写成本账号的备份
    if (_libraryCache.libraryAccount != id) return;
    // 读取失败时媒体库可能是空的或残缺的：等下次读取成功再备份，不覆盖已有的完整备份
    if (library.loadError != null) return;

    final liked = library.likedTracks;
    final playlists = library.playlists
        .where(
          (p) =>
              !p.id.endsWith('_liked') &&
              !p.id.startsWith(BackupAccount.backupLikedPrefix),
        )
        .toList();
    _lastLocalLiked = liked;
    _lastLocalPlaylists = library.playlists;

    final email = _auth.email.trim();
    final displayName = _auth.displayName.trim().isNotEmpty
        ? _auth.displayName.trim()
        : (email.isNotEmpty ? email : id);

    bool isSelf(BackupAccount a) =>
        a.id == id || (email.isNotEmpty && a.email.trim() == email);

    // 换了账号：之前登录账号的备份降级为「以前登录的账号」保留，并在设置里显示出来
    var accounts = [
      for (final a in _accounts)
        if (a.isCurrentAccount && !isSelf(a))
          a.copyWith(isCurrentAccount: false)
        else
          a,
    ];
    // 同一账号以前作为外部账号 / 以前登录过：并入当前账号这一条，不留重复
    final existingIndex = accounts.indexWhere(isSelf);
    final existing = existingIndex >= 0 ? accounts[existingIndex] : null;
    final updated = BackupAccount(
      id: id,
      email: email,
      displayName: displayName,
      avatarUrl: _auth.avatarUrl,
      isCurrentAccount: true,
      syncToLocal: existing?.syncToLocal ?? true,
      lastBackupAt: _now(),
      likedTracks: List.unmodifiable(liked),
      playlists: List.unmodifiable(playlists),
    );
    accounts = [
      for (var i = 0; i < accounts.length; i++)
        if (i != existingIndex) accounts[i],
    ];
    _accounts = List.unmodifiable([updated, ...accounts]);
    _persistToDisk();
    _notify();
  }

  /// 当前登录账号的备份记录（设置页不显示它；切换到别的账号后它才作为「以前登录的账号」出现）。
  /// 只认「标记为当前账号且就是现在登录的这个号」：换号后即使还没来得及备份新账号
  /// （例如关闭了自动备份），旧账号的记录也会立即作为「以前登录的账号」显示出来。
  bool isLiveCurrentAccount(BackupAccount account) {
    if (!account.isCurrentAccount || !_auth.isLoggedIn) return false;
    final id = _auth.username.trim();
    final email = _auth.email.trim();
    return (id.isNotEmpty && account.id == id) ||
        (email.isNotEmpty && account.email.trim() == email);
  }

  /// 设置页「歌单备份」里显示的账号：隐藏当前登录账号自己的备份。
  List<BackupAccount> get visibleAccounts => [
    for (final a in _accounts)
      if (!isLiveCurrentAccount(a)) a,
  ];

  /// 若磁盘上已有外部账号的已点赞歌曲或歌单曲目为空（如旧版本留下的 0 首记录），自动拉取补齐落盘。
  Future<void> _hydrateIncompleteAccounts() async {
    var changed = false;
    final nextAccounts = <BackupAccount>[];
    for (final account in _accounts) {
      if (account.isCurrentAccount) {
        nextAccounts.add(account);
        continue;
      }
      final needsHydrate =
          account.likedTracks.isEmpty ||
          account.playlists.any((p) => p.tracks.isEmpty);
      if (needsHydrate &&
          (account.accessToken.isNotEmpty || account.spDc.isNotEmpty)) {
        try {
          final snap = await _fetchSnapshot(
            BackupSessionCredentials(
              spDc: account.spDc,
              accessToken: account.accessToken,
              clientToken: account.clientToken,
              userId: account.id,
              email: account.email,
              displayName: account.displayName,
              avatarUrl: account.avatarUrl,
              profileDir: account.profileDir,
            ),
          );
          if (snap.likedTracks.isNotEmpty ||
              snap.playlists.any((p) => p.tracks.isNotEmpty)) {
            nextAccounts.add(
              account.copyWith(
                likedTracks: snap.likedTracks.isNotEmpty
                    ? List.unmodifiable(snap.likedTracks)
                    : account.likedTracks,
                playlists: snap.playlists.isNotEmpty
                    ? List.unmodifiable(snap.playlists)
                    : account.playlists,
                lastBackupAt: _now(),
              ),
            );
            changed = true;
            continue;
          }
        } catch (_) {}
      }
      nextAccounts.add(account);
    }
    if (changed && !_disposed) {
      _accounts = List.unmodifiable(nextAccounts);
      _persistToDisk();
      _notify();
    }
  }

  Future<BackupAccountSnapshot> _fetchSnapshot(
    BackupSessionCredentials credentials,
  ) {
    final custom = _customRemoteFetcher;
    if (custom != null) {
      return custom(credentials.spDc);
    }
    return _sessionFetcher.fetchWithSession(credentials);
  }

  /// 通过独立 WebView 拿到的会话凭据添加（或更新）外部备份账号，按唯一识别符（邮箱 / 唯一 ID）去重并落盘。
  Future<BackupAccount> addAccountWithSession(
    BackupSessionCredentials credentials,
  ) async {
    final cleanSpDc = credentials.spDc.trim();
    if (cleanSpDc.isEmpty && credentials.accessToken.trim().isEmpty) {
      throw ArgumentError('WebView 会话凭据不能为空');
    }
    _isBackingUp = true;
    _lastError = null;
    _notify();
    try {
      final snapshot = await _fetchSnapshot(credentials);
      final resolvedEmail = snapshot.email.trim().isNotEmpty
          ? snapshot.email.trim()
          : credentials.email.trim();
      final resolvedId = snapshot.id.trim().isNotEmpty
          ? snapshot.id.trim()
          : credentials.userId.trim();
      final existingIndex = _accounts.indexWhere(
        (a) =>
            !a.isCurrentAccount &&
            a.matchesIdentity(otherId: resolvedId, otherEmail: resolvedEmail),
      );
      final account = BackupAccount(
        id: resolvedId,
        email: resolvedEmail,
        displayName: snapshot.displayName,
        avatarUrl: snapshot.avatarUrl,
        spDc: cleanSpDc,
        accessToken: credentials.accessToken.trim(),
        clientToken: credentials.clientToken.trim(),
        profileDir: credentials.profileDir.isNotEmpty
            ? credentials.profileDir
            : (existingIndex >= 0 ? _accounts[existingIndex].profileDir : ''),
        isCurrentAccount: false,
        syncToLocal: existingIndex >= 0
            ? _accounts[existingIndex].syncToLocal
            : true,
        lastBackupAt: _now(),
        likedTracks: List.unmodifiable(snapshot.likedTracks),
        playlists: List.unmodifiable(snapshot.playlists),
      );
      if (existingIndex >= 0) {
        _accounts = [..._accounts]..[existingIndex] = account;
      } else {
        _accounts = [..._accounts, account];
      }
      _persistToDisk();
      return account;
    } catch (e) {
      _lastError = '备份账号失败：$e';
      rethrow;
    } finally {
      _isBackingUp = false;
      _notify();
    }
  }

  /// 兼容仅传 `spDc` 的添加方式。
  Future<BackupAccount> addAccountWithSpDc(
    String spDc, {
    String accessToken = '',
    String clientToken = '',
    String userId = '',
    String email = '',
    String displayName = '',
    String avatarUrl = '',
    String profileDir = '',
  }) => addAccountWithSession(
    BackupSessionCredentials(
      spDc: spDc,
      accessToken: accessToken,
      clientToken: clientToken,
      userId: userId,
      email: email,
      displayName: displayName,
      avatarUrl: avatarUrl,
      profileDir: profileDir,
    ),
  );

  /// 立即执行一次全量备份（本机账号 + 所有已添加的外部账号）并落盘。
  Future<void> backupAllAccounts() async {
    if (_isBackingUp) return;
    _isBackingUp = true;
    _lastError = null;
    _notify();
    try {
      if (_autoCurrentAccount) {
        _backupCurrentAccountImmediate();
      }
      final updated = <BackupAccount>[];
      for (final account in _accounts) {
        if (account.isCurrentAccount) {
          updated.add(account);
          continue;
        }
        if (account.spDc.isEmpty && account.accessToken.isEmpty) {
          updated.add(account);
          continue;
        }
        try {
          final snapshot = await _fetchSnapshot(
            BackupSessionCredentials(
              spDc: account.spDc,
              accessToken: account.accessToken,
              clientToken: account.clientToken,
              userId: account.id,
              email: account.email,
              displayName: account.displayName,
              avatarUrl: account.avatarUrl,
              profileDir: account.profileDir,
            ),
          );
          updated.add(
            account.copyWith(
              id: snapshot.id.isNotEmpty ? snapshot.id : account.id,
              email: snapshot.email.isNotEmpty ? snapshot.email : account.email,
              displayName: snapshot.displayName,
              avatarUrl: snapshot.avatarUrl,
              lastBackupAt: _now(),
              likedTracks: List.unmodifiable(snapshot.likedTracks),
              playlists: List.unmodifiable(snapshot.playlists),
            ),
          );
        } catch (e) {
          _lastError ??= '账号 ${account.title} 备份失败：$e';
          updated.add(account);
        }
      }
      _accounts = List.unmodifiable(updated);
      _persistToDisk();
    } finally {
      _isBackingUp = false;
      _notify();
    }
  }

  /// 正在后台导入（设置页据此禁用导入按钮、显示进度）。
  bool get isImporting => _isImporting;
  bool _isImporting = false;

  /// 将所选的备份歌曲列表一键**合并**导入到当前账号的「已点赞的歌曲」（Liked Songs）。
  /// 本地一次合并，同步到 Spotify 在后台逐首进行，不阻塞界面。
  Future<int> importSelectedTracksToLiked(List<SpotifyTrack> tracks) async {
    final library = _library;
    if (library == null || tracks.isEmpty) return 0;
    return _runImport(() => library.likeTracks(tracks));
  }

  /// 将所选的备份歌单列表一键导入到当前账号（在后台进行，不阻塞界面）：
  /// - 若选中的包含某账号的「已点赞的歌曲」（`backup_liked_*`），将其歌曲合并进当前账号的 Liked Songs；
  /// - 普通歌单保留真实歌单 ID 导入到当前账号歌单列表。
  Future<BackupSyncResult> importSelectedPlaylists(
    List<SpotifyPlaylist> playlists,
  ) async {
    final library = _library;
    if (library == null || playlists.isEmpty) {
      return const BackupSyncResult(addedLikedTracks: 0, syncedPlaylists: 0);
    }
    final likedTracks = <SpotifyTrack>[];
    final synced = <SpotifyPlaylist>[];
    for (final playlist in playlists) {
      if (playlist.id.startsWith(BackupAccount.backupLikedPrefix) ||
          playlist.id == BackupLibraryPort.likedSongsId) {
        likedTracks.addAll(playlist.tracks);
        continue;
      }
      if (playlist.id.isEmpty) continue;
      synced.add(
        playlist.copyWith(
          uri: playlist.uri.isNotEmpty
              ? playlist.uri
              : 'spotify:playlist:${playlist.id}',
          totalTracks: playlist.tracks.isNotEmpty
              ? playlist.tracks.length
              : playlist.totalTracks,
        ),
      );
    }
    var addedTracks = 0;
    await _runImport(() {
      addedTracks = library.likeTracks(likedTracks);
      library.upsertLocalPlaylists(synced);
      return 0;
    });
    return BackupSyncResult(
      addedLikedTracks: addedTracks,
      syncedPlaylists: synced.length,
    );
  }

  /// 导入期间暂停「媒体库一变就备份」，结束后只备份一次。
  /// 先让出一帧，界面能立刻显示「后台导入中」再开始合并。
  Future<int> _runImport(int Function() work) async {
    _isImporting = true;
    _notify();
    await Future<void>.delayed(Duration.zero);
    final wasAuto = _autoCurrentAccount;
    _autoCurrentAccount = false;
    try {
      return work();
    } finally {
      _autoCurrentAccount = wasAuto;
      _isImporting = false;
      if (_enabled && _autoCurrentAccount) {
        _backupCurrentAccountImmediate();
      } else {
        _notify();
      }
    }
  }

  /// 一键将已勾选备份账号的全部歌单与已点赞歌曲同步到本机当前账号。
  Future<BackupSyncResult> syncToCurrentAccount() async {
    final selected = <SpotifyPlaylist>[];
    // 不含当前登录账号自己：把自己的歌单「导入」给自己只会在本机歌单里多出一份重复副本
    for (final account in visibleAccounts) {
      if (!account.syncToLocal) continue;
      selected.addAll(account.backedUpPlaylists);
    }
    return importSelectedPlaylists(selected);
  }

  void setAccountSyncEnabled(String accountKey, bool syncToLocal) {
    final index = _accounts.indexWhere(
      (a) => a.uniqueId == accountKey || a.id == accountKey,
    );
    if (index < 0) return;
    _accounts = [..._accounts]
      ..[index] = _accounts[index].copyWith(syncToLocal: syncToLocal);
    _persistToDisk();
    _notify();
  }

  void removeAccount(String accountKey) {
    final before = _accounts.length;
    _accounts = _accounts
        .where((a) => a.uniqueId != accountKey && a.id != accountKey)
        .toList();
    if (_accounts.length == before) return;
    _persistToDisk();
    _notify();
  }

  void _rescheduleTimer() {
    _timer?.cancel();
    _timer = null;
    if (!_enabled || !_enablePeriodicTimer) return;
    _timer = Timer.periodic(effectiveInterval, (_) {
      unawaited(backupAllAccounts());
    });
  }

  void _loadFromDisk() {
    final file = _diskFile;
    if (file != null) {
      final fromFile = _readBackupFile(file);
      if (fromFile != null) {
        _accounts = fromFile;
        return;
      }
      if (file.existsSync()) {
        // 主文件损坏：留一份原样副本，免得之后的落盘把它覆盖掉
        try {
          file.copySync('${file.path}.corrupt');
        } catch (_) {}
      }
      // 上次写到一半（主文件缺失 / 损坏）：用完整写好的临时文件恢复
      final fromTmp = _readBackupFile(File('${file.path}.tmp'));
      if (fromTmp != null) {
        _accounts = fromTmp;
        _persistToDisk();
        return;
      }
    }
    final list = _libraryCache.readJsonList(LibraryCacheStore.keyPlaylistBackups);
    _accounts = List.unmodifiable(list.map(BackupAccount.fromJson));
    // 旧版本存在 SharedPreferences 里：迁移到独立文件后清掉，偏好文件不再背着整份备份
    if (file != null && list.isNotEmpty) {
      _persistToDisk();
      unawaited(_libraryCache.writeJsonList(LibraryCacheStore.keyPlaylistBackups, const []));
    }
  }

  /// 落盘排队：备份可能很大（多个账号的全部歌单曲目），编码放到后台 Isolate、文件异步写，
  /// 不卡界面；连续多次触发时串行执行，最后一次的内容最终落盘。
  Future<void> _persistQueue = Future.value();

  /// 等待排队中的落盘写完（测试用）。
  @visibleForTesting
  Future<void> get pendingPersist => _persistQueue;

  static List<BackupAccount>? _readBackupFile(File file) {
    try {
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return null;
      return List.unmodifiable(
        decoded.whereType<Map<String, dynamic>>().map(BackupAccount.fromJson),
      );
    } catch (_) {
      return null;
    }
  }

  void _persistToDisk() {
    final serialized = [for (final a in _accounts) a.toJson()];
    final file = _diskFile;
    if (file == null) {
      unawaited(
        _libraryCache.writeJsonList(LibraryCacheStore.keyPlaylistBackups, serialized),
      );
      return;
    }
    // 有独立文件时不再写进 SharedPreferences：备份可能很大，偏好文件每次保存都会整份重写
    _persistQueue = _persistQueue.then((_) async {
      try {
        final text = await Isolate.run(() => jsonEncode(serialized));
        if (RustCore.ready) {
          try {
            await rust.rustWriteBackupFileAtomic(
              filePath: file.path,
              content: text,
            );
            return;
          } catch (_) {}
        }
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(text, flush: true);
        try {
          // 原子替换：任何时刻磁盘上都有一份完整的备份（旧的或新的）
          await tmp.rename(file.path);
        } on FileSystemException {
          // 目标被其他程序短暂占用（杀毒 / 同步盘）：退回直接覆盖写入
          await file.writeAsString(text, flush: true);
        }
      } catch (_) {}
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _library?.removeListener(_onLibraryChanged);
    _preferences?.removeListener(_onPreferencesChanged);
    super.dispose();
  }
}
