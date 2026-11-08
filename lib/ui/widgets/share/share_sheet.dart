import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../../models/share_target.dart';
import '../../shell/shell_breakpoints.dart';
import '../cover_image.dart';
import 'embed_code_panel.dart';
import 'share_action_tile.dart';
import '../app_modal.dart';

/// 分享面板：曲目 / 专辑 / 歌单 / 艺人共用。
///
/// - 桌面端：居中对话框（最宽 [maxWidth]）；
/// - 移动端：底部面板，可拖动关闭。
/// 内容为：头部（封面 + 标题 + 类型）→ 快捷操作（复制链接 / 复制 URI / 网页打开）→ 嵌入代码。
/// 所有反馈都在面板内就地完成，不再弹 SnackBar。
class ShareSheet extends StatelessWidget {
  final ShareTarget target;

  /// 桌面对话框中显示右上角关闭按钮。
  final bool showClose;

  const ShareSheet({super.key, required this.target, this.showClose = false});

  /// 对话框最大宽度。
  static const double maxWidth = 520;

  static Future<void> show(BuildContext context, ShareTarget target) {
    if (ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width)) {
      final tokens = context.tokens;
      return showAppDialog<void>(
        context: context,
        useRootNavigator: true,
        builder: (dialogContext) => AppDialog(
          backgroundColor: Theme.of(
            dialogContext,
          ).colorScheme.surfaceContainerHigh,
          borderRadius: tokens.radius(28),
          insetPadding: const EdgeInsets.all(24),
          child: SizedBox(
            width: maxWidth,
            child: ShareSheet(target: target, showClose: true),
          ),
        ),
      );
    }
    return showAppBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => ShareSheet(target: target),
    );
  }

  /// 用系统浏览器打开网页链接；失败时返回链接文本，由卡片退回为复制。
  Future<String?> _openWeb() async {
    final ok = await launchUrl(
      Uri.parse(target.webUrl),
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
    return ok ? null : target.webUrl;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // 底部面板顶部已有拖动条，桌面对话框需要自己的上边距
    final top = showClose ? 24.0 : 0.0;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.9;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, top, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ShareHeader(target: target, showClose: showClose),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: ShareActionTile(
                      icon: Icons.link_rounded,
                      label: l10n.shareCopyLink,
                      copyText: target.webUrl,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ShareActionTile(
                      icon: Icons.tag_rounded,
                      label: l10n.shareCopyUri,
                      copyText: target.uri,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ShareActionTile(
                      icon: Icons.open_in_new_rounded,
                      label: l10n.shareOpenWeb,
                      onTap: _openWeb,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              EmbedCodePanel(target: target),
            ],
          ),
        ),
      ),
    );
  }
}

/// 头部：封面（艺人为圆形）+ 标题 + 「类型 · 副标题」，桌面端右侧关闭按钮。
class _ShareHeader extends StatelessWidget {
  final ShareTarget target;
  final bool showClose;

  const _ShareHeader({required this.target, required this.showClose});

  String _kindLabel(BuildContext context) {
    final l10n = context.l10n;
    return switch (target.kind) {
      ShareKind.track => l10n.typeTrack,
      ShareKind.album => l10n.typeAlbum,
      ShareKind.playlist => l10n.typePlaylist,
      ShareKind.artist => l10n.typeArtist,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final isArtist = target.kind == ShareKind.artist;
    final kind = _kindLabel(context);
    final meta = target.subtitle.isEmpty
        ? kind
        : context.l10n.subtitleJoin(kind, target.subtitle);

    return Row(
      children: [
        CoverImage(
          url: target.imageUrl,
          size: 60,
          circular: isArtist,
          borderRadius: tokens.radius(12),
          placeholderIcon: isArtist
              ? Icons.person_rounded
              : Icons.music_note_rounded,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                target.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (showClose)
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
      ],
    );
  }
}
