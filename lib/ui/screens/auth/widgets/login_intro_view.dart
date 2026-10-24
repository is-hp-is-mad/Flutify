import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';

import '../../../../providers/auth_provider.dart';
import 'auth_error_banner.dart';
import 'login_hero.dart';

/// 登录页的初始态：主视觉 + 标题 + 三条安心说明 + 「登录」主按钮。
///
/// 点按后由 [onSignIn] 打开应用内统一登录页（WebLoginScreen）：用户只在官方登录页登录一次，
/// 全曲播放凭据（sp_dc）与桌面授权都在后台自动完成，不再跳系统浏览器。
class LoginIntroView extends StatelessWidget {
  final VoidCallback onSignIn;

  const LoginIntroView({super.key, required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final error = context.select<AuthProvider, String?>((a) => a.error);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: LoginHero()),
        const SizedBox(height: 36),
        Text(
          context.l10n.loginTitle,
          textAlign: TextAlign.center,
          style: theme.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -1.2,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          context.l10n.loginSubtitle,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 28),
        const _ReassuranceCard(),
        const SizedBox(height: 28),
        SizedBox(
          height: 60,
          child: M3EButton.icon(
            size: M3EButtonSize.md,
            onPressed: onSignIn,
            icon: const Icon(Icons.login_rounded, size: 22),
            label: Text(context.l10n.accountSignIn),
          ),
        ),
        AuthErrorBanner(message: error),
        const SizedBox(height: 20),
        Text(
          context.l10n.loginTermsNotice,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant.withAlpha(170),
          ),
        ),
      ],
    );
  }
}

/// 三条安心说明，放在一张大圆角浅色调卡片里（MD3E 的容器层级）。
class _ReassuranceCard extends StatelessWidget {
  const _ReassuranceCard();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Column(
          children: [
            _Point(
              icon: Icons.verified_user_rounded,
              text: context.l10n.loginPasswordPrivate,
            ),
            _Point(
              icon: Icons.account_circle_outlined,
              text: context.l10n.loginOfficialPage,
            ),
            _Point(
              icon: Icons.devices_rounded,
              text: context.l10n.loginRemoteDevices,
            ),
          ],
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Point({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              size: 18,
              color: colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
