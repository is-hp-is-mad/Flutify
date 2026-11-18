import 'package:flutter/foundation.dart';

import '../../models/image.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';

/// 从独立 WebView 会话拿到的账号凭据与收藏快照。
class BackupAccountSnapshot {
  /// Spotify 唯一用户名 ID（canonical username）。
  final String id;

  /// 账户唯一邮箱（若接口返回则优先作为唯一识别符展示）。
  final String email;

  /// 账号昵称（可能与其他账号重名，仅作辅助展示，不作主键）。
  final String displayName;
  final String avatarUrl;
  final List<SpotifyTrack> likedTracks;
  final List<SpotifyPlaylist> playlists;

  const BackupAccountSnapshot({
    required this.id,
    required this.displayName,
    this.email = '',
    this.avatarUrl = '',
    this.likedTracks = const [],
    this.playlists = const [],
  });

  /// 账户唯一识别符：优先使用邮箱，无邮箱时使用 Spotify 唯一用户名 ID。
  String get uniqueId {
    final mail = email.trim();
    if (mail.isNotEmpty) return mail;
    return id.trim();
  }
}

/// 独立 WebView 登录捕获到的会话信息。
class BackupSessionCredentials {
  final String spDc;
  final String accessToken;
  final String clientToken;
  final String userId;
  final String email;
  final String displayName;
  final String avatarUrl;
  final String profileDir;

  const BackupSessionCredentials({
    required this.spDc,
    this.accessToken = '',
    this.clientToken = '',
    this.userId = '',
    this.email = '',
    this.displayName = '',
    this.avatarUrl = '',
    this.profileDir = '',
  });
}

typedef BackupRemoteFetcher =
    Future<BackupAccountSnapshot> Function(String spDc);

/// 单个已备份账号的落盘快照。
///
/// - 主键与展示均采用账户唯一识别符（[uniqueId]：优先邮箱 [email]，其次 Spotify 唯一用户名 [id]），
///   即使多个账号昵称（[displayName]）完全相同也不会冲突或覆盖；
/// - 每个账号提供独立的 [likedSongsPlaylist]（`id: 'backup_liked_<uniqueId>'`），点击可查看该账号自己的
///   已点赞歌曲（不会跳去当前登录账号的已点赞歌曲），并支持勾选其中部分歌曲一键合并导入到本账号；
/// - 歌单保留真实的 Spotify 歌单 ID（与分享歌单链接 `https://open.spotify.com/playlist/{id}` 一致）。
@immutable
class BackupAccount {
  static const String localAccountFallbackId = 'local_current_account';
  static const String backupLikedPrefix = 'backup_liked_';

  /// Spotify 唯一用户名 ID（canonical username）。
  final String id;

  /// 账户唯一邮箱（如 `user@example.com`）。
  final String email;

  /// 账户昵称（可重复，不作唯一键）。
  final String displayName;
  final String avatarUrl;

  /// 独立 WebView 登录捕获的 `sp_dc`（本机当前账号为空，直接读本地媒体库）。
  final String spDc;

  /// 独立 WebView 页面自身的会话 `accessToken`。
  final String accessToken;

  /// 独立 WebView 页面自身的 `client-token`。
  final String clientToken;

  /// 独立 WebView 资料目录名（多账号隔离 Cookie / Storage）。
  final String profileDir;

  /// 是否为本机当前已登录的账号。
  final bool isCurrentAccount;

  /// 一键同步到本账号时是否包含该账号的备份歌单与收藏歌曲。
  final bool syncToLocal;

  final DateTime? lastBackupAt;
  final List<SpotifyTrack> likedTracks;
  final List<SpotifyPlaylist> playlists;

  const BackupAccount({
    required this.id,
    required this.displayName,
    this.email = '',
    this.avatarUrl = '',
    this.spDc = '',
    this.accessToken = '',
    this.clientToken = '',
    this.profileDir = '',
    this.isCurrentAccount = false,
    this.syncToLocal = true,
    this.lastBackupAt,
    this.likedTracks = const [],
    this.playlists = const [],
  });

  /// 账户唯一识别符：优先使用邮箱 [email]，无邮箱时使用 Spotify 唯一用户名 [id]。
  String get uniqueId {
    final mail = email.trim();
    if (mail.isNotEmpty) return mail;
    return id.trim();
  }

  /// 展示标题：以唯一识别符为主（若昵称与唯一识别符不同，则显示「唯一识别符（昵称）」），
  /// 确保同名账号在界面与同步歌单中绝不混淆。
  String get title {
    final uid = uniqueId;
    final name = displayName.trim();
    if (uid.isNotEmpty && name.isNotEmpty && name != uid) {
      return '$uid（$name）';
    }
    return uid.isNotEmpty ? uid : name;
  }

  /// 该账号自己的「已点赞的歌曲」歌单：
  /// 使用专属 `backup_liked_<uniqueId>` 作为 ID，使详情页直接展示该账号的 [likedTracks]。
  SpotifyPlaylist get likedSongsPlaylist => SpotifyPlaylist(
    id: '$backupLikedPrefix$uniqueId',
    name: '$title · 已点赞的歌曲',
    uri: 'spotify:playlist:$backupLikedPrefix$uniqueId',
    ownerName: title,
    images: const [
      SpotifyImage(
        url: 'https://misc.scdn.co/liked-songs/liked-songs-640.png',
      ),
    ],
    tracks: likedTracks,
    totalTracks: likedTracks.length,
    primaryColor: '#450af5',
  );

