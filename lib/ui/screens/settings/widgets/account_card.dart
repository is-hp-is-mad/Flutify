import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';
import '../../../../providers/auth_provider.dart';
import '../../../widgets/user_avatar.dart';
import '../../auth/login_screen.dart';
import '../../auth/widgets/flutify_mark.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import '../../../widgets/flutify_dialog.dart';

/// 设置页顶部的 Spotify 账号卡片。
///
/// - 未登录：品牌标 + 一句说明 + 「登录」；
/// - 已登录：头像、用户名与「退出登录」（令牌由后台自动续期，不向用户暴露）。
class AccountCard extends StatelessWidget {
  const AccountCard({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: context.tokens.radius(20),
      ),
      child: AnimatedSize(
        duration: context.motion(const Duration(milliseconds: 220)),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: auth.isSignedIn ? _SignedIn(auth: auth) : const _SignedOut(),
      ),
    );
  }
}

class _SignedOut extends StatelessWidget {
  const _SignedOut();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Row(
      children: [
        const FlutifyMark(size: 48, glow: false),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.accountTitle, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(
                l10n.accountSignedOutMessage,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        M3EButton.filled(onPressed: () => LoginScreen.open(context), child: Text(l10n.accountSignIn)),
      ],
    );
  }
}

class _SignedIn extends StatelessWidget {
  final AuthProvider auth;

  const _SignedIn({required this.auth});

  Future<void> _confirmSignOut(BuildContext context) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => FlutifyDialog(
        title: l10n.accountSignOutTitle,
        content: Material(type: MaterialType.transparency, child: Text(l10n.accountSignOutMessage)),
        actions: [
          M3EButton.text(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.commonCancel)),
          M3EButton.text(
            onPressed: () => Navigator.pop(ctx, true),
            decoration: M3EButtonDecoration(
              foregroundColor: WidgetStatePropertyAll(Theme.of(ctx).colorScheme.error),
            ),
            child: Text(l10n.accountSignOutConfirm),
          ),
        ]),
    );
    if (confirmed == true) await auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    final name = auth.displayName;

    return Row(
      children: [
        const UserAvatar(size: 52),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                l10n.accountTitle,
                style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        M3EButton.outlined(
          onPressed: () => _confirmSignOut(context),
          decoration: M3EButtonDecoration(
            foregroundColor: WidgetStatePropertyAll(colorScheme.error),
          ),
          child: Text(l10n.accountSignOut),
        ),
      ],
    );
  }
}
