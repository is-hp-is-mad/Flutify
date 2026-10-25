import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../../../../core/utils/byte_size.dart';
import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';
import '../../../../services/protocol/audio_cache_store.dart';
import '../../../../services/cache/cache_location.dart';
import '../../../../providers/spotify_provider.dart';
import '../../../../services/eme/eme_player.dart';
import '../../../../core/utils/artwork_palette.dart';
import '../../../../services/storage_service.dart';
import '../widgets/settings_menu_field.dart';
import '../widgets/settings_section.dart';
import '../widgets/settings_segmented.dart';
import '../../../widgets/toast/app_toast.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import '../../../widgets/flutify_dialog.dart';
import '../../../widgets/flutify_progress.dart';

/// 存储：音频缓存占用、缓存上限、一键清除。
///
/// - 占用在进入设置页、改上限、清除后重新统计（目录遍历放在异步里，不卡界面）；
/// - 上限改小后立即按「最久没播放先删」淘汰；正在播放与预取的下一首始终保留；
/// - 没有接入协议链路（[AudioCacheStore] 为 null，例如部分测试）时只显示上限。
class StorageSection extends StatefulWidget {
  const StorageSection({super.key});

  /// 可选上限（MB）：256 MB 约 30 首，5 GB 约 600 首（按 160 kbps、4 分钟一首估算）。
  static const List<int> limitsMb = [256, 512, 1024, 2048, 5120];