  /// 该账号下的全部备份条目（该账号自己的「已点赞的歌曲」+ 该账号的收藏歌单）。
  List<SpotifyPlaylist> get backedUpPlaylists => [
    if (likedTracks.isNotEmpty) likedSongsPlaylist,
    for (final p in playlists)
      p.copyWith(
        ownerName: p.ownerName.isNotEmpty && p.ownerName != 'Spotify'
            ? p.ownerName
            : title,
        totalTracks: p.tracks.isNotEmpty ? p.tracks.length : p.totalTracks,
      ),
  ];

  /// 判断两个账号记录是否属于同一个 Spotify 账户（按唯一 ID 或唯一邮箱比对，绝不按昵称比对）。
  bool matchesIdentity({required String otherId, required String otherEmail}) {
    final aId = id.trim();
    final bId = otherId.trim();
    if (aId.isNotEmpty && bId.isNotEmpty && aId == bId) return true;
    final aMail = email.trim().toLowerCase();
    final bMail = otherEmail.trim().toLowerCase();
    if (aMail.isNotEmpty && bMail.isNotEmpty && aMail == bMail) return true;
    return false;
  }

  BackupAccount copyWith({
    String? id,
    String? email,
    String? displayName,
    String? avatarUrl,
    String? spDc,
    String? accessToken,
    String? clientToken,
    String? profileDir,
    bool? isCurrentAccount,
    bool? syncToLocal,
    DateTime? lastBackupAt,
    List<SpotifyTrack>? likedTracks,
    List<SpotifyPlaylist>? playlists,
  }) {
    return BackupAccount(
      id: id ?? this.id,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      spDc: spDc ?? this.spDc,
      accessToken: accessToken ?? this.accessToken,
      clientToken: clientToken ?? this.clientToken,
      profileDir: profileDir ?? this.profileDir,
      isCurrentAccount: isCurrentAccount ?? this.isCurrentAccount,
      syncToLocal: syncToLocal ?? this.syncToLocal,
      lastBackupAt: lastBackupAt ?? this.lastBackupAt,
      likedTracks: likedTracks ?? this.likedTracks,
      playlists: playlists ?? this.playlists,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    'displayName': displayName,
    'avatarUrl': avatarUrl,
    'spDc': spDc,
    'accessToken': accessToken,
    'clientToken': clientToken,
    'profileDir': profileDir,
    'isCurrentAccount': isCurrentAccount,
    'syncToLocal': syncToLocal,
    'lastBackupAt': lastBackupAt?.toIso8601String(),
    'likedTracks': [for (final t in likedTracks) t.toJson()],
    'playlists': [for (final p in playlists) p.toJson()],
  };

  static String _normalizePlaylistId(String rawId) {
    if (!rawId.startsWith('backup_')) return rawId;
    final rest = rawId.substring('backup_'.length);
    final lastUnderscore = rest.lastIndexOf('_');
    if (lastUnderscore <= 0 || lastUnderscore + 1 >= rest.length) return rawId;
    return rest.substring(lastUnderscore + 1);
  }

  factory BackupAccount.fromJson(Map<String, dynamic> json) {
    final rawLiked = json['likedTracks'];
    final rawPlaylists = json['playlists'];
    final lastBackupRaw = json['lastBackupAt'];
    final playlists = rawPlaylists is List
        ? rawPlaylists
              .whereType<Map<String, dynamic>>()
              .map(SpotifyPlaylist.fromJson)
              .where(
                (p) =>
                    !p.id.endsWith('_liked') &&
                    !p.id.startsWith(backupLikedPrefix),
              )
              .map((p) {
                final cleanId = _normalizePlaylistId(p.id);
                return cleanId == p.id
                    ? p
                    : p.copyWith(
                        id: cleanId,
                        uri: 'spotify:playlist:$cleanId',
                      );
              })
              .toList()
        : const <SpotifyPlaylist>[];
    return BackupAccount(
      id: json['id'] as String? ?? '',
      email: json['email'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      avatarUrl: json['avatarUrl'] as String? ?? '',
      spDc: json['spDc'] as String? ?? '',
      accessToken: json['accessToken'] as String? ?? '',
      clientToken: json['clientToken'] as String? ?? '',
      profileDir: json['profileDir'] as String? ?? '',
      isCurrentAccount: json['isCurrentAccount'] as bool? ?? false,
      syncToLocal: json['syncToLocal'] as bool? ?? true,
      lastBackupAt: lastBackupRaw is String
          ? DateTime.tryParse(lastBackupRaw)
          : null,
      likedTracks: rawLiked is List
          ? rawLiked
                .whereType<Map<String, dynamic>>()
                .map(SpotifyTrack.fromJson)
                .toList()
          : const [],
      playlists: playlists,
    );
  }
}

/// 一键同步 / 导入备份到当前账号的结果统计。
@immutable
class BackupSyncResult {
  final int addedLikedTracks;
  final int syncedPlaylists;

  const BackupSyncResult({
    required this.addedLikedTracks,
    required this.syncedPlaylists,
  });
}
