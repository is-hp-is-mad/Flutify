import 'package:flutter/material.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/lyrics.dart';

/// 歌词页底部的「歌词来源」小字。
///
/// 与歌词列表处于同一滚动子树，位置由歌词页统一排版；本组件只负责文字本身的变化：
/// 原文与译词同源时合并为一段，异源时拆成两段，并在切换时按传入曲线做交叉淡入淡出，
/// 时长 / 曲线与切行滚动一致，所以两行歌词之间的换行和它看起来是同一块在动。
class LyricsSourceLabel extends StatelessWidget {
  /// 要显示的一到两行来源文案（原文在前，译词在后）。
  final List<String> lines;
  final double fontSize;
  final Duration duration;
  final Curve curve;

  const LyricsSourceLabel({
    super.key,
    required this.lines,
    required this.fontSize,
    required this.duration,
    required this.curve,
  });

  /// 原文来源文案；[provider] 为 null（尚未解析到时）返回 null。
  static String? textOf(BuildContext context, LyricsProvider? provider) {
    final l10n = context.l10n;
    return switch (provider) {
      LyricsProvider.lrclib => l10n.lyricsFromLrclib,
      LyricsProvider.qqMusic => l10n.lyricsFromQqMusic,
      LyricsProvider.netease => l10n.lyricsFromNetease,
      _ => null,
    };
  }

  /// 译词来源文案。
  ///
  /// Spotify 自带译文来源随原文（同一份歌词记录里的翻译轨），沿用原文文案；
  /// 其余按译文实际来源标注——只按原文来源推断标注译文是错的。
  static String? translationOf(BuildContext context, LyricsProvider? provider) {
    final l10n = context.l10n;
    return switch (provider) {
      LyricsProvider.qqMusic => l10n.lyricsTranslationFromQqMusic,
      LyricsProvider.netease => l10n.lyricsTranslationFromNetease,
      LyricsProvider.spotify => l10n.lyricsFromSpotify,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final key = ValueKey<String>(lines.join('\u0000'));
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: curve,
        switchOutCurve: curve,
        child: key.value.isEmpty
            ? const SizedBox.shrink(key: ValueKey<String>(''))
            : Column(
                key: key,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in lines)
                    Text(
                      line,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: fontSize,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
