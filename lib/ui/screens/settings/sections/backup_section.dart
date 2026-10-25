import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/app_preferences.dart';
import '../../../../models/playlist.dart';
import '../../../../models/track.dart';
import '../../../../providers/library_provider.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../../services/backup/playlist_backup_service.dart';
import '../../../navigation/app_routes.dart';
import '../../../widgets/cover_image.dart';
import '../../../widgets/menu/desktop_menu.dart';
import '../../../widgets/toast/app_toast.dart';
import '../../auth/backup_account_login_screen.dart';
import '../widgets/settings_section.dart';
import '../../../widgets/flutify_dialog.dart';
import '../../../widgets/flutify_progress.dart';

/// 设置页「歌单备份」分组：
/// - 显示各个备份账号各自的「已点赞的歌曲」（点击直接查看该账号的已点赞歌曲，不会跳去本机账号）；
/// - 无论是备份的歌单还是歌曲，均支持勾选其中一部分一键导入到当前账号。
class BackupSection extends StatefulWidget {
  const BackupSection({super.key, this.loginExternalAccount});

  /// 可选注入外部账号登录回调（测试用；默认打开独立 WebView 登录页 [BackupAccountLoginScreen]）。
  final Future<BackupLoginResult?> Function(BuildContext context)?
      loginExternalAccount;