  @override
  State<StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends State<StorageSection> {
  AudioCacheStore? _store;
  late int _limitMb;
  int? _usedBytes;
  bool _clearing = false;

  Future<void> _changeLocation(
    CacheLocation location,
    CacheCategory category,
  ) async {
    final l10n = context.l10n;
    final result = await showDialog<CacheSelection>(
      context: context,
      builder: (_) => _LocationDialog(selection: location.selection(category)),
    );
    if (result == null || !mounted) return;
    setState(() => _clearing = true);
    try {
      final migrated = await location.change(category, result);
      if (!mounted) return;
      setState(() => _usedBytes = null);
      _refreshUsage();
      AppToast.show(
        context,
        l10n.settingsCacheMigrated(
          migrated.files,
          migrated.deferred,
          migrated.failed,
        ),
        tone: migrated.failed > 0 ? ToastTone.error : ToastTone.success,
      );
    } catch (_) {
      if (mounted)
        AppToast.show(
          context,
          l10n.settingsCacheLocationInvalid,
          tone: ToastTone.error,
        );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _clearAll(CacheLocation location) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => FlutifyDialog(
        title: l10n.settingsClearAllCache,
        content: Material(type: MaterialType.transparency, child: Text(l10n.settingsClearAllCacheHelp)),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.commonClear),
          ),
        ]),
    );
    if (confirmed != true || !mounted) return;
    final spotify = context.read<SpotifyProvider>();
    final eme = context.read<EmePlayer>();
    setState(() => _clearing = true);
    final result = CacheResult();
    try {
      ArtworkPalette.clear();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      for (final category in CacheCategory.values) {
        try {
          result.add(
            category == CacheCategory.lyrics
                ? await spotify.clearLyricsCache(
                    clearDisk: () => location.clearCategory(category),
                  )
                : await location.clearCategory(category),
          );
        } catch (_) {
          result.failed++;
        }
      }
      try {
        await eme.clearBrowserCache();
      } catch (_) {
        result.failed++;
      }
      if (mounted)
        AppToast.show(
          context,
          l10n.settingsCacheCleared(
            ByteSize.format(result.bytes),
            result.deferred,
            result.failed,
          ),
          tone: result.failed > 0 ? ToastTone.error : ToastTone.success,
        );
    } finally {
      if (mounted) {
        setState(() => _clearing = false);
        _refreshUsage();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _store = Provider.of<AudioCacheStore?>(context, listen: false);
    final saved = context.read<StorageService>().audioCacheLimitMb;
    // 存储里的值不在可选档位中（旧版本 / 手改）时取最接近的一档
    _limitMb = StorageSection.limitsMb.reduce(
      (a, b) => (a - saved).abs() <= (b - saved).abs() ? a : b,
    );
    _refreshUsage();
  }

  Future<void> _refreshUsage() async {
    final store = _store;
    if (store == null) return;
    final used = await store.sizeBytes();
    if (mounted) setState(() => _usedBytes = used);
  }

  void _setLimit(int mb) {
    setState(() => _limitMb = mb);
    context.read<StorageService>().setAudioCacheLimitMb(mb);
    _store?.maxCacheBytes = mb * ByteSize.mb;
    _refreshUsage();
  }

  Future<void> _confirmClear() async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => FlutifyDialog(
        title: l10n.settingsClearAudioCacheTitle,
        content: Material(type: MaterialType.transparency, child: Text(l10n.settingsClearAudioCacheMessage)),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.commonClear),
          ),
        ]),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      final location = context.read<CacheLocation?>();
      final result = location == null
          ? null
          : await location.clearCategory(CacheCategory.audio);
      final freed = result?.bytes ?? await _store!.clear();
      if (!mounted) return;
      AppToast.show(
        context,
        l10n.settingsCacheCleared(
          ByteSize.format(freed),
          result?.deferred ?? 0,
          result?.failed ?? 0,
        ),
        icon: Icons.cleaning_services_rounded,
        tone: (result?.failed ?? 0) > 0 ? ToastTone.error : ToastTone.success,
      );
    } catch (_) {
      if (mounted)
        AppToast.show(
          context,
          l10n.settingsCacheLocationInvalid,
          tone: ToastTone.error,
        );
    } finally {
      if (mounted) {
        setState(() => _clearing = false);
        _refreshUsage();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    final limitBytes = _limitMb * ByteSize.mb;
    final used = _usedBytes;
    final location = context.watch<CacheLocation?>();

    return SettingsSection(
      title: l10n.settingsStorageSection,
      children: [
        if (location != null) ...[
          if (!kIsWeb &&
              const {
                TargetPlatform.windows,
                TargetPlatform.linux,
                TargetPlatform.macOS,
              }.contains(defaultTargetPlatform))
            for (final category in CacheCategory.values)
              SettingsTile(
                title: switch (category) {
                  CacheCategory.audio => l10n.settingsAudioCacheLocation,
                  CacheCategory.artwork => l10n.settingsArtworkCacheLocation,
                  CacheCategory.lyrics => l10n.settingsLyricsCacheLocation,
                },
                subtitle: location.directory(category),
                trailing: const Icon(Icons.folder_open_rounded),
                onTap: _clearing
                    ? null
                    : () => _changeLocation(location, category),
              ),
          SettingsTile(
            title: l10n.settingsClearAllCache,
            subtitle: l10n.settingsClearAllCacheHelp,
            trailing: _clearing
                ? const SizedBox.square(
                    dimension: 20,
                    child: FlutifySpinner(size: 20),
                  )
                : const Icon(Icons.cleaning_services_rounded),
            onTap: _clearing ? null : () => _clearAll(location),
          ),
        ],
        if (_store != null)
          SettingsTile(
            title: l10n.settingsAudioCache,
            subtitle: used == null
                ? l10n.settingsAudioCacheCalculating
                : l10n.settingsAudioCacheUsage(
                    ByteSize.format(used),
                    ByteSize.format(limitBytes),
                  ),
            below: _UsageBar(
              fraction: used == null ? 0 : (used / limitBytes).clamp(0.0, 1.0),
            ),
          ),
        SettingsTile(
          title: l10n.settingsAudioCacheLimit,
          subtitle: l10n.settingsAudioCacheLimitSubtitle,
          below: SettingsSegmented<int>(
            values: StorageSection.limitsMb,
            labelOf: (mb) => ByteSize.format(mb * ByteSize.mb),
            selected: _limitMb,
            onChanged: _setLimit,
          ),
        ),
        if (_store != null)
          SettingsTile(
            title: l10n.settingsClearAudioCache,
            trailing: _clearing
                ? const SizedBox.square(
                    dimension: 20,
                    child: FlutifySpinner(size: 20),
                  )
                : Icon(
                    Icons.delete_sweep_rounded,
                    color: colorScheme.onSurfaceVariant,
                  ),
            onTap: _clearing || (used ?? 0) == 0 ? null : _confirmClear,
          ),
      ],
    );
  }
}

