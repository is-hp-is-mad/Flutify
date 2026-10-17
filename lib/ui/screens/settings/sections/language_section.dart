import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/app_preferences.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../../providers/spotify_provider.dart';
import '../widgets/settings_section.dart';

/// 语言：跟随系统 / 简繁中文 / English / 日本語。
///
/// 切换后界面立即换语言；主页等由 Spotify 本地化的内容在下一帧（Accept-Language 已更新后）重新拉取。
class LanguageSection extends StatefulWidget {
  const LanguageSection({super.key});

  @override
  State<LanguageSection> createState() => _LanguageSectionState();
}

class _LanguageSectionState extends State<LanguageSection> {
  final _focusNode = FocusNode();
  bool _open = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _change(BuildContext context, AppLanguage language) {
    final provider = context.read<PreferencesProvider>();
    if (provider.prefs.language == language) return;
    final spotify = context.read<SpotifyProvider>();
    provider.update(provider.prefs.copyWith(language: language));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => spotify.loadInitialData(),
    );
  }

  /// 按钮点击：开合语言菜单。
  ///
  /// 只信 [MenuController] 自己的状态，不看本地的 [_open]——两者一旦不一致
  /// （例如菜单被外部关闭后 overlay 先于 `onClose` 掉落），本地状态会把这一次点击
  /// 当成「关闭」，于是按钮看着没反应：菜单不开、界面也不换语言。
  ///
  /// 菜单锚在按钮上，展开后第一项正对按钮中心：命中测试里菜单项会盖住按钮，落在
  /// 中心点的真实点击由菜单项吃掉。所以按钮在整个展开期间都收不到点击，开合只能
  /// 交给菜单项和 [MenuAnchor] 自己的 `onClose`。`_open` 也要在开启时立刻置位，
  /// 别等回调——否则箭头图标会晚一帧才翻转。
  void _toggleMenu(MenuController controller) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    _open = true;
    controller.open();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final radius = context.tokens.radius(16);
    final language = context.select<PreferencesProvider, AppLanguage>(
      (p) => p.prefs.language,
    );
    String label(AppLanguage value) => switch (value) {
      AppLanguage.system => l10n.settingsLanguageSystem,
      AppLanguage.zh => l10n.settingsLanguageZh,
      AppLanguage.zhHant => l10n.settingsLanguageZhHant,
      AppLanguage.en => l10n.settingsLanguageEn,
      AppLanguage.ja => l10n.settingsLanguageJa,
    };

    return SettingsSection(
      title: l10n.settingsLanguageSection,
      children: [
        SettingsTile(
          title: l10n.settingsLanguage,
          subtitle: l10n.settingsLanguageSubtitle,
          below: LayoutBuilder(
            builder: (context, constraints) => MenuAnchor(
              childFocusNode: _focusNode,
              crossAxisUnconstrained: false,
              alignmentOffset: const Offset(0, 4),
              onOpen: () => setState(() => _open = true),
              onClose: () => setState(() => _open = false),
              style: MenuStyle(
                minimumSize: WidgetStatePropertyAll(
                  Size(constraints.maxWidth, 0),
                ),
                maximumSize: WidgetStatePropertyAll(
                  Size(constraints.maxWidth, double.infinity),
                ),
                backgroundColor: WidgetStatePropertyAll(
                  colors.surfaceContainer,
                ),
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(borderRadius: radius),
                ),
                padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
              ),
              menuChildren: [
                for (final value in AppLanguage.values)
                  MenuItemButton(
                    onPressed: () => _change(context, value),
                    trailingIcon: language == value
                        ? const Icon(Icons.check_rounded)
                        : const SizedBox(width: 24),
                    style: MenuItemButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      backgroundColor: language == value
                          ? colors.secondaryContainer
                          : null,
                      foregroundColor: language == value
                          ? colors.onSecondaryContainer
                          : colors.onSurface,
                      shape: RoundedRectangleBorder(
                        borderRadius: context.tokens.radius(12),
                      ),
                    ),
                    child: Text(label(value)),
                  ),
              ],
              builder: (context, controller, child) => Semantics(
                label: l10n.settingsLanguage,
                expanded: _open,
                child: FilledButton(
                  key: const ValueKey('interface-language'),
                  focusNode: _focusNode,
                  onPressed: () => _toggleMenu(controller),
                  style:
                      FilledButton.styleFrom(
                        backgroundColor: colors.surfaceContainerHighest,
                        foregroundColor: colors.onSurface,
                        textStyle: theme.textTheme.bodyLarge,
                        minimumSize: const Size.fromHeight(56),
                        padding: const EdgeInsets.all(16),
                        shape: RoundedRectangleBorder(borderRadius: radius),
                      ).copyWith(
                        side: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.focused)
                              ? BorderSide(color: colors.primary, width: 2)
                              : BorderSide.none,
                        ),
                      ),
                  child: Row(
                    children: [
                      const Icon(Icons.language_rounded),
                      const SizedBox(width: 12),
                      Expanded(child: Text(label(language))),
                      const SizedBox(width: 12),
                      Icon(
                        _open
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
