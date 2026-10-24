import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/app_preferences.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../../services/lyrics/lyrics_language.dart';
import '../widgets/lyrics_source_order_tile.dart';
import '../widgets/settings_section.dart';
import '../widgets/settings_segmented.dart';
import '../widgets/settings_slider_tile.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton;
import '../../../widgets/flutify_dialog.dart';

/// 歌词：字号、对齐、当前行位置、模糊强度、来源补全、译词预取与全屏偏好。
///
/// 对所有歌词视图生效（右栏、手机歌词面板、全屏播放器、沉浸式歌词，含远程模式）。
class LyricsSection extends StatelessWidget {
  const LyricsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final provider = context.read<PreferencesProvider>();
    final prefs = context.select<PreferencesProvider, AppPreferences>(
      (p) => p.prefs,
    );
    final immersiveScreen = context.select<PreferencesProvider, bool>(
      (p) => p.immersiveScreen,
    );

    return SettingsSection(
      title: l10n.settingsLyricsSection,
      children: [
        SettingsSwitchTile(
          title: l10n.settingsLyricsAutoTranslate,
          subtitle: l10n.settingsLyricsAutoTranslateSubtitle,
          value: prefs.lyricsAutoTranslate,
          onChanged: (v) =>
              provider.update(provider.prefs.copyWith(lyricsAutoTranslate: v)),
        ),
        SettingsSwitchTile(
          title: l10n.settingsLyricsExcludeInterface,
          value: prefs.lyricsExcludeInterfaceLanguage,
          onChanged: (v) => provider.update(
            provider.prefs.copyWith(lyricsExcludeInterfaceLanguage: v),
          ),
        ),
        SettingsTile(
          title: l10n.settingsLyricsExcluded,
          subtitle: prefs.lyricsExcludedLanguages.isEmpty
              ? l10n.settingsLyricsExcludedHint
              : prefs.lyricsExcludedLanguages.join(', '),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _editLanguages(context, provider),
        ),
        SettingsSliderTile(
          title: l10n.settingsLyricsSize,
          value: prefs.lyricsScale,
          min: AppPreferences.minLyricsScale,
          max: AppPreferences.maxLyricsScale,
          divisions: 12,
          minIcon: Icons.text_decrease_rounded,
          maxIcon: Icons.text_increase_rounded,
          labelOf: (v) => '${(v * 100).round()}%',
          onChanged: (v) =>
              provider.update(provider.prefs.copyWith(lyricsScale: v)),
        ),
        SettingsTile(
          title: l10n.settingsLyricsAlign,
          below: SettingsSegmented<LyricsAlign>(
            values: LyricsAlign.values,
            labelOf: (v) => v == LyricsAlign.left
                ? l10n.settingsLyricsAlignLeft
                : l10n.settingsLyricsAlignCenter,
            selected: prefs.lyricsAlign,
            onChanged: (v) =>
                provider.update(provider.prefs.copyWith(lyricsAlign: v)),
          ),
        ),
        SettingsSliderTile(
          title: l10n.settingsLyricsFocusPosition,
          subtitle: l10n.settingsLyricsFocusPositionSubtitle,
          value: prefs.lyricsFocusPosition,
          min: AppPreferences.minLyricsFocusPosition,
          max: AppPreferences.maxLyricsFocusPosition,
          divisions: 30,
          minIcon: Icons.vertical_align_top_rounded,
          maxIcon: Icons.vertical_align_bottom_rounded,
          labelOf: (v) => '${(v * 100).round()}%',
          onChanged: (v) =>
              provider.update(provider.prefs.copyWith(lyricsFocusPosition: v)),
        ),
        SettingsSwitchTile(
          title: l10n.settingsLyricsFallback,
          subtitle: l10n.settingsLyricsFallbackSubtitle,
          value: prefs.lyricsFallback,
          onChanged: (v) =>
              provider.update(provider.prefs.copyWith(lyricsFallback: v)),
        ),
        LyricsSourceOrderTile(
          order: prefs.lyricsSourceOrder,
          lrclibEnabled: prefs.lyricsFallback,
          onChanged: (order) => provider.update(
            provider.prefs.copyWith(lyricsSourceOrder: order),
          ),
        ),
        SettingsSwitchTile(
          title: l10n.settingsLyricsBilingual,
          subtitle: l10n.settingsLyricsBilingualSubtitle,
          value: prefs.lyricsBilingual,
          onChanged: (v) =>
              provider.update(provider.prefs.copyWith(lyricsBilingual: v)),
        ),
        SettingsSwitchTile(
          title: l10n.settingsLyricsImmersiveScreen,
          subtitle: l10n.settingsLyricsImmersiveScreenSubtitle,
          value: immersiveScreen,
          onChanged: provider.setImmersiveScreen,
        ),
      ],
    );
  }

  Future<void> _editLanguages(
    BuildContext context,
    PreferencesProvider provider,
  ) async {
    var input = provider.prefs.lyricsExcludedLanguages.join(', ');
    final form = GlobalKey<FormState>();
    final l10n = context.l10n;
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => FlutifyDialog(
        title: l10n.settingsLyricsExcluded,
        content: Material(type: MaterialType.transparency, child: Form(
          key: form,
          child: TextFormField(
            initialValue: input,
            onChanged: (value) => input = value,
            autofocus: true,
            decoration: InputDecoration(
              helperText: l10n.settingsLyricsExcludedHint,
              helperMaxLines: 3,
            ),
            validator: (value) =>
                _languages(value ?? '').every(
                  (code) =>
                      RegExp(r'^[a-z]{2,3}(?:-[A-Za-z]{2,4})?$').hasMatch(code),
                )
                ? null
                : l10n.settingsLyricsExcludedInvalid,
          ),
        )),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          M3EButton.filled(
            onPressed: () {
              if (form.currentState!.validate())
                Navigator.pop(context, _languages(input));
            },
            child: Text(MaterialLocalizations.of(context).saveButtonLabel),
          ),
        ]),
    );
    if (context.mounted && result != null)
      provider.update(
        provider.prefs.copyWith(
          lyricsExcludedLanguages: List.unmodifiable(result),
        ),
      );
  }

  List<String> _languages(String value) => value
      .toLowerCase()
      .split(RegExp(r'[,，\s]+'))
      .where((v) => v.isNotEmpty)
      .map((v) => v.replaceAll('_', '-'))
      .map(
        (v) => RegExp(r'^[a-z]{2,3}(?:-[a-z]{2,4})?$').hasMatch(v)
            ? LyricsLanguage.normalize(v)
            : v,
      )
      .toSet()
      .toList();
}