  @override
  State<BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends State<BackupSection> {
  final Set<String> _selectedPlaylistIds = {};
  bool _initializedSelection = false;

  static String _intervalLabel(int minutes) => switch (minutes) {
    20 => '20 分钟',
    60 => '1 小时',
    120 => '2 小时',
    720 => '12 小时',
    1440 => '1 天',
    _ => '$minutes 分钟',
  };

  Future<void> _addAccount(
    BuildContext context,
    PlaylistBackupService service,
  ) async {
    final login = widget.loginExternalAccount ?? BackupAccountLoginScreen.open;
    final result = await login(context);
    if (result == null ||
        (result.spDc.isEmpty && result.accessToken.isEmpty) ||
        !context.mounted) {
      return;
    }
    try {
      final account = await service.addAccountWithSpDc(
        result.spDc,
        accessToken: result.accessToken,
        clientToken: result.clientToken,
        userId: result.userId,
        email: result.email,
        displayName: result.displayName,
        avatarUrl: result.avatarUrl,
        profileDir: result.profileDir,
      );
      if (!context.mounted) return;
      setState(() {
        for (final p in account.backedUpPlaylists) {
          _selectedPlaylistIds.add(p.id);
        }
      });
      AppToast.show(
        context,
        '已备份账号「${account.title}」（${account.likedTracks.length} 首已点赞歌曲，${account.playlists.length} 个歌单）',
        icon: Icons.check_circle_rounded,
        tone: ToastTone.success,
      );
    } catch (e) {
      if (!context.mounted) return;
      AppToast.show(
        context,
        '添加备份账号失败：$e',
        icon: Icons.error_outline_rounded,
        tone: ToastTone.error,
      );
    }
  }

  Future<void> _syncToCurrentAccount(
    BuildContext context,
    PlaylistBackupService service,
  ) async {
    final result = await service.syncToCurrentAccount();
    if (!context.mounted) return;
    AppToast.show(
      context,
      '已同步 ${result.syncedPlaylists} 个备份歌单、合并 ${result.addedLikedTracks} 首已点赞歌曲到本账号',
      icon: Icons.sync_rounded,
      tone: ToastTone.success,
    );
  }

  Future<void> _importSelectedPlaylists(
    BuildContext context,
    PlaylistBackupService service,
    List<SpotifyPlaylist> allPlaylists,
  ) async {
    final selected = [
      for (final p in allPlaylists)
        if (_selectedPlaylistIds.contains(p.id)) p,
    ];
    if (selected.isEmpty) return;
    // 在后台导入：先提示，界面不等待；完成后再提示结果
    AppToast.show(
      context,
      '正在后台导入 ${selected.length} 个歌单…',
      icon: Icons.downloading_rounded,
    );
    final result = await service.importSelectedPlaylists(selected);
    if (!context.mounted) return;
    AppToast.show(
      context,
      '已导入所选 ${result.syncedPlaylists} 个歌单、合并 ${result.addedLikedTracks} 首已点赞歌曲到本账号',
      icon: Icons.playlist_add_check_rounded,
      tone: ToastTone.success,
    );
  }

  Future<void> _backupNow(
    BuildContext context,
    PlaylistBackupService service,
  ) async {
    await service.backupAllAccounts();
    if (!context.mounted) return;
    final err = service.lastError;
    if (err != null) {
      AppToast.show(
        context,
        err,
        icon: Icons.warning_amber_rounded,
        tone: ToastTone.warning,
      );
    } else {
      AppToast.show(
        context,
        '已将全部备份账号的收藏歌单写入本地磁盘',
        icon: Icons.save_alt_rounded,
        tone: ToastTone.success,
      );
    }
  }

  Future<void> _openTrackPickerDialog(
    BuildContext context,
    PlaylistBackupService service,
    SpotifyPlaylist playlist,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _TrackImportDialog(
        playlist: playlist,
        backupService: service,
        library: context.read<LibraryProvider>(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prefsProvider = context.watch<PreferencesProvider>();
    final backupService = context.watch<PlaylistBackupService?>();
    final prefs = prefsProvider.prefs;
    final enabled = prefs.backupEnabled;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    void updatePrefs({
      bool? backupEnabled,
      bool? autoCurrent,
      int? intervalMinutes,
    }) {
      final next = prefs.copyWith(
        backupEnabled: backupEnabled,
        backupAutoCurrentAccount: autoCurrent,
        backupIntervalMinutes: intervalMinutes,
      );
      prefsProvider.update(next);
      backupService?.configure(
        enabled: next.backupEnabled,
        autoCurrentAccount: next.backupAutoCurrentAccount,
        intervalMinutes: next.backupIntervalMinutes,
      );
    }

    // 当前登录账号自己的备份不显示；切换到别的账号后它作为「以前登录的账号」出现
    final accounts = backupService?.visibleAccounts ?? const <BackupAccount>[];
    final playlists =
        backupService?.allBackedUpPlaylists ?? const <SpotifyPlaylist>[];
    final backingUp = backupService?.isBackingUp ?? false;
    final importing = backupService?.isImporting ?? false;

    if (!_initializedSelection && playlists.isNotEmpty) {
      _initializedSelection = true;
      for (final p in playlists) {
        _selectedPlaylistIds.add(p.id);
      }
    }
    final validIds = playlists.map((p) => p.id).toSet();
    final selectedCount = _selectedPlaylistIds.intersection(validIds).length;
    final allSelected =
        validIds.isNotEmpty && selectedCount == validIds.length;

    return SettingsSection(
      title: '歌单备份',
      footer: '支持查看各账号自己的已点赞歌曲与歌单；无论是备份的歌曲还是歌单，都支持勾选其中一部分一键导入到当前账号。',
      children: [
        SettingsSwitchTile(
          title: '启用歌单备份',
          subtitle: '支持本机账号自动备份与独立 WebView 多账号收藏歌单备份落盘',
          value: enabled,
          onChanged: (value) => updatePrefs(backupEnabled: value),
        ),
        if (enabled) ...[
          SettingsSwitchTile(
            title: '自动备份本机已登录的账号',
            subtitle: '本机账号的收藏更改立即落盘，不等定时轮询',
            value: prefs.backupAutoCurrentAccount,
            onChanged: (value) => updatePrefs(autoCurrent: value),
          ),
          SettingsTile(
            title: '自动备份频率',
            subtitle: '最短 20 分钟以防止触发服务端限流',
            trailing: context.tokens.hyperMaterial
                ? _HyperIntervalButton(
                    value: AppPreferences.backupIntervalOptions.contains(
                      prefs.backupIntervalMinutes,
                    )
                        ? prefs.backupIntervalMinutes
                        : AppPreferences.defaultBackupIntervalMinutes,
                    labelOf: _intervalLabel,
                    onChanged: (value) => updatePrefs(intervalMinutes: value),
                  )
                : DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: AppPreferences.backupIntervalOptions.contains(
                  prefs.backupIntervalMinutes,
                )
                    ? prefs.backupIntervalMinutes
                    : AppPreferences.defaultBackupIntervalMinutes,
                items: [
                  for (final minutes in AppPreferences.backupIntervalOptions)
                    DropdownMenuItem<int>(
                      value: minutes,
                      child: Text(_intervalLabel(minutes)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) updatePrefs(intervalMinutes: value);
                },
              ),
            ),
          ),
          if (backupService != null) ...[
            SettingsTile(
              title: '添加要同步歌单的账号',
              subtitle: '使用独立 WebView 资料登录 open.spotify.com 并读取其已收藏歌曲的歌单',
              trailing: backingUp
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: FlutifySpinner(size: 20),
                    )
                  : const Icon(Icons.person_add_alt_1_rounded),
              onTap: backingUp
                  ? null
                  : () => _addAccount(context, backupService),
            ),
            SettingsTile(
              title: '一键同步已备份的歌单到本账号',
              subtitle: '将下方已勾选账号的收藏歌曲合并进已点赞歌曲，并同步歌单到当前账号',
              trailing: const Icon(Icons.sync_rounded),
              onTap: accounts.isEmpty || backingUp
                  ? null
                  : () => _syncToCurrentAccount(context, backupService),
            ),
            SettingsTile(
              title: '立即备份全部账号',
              subtitle: '手动拉取各账号最新收藏并写入本地磁盘',
              trailing: const Icon(Icons.backup_rounded),
              onTap: backingUp
                  ? null
                  : () => _backupNow(context, backupService),
            ),
            for (final account in accounts)
              _BackupAccountTile(
                account: account,
                onToggleSync: (v) =>
                    backupService.setAccountSyncEnabled(account.uniqueId, v),
                onRemove: account.isCurrentAccount
                    ? null
                    : () => backupService.removeAccount(account.uniqueId),
              ),
            if (playlists.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        M3ECheckbox(
                          value: allSelected,
                          onChanged: (_) {
                            setState(() {
                              if (allSelected) {
                                _selectedPlaylistIds.removeAll(validIds);
                              } else {
                                _selectedPlaylistIds.addAll(validIds);
                              }
                            });
                          },
                        ),
                        Text(
                          '已落盘的备份歌单（已选 $selectedCount / ${playlists.length}）',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    M3EButton.icon(
                      style: M3EButtonStyle.tonal,
                      onPressed: selectedCount == 0 || backingUp || importing
                          ? null
                          : () => _importSelectedPlaylists(
                              context,
                              backupService,
                              playlists,
                            ),
                      icon: const Icon(
                        Icons.playlist_add_check_rounded,
                        size: 18,
                      ),
                      label: Text('一键导入所选歌单（$selectedCount）'),
                    ),
                  ],
                ),
              ),
            for (final playlist in playlists)
              _BackedUpPlaylistTile(
                playlist: playlist,
                selected: _selectedPlaylistIds.contains(playlist.id),
                onSelectedChanged: (v) {
                  setState(() {
                    if (v == true) {
                      _selectedPlaylistIds.add(playlist.id);
                    } else {
                      _selectedPlaylistIds.remove(playlist.id);
                    }
                  });
                },
                onPickTracks: playlist.tracks.isEmpty
                    ? null
                    : () => _openTrackPickerDialog(
                        context,
                        backupService,
                        playlist,
                      ),
              ),
          ],
        ],
      ],
    );
  }
}

