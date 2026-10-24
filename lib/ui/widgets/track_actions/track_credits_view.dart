import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../models/artist.dart';
import '../../../models/track.dart';
import '../../../models/track_credits.dart';
import '../../../services/spotify_api_service.dart';
import '../../navigation/app_routes.dart';
import '../../shell/shell_breakpoints.dart';

/// 「查看制作人员」：按角色分组列出参与者（表演者、作曲和作词、制作兼工程…）与版权来源。
///
/// 桌面端为居中的大圆角对话框，移动端为底部面板，内容相同。
/// 在 Spotify 上有艺人页的参与者可点击进入艺人页（先关闭弹窗）。
class TrackCreditsView extends StatefulWidget {
  final SpotifyTrack track;

  /// 打开弹窗前的页面 context，用于关闭弹窗后导航到艺人页。
  final BuildContext hostContext;

  const TrackCreditsView({super.key, required this.track, required this.hostContext});

  static Future<void> show(BuildContext context, SpotifyTrack track) {
    final view = TrackCreditsView(track: track, hostContext: context);
    if (ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width)) {
      return showDialog(
        context: context,
        builder: (_) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640), child: view),
        ),
      );
    }
    return showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85),
        child: SafeArea(top: false, child: view),
      ),
    );
  }

  @override
  State<TrackCreditsView> createState() => _TrackCreditsViewState();
}

class _TrackCreditsViewState extends State<TrackCreditsView> {
  late Future<TrackCredits> _future = _load();

  Future<TrackCredits> _load() => context.read<SpotifyApiService>().getTrackCredits(widget.track.id);

  void _retry() => setState(() => _future = _load());

  void _openArtist(CreditPerson person) {
    Navigator.of(context).pop();
    final host = widget.hostContext;
    if (host.mounted) AppRoutes.openArtist(host, SpotifyArtist(id: person.artistId, name: person.name));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.creditsTitle,
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.track.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Flexible(
          child: FutureBuilder<TrackCredits>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: M3ELoadingIndicator()),
                );
              }
              if (snapshot.hasError) {
                return _Message(
                  text: snapshot.error.toString(),
                  action: M3EButton.text(onPressed: _retry, child: Text(l10n.commonRetry)),
                );
              }
              final credits = snapshot.data!;
              if (credits.isEmpty) return _Message(text: l10n.creditsEmpty);
              return ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                children: [
                  for (final group in credits.groups) ...[
                    if (group.name.isNotEmpty) _SectionTitle(group.name),
                    for (final person in group.people)
                      _PersonRow(person: person, onTap: person.hasArtistPage ? () => _openArtist(person) : null),
                    const SizedBox(height: 8),
                  ],
                  if (credits.sources.isNotEmpty) ...[
                    _SectionTitle(l10n.creditsSources),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: Text(
                        credits.sources.join('\n'),
                        style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant, height: 1.5),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 分组标题：强调色、粗体小标题。
class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w800),
      ),
    );
  }
}

/// 一位参与者：首字母圆章 + 姓名 + 角色；有艺人页时整行可点、右侧带箭头。
class _PersonRow extends StatelessWidget {
  final CreditPerson person;
  final VoidCallback? onTap;

  const _PersonRow({required this.person, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final initial = person.name.characters.first.toUpperCase();

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        mouseCursor: onTap == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: colorScheme.secondaryContainer,
                foregroundColor: colorScheme.onSecondaryContainer,
                child: Text(initial, style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      person.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (person.roles.isNotEmpty)
                      Text(
                        person.roles.join('、'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              if (onTap != null) Icon(Icons.chevron_right_rounded, color: colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// 加载失败 / 无数据时的居中说明（可带操作按钮）。
class _Message extends StatelessWidget {
  final String text;
  final Widget? action;

  const _Message({required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (action != null) ...[const SizedBox(height: 8), action!],
        ],
      ),
    );
  }
}
