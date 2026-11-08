import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/utils/byte_size.dart';
import '../../../../l10n/l10n.dart';
import '../../../../providers/spotify_provider.dart';
import '../widgets/settings_section.dart';
import '../../../widgets/toast/app_toast.dart';

/// 隐私：清除搜索记录、清除歌词缓存。
///
/// 两项都只影响本机；没有内容可清时置灰不可点。清除后用 SnackBar 简短确认。
class PrivacySection extends StatelessWidget {
  const PrivacySection({super.key});

  void _done(BuildContext context) {
    AppToast.show(
      context,
      context.l10n.settingsCleared,
      icon: Icons.delete_sweep_rounded,
      tone: ToastTone.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final spotify = context.read<SpotifyProvider>();
    final (searchCount, lyricsCount) = context
        .select<SpotifyProvider, (int, int)>(
          (p) => (p.recentSearches.length, p.cachedLyricsCount),
        );

    return SettingsSection(
      title: l10n.settingsPrivacySection,
      children: [
        _ActionTile(
          title: l10n.settingsClearSearchHistory,
          subtitle: searchCount == 0
              ? l10n.settingsSearchHistoryEmpty
              : l10n.settingsSearchHistoryCount(searchCount),
          icon: Icons.manage_search_rounded,
          onTap: searchCount == 0
              ? null
              : () {
                  spotify.clearRecentSearches();
                  _done(context);
                },
        ),
        _ActionTile(
          title: l10n.settingsClearLyricsCache,
          subtitle: l10n.settingsClearLyricsCacheSubtitle,
          icon: Icons.lyrics_outlined,
          onTap: lyricsCount == 0
              ? null
              : () async {
                  try {
                    final result = await spotify.clearLyricsCache();
                    if (!context.mounted) return;
                    if (result.failed > 0) {
                      AppToast.show(
                        context,
                        l10n.settingsCacheCleared(
                          ByteSize.format(result.bytes),
                          result.deferred,
                          result.failed,
                        ),
                        tone: ToastTone.error,
                      );
                    } else {
                      _done(context);
                    }
                  } catch (_) {
                    if (context.mounted)
                      AppToast.show(
                        context,
                        l10n.settingsCacheLocationInvalid,
                        tone: ToastTone.error,
                      );
                  }
                },
        ),
      ],
    );
  }
}

/// 一次性操作行：不可用时整行半透明。
class _ActionTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onTap;

  const _ActionTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: SettingsTile(
        title: title,
        subtitle: subtitle,
        trailing: Icon(
          icon,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        onTap: onTap,
      ),
    );
  }
}