class _BackupAccountTile extends StatelessWidget {
  final BackupAccount account;
  final ValueChanged<bool> onToggleSync;
  final VoidCallback? onRemove;

  const _BackupAccountTile({
    required this.account,
    required this.onToggleSync,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 没有会话凭据的账号是以前在本机登录过的账号（只保留最后一次的快照，不会再远程刷新）
    final badge = account.spDc.isEmpty && account.accessToken.isEmpty
        ? '以前登录的账号'
        : '外部备份账号';
    return SettingsTile(
      title: '${account.title}（$badge）',
      subtitle:
          '已落盘 ${account.likedTracks.length} 首已点赞歌曲 · ${account.playlists.length} 个歌单',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: '参与一键同步到本账号',
            child: M3ESwitch(
              value: account.syncToLocal,
              onChanged: onToggleSync,
            ),
          ),
          if (onRemove != null)
            IconButton(
              icon: Icon(
                Icons.delete_outline_rounded,
                color: colorScheme.error,
              ),
              tooltip: '移除该备份账号',
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}

/// 备份歌单行：
/// - 左侧复选框支持勾选部分歌单批量导入；
/// - 点击整行直接进入 [PlaylistDetailScreen] 查看该账号的已点赞歌曲或歌单（详情页内也可勾选部分歌曲导入）；
/// - 右侧「选歌导入」按钮可直接弹窗勾选该歌单内的一部分歌曲一键导入到本账号。
class _BackedUpPlaylistTile extends StatelessWidget {
  final SpotifyPlaylist playlist;
  final bool selected;
  final ValueChanged<bool?> onSelectedChanged;
  final VoidCallback? onPickTracks;

  const _BackedUpPlaylistTile({
    required this.playlist,
    required this.selected,
    required this.onSelectedChanged,
    this.onPickTracks,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    final isLiked = playlist.id.startsWith(BackupAccount.backupLikedPrefix);
    final backupService = context.read<PlaylistBackupService?>();
    final isExternalBackupLiked = isLiked &&
        (backupService?.isExternalBackupLikedPlaylist(playlist.id) ?? true);
    final count = playlist.tracks.isNotEmpty
        ? playlist.tracks.length
        : playlist.totalTracks;

    return InkWell(
      mouseCursor: SystemMouseCursors.click,
      borderRadius: context.tokens.radius(12),
      onTap: () => AppRoutes.openPlaylist(context, playlist),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            M3ECheckbox(value: selected, onChanged: onSelectedChanged),
            const SizedBox(width: 4),
            if (isLiked)
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: context.tokens.radius(8),
                  gradient: kLikedSongsGradient,
                ),
                child: const Icon(
                  Icons.favorite_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              )
            else
              CoverImage(
                url: playlist.coverUrl,
                size: 48,
                borderRadius: context.tokens.radius(8),
                placeholderIcon: Icons.queue_music_rounded,
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.subtitleJoin(playlist.ownerName, l10n.songCount(count)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onPickTracks != null)
              IconButton(
                icon: const Icon(Icons.checklist_rounded, size: 22),
                tooltip: isExternalBackupLiked
                    ? '选择部分歌曲一键导入到本账号'
                    : '多选收藏歌曲',
                onPressed: onPickTracks,
              ),
            Icon(
              Icons.chevron_right_rounded,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹窗勾选歌单或某账号「已点赞的歌曲」中的一部分歌曲，一键导入到当前账号。
class _TrackImportDialog extends StatefulWidget {
  final SpotifyPlaylist playlist;
  final PlaylistBackupService backupService;
  final LibraryProvider library;

  const _TrackImportDialog({
    required this.playlist,
    required this.backupService,
    required this.library,
  });

  @override
  State<_TrackImportDialog> createState() => _TrackImportDialogState();
}

class _TrackImportDialogState extends State<_TrackImportDialog> {
  late final Set<String> _selectedIds = {
    for (final t in widget.playlist.tracks)
      if (t.id.isNotEmpty) t.id,
  };

  List<SpotifyTrack> get _selectedTracks => [
    for (final t in widget.playlist.tracks)
      if (_selectedIds.contains(t.id)) t,
  ];

  @override
  Widget build(BuildContext context) {
    final tracks = widget.playlist.tracks;
    final allIds = tracks.map((t) => t.id).where((id) => id.isNotEmpty).toSet();
    final allSelected =
        allIds.isNotEmpty && _selectedIds.length == allIds.length;
    final isExternalBackupLiked = widget.backupService
        .isExternalBackupLikedPlaylist(widget.playlist.id);
    final selected = _selectedTracks;

    return FlutifyDialog(
      title: isExternalBackupLiked
          ? '选择要导入的歌曲 · ${widget.playlist.name}'
          : '多选收藏歌曲 · ${widget.playlist.name}',
      // CheckboxListTile 需要 Material 祖先
      content: Material(
        type: MaterialType.transparency,
        child: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                M3EButton.icon(
                  style: M3EButtonStyle.text,
                  onPressed: () {
                    setState(() {
                      if (allSelected) {
                        _selectedIds.clear();
                      } else {
                        _selectedIds.addAll(allIds);
                      }
                    });
                  },
                  icon: Icon(
                    allSelected
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    size: 20,
                  ),
                  label: Text(allSelected ? '取消全选' : '全选'),
                ),
                const Spacer(),
                Text('已选 ${selected.length} / ${tracks.length} 首'),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: tracks.length,
                itemBuilder: (context, index) {
                  final track = tracks[index];
                  final checked = _selectedIds.contains(track.id);
                  void toggle(bool? v) {
                    setState(() {
                      if (v == true) {
                        _selectedIds.add(track.id);
                      } else {
                        _selectedIds.remove(track.id);
                      }
                    });
                  }

                  return ListTile(
                    leading: M3ECheckbox(value: checked, onChanged: toggle),
                    onTap: () => toggle(!checked),
                    title: Text(
                      track.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      track.artistNames,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        ),
      ),
      actions: [
        M3EButton.text(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        if (isExternalBackupLiked)
          M3EButton.icon(
            style: M3EButtonStyle.outlined,
            onPressed: selected.isEmpty
                ? null
                : () {
                    final imported = widget.playlist.copyWith(
                      id: 'imported_${DateTime.now().millisecondsSinceEpoch}',
                      uri: '',
                      tracks: selected,
                      totalTracks: selected.length,
                    );
                    widget.library.upsertLocalPlaylist(imported);
                    Navigator.of(context).pop();
                    AppToast.show(
                      context,
                      '已将所选 ${selected.length} 首歌曲作为歌单「${widget.playlist.name}」导入到本账号',
                      icon: Icons.playlist_add_check_rounded,
                      tone: ToastTone.success,
                    );
                  },
            icon: const Icon(Icons.library_add_rounded, size: 18),
            label: Text('导入所选为歌单（${selected.length}）'),
          ),
        M3EButton.icon(
          style: M3EButtonStyle.filled,
          onPressed: selected.isEmpty
              ? null
              : () async {
                  final added = await widget.backupService
                      .importSelectedTracksToLiked(selected);
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                  AppToast.show(
                    context,
                    isExternalBackupLiked
                        ? '已将所选 ${selected.length} 首歌曲合并导入到本账号「已点赞的歌曲」（新增 $added 首）'
                        : '已收藏所选 ${selected.length} 首歌曲（新增 $added 首）',
                    icon: Icons.favorite_rounded,
                    tone: ToastTone.success,
                  );
                },
          icon: const Icon(Icons.favorite_rounded, size: 18),
          label: Text(
            isExternalBackupLiked
                ? '合并到已点赞歌曲（${selected.length}）'
                : '收藏所选歌曲（${selected.length}）',
          ),
        ),
      ],
    );
  }
}

/// 柔光玻璃模式下的「自动备份频率」选择：当前值 + 下拉箭头，点开澎湃 OS 4 菜单。
class _HyperIntervalButton extends StatelessWidget {
  final int value;
  final String Function(int minutes) labelOf;
  final ValueChanged<int> onChanged;

  const _HyperIntervalButton({
    required this.value,
    required this.labelOf,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return FlutifyPopupMenuButton<int>(
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final minutes in AppPreferences.backupIntervalOptions)
          DesktopMenu.check(minutes, labelOf(minutes), checked: minutes == value),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(labelOf(value)),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down_rounded),
          ],
        ),
      ),
    );
  }
}
