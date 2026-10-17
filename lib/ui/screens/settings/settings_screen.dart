import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../services/auth/web_token_service.dart';
import '../../shell/shell_breakpoints.dart';
import 'sections/about_section.dart';
import 'sections/animation_debug_section.dart';
import 'sections/update_section.dart';
import 'sections/accent_section.dart';
import 'sections/appearance_section.dart';
import 'sections/connect_section.dart';
import 'sections/glass_section.dart';
import 'sections/language_section.dart';
import 'sections/lyrics_section.dart';
import 'sections/motion_section.dart';
import 'sections/network_section.dart';
import 'sections/playback_section.dart';
import 'sections/privacy_section.dart';
import 'sections/startup_section.dart';
import 'sections/storage_section.dart';
import 'sections/taskbar_lyrics_section.dart';
import 'sections/text_shape_section.dart';
import 'widgets/account_card.dart';
import 'widgets/web_login_card.dart';

/// 账号区卡片：账号卡片 + （有 Web token 服务时）全曲播放 Web 登录卡片。
/// 测试中不注入 WebTokenService，Web 登录卡片自动省略。
List<Widget> _accountCards(BuildContext context) => [
      const AccountCard(),
      if (context.read<WebTokenService?>() != null) ...[
        const SizedBox(height: 12),
        const WebLoginCard(),
      ],
    ];

/// 设置页（单列顺序）：账号 → 播放 → 歌词 → 外观 → 强调色 → 液态玻璃 → 文字与形状 → 动效
/// → 动画调试（临时）→ 语言 → Spotify Connect → 网络 → 存储 → 隐私 → 启动 → 关于。
///
/// 所有设置项修改后即时生效、自动保存，无需「保存」按钮。按窗口形态分两套布局：
/// - 移动端：iOS「设置」式单列分组，顶部 AppBar 带返回；
/// - 桌面端：嵌在主框架内容区（顶栏负责后退），大标题 + 横向设置行
///   （标题在左、控件在右）；内容区足够宽时分为左右两栏。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// 桌面端推入内容区时的路由名，用于避免重复打开。
  static const String routeName = '/settings';

  @override
  Widget build(BuildContext context) {
    final desktop = ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width);
    return desktop ? const _DesktopSettings() : const _MobileSettings();
  }
}

/// 单列布局（移动端、窄桌面）的分组顺序：常用的播放 / 歌词在前，一次性操作（存储、隐私）与关于在后。
const List<Widget> _singleColumn = [
  PlaybackSection(),
  LyricsSection(),
  TaskbarLyricsSection(),
  AppearanceSection(),
  AccentSection(),
  GlassSection(),
  TextShapeSection(),
  MotionSection(),
  AnimationDebugSection(),
  LanguageSection(),
  ConnectSection(),
  NetworkSection(),
  StorageSection(),
  PrivacySection(),
  StartupSection(),
  UpdateSection(),
  AboutSection(),
];

/// 移动端：单列、限宽 720（平板横屏时不拉得过长）。
class _MobileSettings extends StatelessWidget {
  const _MobileSettings();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.commonSettings)),
      body: SafeArea(
        top: false, // AppBar already consumes the status bar inset.
        bottom: false, // Included in the scroll padding below.
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              // 末尾留白 = 底部播放栏 / 导航占位（MediaQuery 底部 padding）+ 基础间距
              padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.paddingOf(context).bottom + 40),
              children: [..._accountCards(context), const SizedBox(height: 28), ..._singleColumn],
            ),
          ),
        ),
      ),
    );
  }
}

/// 桌面端：内容区内水平居中的大标题页面（标题与内容列左边对齐）。
///
/// - 内容区宽 ≥ [_twoColumnWidth]：左栏「账号 / 外观 / 文字与形状 / 动效 / 歌词 / 语言 / 网络 / 启动 / 关于」，
///   右栏「播放 / 强调色 / 液态玻璃 / Spotify Connect / 存储 / 隐私」（玻璃带预览，较高），两栏高度大致平衡；
/// - 更窄时单列，限宽 [_singleColumnMaxWidth]。
class _DesktopSettings extends StatelessWidget {
  const _DesktopSettings();

  static const double _twoColumnWidth = 1040;
  static const double _singleColumnMaxWidth = 760;
  static const double _twoColumnMaxWidth = 1240;
  static const double _columnGap = 24;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final twoColumns = constraints.maxWidth >= _twoColumnWidth;
          final body = twoColumns
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ..._accountCards(context),
                          const SizedBox(height: 28),
                          const AppearanceSection(),
                          const TextShapeSection(),
                          const MotionSection(),
                          const AnimationDebugSection(),
                          const LyricsSection(),
                          const TaskbarLyricsSection(),
                          const LanguageSection(),
                          const NetworkSection(),
                          const StartupSection(),
                          const UpdateSection(),
                          const AboutSection(),
                        ],
                      ),
                    ),
                    const SizedBox(width: _columnGap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: const [
                          PlaybackSection(),
                          AccentSection(),
                          GlassSection(),
                          ConnectSection(),
                          StorageSection(),
                          PrivacySection(),
                        ],
                      ),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [..._accountCards(context), const SizedBox(height: 28), ..._singleColumn],
                );

          return SingleChildScrollView(
            // 末尾留白 = 悬浮播放栏占位（MediaQuery 底部 padding）+ 基础间距
            padding: EdgeInsets.fromLTRB(32, 28, 32, MediaQuery.paddingOf(context).bottom + 48),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: twoColumns ? _twoColumnMaxWidth : _singleColumnMaxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      context.l10n.commonSettings,
                      style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.5),
                    ),
                    const SizedBox(height: 24),
                    body,
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