/// 占用条：细长胶囊，接近上限时转为警示色。
class _LocationDialog extends StatefulWidget {
  final CacheSelection selection;
  const _LocationDialog({required this.selection});
  @override
  State<_LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends State<_LocationDialog> {
  late CachePreset _preset = widget.selection.preset;
  late final _controller = TextEditingController(
    text: widget.selection.customPath,
  );
  bool _picking = false;
  bool _pickerFailed = false;

  Future<void> _pickDirectory() async {
    setState(() {
      _picking = true;
      _pickerFailed = false;
    });
    try {
      final path = await getDirectoryPath(
        initialDirectory: p.isAbsolute(_controller.text)
            ? _controller.text
            : null,
        confirmButtonText: context.l10n.settingsCacheChooseDirectory,
      );
      if (path != null && mounted) setState(() => _controller.text = path);
    } catch (_) {
      if (mounted) setState(() => _pickerFailed = true);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FlutifyDialog(
      title: l10n.settingsCacheLocation,
      content: Material(type: MaterialType.transparency, child: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.settingsCacheLocationHelp),
              const SizedBox(height: 16),
              // 柔光玻璃：用设置页同款下拉，菜单走澎湃 OS 4 弹出动画
              if (context.tokens.hyperMaterial)
                SettingsMenuField<CachePreset>(
                  buttonKey: const ValueKey('cache-preset'),
                  value: _preset,
                  semanticLabel: l10n.settingsCacheLocation,
                  onChanged: _picking
                      ? null
                      : (value) => setState(() => _preset = value),
                  options: [
                    SettingsMenuOption(
                      value: CachePreset.appData,
                      label: l10n.settingsCacheAppData,
                      icon: Icons.storage_rounded,
                    ),
                    SettingsMenuOption(
                      value: CachePreset.application,
                      label: l10n.settingsCacheApplication,
                      icon: Icons.apps_rounded,
                    ),
                    SettingsMenuOption(
                      value: CachePreset.custom,
                      label: l10n.settingsCacheCustom,
                      icon: Icons.folder_open_rounded,
                    ),
                  ],
                )
              else
              DropdownMenu<CachePreset>(
                key: const ValueKey('cache-preset'),
                initialSelection: _preset,
                expandedInsets: EdgeInsets.zero,
                enabled: !_picking,
                requestFocusOnTap: false,
                label: Text(l10n.settingsCacheLocation),
                inputDecorationTheme: InputDecorationThemeData(
                  filled: true,
                  fillColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: context.tokens.radius(16),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: context.tokens.radius(16),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: context.tokens.radius(16),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                  ),
                ),
                menuStyle: MenuStyle(
                  backgroundColor: WidgetStatePropertyAll(
                    Theme.of(context).colorScheme.surfaceContainer,
                  ),
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(
                      borderRadius: context.tokens.radius(16),
                    ),
                  ),
                  padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
                ),
                dropdownMenuEntries: [
                  DropdownMenuEntry(
                    value: CachePreset.appData,
                    label: l10n.settingsCacheAppData,
                    leadingIcon: const Icon(Icons.storage_rounded),
                  ),
                  DropdownMenuEntry(
                    value: CachePreset.application,
                    label: l10n.settingsCacheApplication,
                    leadingIcon: const Icon(Icons.apps_rounded),
                  ),
                  DropdownMenuEntry(
                    value: CachePreset.custom,
                    label: l10n.settingsCacheCustom,
                    leadingIcon: const Icon(Icons.folder_open_rounded),
                  ),
                ],
                onSelected: (value) {
                  if (value != null) setState(() => _preset = value);
                },
              ),
              if (_preset == CachePreset.custom) ...[
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('cache-custom-path'),
                  controller: _controller,
                  autocorrect: false,
                  enabled: !_picking,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: l10n.settingsCacheLocationHint,
                  ),
                ),
                const SizedBox(height: 8),
                M3EButton.icon(
                      style: M3EButtonStyle.tonal,
                  onPressed: _picking ? null : _pickDirectory,
                  icon: const Icon(Icons.folder_open_rounded),
                  label: Text(l10n.settingsCacheChooseDirectory),
                ),
                if (_pickerFailed)
                  Text(
                    l10n.settingsCachePickerFailed,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ],
          ),
        ),
      )),
      actions: [
        M3EButton.text(
          onPressed: _picking ? null : () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        M3EButton.filled(
          onPressed:
              _picking ||
                  (_preset == CachePreset.custom &&
                      !p.isAbsolute(_controller.text.trim()))
              ? null
              : () => Navigator.pop(
                  context,
                  CacheSelection(_preset, _controller.text.trim()),
                ),
          child: Text(l10n.settingsApply),
        ),
      ]);
  }
}

class _UsageBar extends StatelessWidget {
  final double fraction;

  const _UsageBar({required this.fraction});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return FlutifyLinearProgress(
      value: fraction,
      thickness: 6,
      trackColor: colorScheme.surfaceContainerHighest,
      color: fraction > 0.9 ? colorScheme.error : colorScheme.primary,
    );
  }
}
