import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../services/widget/widget_bridge.dart';
import '../../../widgets/toast/app_toast.dart';
import '../widgets/settings_section.dart';

/// 桌面小组件（Android）：列出 4 款，点「添加」由桌面弹窗确认后直接放到桌面。
///
/// 澎湃 OS 里经典小组件藏在小组件列表底部的「安卓小部件」分区，不好找，这里提供直接添加。
/// 没有小组件桥（非 Android、测试）时不显示整个分组。
class HomeWidgetsSection extends StatelessWidget {
  const HomeWidgetsSection({super.key});

  static WidgetBridge? _bridge(BuildContext context) {
    try {
      return context.read<WidgetBridge?>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bridge = _bridge(context);
    if (bridge == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    Widget tile(HomeWidgetStyle style, String title, String subtitle) =>
        SettingsTile(
          title: title,
          subtitle: subtitle,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_to_home_screen_rounded, color: muted, size: 20),
              const SizedBox(width: 6),
              Text(l10n.homeWidgetAdd, style: TextStyle(color: muted)),
            ],
          ),
          onTap: () => _pin(context, bridge, style),
        );

    return SettingsSection(
      title: l10n.settingsHomeWidgetsSection,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Text(
            l10n.settingsHomeWidgetsSubtitle,
            style: TextStyle(color: muted, fontSize: 13),
          ),
        ),
        tile(
          HomeWidgetStyle.nowPlaying,
          l10n.homeWidgetNowPlaying,
          l10n.homeWidgetNowPlayingDesc,
        ),
        tile(
          HomeWidgetStyle.albumCard,
          l10n.homeWidgetAlbumCard,
          l10n.homeWidgetAlbumCardDesc,
        ),
        tile(
          HomeWidgetStyle.cover,
          l10n.homeWidgetCover,
          l10n.homeWidgetCoverDesc,
        ),
        tile(
          HomeWidgetStyle.upNext,
          l10n.homeWidgetUpNext,
          l10n.homeWidgetUpNextDesc,
        ),
      ],
    );
  }

  static Future<void> _pin(
    BuildContext context,
    WidgetBridge bridge,
    HomeWidgetStyle style,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final unsupported = context.l10n.homeWidgetPinUnsupported;
    // 接受后由桌面弹窗确认，这里不再提示；只在桌面不支持时告诉用户去哪儿加
    if (!await bridge.requestPin(style)) {
      AppToast.showOn(messenger, unsupported, tone: ToastTone.warning);
    }
  }
}
